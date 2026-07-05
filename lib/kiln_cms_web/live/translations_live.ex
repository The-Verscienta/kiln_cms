defmodule KilnCMSWeb.TranslationsLive do
  @moduledoc """
  The **translation coverage dashboard** (`/editor/translations`): every piece
  of content grouped by `(type, slug)` with one chip per configured locale —
  published / draft / in review / missing — plus an *Outdated* marker when the
  default-locale source moved on after a translation's last edit. Existing
  variants link to their editor; a missing chip creates the draft translation
  in place. Editor-gated; only meaningful (and only linked in the nav) when
  more than one locale is configured.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Translations
  alias KilnCMS.I18n

  # Rows scanned per content type — recent content first; a site with more
  # translated slugs than this sees the newest window, which is what a
  # translation team works from.
  @per_type_limit 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Translations"))
     |> assign(:locales, I18n.locales())
     |> load_rows()}
  end

  # A missing chip: create the draft translation from the row's source record
  # and jump straight into its editor.
  @impl true
  def handle_event(
        "create_translation",
        %{"kind" => kind, "id" => id, "locale" => locale},
        socket
      ) do
    actor = socket.assigns.current_user
    source = ContentTypes.get_record!(kind, id, actor: actor)
    translation = Translations.create_translation!(kind, source, locale, actor: actor)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Draft translation created (%{locale}).", locale: locale))
     |> push_navigate(to: ~p"/editor/content/#{kind}/#{translation.id}")}
  rescue
    _error ->
      {:noreply, put_flash(socket, :error, gettext("Couldn't create that translation."))}
  end

  # --- data -------------------------------------------------------------------

  defp load_rows(socket) do
    actor = socket.assigns.current_user
    default = I18n.default_locale()

    rows =
      (ContentTypes.all() ++ ContentTypes.dynamic_all())
      |> Enum.flat_map(fn ct ->
        ct
        |> ContentTypes.list!(
          actor: actor,
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
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
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

        <div :if={@rows != [] and length(@locales) > 1} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("Content")}</th>
                <th>{gettext("Type")}</th>
                <th :for={locale <- @locales} class="font-mono">{locale}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"row-#{row.kind}-#{row.source.id}"}>
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
