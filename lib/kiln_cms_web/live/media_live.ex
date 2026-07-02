defmodule KilnCMSWeb.MediaLive do
  @moduledoc """
  Media library — upload images (LiveView direct uploads), browse the library,
  and delete items. Reachable only by editors/admins (`:live_editor_required`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.ImageProcessor
  alias KilnCMS.Storage

  @accept ~w(.jpg .jpeg .png .webp .gif)
  @max_entries 10
  @max_file_size 10_000_000
  # Bound the library window loaded into the LiveView (newest first) so a large
  # media library can't grow one editor's heap without limit.
  @max_media 500

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    # Live-refresh the library when a background variant job finishes.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, KilnCMS.Media.VariantWorker.topic())
    end

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Media library"))
     |> assign(:is_admin, actor.role == :admin)
     |> assign(:query, "")
     |> assign(:selected, nil)
     |> assign(:view, :library)
     |> assign(:trashed, [])
     |> assign(:refresh_timer, nil)
     |> assign(:max_media, @max_media)
     |> assign(:media, list_media(actor))
     |> allow_upload(:media,
       accept: @accept,
       max_entries: @max_entries,
       max_file_size: @max_file_size
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, :query, q)}

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
  end

  def handle_event("save", _params, socket) do
    actor = socket.assigns.actor

    results =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        {:ok, {entry.client_name, store_entry(path, entry, actor)}}
      end)

    {ok, failed} = Enum.split_with(results, fn {_name, result} -> result == :ok end)
    failures = for {name, {:error, reason}} <- failed, do: {name, reason}

    socket =
      socket
      |> assign(:media, list_media(actor))
      |> flash_for_upload(length(ok), failures)

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case CMS.get_media_item(id, actor: actor) do
        {:ok, item} -> delete_item(socket, item, actor)
        _ -> put_flash(socket, :error, gettext("That item no longer exists."))
      end

    {:noreply, socket |> assign(:selected, nil) |> assign(:media, list_media(actor))}
  end

  # --- trash -----------------------------------------------------------------

  def handle_event("show_trash", _params, socket) do
    actor = socket.assigns.actor

    if socket.assigns.is_admin do
      {:noreply, socket |> assign(:view, :trash) |> assign(:trashed, list_trashed(actor))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_library", _params, socket),
    do: {:noreply, assign(socket, :view, :library)}

  def handle_event("restore", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case find_trashed(socket, id) do
        nil ->
          put_flash(socket, :error, gettext("That item no longer exists."))

        item ->
          case CMS.restore_media_item(item, actor: actor) do
            {:ok, _} ->
              put_flash(socket, :info, gettext("Restored %{name}.", name: item.filename))

            _ ->
              put_flash(socket, :error, gettext("You don't have permission to restore media."))
          end
      end

    {:noreply,
     socket |> assign(:trashed, list_trashed(actor)) |> assign(:media, list_media(actor))}
  end

  def handle_event("purge", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case find_trashed(socket, id) do
        nil -> put_flash(socket, :error, gettext("That item no longer exists."))
        item -> purge_item(socket, item, actor)
      end

    {:noreply, assign(socket, :trashed, list_trashed(actor))}
  end

  def handle_event("select", %{"id" => id}, socket) do
    case CMS.get_media_item(id, actor: socket.assigns.actor) do
      {:ok, item} -> {:noreply, assign(socket, :selected, item)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :selected, nil)}

  def handle_event("save_meta", %{"alt" => alt, "caption" => caption}, socket) do
    actor = socket.assigns.actor

    socket =
      case CMS.update_media_item(socket.assigns.selected, %{alt: alt, caption: caption},
             actor: actor
           ) do
        {:ok, item} ->
          socket
          |> assign(:selected, item)
          |> assign(:media, list_media(actor))
          |> put_flash(:info, gettext("Saved details."))

        _ ->
          put_flash(socket, :error, gettext("Couldn't save those details."))
      end

    {:noreply, socket}
  end

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("URL copied to clipboard."))}

  # A background variant job finished — refresh the library so the new
  # dimensions/thumbnail show without a manual reload. Completions arrive in
  # bursts (one broadcast per file, to every open MediaLive), so coalesce them
  # into a single re-query instead of one 500-row fetch per broadcast.
  @impl true
  def handle_info({:media_processed, _id}, socket) do
    if socket.assigns.refresh_timer do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :refresh_timer, Process.send_after(self(), :refresh_media, 200))}
    end
  end

  def handle_info(:refresh_media, socket) do
    {:noreply,
     socket
     |> assign(:refresh_timer, nil)
     |> assign(:media, list_media(socket.assigns.actor))}
  end

  # --- helpers ---------------------------------------------------------------

  # `source`, when removed, is the server-built stripped temp file (UUID path),
  # never user input — the File.rm traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  # Returns :ok or {:error, reason} — the reason reaches the failure flash so
  # editors learn WHICH file failed and why, not just a count (audit U-M5).
  defp store_entry(path, entry, actor) do
    case ImageProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type}} ->
        key = Storage.generate_key_with_ext(ext)
        # Strip EXIF/GPS + the client filename before persisting (#215). On any
        # strip failure we fall back to the original so a valid upload still saves.
        {source, stripped?} = stripped_source(path, ext)

        try do
          case Storage.store(key, source) do
            {:ok, ^key} -> create_from_upload(key, content_type, entry, actor)
            _ -> {:error, :storage_failed}
          end
        after
          if stripped?, do: File.rm(source)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # {temp_path, true} when a metadata-stripped copy was produced (caller cleans
  # it up); {original_path, false} when stripping wasn't possible.
  defp stripped_source(path, ext) do
    case ImageProcessor.strip_metadata(path, ext) do
      {:ok, tmp} -> {tmp, true}
      {:error, _} -> {path, false}
    end
  end

  defp create_from_upload(key, content_type, entry, actor) do
    attrs = %{
      filename: entry.client_name,
      content_type: content_type,
      byte_size: entry.client_size,
      storage_key: key,
      url: Storage.url(key)
    }

    case CMS.create_media_item(attrs, actor: actor) do
      {:ok, item} ->
        enqueue_processing(item)
        :ok

      _ ->
        Storage.delete(key)
        {:error, :create_failed}
    end
  end

  # Queue background dimension/variant processing (keeps libvips off the upload
  # request). The worker re-fetches the original from storage, so there's no
  # node-local temp hand-off.
  defp enqueue_processing(item) do
    %{media_item_id: item.id}
    |> KilnCMS.Media.VariantWorker.new()
    |> Oban.insert!()
  end

  defp delete_variant_blobs(variants) do
    for {_label, %{"key" => key}} <- variants || %{}, do: Storage.delete(key)
  end

  # Soft delete: stamp `archived_at` but keep the row and blobs, so content still
  # referencing the item keeps working and an admin can restore it from trash.
  defp delete_item(socket, item, actor) do
    case CMS.destroy_media_item(item, actor: actor) do
      :ok -> put_flash(socket, :info, gettext("Moved %{name} to trash.", name: item.filename))
      _ -> put_flash(socket, :error, gettext("You don't have permission to delete media."))
    end
  end

  # Permanent delete: drop the row and reclaim the original + variant blobs.
  defp purge_item(socket, item, actor) do
    case CMS.purge_media_item(item, actor: actor) do
      :ok ->
        if item.storage_key, do: Storage.delete(item.storage_key)
        delete_variant_blobs(item.variants)
        put_flash(socket, :info, gettext("Permanently deleted %{name}.", name: item.filename))

      _ ->
        put_flash(socket, :error, gettext("You don't have permission to delete media."))
    end
  end

  defp find_trashed(socket, id), do: Enum.find(socket.assigns.trashed, &(&1.id == id))

  defp list_trashed(actor) do
    CMS.list_trashed_media_items!(actor: actor, query: [sort: [updated_at: :desc]])
  end

  # The thumbnail to show in the grid — the small variant when available, else
  # the original.
  defp thumb_src(%{variants: %{"thumb" => %{"url" => url}}}), do: url
  defp thumb_src(item), do: item.url

  defp list_media(actor) do
    CMS.list_media_items!(actor: actor, query: [sort: [inserted_at: :desc], limit: @max_media])
  end

  defp visible_media(media, ""), do: media

  defp visible_media(media, query) do
    q = String.downcase(query)
    Enum.filter(media, &String.contains?(String.downcase(&1.filename), q))
  end

  defp flash_for_upload(socket, ok, []) when ok > 0,
    do:
      put_flash(
        socket,
        :info,
        ngettext("Uploaded %{count} file.", "Uploaded %{count} files.", ok, count: ok)
      )

  defp flash_for_upload(socket, _ok, []), do: socket

  # Server-side rejections name the file and the reason (audit U-M5) instead of
  # collapsing to "2 uploads failed."
  defp flash_for_upload(socket, ok, failures) do
    detail =
      Enum.map_join(failures, "; ", fn {name, reason} ->
        "#{name} (#{upload_failure_reason(reason)})"
      end)

    message =
      if ok > 0,
        do: gettext("Uploaded %{ok}. Failed: %{detail}", ok: ok, detail: detail),
        else: gettext("Upload failed: %{detail}", detail: detail)

    put_flash(socket, :error, message)
  end

  defp upload_failure_reason(:unsupported_format), do: gettext("unsupported image format")
  defp upload_failure_reason(:storage_failed), do: gettext("couldn't be stored")
  defp upload_failure_reason(:create_failed), do: gettext("couldn't be saved")
  defp upload_failure_reason(_invalid), do: gettext("not a valid image")

  defp humanize_bytes(nil), do: "—"
  defp humanize_bytes(b) when b < 1_024, do: "#{b} B"
  defp humanize_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1_024, 1)} KB"
  defp humanize_bytes(b), do: "#{Float.round(b / 1_048_576, 1)} MB"

  defp error_to_string(:too_large), do: gettext("too large (max 10 MB)")
  defp error_to_string(:too_many_files), do: gettext("too many files (max 10)")
  defp error_to_string(:not_accepted), do: gettext("unsupported type")
  defp error_to_string(other), do: to_string(other)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, visible_media(assigns.media, assigns.query))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
      <div class="space-y-8">
        <div class="flex items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold">{gettext("Media library")}</h1>
            <p class="text-sm text-base-content/70">{gettext("Upload and manage images.")}</p>
          </div>
          <div :if={@is_admin} class="flex gap-1 text-sm">
            <button
              type="button"
              phx-click="show_library"
              class={[
                "rounded px-3 py-1.5",
                @view == :library && "bg-base-200 font-medium",
                @view != :library && "text-base-content/60 hover:bg-base-200"
              ]}
            >
              {gettext("Library")}
            </button>
            <button
              type="button"
              phx-click="show_trash"
              class={[
                "rounded px-3 py-1.5",
                @view == :trash && "bg-base-200 font-medium",
                @view != :trash && "text-base-content/60 hover:bg-base-200"
              ]}
            >
              {gettext("Trash")}
            </button>
          </div>
        </div>

        <.trash_panel :if={@view == :trash} items={@trashed} />

        <form
          :if={@view == :library}
          id="upload-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <div
            class="rounded-lg border-2 border-dashed border-base-content/20 p-8 text-center"
            phx-drop-target={@uploads.media.ref}
          >
            <.icon name="hero-arrow-up-tray" class="mx-auto size-8 text-base-content/70" />
            <p class="mt-2 text-sm">
              <label for={@uploads.media.ref} class="cursor-pointer font-medium underline">
                {gettext("Choose images")}
              </label>
              {gettext("or drag and drop")}
            </p>
            <p class="mt-1 text-xs text-base-content/70">
              {gettext("PNG, JPG, WEBP or GIF up to 10 MB")}
            </p>
            <.live_file_input upload={@uploads.media} class="sr-only" />
          </div>

          <div :if={@uploads.media.entries != []} class="space-y-3">
            <div
              :for={entry <- @uploads.media.entries}
              class="flex items-center gap-4 rounded border border-base-content/10 p-3"
            >
              <.live_img_preview entry={entry} class="size-14 rounded object-cover" />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium">{entry.client_name}</p>
                <div
                  class="mt-1 h-1.5 w-full overflow-hidden rounded bg-base-content/10"
                  role="progressbar"
                  aria-valuenow={entry.progress}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-label={gettext("Upload progress for %{name}", name: entry.client_name)}
                >
                  <div class="h-full bg-primary" style={"width: #{entry.progress}%"}></div>
                </div>
                <p :for={err <- upload_errors(@uploads.media, entry)} class="mt-1 text-xs text-error">
                  {error_to_string(err)}
                </p>
              </div>
              <button
                type="button"
                phx-click="cancel"
                phx-value-ref={entry.ref}
                aria-label={gettext("Cancel upload")}
                class="text-base-content/70 hover:text-error"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>
          </div>

          <p :for={err <- upload_errors(@uploads.media)} class="text-sm text-error">
            {error_to_string(err)}
          </p>

          <.button :if={@uploads.media.entries != []} type="submit" variant="primary">
            {ngettext("Upload %{count} file", "Upload %{count} files", length(@uploads.media.entries),
              count: length(@uploads.media.entries)
            )}
          </.button>
        </form>

        <div :if={@view == :library}>
          <div class="mb-3 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
            <h2 class="text-lg font-medium">
              {gettext("Library (%{count})", count: length(@visible))}
            </h2>
            <form :if={@media != []} id="media-filter" phx-change="search" class="sm:w-auto">
              <input
                type="text"
                name="q"
                value={@query}
                placeholder={gettext("Filter by filename")}
                phx-debounce="200"
                autocomplete="off"
                class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm sm:w-auto"
              />
            </form>
          </div>
          <p
            :if={length(@media) >= @max_media}
            class="mb-3 text-xs text-base-content/60"
            role="status"
          >
            {gettext(
              "Showing the newest %{max} files — older files exist but aren't listed here.",
              max: @max_media
            )}
          </p>
          <.empty_state :if={@media == []} icon="hero-photo" title={gettext("No media yet")}>
            {gettext("Upload an image above to start building your library.")}
          </.empty_state>
          <p :if={@media != [] and @visible == []} class="text-sm text-base-content/60">
            {gettext("No media matches “%{query}”.", query: @query)}
          </p>
          <ul
            :if={@visible != []}
            class="grid grid-cols-2 gap-4 sm:grid-cols-3"
            id="media-grid"
            phx-update="replace"
          >
            <li
              :for={item <- @visible}
              id={"media-#{item.id}"}
              class="group relative overflow-hidden rounded border border-base-content/10"
            >
              <button
                type="button"
                phx-click="select"
                phx-value-id={item.id}
                aria-label={gettext("View details for %{name}", name: item.filename)}
                class="block w-full focus-visible:ring-2 focus-visible:ring-primary"
              >
                <img
                  src={thumb_src(item)}
                  alt={item.alt || item.filename}
                  loading="lazy"
                  class="aspect-square w-full object-cover"
                />
              </button>
              <div class="p-2">
                <p class="truncate text-xs font-medium">{item.filename}</p>
                <p class="flex items-center gap-1 text-[10px] text-base-content/70">
                  <span :if={item.width}>{item.width}×{item.height}</span>
                  <span>{humanize_bytes(item.byte_size)}</span>
                  <span :if={!item.alt} class="text-warning" title={gettext("Missing alt text")}>
                    {gettext("· no alt")}
                  </span>
                </p>
              </div>
              <button
                phx-click="delete"
                phx-value-id={item.id}
                data-confirm={gettext("Delete %{name}?", name: item.filename)}
                aria-label={gettext("Delete")}
                class="absolute right-1 top-1 rounded bg-base-100/80 p-1 transition hover:text-error opacity-100 sm:opacity-0 sm:group-hover:opacity-100 focus:opacity-100 focus-visible:opacity-100"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>
        </div>
      </div>

      <.media_detail :if={@selected} item={@selected} />
    </Layouts.app>
    """
  end

  attr :items, :list, required: true

  # Trashed (soft-deleted) media: restore brings an item back to the library;
  # delete permanently purges the row and reclaims its storage blobs.
  defp trash_panel(assigns) do
    ~H"""
    <div>
      <h2 class="mb-3 text-lg font-medium">{gettext("Trash (%{count})", count: length(@items))}</h2>
      <p :if={@items == []} class="text-sm text-base-content/60">{gettext("Trash is empty.")}</p>
      <ul
        :if={@items != []}
        class="divide-y divide-base-content/10 rounded border border-base-content/10"
      >
        <li :for={item <- @items} id={"trash-#{item.id}"} class="flex items-center gap-4 p-3">
          <img
            src={thumb_src(item)}
            alt={item.alt || item.filename}
            loading="lazy"
            class="size-12 shrink-0 rounded object-cover"
          />
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-medium">{item.filename}</p>
            <p class="text-xs text-base-content/70">
              {gettext("deleted %{at}", at: Calendar.strftime(item.updated_at, "%Y-%m-%d %H:%M"))}
            </p>
          </div>
          <button
            type="button"
            phx-click="restore"
            phx-value-id={item.id}
            class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200"
          >
            {gettext("Restore")}
          </button>
          <button
            type="button"
            phx-click="purge"
            phx-value-id={item.id}
            data-confirm={
              gettext("Permanently delete %{name}? This can't be undone.", name: item.filename)
            }
            class="rounded border border-error/40 px-3 py-1 text-xs text-error hover:bg-error/10"
          >
            {gettext("Delete permanently")}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :item, :map, required: true

  # Detail drawer for a single media item: preview, metadata, copyable URL, and
  # an alt-text / caption editor (accessibility + SEO).
  defp media_detail(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40" phx-window-keydown="close" phx-key="Escape">
      <div class="absolute inset-0 bg-black/40" phx-click="close" aria-hidden="true"></div>
      <div
        id="media-detail-dialog"
        phx-hook="FocusTrap"
        role="dialog"
        aria-modal="true"
        aria-labelledby="media-detail-title"
        tabindex="-1"
        class="absolute right-0 top-0 h-full w-full max-w-md overflow-y-auto bg-base-100 p-6 shadow-xl"
      >
        <div class="flex items-start justify-between gap-4">
          <h2 id="media-detail-title" class="truncate text-lg font-medium">{@item.filename}</h2>
          <button
            type="button"
            phx-click="close"
            aria-label={gettext("Close")}
            class="text-base-content/70 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <img
          src={@item.url}
          alt={@item.alt || @item.filename}
          class="mt-4 max-h-64 w-full rounded object-contain"
        />

        <dl class="mt-4 grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-base-content/70">
          <dt class="text-base-content/70">{gettext("Type")}</dt>
          <dd>{@item.content_type || "—"}</dd>
          <dt class="text-base-content/70">{gettext("Size")}</dt>
          <dd>{humanize_bytes(@item.byte_size)}</dd>
          <dt :if={@item.width} class="text-base-content/70">{gettext("Dimensions")}</dt>
          <dd :if={@item.width}>{@item.width} × {@item.height} px</dd>
          <dt class="text-base-content/70">{gettext("Uploaded")}</dt>
          <dd>{Calendar.strftime(@item.inserted_at, "%Y-%m-%d %H:%M")}</dd>
        </dl>

        <div :if={@item.variants not in [nil, %{}]} class="mt-4">
          <p class="text-xs text-base-content/70">{gettext("Responsive variants")}</p>
          <ul class="mt-1 space-y-1">
            <li
              :for={{label, v} <- @item.variants}
              class="flex items-center justify-between gap-2 text-xs"
            >
              <span class="font-medium capitalize">{label}</span>
              <span class="text-base-content/70">{v["width"]} × {v["height"]}</span>
              <a
                href={v["url"]}
                target="_blank"
                rel="noopener noreferrer"
                class="text-primary hover:underline"
              >
                {gettext("open")} <span class="sr-only">{gettext("(opens in a new tab)")}</span>
              </a>
            </li>
          </ul>
        </div>

        <div class="mt-4">
          <label class="text-xs text-base-content/70">{gettext("URL")}</label>
          <div class="mt-1 flex gap-2">
            <input
              type="text"
              value={@item.url}
              readonly
              class="min-w-0 flex-1 rounded border border-base-content/20 bg-base-200/40 px-2 py-1 text-xs"
            />
            <button
              type="button"
              id="copy-url"
              phx-hook="Clipboard"
              data-clipboard-text={@item.url}
              class="shrink-0 rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
            >
              {gettext("Copy")}
            </button>
          </div>
        </div>

        <form phx-submit="save_meta" class="mt-5 space-y-3">
          <div>
            <label for="media-alt" class="text-sm font-medium">{gettext("Alt text")}</label>
            <input
              id="media-alt"
              name="alt"
              value={@item.alt}
              placeholder={gettext("Describe the image for screen readers")}
              class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            />
          </div>
          <div>
            <label for="media-caption" class="text-sm font-medium">{gettext("Caption")}</label>
            <textarea
              id="media-caption"
              name="caption"
              rows="2"
              class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            >{@item.caption}</textarea>
          </div>
          <.button type="submit" variant="primary">{gettext("Save details")}</.button>
        </form>
      </div>
    </div>
    """
  end
end
