defmodule KilnCMSWeb.MediaLive do
  @moduledoc """
  Media library — upload images (LiveView direct uploads), browse the library,
  and delete items. Reachable only by editors/admins (`:live_editor_required`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Storage

  @accept ~w(.jpg .jpeg .png .webp .gif)
  @max_entries 10
  @max_file_size 10_000_000

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:query, "")
     |> assign(:selected, nil)
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
        {:ok, store_entry(path, entry, actor)}
      end)

    {ok, failed} = Enum.split_with(results, &(&1 == :ok))

    socket =
      socket
      |> assign(:media, list_media(actor))
      |> flash_for_upload(length(ok), length(failed))

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case CMS.get_media_item(id, actor: actor) do
        {:ok, item} -> delete_item(socket, item, actor)
        _ -> put_flash(socket, :error, "That item no longer exists.")
      end

    {:noreply, socket |> assign(:selected, nil) |> assign(:media, list_media(actor))}
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
          |> put_flash(:info, "Saved details.")

        _ ->
          put_flash(socket, :error, "Couldn't save those details.")
      end

    {:noreply, socket}
  end

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, "URL copied to clipboard.")}

  # --- helpers ---------------------------------------------------------------

  defp store_entry(path, entry, actor) do
    key = Storage.generate_key(entry.client_name)

    with {:ok, ^key} <- Storage.store(key, path),
         {:ok, _item} <-
           CMS.create_media_item(
             %{
               filename: entry.client_name,
               content_type: entry.client_type,
               byte_size: entry.client_size,
               storage_key: key,
               url: Storage.url(key)
             },
             actor: actor
           ) do
      :ok
    else
      _error ->
        # Roll back the stored blob if the record couldn't be created.
        Storage.delete(key)
        :error
    end
  end

  defp delete_item(socket, item, actor) do
    case CMS.destroy_media_item(item, actor: actor) do
      :ok ->
        if item.storage_key, do: Storage.delete(item.storage_key)
        put_flash(socket, :info, "Deleted #{item.filename}.")

      _ ->
        put_flash(socket, :error, "You don't have permission to delete media.")
    end
  end

  defp list_media(actor) do
    CMS.list_media_items!(actor: actor, query: [sort: [inserted_at: :desc]])
  end

  defp visible_media(media, ""), do: media

  defp visible_media(media, query) do
    q = String.downcase(query)
    Enum.filter(media, &String.contains?(String.downcase(&1.filename), q))
  end

  defp flash_for_upload(socket, ok, 0) when ok > 0,
    do: put_flash(socket, :info, "Uploaded #{ok} #{pluralize(ok, "file")}.")

  defp flash_for_upload(socket, 0, failed) when failed > 0,
    do: put_flash(socket, :error, "#{failed} #{pluralize(failed, "upload")} failed.")

  defp flash_for_upload(socket, ok, failed) when ok > 0 and failed > 0,
    do: put_flash(socket, :info, "Uploaded #{ok}; #{failed} failed.")

  defp flash_for_upload(socket, _, _), do: socket

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  defp humanize_bytes(nil), do: "—"
  defp humanize_bytes(b) when b < 1_024, do: "#{b} B"
  defp humanize_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1_024, 1)} KB"
  defp humanize_bytes(b), do: "#{Float.round(b / 1_048_576, 1)} MB"

  defp error_to_string(:too_large), do: "too large (max 10 MB)"
  defp error_to_string(:too_many_files), do: "too many files (max 10)"
  defp error_to_string(:not_accepted), do: "unsupported type"
  defp error_to_string(other), do: to_string(other)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, visible_media(assigns.media, assigns.query))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div>
          <h1 class="text-2xl font-semibold">Media library</h1>
          <p class="text-sm text-base-content/70">Upload and manage images.</p>
        </div>

        <form id="upload-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <div
            class="rounded-lg border-2 border-dashed border-base-content/20 p-8 text-center"
            phx-drop-target={@uploads.media.ref}
          >
            <.icon name="hero-arrow-up-tray" class="mx-auto size-8 text-base-content/40" />
            <p class="mt-2 text-sm">
              <label for={@uploads.media.ref} class="cursor-pointer font-medium underline">
                Choose images
              </label>
              or drag and drop
            </p>
            <p class="mt-1 text-xs text-base-content/50">PNG, JPG, WEBP or GIF up to 10 MB</p>
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
                <div class="mt-1 h-1.5 w-full overflow-hidden rounded bg-base-content/10">
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
                aria-label="Cancel upload"
                class="text-base-content/50 hover:text-error"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>
          </div>

          <p :for={err <- upload_errors(@uploads.media)} class="text-sm text-error">
            {error_to_string(err)}
          </p>

          <.button :if={@uploads.media.entries != []} type="submit" variant="primary">
            Upload {length(@uploads.media.entries)} {pluralize(length(@uploads.media.entries), "file")}
          </.button>
        </form>

        <div>
          <div class="mb-3 flex items-center justify-between gap-4">
            <h2 class="text-lg font-medium">Library ({length(@visible)})</h2>
            <form :if={@media != []} id="media-filter" phx-change="search">
              <input
                type="text"
                name="q"
                value={@query}
                placeholder="Filter by filename"
                phx-debounce="200"
                autocomplete="off"
                class="rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
              />
            </form>
          </div>
          <p :if={@media == []} class="text-sm text-base-content/60">No media yet.</p>
          <p :if={@media != [] and @visible == []} class="text-sm text-base-content/60">
            No media matches “{@query}”.
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
              <img
                src={item.url}
                alt={item.alt || item.filename}
                phx-click="select"
                phx-value-id={item.id}
                class="aspect-square w-full cursor-pointer object-cover"
              />
              <div class="p-2">
                <p class="truncate text-xs font-medium">{item.filename}</p>
                <p class="flex items-center gap-1 text-[10px] text-base-content/50">
                  {humanize_bytes(item.byte_size)}
                  <span :if={!item.alt} class="text-warning" title="Missing alt text">· no alt</span>
                </p>
              </div>
              <button
                phx-click="delete"
                phx-value-id={item.id}
                data-confirm={"Delete #{item.filename}?"}
                aria-label="Delete"
                class="absolute right-1 top-1 rounded bg-base-100/80 p-1 opacity-0 transition group-hover:opacity-100 hover:text-error"
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

  attr :item, :map, required: true

  # Detail drawer for a single media item: preview, metadata, copyable URL, and
  # an alt-text / caption editor (accessibility + SEO).
  defp media_detail(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40" phx-window-keydown="close" phx-key="Escape">
      <div class="absolute inset-0 bg-black/40" phx-click="close" aria-hidden="true"></div>
      <div class="absolute right-0 top-0 h-full w-full max-w-md overflow-y-auto bg-base-100 p-6 shadow-xl">
        <div class="flex items-start justify-between gap-4">
          <h2 class="truncate text-lg font-medium">{@item.filename}</h2>
          <button
            type="button"
            phx-click="close"
            aria-label="Close"
            class="text-base-content/50 hover:text-base-content"
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
          <dt class="text-base-content/50">Type</dt>
          <dd>{@item.content_type || "—"}</dd>
          <dt class="text-base-content/50">Size</dt>
          <dd>{humanize_bytes(@item.byte_size)}</dd>
          <dt class="text-base-content/50">Uploaded</dt>
          <dd>{Calendar.strftime(@item.inserted_at, "%Y-%m-%d %H:%M")}</dd>
        </dl>

        <div class="mt-4">
          <label class="text-xs text-base-content/50">URL</label>
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
              Copy
            </button>
          </div>
        </div>

        <form phx-submit="save_meta" class="mt-5 space-y-3">
          <div>
            <label for="media-alt" class="text-sm font-medium">Alt text</label>
            <input
              id="media-alt"
              name="alt"
              value={@item.alt}
              placeholder="Describe the image for screen readers"
              class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            />
          </div>
          <div>
            <label for="media-caption" class="text-sm font-medium">Caption</label>
            <textarea
              id="media-caption"
              name="caption"
              rows="2"
              class="mt-1 w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            >{@item.caption}</textarea>
          </div>
          <.button type="submit" variant="primary">Save details</.button>
        </form>
      </div>
    </div>
    """
  end
end
