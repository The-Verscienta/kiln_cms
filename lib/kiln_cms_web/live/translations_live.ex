defmodule KilnCMSWeb.TranslationsLive do
  @moduledoc """
  The **translation coverage dashboard** (`/editor/translations`): every piece
  of content grouped by `(type, slug)` with one chip per configured locale —
  published / draft / in review / missing — plus an *Outdated* marker when the
  default-locale source moved on after a translation's last edit. Existing
  variants link to their editor; a missing chip creates the draft translation
  in place. Editor-gated; only meaningful (and only linked in the nav) when
  more than one locale is configured.

  It is also the **translation-vendor seam** (#502): pick a target locale, tick
  the rows to send out, and the export link hands
  `KilnCMSWeb.TranslationsExportController` an XLIFF 2.0 document; the file
  that comes back is uploaded here and applied through `KilnCMS.CMS.Xliff`.
  The import result is rendered in full rather than flashed, because "which
  units did not land" is the question an operator actually has after an import
  and a flash message cannot answer it.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Translations
  alias KilnCMS.CMS.Xliff
  alias KilnCMS.I18n

  # Rows scanned per content type — recent content first; a site with more
  # translated slugs than this sees the newest window, which is what a
  # translation team works from.
  @per_type_limit 200

  # `KilnCMS.CMS.Xliff` owns what an export is, cap included — the link would
  # 400 past it, and this page must not offer a download that fails on click.
  @max_export_rows Xliff.max_batch()

  # The parser refuses anything larger anyway (`Xliff.Document`), so the upload
  # is capped at the same number and the operator hears about it before the
  # bytes travel rather than after.
  @max_upload_bytes 16 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Translations"))
     |> assign(:locales, I18n.locales())
     |> assign(:default_locale, I18n.default_locale())
     |> assign(:vendor_locale, default_vendor_locale())
     |> assign(:selected, MapSet.new())
     |> assign(:import_reports, nil)
     |> allow_upload(:xliff,
       accept: ~w(.xlf .xliff .xml),
       max_entries: 1,
       max_file_size: @max_upload_bytes
     )
     |> load_rows()}
  end

  # The first locale that is not the default — the common case is one extra
  # locale, and then this dashboard needs no configuring at all.
  defp default_vendor_locale do
    Enum.find(I18n.locales(), &(&1 != I18n.default_locale()))
  end

  # A missing chip: create the draft translation from the row's source record
  # and jump straight into its editor.
  @impl true
  def handle_event(
        "create_translation",
        %{"kind" => kind, "id" => id, "locale" => locale},
        socket
      )
      when is_binary(kind) and is_binary(id) and is_binary(locale) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org
    source = ContentTypes.get_record!(kind, id, actor: actor, tenant: org)

    translation =
      Translations.create_translation!(kind, source, locale, actor: actor, tenant: org)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Draft translation created (%{locale}).", locale: locale))
     |> push_navigate(to: ~p"/editor/content/#{kind}/#{translation.id}")}
  rescue
    _error ->
      {:noreply, put_flash(socket, :error, gettext("Couldn't create that translation."))}
  end

  # --- vendor round trip (#502) -----------------------------------------------

  def handle_event("select_vendor_locale", %{"locale" => locale}, socket)
      when is_binary(locale) do
    if locale in socket.assigns.locales and locale != socket.assigns.default_locale do
      {:noreply, assign(socket, :vendor_locale, locale)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_export", %{"key" => key}, socket) when is_binary(key) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, key),
        do: MapSet.delete(selected, key),
        else: MapSet.put(selected, key)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear_export", _params, socket),
    do: {:noreply, assign(socket, :selected, MapSet.new())}

  # `phx-change` on the upload form. Required by `live_file_input`; there is
  # nothing to validate beyond what `allow_upload` already enforces.
  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  def handle_event("import_xliff", _params, socket) do
    scope = [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

    results =
      consume_uploaded_entries(socket, :xliff, fn %{path: path}, entry ->
        {:ok, {entry.client_name, read_and_import(path, scope)}}
      end)

    {:noreply, apply_import_results(socket, results)}
  end

  def handle_event("dismiss_import", _params, socket),
    do: {:noreply, assign(socket, :import_reports, nil)}

  def handle_event("cancel_import", %{"ref" => ref}, socket) when is_binary(ref),
    do: {:noreply, cancel_upload(socket, :xliff, ref)}

  # The upload lives in Phoenix's own temporary directory and is named by it,
  # so the path is never operator- or attacker-supplied.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_and_import(path, scope) do
    case File.read(path) do
      {:ok, xml} -> Xliff.import(xml, scope)
      {:error, reason} -> {:error, {:unreadable_upload, reason}}
    end
  end

  defp apply_import_results(socket, []),
    do: put_flash(socket, :error, gettext("Choose an XLIFF file first."))

  defp apply_import_results(socket, [{name, {:ok, reports}}]) do
    applied = reports |> Enum.map(&length(&1.applied)) |> Enum.sum()

    socket
    |> assign(:import_reports, %{filename: name, reports: reports})
    |> put_flash(
      :info,
      gettext("Imported %{name}: %{count} translations applied.", name: name, count: applied)
    )
    |> load_rows()
  end

  defp apply_import_results(socket, [{name, {:error, reason}}]) do
    socket
    |> assign(:import_reports, nil)
    |> put_flash(
      :error,
      gettext("Couldn't read %{name}: %{reason}.", name: name, reason: import_error(reason))
    )
  end

  defp import_error(:not_an_xliff_file), do: gettext("not an XLIFF 2.0 file")
  defp import_error(:empty_file), do: gettext("the file is empty")
  defp import_error(:missing_locale), do: gettext("the file names no target locale")

  defp import_error({:unknown_locale, locale}),
    do: gettext("%{locale} is not a configured locale", locale: locale)

  defp import_error({:too_large, _size, max}),
    do: gettext("larger than the %{max} MB limit", max: div(max, 1024 * 1024))

  defp import_error({:malformed_xml, _detail}), do: gettext("the XML could not be parsed")
  defp import_error(_other), do: gettext("unreadable")

  defp upload_error_message(:too_large),
    do:
      gettext("That file is larger than the %{max} MB limit.",
        max: div(@max_upload_bytes, 1024 * 1024)
      )

  defp upload_error_message(:not_accepted),
    do: gettext("Only .xlf, .xliff and .xml files can be imported.")

  defp upload_error_message(:too_many_files), do: gettext("Import one file at a time.")
  defp upload_error_message(_other), do: gettext("That file could not be uploaded.")

  # The rows an export can actually be built from: the source has to be in the
  # default locale (that is where a translation job starts) and cannot be the
  # target of its own translation.
  defp exportable?(row, default_locale, vendor_locale),
    do: row.source.locale == default_locale and vendor_locale not in [nil, default_locale]

  # The selection, filtered to what can actually be exported and ordered as the
  # table is. A row that was ticked and then stopped being exportable (the
  # target locale changed to its own source locale) drops out here rather than
  # 400ing on the click.
  defp export_keys(assigns) do
    assigns.rows
    |> Enum.filter(
      &(MapSet.member?(assigns.selected, row_key(&1)) and
          exportable?(&1, assigns.default_locale, assigns.vendor_locale))
    )
    |> Enum.map(&row_key/1)
    |> Enum.split(@max_export_rows)
  end

  defp row_key(row), do: "#{row.kind}:#{row.source.id}"

  defp export_path(target, keys),
    do: ~p"/editor/translations/export.xlf?#{%{"target" => target, "record" => keys}}"

  # --- data -------------------------------------------------------------------

  defp load_rows(socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org
    default = I18n.default_locale()

    # Scope the translation dashboard to the editor's current site (epic #336).
    rows =
      ContentTypes.all_for_org(org.id)
      |> Enum.flat_map(fn ct ->
        ct
        |> ContentTypes.list!(
          actor: actor,
          tenant: org,
          query: [
            select: [:id, :title, :slug, :state, :locale, :updated_at],
            sort: [updated_at: :desc],
            limit: @per_type_limit
          ]
        )
        |> Enum.group_by(& &1.slug)
        |> Enum.map(fn {_slug, records} -> row(ct, records, default) end)
      end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    assign(socket, :rows, rows)
  end

  # One dashboard row per (type, slug): the default-locale record (or the
  # first variant) represents it; each configured locale gets a cell.
  defp row(ct, records, default) do
    by_locale = Map.new(records, &{&1.locale, &1})
    source = by_locale[default] || hd(records)

    cells =
      for locale <- I18n.locales() do
        variant = by_locale[locale]

        %{
          locale: locale,
          record: variant,
          status: if(variant, do: variant.state, else: :missing),
          stale?:
            variant != nil and locale != default and by_locale[default] != nil and
              DateTime.after?(by_locale[default].updated_at, variant.updated_at)
        }
      end

    %{
      kind: ct.type,
      label: ct.label,
      source: source,
      title: source.title,
      updated_at: records |> Enum.map(& &1.updated_at) |> Enum.max(DateTime),
      cells: cells
    }
  end

  defp chip_class(:missing), do: "border-dashed border-base-content/30 text-base-content/50"
  defp chip_class(:published), do: "border-success/40 bg-success/10"
  defp chip_class(:archived), do: "border-base-content/20 text-base-content/50"
  defp chip_class(_draftish), do: "border-warning/40 bg-warning/10"

  defp status_label(:missing), do: gettext("missing")
  defp status_label(:published), do: gettext("published")
  defp status_label(:in_review), do: gettext("in review")
  defp status_label(:archived), do: gettext("archived")
  defp status_label(_draft), do: gettext("draft")

  # --- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    {keys, over_cap} = export_keys(assigns)

    assigns =
      assigns
      |> assign(:export_keys, keys)
      |> assign(:export_overflow, length(over_cap))
      |> assign(:max_export_rows, @max_export_rows)
      |> assign(:vendor_locales, Enum.reject(assigns.locales, &(&1 == assigns.default_locale)))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:translations}
    >
      <div class="mx-auto max-w-5xl space-y-4">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Translations")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Coverage per locale for every piece of content. Click a chip to edit; a missing chip creates the draft translation."
            )}
          </p>
        </div>

        <p :if={length(@locales) < 2} class="text-sm text-base-content/60">
          {gettext("Only one locale is configured — add locales to config :kiln_cms, :i18n.")}
        </p>

        <p :if={@rows == [] and length(@locales) > 1} class="text-sm text-base-content/60">
          {gettext("No content yet.")}
        </p>

        <section
          :if={@vendor_locales != [] and length(@locales) > 1}
          id="xliff"
          class="rounded-lg border border-base-content/10 p-4 space-y-3"
        >
          <div>
            <h2 class="text-sm font-semibold uppercase tracking-wide">
              {gettext("Translation vendors (XLIFF)")}
            </h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Send content out as XLIFF 2.0 and apply the file that comes back. Tick rows below, pick the target locale, then export."
              )}
            </p>
          </div>

          <div class="flex flex-wrap items-end gap-4">
            <form id="xliff-locale" phx-change="select_vendor_locale">
              <label
                for="xliff-target"
                class="block text-xs uppercase tracking-wide text-base-content/60"
              >
                {gettext("Target locale")}
              </label>
              <select
                id="xliff-target"
                name="locale"
                aria-label={gettext("Target locale")}
                class="field-select mt-1 w-auto font-mono"
              >
                <option
                  :for={locale <- @vendor_locales}
                  value={locale}
                  selected={locale == @vendor_locale}
                >
                  {locale}
                </option>
              </select>
            </form>

            <div class="flex items-center gap-2">
              <.link
                :if={@export_keys != []}
                href={export_path(@vendor_locale, @export_keys)}
                download
                class="btn btn-sm btn-primary"
              >
                {gettext("Export %{count} selected", count: length(@export_keys))}
              </.link>
              <span :if={@export_keys == []} class="text-sm text-base-content/60">
                {gettext("Tick a row to export.")}
              </span>
              <button
                :if={@export_keys != []}
                type="button"
                phx-click="clear_export"
                class="btn btn-sm btn-ghost"
              >
                {gettext("Clear")}
              </button>
            </div>

            <form
              id="xliff-import"
              phx-change="validate_import"
              phx-submit="import_xliff"
              class="flex max-w-full flex-wrap items-center gap-2 sm:ml-auto sm:border-l sm:border-base-content/10 sm:pl-4"
            >
              <.live_file_input
                upload={@uploads.xliff}
                class="max-w-full text-sm file:mr-3 file:rounded file:border-0 file:bg-base-content/10 file:px-3 file:py-1.5 file:text-sm file:text-base-content hover:file:bg-base-content/20"
              />
              <button type="submit" class="btn btn-sm btn-default">{gettext("Import XLIFF")}</button>
            </form>
          </div>

          <%!-- `upload_errors/1` only ever returns upload-scoped errors
                (`:too_many_files`); `:too_large` and `:not_accepted` are keyed
                on the ENTRY and need the arity-2 form over a rendered entry.
                Without the entry row an oversized or wrong-typed file showed no
                error at all, could not be cleared, and answered the Import
                button with "choose a file first" while one was plainly
                selected. --%>
          <p :for={error <- upload_errors(@uploads.xliff)} class="text-sm text-error">
            {upload_error_message(error)}
          </p>

          <div
            :for={entry <- @uploads.xliff.entries}
            class="flex flex-wrap items-center gap-2 text-sm"
          >
            <span class="font-mono">{entry.client_name}</span>
            <span :for={error <- upload_errors(@uploads.xliff, entry)} class="text-error">
              {upload_error_message(error)}
            </span>
            <button
              type="button"
              phx-click="cancel_import"
              phx-value-ref={entry.ref}
              class="btn btn-sm btn-ghost"
            >
              {gettext("Remove")}
            </button>
          </div>

          <p :if={@export_overflow > 0} class="text-sm text-warning">
            {gettext(
              "An export is capped at %{max} records — %{over} selected rows are not in this file.",
              max: @max_export_rows,
              over: @export_overflow
            )}
          </p>

          <div :if={@import_reports} class="rounded border border-base-content/10 p-3 text-sm">
            <div class="flex items-start justify-between gap-2">
              <h3 class="font-medium">
                {gettext("Import result — %{filename}", filename: @import_reports.filename)}
              </h3>
              <button type="button" phx-click="dismiss_import" class="btn btn-sm btn-ghost">
                {gettext("Dismiss")}
              </button>
            </div>
            <ul class="mt-2 space-y-1">
              <li :for={report <- @import_reports.reports} class="font-mono text-xs">
                <span class="font-sans">{report.original || gettext("unknown file")}</span>
                <span :if={report.error} class="text-error">
                  — {gettext("failed")}: {inspect(report.error)}
                </span>
                <span :if={is_nil(report.error)}>
                  — {gettext("%{n} applied", n: length(report.applied))}, {gettext("%{n} unchanged",
                    n: length(report.unchanged)
                  )}<span :if={report.created?}>, {gettext("draft created")}</span>
                </span>
                <span :if={report.untranslated != []} class="text-base-content/60">
                  — {gettext("%{n} left untranslated", n: length(report.untranslated))}
                </span>
                <span :if={report.unknown != []} class="text-warning">
                  — {gettext("%{n} unit(s) matched nothing: %{ids}",
                    n: length(report.unknown),
                    ids: Enum.join(Enum.take(report.unknown, 5), ", ")
                  )}
                </span>
                <span :if={report.by_position != []} class="text-warning">
                  — {gettext("%{n} matched by position, not identity — check them",
                    n: length(report.by_position)
                  )}
                </span>
              </li>
            </ul>
          </div>
        </section>

        <div :if={@rows != [] and length(@locales) > 1} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th :if={@vendor_locales != []} class="w-8">
                  <span class="sr-only">{gettext("Export")}</span>
                </th>
                <th>{gettext("Content")}</th>
                <th>{gettext("Type")}</th>
                <th :for={locale <- @locales} class="font-mono">{locale}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"row-#{row.kind}-#{row.source.id}"}>
                <td :if={@vendor_locales != []}>
                  <input
                    type="checkbox"
                    class="size-4 rounded border border-base-content/30 accent-primary disabled:cursor-not-allowed disabled:opacity-30"
                    checked={MapSet.member?(@selected, row_key(row))}
                    disabled={not exportable?(row, @default_locale, @vendor_locale)}
                    title={
                      if(exportable?(row, @default_locale, @vendor_locale),
                        do: gettext("Include in the XLIFF export"),
                        else:
                          gettext("No %{locale} source to translate from", locale: @default_locale)
                      )
                    }
                    phx-click="toggle_export"
                    phx-value-key={row_key(row)}
                  />
                </td>
                <td class="max-w-64 truncate font-medium">{row.title}</td>
                <td class="text-xs uppercase tracking-wide text-base-content/60">
                  {row.label}
                </td>
                <td :for={cell <- row.cells}>
                  <.link
                    :if={cell.record}
                    navigate={~p"/editor/content/#{row.kind}/#{cell.record.id}"}
                    class={[
                      "inline-flex items-center gap-1 rounded border px-2 py-0.5 text-xs hover:opacity-80",
                      chip_class(cell.status)
                    ]}
                  >
                    {status_label(cell.status)}
                    <span
                      :if={cell.stale?}
                      class="rounded bg-warning/20 px-1 text-[10px] font-medium uppercase text-warning"
                      title={gettext("The source locale was updated after this translation.")}
                    >
                      {gettext("Outdated")}
                    </span>
                  </.link>
                  <button
                    :if={is_nil(cell.record)}
                    type="button"
                    phx-click="create_translation"
                    phx-value-kind={row.kind}
                    phx-value-id={row.source.id}
                    phx-value-locale={cell.locale}
                    class={[
                      "rounded border px-2 py-0.5 text-xs hover:bg-base-200",
                      chip_class(:missing)
                    ]}
                  >
                    + {status_label(:missing)}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
