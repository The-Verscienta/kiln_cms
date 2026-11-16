defmodule KilnCMSWeb.FieldSyncLive do
  @moduledoc """
  Field definition sync from the console (#2438): upload a
  `kiln-field-definitions` file (`mix kiln.fields.export`, or
  `/editor/fields/export.json`), see what importing it would do, and apply it —
  for an admin who has no shell on the environment. `docs/field-sync.md`.

  It is a thin screen over `KilnCMS.CMS.FieldSync.import_doc/2`; nothing is
  diffed or validated here.

  ## Flow

  1. **Upload.** One `.json` file, at most 2 MB, read
     on submit and checked by content (it must decode to a JSON object), not by
     its extension.
  2. **Preview.** `import_doc(doc, apply?: false)`: the diff (`+ ~ - ?`), the
     refusals that need an explicit flag, and any write the real run would
     refuse. Nothing is written.
  3. **Flags.** *Delete fields the file does not list* (`--prune`) and *allow
     changes that drop stored values* (`--allow-data-loss`) are two separate
     checkboxes, each listing exactly what it unlocks. Both start off, and are
     reset whenever a new file is read. Changing either re-runs the preview and
     cancels a pending confirmation.
  4. **Confirm.** "Apply…" opens a summary; only "Yes, apply these changes"
     writes. It sends the digest of the preview shown (`FieldSync.digest/1`),
     and the import refuses with `:stale` when the site's definitions no longer
     plan the same changes, so what is applied is what was shown. The window
     between that check and the write is not locked against another admin's
     edit of the same field in the same moment; the whole import still runs in
     one transaction.
  5. **Audit.** A successful apply records an `org_setting_changed` security
     event (`setting` `field_definitions`, with the counts and whether pruning
     or data loss was confirmed). A command-line import is not recorded.

  Admin only: the route is in the `:admin_routes` live session, and every event
  re-checks the tier and `import_doc` authorizes again.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.FieldSync
  alias KilnCMS.Security.Recorder

  @max_bytes 2_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Sync field definitions"))
     |> assign(:file_error, nil)
     |> assign(:applied, nil)
     |> reset_preview()
     |> allow_upload(:definitions,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: @max_bytes,
       auto_upload: false
     )}
  end

  defp reset_preview(socket) do
    socket
    |> assign(:doc, nil)
    |> assign(:file_name, nil)
    |> assign(:prune?, false)
    |> assign(:allow?, false)
    |> assign(:confirming?, false)
    |> assign(:preview, nil)
  end

  # --- events ----------------------------------------------------------------

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) when is_binary(ref),
    do: {:noreply, cancel_upload(socket, :definitions, ref)}

  def handle_event("preview", _params, socket) do
    with :ok <- admin(socket),
         [result] <- consume(socket) do
      case result do
        {:ok, name, doc} ->
          {:noreply,
           socket
           |> reset_preview()
           |> assign(:applied, nil)
           |> assign(:file_error, nil)
           |> assign(:file_name, name)
           |> assign(:doc, doc)
           |> run_preview()}

        {:error, message} ->
          {:noreply, socket |> reset_preview() |> assign(:file_error, message)}
      end
    else
      :forbidden ->
        {:noreply, forbidden(socket)}

      [] ->
        {:noreply, assign(socket, :file_error, gettext("Choose a file to preview."))}
    end
  end

  def handle_event("flags", params, socket) do
    with :ok <- admin(socket), true <- socket.assigns.doc != nil do
      {:noreply,
       socket
       |> assign(:prune?, params["prune"] == "true")
       |> assign(:allow?, params["allow_data_loss"] == "true")
       |> assign(:confirming?, false)
       |> run_preview()}
    else
      :forbidden -> {:noreply, forbidden(socket)}
      false -> {:noreply, socket}
    end
  end

  def handle_event("ask_apply", _params, socket) do
    case admin(socket) do
      :ok ->
        {:noreply,
         assign(socket, :confirming?, applicable?(socket.assigns.preview, socket.assigns.allow?))}

      :forbidden ->
        {:noreply, forbidden(socket)}
    end
  end

  def handle_event("cancel_apply", _params, socket),
    do: {:noreply, assign(socket, :confirming?, false)}

  def handle_event("apply", _params, socket) do
    %{preview: preview, doc: doc} = socket.assigns

    with :ok <- admin(socket),
         true <- socket.assigns.confirming? and applicable?(preview, socket.assigns.allow?) do
      case FieldSync.import_doc(doc, opts(socket, apply?: true, expect_digest: preview.digest)) do
        {:ok, report} ->
          audit(socket, report)

          {:noreply,
           socket
           |> reset_preview()
           |> assign(:applied, summary(report))
           |> put_flash(:info, gettext("Field definitions applied."))}

        {:error, :stale} ->
          {:noreply,
           socket
           |> assign(:confirming?, false)
           |> run_preview()
           |> put_flash(
             :error,
             gettext(
               "The site's field definitions changed since this preview. Nothing was applied; review the updated changes."
             )
           )}

        {:error, :forbidden} ->
          {:noreply, forbidden(socket)}

        {:error, report} ->
          {:noreply,
           socket
           |> assign(:confirming?, false)
           |> assign(:preview, slim(report))
           |> put_flash(:error, gettext("Nothing was applied. See the problems below."))}
      end
    else
      :forbidden -> {:noreply, forbidden(socket)}
      false -> {:noreply, assign(socket, :confirming?, false)}
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Re-checked on every event: the socket outlives a role change.
  defp admin(socket) do
    case KilnCMSWeb.LiveUserAuth.effective_tier(socket) do
      :admin -> :ok
      _other -> :forbidden
    end
  end

  defp forbidden(socket) do
    socket
    |> reset_preview()
    |> put_flash(:error, gettext("Only an admin can import field definitions."))
  end

  defp consume(socket) do
    consume_uploaded_entries(socket, :definitions, fn %{path: path}, entry ->
      {:ok, read_document(path, entry.client_name)}
    end)
  end

  # Checked by content: whatever the name says, it must be a JSON object.
  # The path is the upload's own temp file.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_document(path, name) do
    with {:ok, json} <- File.read(path),
         {:ok, %{} = doc} <- Jason.decode(json) do
      {:ok, name, doc}
    else
      _other ->
        {:error, gettext("That file is not a JSON object. Upload a file made by Export.")}
    end
  end

  defp opts(socket, extra) do
    [
      actor: socket.assigns.current_user,
      tenant: socket.assigns.current_org,
      prune?: socket.assigns.prune?,
      allow_data_loss?: socket.assigns.allow?
    ] ++ extra
  end

  defp run_preview(socket) do
    case FieldSync.import_doc(socket.assigns.doc, opts(socket, apply?: false)) do
      {:ok, report} -> assign(socket, :preview, slim(report))
      {:error, :forbidden} -> forbidden(socket)
      {:error, report} -> assign(socket, :preview, slim(report))
    end
  end

  # Only what the screen shows and the digest: the report's stored records
  # stay out of the socket.
  defp slim(report) do
    %{
      digest: FieldSync.digest(report),
      ops:
        for(
          op <- report.ops,
          op.op != :unchanged,
          do: Map.take(op, [:op, :kind, :path, :changes, :attrs])
        ),
      counts: report.counts,
      blocked: report.blocked,
      errors: report.errors,
      untouched: report.untouched
    }
  end

  # Nothing to apply when the file is invalid, refused or already in place.
  defp applicable?(nil, _allow?), do: false

  # A blocked change is listed either way; it only stops the apply until the
  # admin has allowed data loss.
  defp applicable?(preview, allow?) do
    preview.errors == [] and (preview.blocked == [] or allow?) and changes(preview) > 0
  end

  defp changes(%{counts: counts}),
    do: Map.get(counts, :create, 0) + Map.get(counts, :update, 0) + Map.get(counts, :delete, 0)

  defp summary(report) do
    %{
      created: Map.get(report.counts, :create, 0),
      updated: Map.get(report.counts, :update, 0),
      deleted: Map.get(report.counts, :delete, 0)
    }
  end

  defp audit(socket, report) do
    %{created: c, updated: u, deleted: d} = summary(report)

    Recorder.record_after_commit(:org_setting_changed,
      tenant: socket.assigns.current_org.id,
      user: socket.assigns.current_user,
      request: socket.assigns.security_context[Recorder.context_key()],
      metadata: %{
        "setting" => "field_definitions",
        "created" => c,
        "updated" => u,
        "deleted" => d,
        "prune" => socket.assigns.prune?,
        "data_loss" => socket.assigns.allow?
      }
    )
  end

  defp upload_error_text(:too_large), do: gettext("That file is larger than 2 MB.")
  defp upload_error_text(:not_accepted), do: gettext("Only a .json file can be imported.")
  defp upload_error_text(:too_many_files), do: gettext("Choose one file.")
  defp upload_error_text(_other), do: gettext("That file could not be uploaded.")

  defp op_label(%{op: :create}), do: gettext("Create")
  defp op_label(%{op: :update}), do: gettext("Update")
  defp op_label(%{op: :delete}), do: gettext("Delete")
  defp op_label(%{op: :untouched}), do: gettext("Kept")

  defp op_sign(%{op: :create}), do: "+"
  defp op_sign(%{op: :update}), do: "~"
  defp op_sign(%{op: :delete}), do: "−"
  defp op_sign(%{op: :untouched}), do: "?"

  defp op_detail(%{op: :create, attrs: attrs, kind: :section}), do: attrs["display"]
  defp op_detail(%{op: :create, attrs: attrs}), do: attrs["field_type"] || gettext("type")

  defp op_detail(%{op: :update, changes: changes}),
    do: changes |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp op_detail(_op), do: nil

  defp deletes(preview), do: Enum.filter(preview.ops, &(&1.op == :delete))

  defp kept(preview), do: preview.untouched

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:fields}
    >
      <div class="space-y-8">
        <div>
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:fields}
          />
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Sync field definitions")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Move a content model between environments. Upload a file made by Export, review what it would change, then apply it. Content is never moved."
            )}
          </p>
          <p class="mt-2 flex flex-wrap gap-4 text-sm">
            <.link navigate={~p"/editor/fields"} class="underline">
              {gettext("Back to custom fields")}
            </.link>
            <a href={~p"/editor/fields/export.json"} download class="underline">
              {gettext("Download this site's definitions")}
            </a>
          </p>
        </div>

        <section :if={@applied} id="sync-applied" class="card card-pad space-y-1">
          <h2 class="text-lg font-medium">{gettext("Applied")}</h2>
          <p class="text-sm">
            {gettext("%{created} created, %{updated} updated, %{deleted} deleted.",
              created: @applied.created,
              updated: @applied.updated,
              deleted: @applied.deleted
            )}
          </p>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("1. Choose a file")}</h2>
          <form
            id="sync-upload-form"
            phx-change="validate"
            phx-submit="preview"
            class="card card-pad space-y-3"
          >
            <div>
              <label for={@uploads.definitions.ref} class="block text-sm font-medium">
                {gettext("Field definitions file (.json, up to 2 MB)")}
              </label>
              <.live_file_input
                upload={@uploads.definitions}
                class="mt-1 block text-sm"
                aria-describedby="sync-upload-help"
              />
              <p id="sync-upload-help" class="mt-1 text-xs text-base-content/70">
                {gettext("Nothing is written until you confirm on the next steps.")}
              </p>
            </div>

            <ul class="space-y-1">
              <li
                :for={entry <- @uploads.definitions.entries}
                id={"sync-entry-#{entry.ref}"}
                class="flex flex-wrap items-center gap-2 text-sm"
              >
                <span class="min-w-0 truncate">{entry.client_name}</span>
                <span :for={err <- upload_errors(@uploads.definitions, entry)} class="text-error">
                  {upload_error_text(err)}
                </span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="underline"
                >
                  {gettext("Remove")}
                </button>
              </li>
            </ul>
            <p :for={err <- upload_errors(@uploads.definitions)} class="text-sm text-error">
              {upload_error_text(err)}
            </p>
            <p :if={@file_error} id="sync-file-error" class="text-sm text-error" role="alert">
              {@file_error}
            </p>

            <button
              type="submit"
              class="btn btn-default"
              disabled={
                !Enum.any?(@uploads.definitions.entries) or
                  Enum.any?(@uploads.definitions.entries, &(!&1.valid?))
              }
            >
              {gettext("Preview changes")}
            </button>
          </form>
        </section>

        <section :if={@preview} id="sync-preview" class="space-y-4">
          <h2 class="text-lg font-medium">
            {gettext("2. Review the changes")}
            <span class="text-sm font-normal text-base-content/70">— {@file_name}</span>
          </h2>

          <div :if={@preview.errors != []} id="sync-errors" class="card card-pad space-y-1">
            <h3 class="font-medium text-error">{gettext("This file cannot be imported")}</h3>
            <ul class="list-disc space-y-1 pl-5 text-sm">
              <li :for={err <- @preview.errors}>
                <span class="font-mono">{err.path}</span>: {Enum.join(err.messages, "; ")}
              </li>
            </ul>
          </div>

          <p :if={@preview.errors == []} id="sync-counts" class="text-sm" aria-live="polite">
            {gettext(
              "%{create} to create, %{update} to update, %{delete} to delete, %{unchanged} unchanged.",
              create: Map.get(@preview.counts, :create, 0),
              update: Map.get(@preview.counts, :update, 0),
              delete: Map.get(@preview.counts, :delete, 0),
              unchanged: Map.get(@preview.counts, :unchanged, 0)
            )}
          </p>

          <ul :if={@preview.ops != []} id="sync-diff" class="card divide-y divide-base-300 text-sm">
            <li :for={op <- @preview.ops} class="flex flex-wrap items-baseline gap-x-3 gap-y-1 p-3">
              <span aria-hidden="true" class="w-4 font-mono">{op_sign(op)}</span>
              <span class="w-16 font-medium">{op_label(op)}</span>
              <span class="font-mono">{op.path}</span>
              <span :if={op_detail(op)} class="text-base-content/70">{op_detail(op)}</span>
            </li>
          </ul>

          <div :if={kept(@preview) != []} id="sync-kept" class="text-sm">
            <h3 class="font-medium">{gettext("Not in the file (kept)")}</h3>
            <ul class="list-disc pl-5 font-mono">
              <li :for={path <- kept(@preview)}>{path}</li>
            </ul>
          </div>

          <div
            :if={@preview.blocked != []}
            id="sync-blocked"
            class="card card-pad space-y-2 border-error"
            role="alert"
          >
            <h3 class="font-medium text-error">
              {gettext("Refused: these changes drop stored values")}
            </h3>
            <ul class="list-disc space-y-1 pl-5 text-sm">
              <li :for={b <- @preview.blocked}>
                <span class="font-mono">{b.path}</span>: {b.reason}
              </li>
            </ul>
            <p :if={!@allow?} class="text-sm text-base-content/70">
              {gettext(
                "Nothing can be applied until you allow this below. The remaining writes are not checked until then."
              )}
            </p>
          </div>

          <form id="sync-flags" phx-change="flags" class="card card-pad space-y-4">
            <fieldset class="space-y-1">
              <legend class="font-medium">{gettext("Confirmations")}</legend>
              <div>
                <label class="flex items-start gap-2 text-sm">
                  <input type="hidden" name="prune" value="false" />
                  <input
                    type="checkbox"
                    name="prune"
                    value="true"
                    checked={@prune?}
                    aria-describedby="sync-prune-help"
                    class="mt-1"
                  />
                  <span>{gettext("Delete fields this file does not list")}</span>
                </label>
                <p id="sync-prune-help" class="ml-6 text-xs text-base-content/70">
                  <%= if @prune? do %>
                    {ngettext(
                      "%{count} field will be deleted.",
                      "%{count} fields will be deleted.",
                      length(deletes(@preview))
                    )}
                  <% else %>
                    {gettext("Off: fields missing from the file stay as they are.")}
                  <% end %>
                </p>
              </div>
              <div>
                <label class="flex items-start gap-2 text-sm">
                  <input type="hidden" name="allow_data_loss" value="false" />
                  <input
                    type="checkbox"
                    name="allow_data_loss"
                    value="true"
                    checked={@allow?}
                    aria-describedby="sync-loss-help"
                    class="mt-1"
                  />
                  <span>{gettext("Allow changes that drop values records already hold")}</span>
                </label>
                <p id="sync-loss-help" class="ml-6 text-xs text-base-content/70">
                  {gettext(
                    "Off: a delete, a type change or a list made single is refused while records hold a value."
                  )}
                </p>
              </div>
            </fieldset>
          </form>

          <div class="space-y-3">
            <button
              type="button"
              id="sync-ask-apply"
              phx-click="ask_apply"
              class="btn btn-default"
              disabled={!applicable?(@preview, @allow?)}
            >
              {gettext("Apply…")}
            </button>

            <div
              :if={@confirming?}
              id="sync-confirm"
              phx-mounted={JS.focus_first(to: "#sync-confirm")}
              role="alertdialog"
              aria-labelledby="sync-confirm-title"
              class="card card-pad space-y-3"
            >
              <h3 id="sync-confirm-title" class="font-medium">
                {gettext("Apply these changes to this site?")}
              </h3>
              <p class="text-sm">
                {gettext("%{create} created, %{update} updated, %{delete} deleted.",
                  create: Map.get(@preview.counts, :create, 0),
                  update: Map.get(@preview.counts, :update, 0),
                  delete: Map.get(@preview.counts, :delete, 0)
                )}
              </p>
              <p :if={@prune?} class="text-sm">
                {gettext("You confirmed deleting fields the file does not list.")}
              </p>
              <p :if={@allow?} class="text-sm">
                {gettext("You confirmed changes that drop stored values.")}
              </p>
              <div class="flex gap-2">
                <button type="button" id="sync-apply" phx-click="apply" class="btn btn-primary">
                  {gettext("Yes, apply these changes")}
                </button>
                <button
                  type="button"
                  phx-click={JS.push("cancel_apply") |> JS.focus(to: "#sync-ask-apply")}
                  class="btn btn-ghost"
                >
                  {gettext("Cancel")}
                </button>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
