defmodule KilnCMSWeb.MediaLive do
  @moduledoc """
  Media library — upload images (LiveView direct uploads), browse the library,
  and delete items. Reachable only by editors/admins (`:live_editor_required`).
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.AVProcessor
  alias KilnCMS.CMS
  alias KilnCMS.DocumentProcessor
  alias KilnCMS.ImageProcessor
  alias KilnCMS.MediaKind
  alias KilnCMS.Storage
  alias KilnCMS.Unsplash
  alias KilnCMSWeb.Params

  @accept ~w(.jpg .jpeg .png .webp .gif .pdf .mp4 .m4a .webm .mp3 .vtt)
  @max_entries 10
  # Phoenix's `allow_upload` takes one ceiling for every entry (there's no
  # per-accept-type cap in the API), so this is the LARGEST of the per-type
  # caps below — `check_size/2` enforces the tighter one for whichever type an
  # upload turns out to be, after `ImageProcessor`/`DocumentProcessor`/
  # `AVProcessor` has byte-sniffed it.
  @max_image_size 10_000_000
  @max_document_size 25_000_000
  # Video is the outlier and the reason the ceiling moved (#494): a few
  # minutes of web-ready H.264 is comfortably past every other cap here.
  # There is no transcoding, so this is also the practical statement of "how
  # big a file will Kiln accept" — see docs/media-pipeline.md.
  @max_video_size 500_000_000
  @max_audio_size 100_000_000
  # A caption track is text; anything remotely this size is not a `.vtt`.
  @max_captions_size 2_000_000
  @max_file_size 500_000_000
  # Server-side page size: the grid loads pages of newest-first items and any
  # older item is reachable via Load more or the (server-side) filter.
  @page_size 60
  # Bound on the trashed-media list — trash restores are recent-item work, and
  # an unbounded read would grow the LiveView heap with the trash.
  @max_trashed 500

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    # Live-refresh the library when a background variant job finishes.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, KilnCMS.Media.VariantWorker.topic())
    end

    {:ok,
     socket
     # `query: nil` is a sentinel: the first handle_params always loads.
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Media library"))
     |> assign(:is_admin, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     |> assign(:query, nil)
     |> assign(:selected, nil)
     |> assign(:usages, empty_usages())
     |> assign(:usage_counts, %{})
     |> assign(:view, :library)
     |> assign(:trashed, [])
     |> assign(:refresh_timer, nil)
     |> assign(:media, [])
     |> assign(:more?, false)
     |> assign(:total, 0)
     |> assign(:unsplash_enabled?, Unsplash.enabled?())
     |> assign(:unsplash_query, "")
     |> assign(:unsplash_photos, [])
     |> assign(:unsplash_page, 1)
     |> assign(:unsplash_more?, false)
     |> assign(:unsplash_searching?, false)
     |> assign(:unsplash_importing, MapSet.new())
     |> allow_upload(:media,
       accept: @accept,
       max_entries: @max_entries,
       max_file_size: @max_file_size
     )}
  end

  # The library filter and the open item live in the URL (audit U-M3) so
  # refresh/back/share keep them; the search patch uses `replace: true` to
  # avoid one history entry per debounced keystroke. The filter runs in the
  # database (audit U-M2), so it finds items beyond the loaded pages.
  @impl true
  def handle_params(params, _uri, socket) do
    # `?q[a]=1` decodes to a MAP, which flowed into `search_filter/1`'s
    # `String.replace/3` and raised (#764). Bookmarkable URL, so absent is the
    # right answer — same as the omitted parameter.
    q = Params.string(params, "q", "")

    socket =
      if q == socket.assigns.query,
        do: socket,
        else: socket |> assign(:query, q) |> load_media()

    {:noreply, assign_selected(socket, params["id"])}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("search", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, push_patch(socket, to: media_path(q, nil), replace: true)}
  end

  def handle_event("load_more", _params, socket) do
    case List.last(socket.assigns.media) do
      nil ->
        {:noreply, assign(socket, :more?, false)}

      last ->
        {page, more?} = fetch_media(socket, last.inserted_at, @page_size)

        {:noreply,
         socket
         |> assign(:media, socket.assigns.media ++ page)
         |> assign(:more?, more?)}
    end
  end

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
  end

  def handle_event("save", _params, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    results =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        {:ok, {entry.client_name, store_entry(path, entry, actor, org)}}
      end)

    {ok, failed} = Enum.split_with(results, fn {_name, result} -> result == :ok end)
    failures = for {name, {:error, reason}} <- failed, do: {name, reason}

    socket =
      socket
      |> reload_media()
      |> flash_for_upload(length(ok), failures)

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case CMS.get_media_item(id, actor: actor, tenant: socket.assigns.current_org) do
        {:ok, item} -> delete_item(socket, item, actor)
        _ -> put_flash(socket, :error, gettext("That item no longer exists."))
      end

    {:noreply, socket |> assign(:selected, nil) |> reload_media()}
  end

  # --- trash -----------------------------------------------------------------

  # Bulk variant regeneration (#473) — admin-only.
  #
  # The scan runs in a supervised task, not here. Oban's unique inserts are one
  # transaction per row, so enqueuing a ten-thousand-image library is tens of
  # thousands of serialized round trips — long enough to block this LiveView
  # past the heartbeat and drop the socket. The work itself then runs on the
  # throttled `:media` queue at the lowest priority.
  #
  # The tier is re-read rather than trusted from the mount assign: `Regeneration`
  # reads with `authorize?: false`, so this check is the only one, and an
  # assign captured at mount outlives a revoked role for the life of the socket.
  def handle_event("regenerate_variants", _params, socket) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      org_id = socket.assigns.current_org.id

      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn ->
        KilnCMS.Media.Regeneration.run(org_id, only_missing?: false)
      end)

      {:noreply,
       put_flash(
         socket,
         :info,
         gettext(
           "Reprocessing the library in the background. Originals are untouched; new variants appear as jobs finish."
         )
       )}
    else
      {:noreply, put_flash(socket, :error, gettext("You need admin access to do that."))}
    end
  end

  def handle_event("show_trash", _params, socket) do
    actor = socket.assigns.actor

    if socket.assigns.is_admin do
      {:noreply,
       socket
       |> assign(:view, :trash)
       |> assign(:trashed, list_trashed(actor, socket.assigns.current_org))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_library", _params, socket),
    do: {:noreply, assign(socket, :view, :library)}

  # --- Unsplash --------------------------------------------------------------

  def handle_event("show_unsplash", _params, socket) do
    if socket.assigns.unsplash_enabled? do
      {:noreply, assign(socket, :view, :unsplash)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("unsplash_search", %{"q" => q}, socket) when is_binary(q) do
    case String.trim(q) do
      "" ->
        {:noreply,
         socket
         |> assign(:unsplash_query, "")
         |> assign(:unsplash_photos, [])
         |> assign(:unsplash_more?, false)
         |> assign(:unsplash_searching?, false)}

      query ->
        {:noreply,
         socket
         |> assign(:unsplash_query, query)
         |> assign(:unsplash_page, 1)
         |> assign(:unsplash_searching?, true)
         |> start_async(:unsplash_search, fn -> {query, 1, Unsplash.search(query, 1)} end)}
    end
  end

  def handle_event("unsplash_load_more", _params, socket) do
    %{unsplash_query: query, unsplash_page: page} = socket.assigns
    next = page + 1

    {:noreply,
     socket
     |> assign(:unsplash_searching?, true)
     |> start_async(:unsplash_search, fn -> {query, next, Unsplash.search(query, next)} end)}
  end

  def handle_event("unsplash_import", %{"id" => id}, socket) do
    photo = Enum.find(socket.assigns.unsplash_photos, &(&1.id == id))

    if is_nil(photo) or MapSet.member?(socket.assigns.unsplash_importing, id) do
      {:noreply, socket}
    else
      actor = socket.assigns.actor
      org = socket.assigns.current_org

      {:noreply,
       socket
       |> assign(:unsplash_importing, MapSet.put(socket.assigns.unsplash_importing, id))
       |> start_async({:unsplash_import, id}, fn -> import_unsplash(photo, actor, org) end)}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case find_trashed(socket, id) do
        nil ->
          put_flash(socket, :error, gettext("That item no longer exists."))

        item ->
          case CMS.restore_media_item(item, actor: actor, tenant: socket.assigns.current_org) do
            {:ok, _} ->
              put_flash(socket, :info, gettext("Restored %{name}.", name: item.filename))

            _ ->
              put_flash(socket, :error, gettext("You don't have permission to restore media."))
          end
      end

    {:noreply,
     socket
     |> assign(:trashed, list_trashed(actor, socket.assigns.current_org))
     |> reload_media()}
  end

  def handle_event("purge", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      case find_trashed(socket, id) do
        nil -> put_flash(socket, :error, gettext("That item no longer exists."))
        item -> purge_item(socket, item, actor)
      end

    {:noreply, assign(socket, :trashed, list_trashed(actor, socket.assigns.current_org))}
  end

  # Selection lives in the URL, so an open drawer survives refresh and can be
  # deep-linked (e.g. from the search palette).
  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: media_path(socket.assigns.query, id))}

  def handle_event("close", _params, socket),
    do: {:noreply, push_patch(socket, to: media_path(socket.assigns.query, nil))}

  # Click on the focal editor: move the point the focal-aware crops center on.
  def handle_event("set_focal", %{"x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    case KilnCMS.Media.Transform.set_focal_point(socket.assigns.selected, x, y,
           actor: socket.assigns.actor
         ) do
      {:ok, item} -> {:noreply, socket |> assign(:selected, item) |> reload_media()}
      _error -> {:noreply, put_flash(socket, :error, gettext("Couldn't set the focal point."))}
    end
  end

  # Rotate/flip the original (a new file — the previous one keeps serving
  # already-published snapshots), then variants regenerate in the background.
  def handle_event("transform", %{"op" => op}, socket)
      when op in ~w(rotate_left rotate_right flip_horizontal flip_vertical) do
    case KilnCMS.Media.Transform.apply(
           socket.assigns.selected,
           String.to_existing_atom(op),
           actor: socket.assigns.actor
         ) do
      {:ok, item} ->
        {:noreply,
         socket
         |> assign(:selected, item)
         |> reload_media()
         |> put_flash(:info, gettext("Image updated — variants are regenerating."))}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't edit that image."))}
    end
  end

  def handle_event("save_meta", %{"alt" => alt, "caption" => caption} = params, socket) do
    actor = socket.assigns.actor
    decorative = params["decorative"] in [true, "true"]

    socket =
      case CMS.update_media_item(
             socket.assigns.selected,
             %{alt: alt, caption: caption, decorative: decorative},
             actor: actor,
             tenant: socket.assigns.current_org
           ) do
        {:ok, item} ->
          socket
          |> assign(:selected, item)
          |> reload_media()
          |> put_flash(:info, gettext("Saved details."))

        _ ->
          put_flash(socket, :error, gettext("Couldn't save those details."))
      end

    {:noreply, socket}
  end

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("URL copied to clipboard."))}

  @impl true
  def handle_async(:unsplash_search, result, socket) do
    socket = assign(socket, :unsplash_searching?, false)

    case result do
      # A result for a query the user has since replaced — drop it.
      {:ok, {query, _page, _result}} when query != socket.assigns.unsplash_query ->
        {:noreply, socket}

      {:ok, {_query, page, {:ok, %{photos: photos, more?: more?}}}} ->
        photos = if page == 1, do: photos, else: socket.assigns.unsplash_photos ++ photos

        {:noreply,
         socket
         |> assign(:unsplash_photos, photos)
         |> assign(:unsplash_page, page)
         |> assign(:unsplash_more?, more?)}

      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Unsplash search failed — please try again."))}
    end
  end

  def handle_async({:unsplash_import, id}, result, socket) do
    socket =
      assign(socket, :unsplash_importing, MapSet.delete(socket.assigns.unsplash_importing, id))

    case result do
      {:ok, {:ok, item}} ->
        {:noreply,
         socket
         |> reload_media()
         |> put_flash(
           :info,
           gettext("Imported %{name} into the library.", name: item.filename)
         )}

      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Couldn't import that photo from Unsplash."))}
    end
  end

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
    {:noreply, socket |> assign(:refresh_timer, nil) |> reload_media()}
  end

  # --- helpers ---------------------------------------------------------------

  # Tries the image path first (the common case), then A/V (#494), then
  # documents (#481) — the byte-sniffers are independent and a file can only
  # ever satisfy one, so trying each in turn costs nothing an outright
  # rejection wouldn't already cost. The *last* sniffer's error is the one
  # reported, which is why documents go last: "unsupported format" from the
  # narrowest validator is the least misleading message for a file that
  # matched nothing.
  #
  # `source`, when removed, is the server-built stripped temp file (UUID path),
  # never user input — the File.rm traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  # Returns :ok or {:error, reason} — the reason reaches the failure flash so
  # editors learn WHICH file failed and why, not just a count (audit U-M5).
  defp store_entry(path, entry, actor, org) do
    case ImageProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type}} ->
        with :ok <- check_size(path, @max_image_size) do
          store_image(path, ext, content_type, entry, actor, org)
        end

      {:error, _reason} ->
        store_entry_as_av(path, entry, actor, org)
    end
  end

  defp store_entry_as_av(path, entry, actor, org) do
    case AVProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type, kind: kind}} ->
        with :ok <- check_size(path, av_size_cap(kind)) do
          # No metadata-stripping step, same as the document path: an MP4's
          # metadata atoms need container-specific tooling this codebase
          # doesn't have (tracked separately).
          store_as_is(path, ext, content_type, entry, actor, org)
        end

      {:error, _reason} ->
        store_entry_as_document(path, entry, actor, org)
    end
  end

  defp av_size_cap(:video), do: @max_video_size
  defp av_size_cap(:audio), do: @max_audio_size
  defp av_size_cap(:captions), do: @max_captions_size

  defp store_entry_as_document(path, entry, actor, org) do
    case DocumentProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type}} ->
        # Strip BEFORE the size check reads the file we store, and store the
        # stripped copy — the image path draws the same line, for the same
        # reason: what gets recorded must be what a reader will download.
        with :ok <- check_size(path, @max_document_size),
             {:ok, stripped} <- DocumentProcessor.strip_metadata(path) do
          try do
            store_as_is(stripped, ext, content_type, entry, actor, org)
          after
            File.rm(stripped)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Measured from the RECEIVED FILE, not `entry.client_size`.
  #
  # `client_size` is a number the browser put in the upload payload; a modified
  # client can declare anything. LiveView enforces the real byte count only
  # against `allow_upload`'s single `max_file_size`, which is the largest cap
  # here (500 MB, for video) — so trusting `client_size` would make every
  # tighter per-kind cap advisory, and a "2 MB" caption track could be 500 MB
  # of anything. `File.stat` is the only number nobody outside this server
  # chose.
  #
  # `path` is LiveView's own server-generated upload temp file — the traversal
  # warning is the same false positive as elsewhere in this module.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_size(path, max) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= max -> :ok
      {:ok, _stat} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  # The stored blob's real size, for `MediaItem.byte_size`. Same reasoning as
  # `check_size/2`: what gets recorded should be what a reader will actually
  # download, which for an image is the *stripped* copy rather than what the
  # client uploaded or claimed.
  # sobelow_skip ["Traversal.FileModule"]
  defp stored_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp store_image(path, ext, content_type, entry, actor, org) do
    key = Storage.generate_key_with_ext(ext)
    # Strip EXIF/GPS + the client filename before persisting (#215). On any
    # strip failure we fall back to the original so a valid upload still saves.
    {source, stripped?} = stripped_source(path, ext)

    try do
      case Storage.store(key, source) do
        {:ok, ^key} ->
          create_from_upload(key, content_type, stored_size(source), entry, actor, org)

        _ ->
          {:error, :storage_failed}
      end
    after
      if stripped?, do: File.rm(source)
    end
  end

  # No metadata-stripping step (#481 follow-up: PDF metadata needs
  # PDF-specific tooling this codebase doesn't have yet, unlike
  # ImageProcessor's libvips-based strip; the same is true of MP4 atoms) —
  # the upload's own temp file is stored as-is, matching what the image path
  # does when stripping fails. Shared by the document and A/V paths.
  defp store_as_is(path, ext, content_type, entry, actor, org) do
    key = Storage.generate_key_with_ext(ext)

    case Storage.store(key, path) do
      {:ok, ^key} -> create_from_upload(key, content_type, stored_size(path), entry, actor, org)
      _ -> {:error, :storage_failed}
    end
  end

  # Import an Unsplash photo: download (which also reports the download to
  # Unsplash, per their guidelines), then run the same validate → strip →
  # store → create pipeline as a direct upload. Runs inside start_async.
  # sobelow_skip ["Traversal.FileModule"] — path is a server-generated temp file.
  defp import_unsplash(photo, actor, org) do
    with {:ok, path} <- Unsplash.download(photo) do
      try do
        store_unsplash(path, photo, actor, org)
      after
        File.rm(path)
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp store_unsplash(path, photo, actor, org) do
    case ImageProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type}} ->
        key = Storage.generate_key_with_ext(ext)
        {source, stripped?} = stripped_source(path, ext)

        try do
          case Storage.store(key, source) do
            {:ok, ^key} ->
              attrs = %{
                filename: "unsplash-#{photo.id}#{ext}",
                content_type: content_type,
                byte_size: File.stat!(source).size,
                storage_key: key,
                url: Storage.url(key),
                alt: photo.alt,
                caption: Unsplash.attribution(photo)
              }

              case CMS.create_media_item(attrs, actor: actor, tenant: org) do
                {:ok, item} ->
                  enqueue_processing(item)
                  {:ok, item}

                _ ->
                  Storage.delete(key)
                  {:error, :create_failed}
              end

            _ ->
              {:error, :storage_failed}
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

  defp create_from_upload(key, content_type, byte_size, entry, actor, org) do
    attrs = %{
      filename: entry.client_name,
      content_type: content_type,
      byte_size: byte_size,
      storage_key: key,
      url: Storage.url(key)
    }

    case CMS.create_media_item(attrs, actor: actor, tenant: org) do
      {:ok, item} ->
        enqueue_processing(item)
        :ok

      _ ->
        Storage.delete(key)
        {:error, :create_failed}
    end
  end

  # Queue background dimension/variant processing (keeps libvips and ffmpeg
  # off the upload request). The worker re-fetches the original from storage,
  # so there's no node-local temp hand-off.
  #
  # A/V goes to `Media.AVWorker` instead (#494), and a caption track / a
  # document goes nowhere at all: neither has anything to derive, and
  # `VariantWorker` would just fetch the blob to discover libvips can't read
  # it.
  defp enqueue_processing(item) do
    # Carry the item's org so the worker re-fetches/updates under its tenant
    # (epic #336) — future-proof for the strict `global?: false` flip.
    args = %{media_item_id: item.id, org_id: item.org_id}

    cond do
      MediaKind.playable?(item.content_type) ->
        args |> KilnCMS.Media.AVWorker.new() |> Oban.insert!()

      MediaKind.of(item.content_type) == :image ->
        args |> KilnCMS.Media.VariantWorker.new() |> Oban.insert!()

      true ->
        :ok
    end
  end

  defp delete_variant_blobs(variants) do
    for {_label, %{"key" => key}} <- variants || %{}, do: Storage.delete(key)
  end

  # Soft delete: stamp `archived_at` but keep the row and blobs, so content still
  # referencing the item keeps working and an admin can restore it from trash.
  defp delete_item(socket, item, actor) do
    case CMS.destroy_media_item(item, actor: actor, tenant: socket.assigns.current_org) do
      :ok -> put_flash(socket, :info, gettext("Moved %{name} to trash.", name: item.filename))
      _ -> put_flash(socket, :error, gettext("You don't have permission to delete media."))
    end
  end

  # Permanent delete: drop the row and reclaim the original + variant blobs.
  defp purge_item(socket, item, actor) do
    case CMS.purge_media_item(item, actor: actor, tenant: socket.assigns.current_org) do
      :ok ->
        if item.storage_key, do: Storage.delete(item.storage_key)
        delete_variant_blobs(item.variants)
        put_flash(socket, :info, gettext("Permanently deleted %{name}.", name: item.filename))

      _ ->
        put_flash(socket, :error, gettext("You don't have permission to delete media."))
    end
  end

  defp find_trashed(socket, id), do: Enum.find(socket.assigns.trashed, &(&1.id == id))

  defp list_trashed(actor, org) do
    CMS.list_trashed_media_items!(
      actor: actor,
      tenant: org,
      query: [sort: [updated_at: :desc], limit: @max_trashed]
    )
  end

  # The thumbnail to show in the grid — the small variant when available,
  # else the original — or `nil` for a document (no `width`, so nothing was
  # ever generated to preview) or a gated item (no public `url` — #481), so
  # the caller falls back to a file badge instead of a broken/blank `<img>`.
  #
  # Dispatching on kind FIRST matters for A/V (#494): a video ffprobe measured
  # has a `width` exactly like an image does, so the image rules below would
  # otherwise put an `.mp4` in an `<img src>`. Its generated poster frame,
  # when it has one, is the only image a video has.
  defp thumb_src(item) do
    case MediaKind.of(item.content_type) do
      :image -> image_thumb_url(item)
      :video -> poster_url(item)
      _kind -> nil
    end
  end

  defp poster_url(%{variants: %{"poster" => %{"url" => url}}}), do: url
  defp poster_url(_item), do: nil

  defp image_thumb_url(%{variants: %{"thumb" => %{"url" => url}}}), do: url
  defp image_thumb_url(%{width: nil}), do: nil
  defp image_thumb_url(item), do: item.url

  defp image?(item), do: MediaKind.of(item.content_type) == :image

  # `nil` (rather than "—") when there's nothing measured, so the caller can
  # drop the whole row: an unprobed video with no ffmpeg installed shouldn't
  # advertise a Duration field it will never fill in.
  defp duration_label(item), do: MediaKind.humanize_duration(item.duration_seconds)

  # The placeholder icon when there is no thumbnail to show — a document, an
  # unprobed video, a gated item. Naming the kind is the difference between
  # "this file is broken" and "this is a video with no poster yet".
  defp kind_icon(item) do
    case MediaKind.of(item.content_type) do
      :video -> "hero-film"
      :audio -> "hero-musical-note"
      :captions -> "hero-language"
      _kind -> "hero-document"
    end
  end

  defp file_ext(filename) do
    case filename && Path.extname(filename) do
      "." <> ext -> String.upcase(ext)
      _ -> "FILE"
    end
  end

  # First page under the current filter.
  defp load_media(socket) do
    {items, more?} = fetch_media(socket, nil, @page_size)

    socket
    |> assign(:media, items)
    |> assign(:more?, more?)
    |> assign(:usage_counts, usage_counts(items, socket.assigns.current_org))
    |> assign(:total, count_media(socket))
  end

  # One query for the whole grid, so the delete confirmation can say what a
  # delete affects. Best-effort: the count is context, and an unreadable
  # reference graph must not stop the library from rendering.
  defp usage_counts(items, org_id) do
    KilnCMS.Firing.References.usage_counts(tenant_id(org_id), Enum.map(items, & &1.id))
  rescue
    _error -> %{}
  end

  # Refresh the loaded items in place (after uploads, deletes, metadata edits,
  # variant completions) without collapsing Load more depth.
  defp reload_media(socket) do
    depth = max(@page_size, length(socket.assigns.media))
    {items, more?} = fetch_media(socket, nil, depth)

    socket
    |> assign(:media, items)
    |> assign(:more?, more?)
    |> assign(:total, count_media(socket))
  end

  # Total items under the current filter, so the heading can say
  # "Library (60 of 679)" rather than passing the loaded page off as the
  # whole library.
  defp count_media(socket) do
    query =
      case socket.assigns.query do
        q when q in [nil, ""] -> []
        q -> [filter: search_filter(q)]
      end

    CMS.list_media_items!(
      actor: socket.assigns.actor,
      tenant: socket.assigns.current_org,
      query: query,
      page: [limit: 1, count: true]
    ).count
  end

  defp fetch_media(socket, cursor, limit) do
    items =
      CMS.list_media_items!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: media_query(socket.assigns.query, cursor, limit)
      )

    {items, length(items) >= limit}
  end

  defp media_query(q, cursor, limit) do
    [
      q not in [nil, ""] && {:filter, search_filter(q)},
      cursor && {:filter, expr(inserted_at < ^cursor)}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Kernel.++(sort: [inserted_at: :desc], limit: limit)
  end

  # Case-insensitive match on filename, alt text or caption — what the filter
  # placeholder promises; %, _ and \ in the input match literally.
  defp search_filter(q) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"
    expr(ilike(filename, ^pattern) or ilike(alt, ^pattern) or ilike(caption, ^pattern))
  end

  defp media_path(q, id) do
    params =
      [q: q, id: id]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    ~p"/media?#{params}"
  end

  defp assign_selected(socket, nil),
    do: socket |> assign(:selected, nil) |> assign(:usages, empty_usages())

  defp assign_selected(socket, id) do
    case CMS.get_media_item(id, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
      {:ok, item} ->
        socket
        |> assign(:selected, item)
        |> assign(:usages, usages(item, socket.assigns.current_org))

      _ ->
        socket
        |> assign(:selected, nil)
        |> assign(:usages, empty_usages())
        |> put_flash(:error, gettext("That item no longer exists."))
    end
  end

  # Best-effort: the "used by" list is context, and an editor must still be able
  # to open a media item when the reference graph can't be read.
  defp usages(item, org_id) do
    KilnCMS.Firing.References.usages(tenant_id(org_id) || item.org_id, item.id)
  rescue
    _error -> empty_usages()
  end

  # Deleting a hero image without being told what it appears on is how a page
  # loses its hero (#403). The count comes from one query over the whole grid,
  # so it is available at the point of decision rather than only inside a drawer
  # the editor may never open.
  defp delete_confirm(item, counts) do
    case Map.get(counts, item.id) do
      nil ->
        gettext("Delete %{name}?", name: item.filename)

      count ->
        gettext("Delete %{name}? It is used by %{count} published document(s).",
          name: item.filename,
          count: count
        )
    end
  end

  defp empty_usages, do: %{total: 0, items: []}

  # `current_org` is the org STRUCT on this LiveView; the reference read wants
  # its id.
  defp tenant_id(%{id: id}), do: id
  defp tenant_id(id) when is_binary(id), do: id
  defp tenant_id(_other), do: nil

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

  defp upload_failure_reason(:too_many_pixels), do: gettext("image dimensions are too large")
  defp upload_failure_reason(:unsupported_format), do: gettext("unsupported file format")
  defp upload_failure_reason(:too_large), do: gettext("file is too large for its type")
  defp upload_failure_reason(:storage_failed), do: gettext("couldn't be stored")
  defp upload_failure_reason(:create_failed), do: gettext("couldn't be saved")

  # #807. Both of these mean "we could not remove this PDF's metadata", and the
  # upload is refused rather than stored unstripped — so the message has to name
  # the server as the problem, not the file. An editor told "unsupported format"
  # about a PDF that opens fine everywhere would keep retrying it.
  defp upload_failure_reason(:unavailable),
    do: gettext("can't be processed — PDF metadata stripping isn't available on this server")

  defp upload_failure_reason(:strip_failed),
    do: gettext("couldn't have its metadata removed, so it wasn't stored")

  defp upload_failure_reason(_invalid), do: gettext("not a supported file")

  defp humanize_bytes(nil), do: "—"
  defp humanize_bytes(b) when b < 1_024, do: gettext("%{size} B", size: b)

  defp humanize_bytes(b) when b < 1_048_576,
    do: gettext("%{size} KB", size: Float.round(b / 1_024, 1))

  defp humanize_bytes(b), do: gettext("%{size} MB", size: Float.round(b / 1_048_576, 1))

  defp error_to_string(:too_large), do: gettext("too large (max 10 MB)")
  defp error_to_string(:too_many_files), do: gettext("too many files (max 10)")
  defp error_to_string(:not_accepted), do: gettext("unsupported type")
  defp error_to_string(other), do: to_string(other)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtering?, assigns.query not in [nil, ""])

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:media}
    >
      <div class="space-y-8">
        <div class="flex items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold">{gettext("Media library")}</h1>
            <p class="text-sm text-base-content/70">
              {gettext("Upload and manage images, documents, video and audio.")}
            </p>
          </div>
          <div :if={@is_admin or @unsplash_enabled?} class="tabs" role="tablist">
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@view == :library)}
              phx-click="show_library"
              class="tab"
            >
              {gettext("Library")}
            </button>
            <button
              :if={@unsplash_enabled?}
              type="button"
              role="tab"
              aria-selected={to_string(@view == :unsplash)}
              phx-click="show_unsplash"
              class="tab"
            >
              {gettext("Unsplash")}
            </button>
            <button
              :if={@is_admin}
              type="button"
              role="tab"
              aria-selected={to_string(@view == :trash)}
              phx-click="show_trash"
              class="tab"
            >
              {gettext("Trash")}
            </button>
          </div>
        </div>

        <div :if={@is_admin} class="flex flex-wrap items-center gap-3 text-sm">
          <button
            type="button"
            phx-click="regenerate_variants"
            data-confirm={
              gettext(
                "Reprocess every image in the library? Originals are untouched — this rebuilds the responsive and modern-format variants in the background."
              )
            }
            class="btn btn-sm btn-default"
          >
            <.icon name="hero-arrow-path" class="mr-1 size-4" />{gettext("Regenerate variants")}
          </button>
          <span class="text-xs text-base-content/60">
            {gettext("Variant formats: %{formats}. Run this after changing them.",
              formats: variant_format_summary()
            )}
          </span>
        </div>

        <.trash_panel :if={@view == :trash} items={@trashed} />

        <.unsplash_panel
          :if={@view == :unsplash}
          query={@unsplash_query}
          photos={@unsplash_photos}
          more?={@unsplash_more?}
          searching?={@unsplash_searching?}
          importing={@unsplash_importing}
        />

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
                {gettext("Choose files")}
              </label>
              {gettext("or drag and drop")}
            </p>
            <%!-- The accepted set is worth spelling out per kind rather than
                  as one list: the caps differ by an order of magnitude, and
                  A/V is the one where "why was this rejected" is otherwise
                  unanswerable — there is no transcoding, so the container
                  matters (#494). --%>
            <p class="mt-1 text-xs text-base-content/70">
              {gettext("Images: PNG, JPG, WEBP, GIF up to 10 MB")}
            </p>
            <p class="text-xs text-base-content/70">
              {gettext("Documents: PDF up to 25 MB")}
            </p>
            <p class="text-xs text-base-content/70">
              {gettext(
                "Video: MP4, WebM up to 500 MB · Audio: MP3, M4A up to 100 MB · Captions: WebVTT"
              )}
            </p>
            <p class="text-xs text-base-content/50">
              {gettext("Video and audio are served as uploaded — export web-ready H.264/AAC.")}
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
              {if length(@media) < @total,
                do:
                  gettext("Library (%{count} of %{total})",
                    count: length(@media),
                    total: @total
                  ),
                else: gettext("Library (%{count})", count: length(@media))}
            </h2>
            <form
              :if={@media != [] or @filtering?}
              id="media-filter"
              phx-change="search"
              class="sm:w-auto"
            >
              <label for="media-filter-input" class="sr-only">
                {gettext("Filter by filename, alt text or caption")}
              </label>
              <input
                id="media-filter-input"
                type="text"
                name="q"
                value={@query}
                placeholder={gettext("Filter by filename, alt or caption")}
                aria-label={gettext("Filter by filename, alt text or caption")}
                phx-debounce="200"
                autocomplete="off"
                class="field-input w-full sm:w-auto"
              />
            </form>
          </div>
          <p class="sr-only" role="status">
            {ngettext("%{count} file shown", "%{count} files shown", length(@media),
              count: length(@media)
            )}
          </p>
          <.empty_state
            :if={@media == [] and not @filtering?}
            icon="hero-photo"
            title={gettext("No media yet")}
          >
            {gettext("Upload a file above to start building your library.")}
          </.empty_state>
          <p :if={@media == [] and @filtering?} class="text-sm text-base-content/60">
            {gettext("No media matches “%{query}”.", query: @query)}
          </p>
          <ul
            :if={@media != []}
            class="grid grid-cols-2 gap-4 sm:grid-cols-3"
            id="media-grid"
            phx-update="replace"
          >
            <li
              :for={item <- @media}
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
                  :if={thumb_src(item)}
                  src={thumb_src(item)}
                  alt={item.alt || item.filename}
                  loading="lazy"
                  class="aspect-square w-full object-cover"
                />
                <%!-- A document (no width, so no thumbnail variant), a gated
                      item (no public `url` to preview — #481) or an A/V item
                      with no poster frame (#494) gets a kind badge instead of
                      a broken/blank <img>. --%>
                <div
                  :if={!thumb_src(item)}
                  class="flex aspect-square w-full flex-col items-center justify-center gap-1 bg-base-200 text-base-content/60"
                >
                  <.icon name={kind_icon(item)} class="size-8" />
                  <span class="text-[10px] font-medium uppercase">{file_ext(item.filename)}</span>
                </div>
              </button>
              <div class="p-2">
                <p class="truncate text-xs font-medium">{item.filename}</p>
                <p class="flex items-center gap-1 text-[10px] text-base-content/70">
                  <span :if={item.width}>{item.width}×{item.height}</span>
                  <span>{humanize_bytes(item.byte_size)}</span>
                  <span
                    :if={item.audience != :public}
                    class="rounded bg-warning/15 px-1 py-px text-[9px] font-semibold uppercase text-warning-ink"
                    title={gettext("Gated to the %{audience} audience", audience: item.audience)}
                  >
                    {gettext("Gated")}
                  </span>
                  <%!-- `decorative` clears the warning (#403): an editor who has
                        correctly marked a divider must not watch the badge stay
                        lit, or they learn to ignore it on the images that
                        really are missing alt. --%>
                  <span
                    :if={!item.alt && !item.decorative}
                    class="text-warning"
                    title={gettext("Missing alt text")}
                  >
                    {gettext("· no alt")}
                  </span>
                </p>
              </div>
              <button
                phx-click="delete"
                phx-value-id={item.id}
                data-confirm={delete_confirm(item, @usage_counts)}
                aria-label={gettext("Delete")}
                class="absolute right-1 top-1 rounded bg-base-100/80 p-1 transition hover:text-error opacity-100 sm:opacity-0 sm:group-hover:opacity-100 focus:opacity-100 focus-visible:opacity-100"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>

          <div :if={@more?} class="mt-4 flex justify-center">
            <button
              type="button"
              phx-click="load_more"
              phx-disable-with={gettext("Loading…")}
              class="btn btn-default"
            >
              {gettext("Load more")}
            </button>
          </div>
        </div>
      </div>

      <.media_detail :if={@selected} item={@selected} usages={@usages} />
    </Layouts.console>
    """
  end

  attr :query, :string, required: true
  attr :photos, :list, required: true
  attr :more?, :boolean, required: true
  attr :searching?, :boolean, required: true
  attr :importing, :any, required: true

  # Unsplash stock-photo search: importing a result downloads the file
  # server-side and adds it to the library like a regular upload.
  defp unsplash_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <form id="unsplash-search" phx-submit="unsplash_search" class="flex gap-2">
        <label for="unsplash-search-input" class="sr-only">
          {gettext("Search Unsplash photos")}
        </label>
        <input
          id="unsplash-search-input"
          type="text"
          name="q"
          value={@query}
          placeholder={gettext("Search Unsplash photos")}
          autocomplete="off"
          class="field-input min-w-0 flex-1"
        />
        <.button type="submit" variant="primary" phx-disable-with={gettext("Searching…")}>
          {gettext("Search")}
        </.button>
      </form>

      <p class="text-xs text-base-content/60">
        {gettext("Photos from Unsplash — importing adds a copy to your library.")}
      </p>

      <p :if={@searching? and @photos == []} class="text-sm text-base-content/60" role="status">
        {gettext("Searching…")}
      </p>

      <p
        :if={!@searching? and @photos == [] and @query != ""}
        class="text-sm text-base-content/60"
        role="status"
      >
        {gettext("No photos match “%{query}”.", query: @query)}
      </p>

      <ul :if={@photos != []} class="grid grid-cols-2 gap-4 sm:grid-cols-3" id="unsplash-grid">
        <li
          :for={photo <- @photos}
          id={"unsplash-#{photo.id}"}
          class="overflow-hidden rounded border border-base-content/10"
        >
          <img
            src={photo.thumb_url}
            alt={photo.alt || gettext("Unsplash photo")}
            loading="lazy"
            class="aspect-square w-full object-cover"
          />
          <div class="flex items-center justify-between gap-2 p-2">
            <p class="min-w-0 truncate text-[10px] text-base-content/70">
              <a
                href={photo.photographer_url}
                target="_blank"
                rel="noopener noreferrer"
                class="hover:underline"
              >
                {photo.photographer}
              </a>
            </p>
            <button
              type="button"
              phx-click="unsplash_import"
              phx-value-id={photo.id}
              disabled={MapSet.member?(@importing, photo.id)}
              class="btn btn-sm btn-default shrink-0"
            >
              {if MapSet.member?(@importing, photo.id),
                do: gettext("Importing…"),
                else: gettext("Import")}
            </button>
          </div>
        </li>
      </ul>

      <div :if={@more?} class="flex justify-center">
        <button
          type="button"
          phx-click="unsplash_load_more"
          disabled={@searching?}
          class="btn btn-default"
        >
          {if @searching?, do: gettext("Loading…"), else: gettext("Load more")}
        </button>
      </div>
    </div>
    """
  end

  attr :items, :list, required: true

  # Trashed (soft-deleted) media: restore brings an item back to the library;
  # delete permanently purges the row and reclaims its storage blobs.
  defp trash_panel(assigns) do
    assigns = assign(assigns, :max_trashed, @max_trashed)

    ~H"""
    <div>
      <h2 class="mb-3 text-lg font-medium">{gettext("Trash (%{count})", count: length(@items))}</h2>
      <p :if={length(@items) >= @max_trashed} class="mb-3 text-xs text-base-content/60" role="status">
        {gettext(
          "Showing the %{max} most recently deleted files — older trashed files exist but aren't listed here.",
          max: @max_trashed
        )}
      </p>
      <p :if={@items == []} class="text-sm text-base-content/60">{gettext("Trash is empty.")}</p>
      <ul
        :if={@items != []}
        class="card divide-y divide-base-content/10 overflow-hidden"
      >
        <li :for={item <- @items} id={"trash-#{item.id}"} class="flex items-center gap-4 p-3">
          <img
            :if={thumb_src(item)}
            src={thumb_src(item)}
            alt={item.alt || item.filename}
            loading="lazy"
            class="size-12 shrink-0 rounded object-cover"
          />
          <%!-- Same kind badge the grid uses: a trashed document or A/V item
               has no thumbnail, and an <img> with a nil src renders as a
               broken image. --%>
          <div
            :if={!thumb_src(item)}
            class="flex size-12 shrink-0 items-center justify-center rounded bg-base-200 text-base-content/60"
          >
            <.icon name={kind_icon(item)} class="size-5" />
          </div>
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-medium">{item.filename}</p>
            <p class="text-xs text-base-content/70">
              {gettext("deleted")}
              <time
                id={"trash-time-#{item.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(item.updated_at)}
              >{Calendar.strftime(item.updated_at, "%Y-%m-%d %H:%M")} UTC</time>
            </p>
          </div>
          <button
            type="button"
            phx-click="restore"
            phx-value-id={item.id}
            class="btn btn-sm btn-default"
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
            class="btn btn-sm btn-danger"
          >
            {gettext("Delete permanently")}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :usages, :map, required: true

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

        <%!-- Raster images get the focal-point editor: click (or focus and use
             arrow keys) to move the point crops center on. Non-images keep a
             plain preview.

             Gated on `image?/1` as well as `width`, not `width` alone (#494):
             ffprobe writes `width`/`height` for a video too, and neither a
             focal point nor the rotate/flip controls below mean anything for
             one — `Media.Transform` runs libvips, which can't open an MP4. --%>
        <div :if={image?(@item) and @item.width} class="mt-4 flex justify-center">
          <div
            id={"focal-editor-#{@item.id}"}
            phx-hook="FocalPoint"
            role="button"
            tabindex="0"
            aria-label={gettext("Focal point — click or use arrow keys to set where crops center")}
            data-focal-x={@item.focal_x || 0.5}
            data-focal-y={@item.focal_y || 0.5}
            class="relative inline-block cursor-crosshair rounded focus:outline-none focus:ring-2 focus:ring-primary"
          >
            <img src={@item.url} alt={@item.alt || @item.filename} class="block max-h-64 rounded" />
            <span
              class="pointer-events-none absolute -ml-2 -mt-2 size-4 rounded-full border-2 border-white bg-primary/70 shadow"
              style={"left: #{(@item.focal_x || 0.5) * 100}%; top: #{(@item.focal_y || 0.5) * 100}%"}
            />
          </div>
        </div>
        <%!-- A/V (#494) previews in a real player rather than an <img>, and
             plays through the authorized stream route so a gated item
             previews here exactly as it would on a page. `preload="metadata"`
             keeps opening the drawer from pulling down a whole video. --%>
        <video
          :if={MediaKind.of(@item.content_type) == :video}
          id={"media-preview-#{@item.id}"}
          src={~p"/media/#{@item.id}/stream"}
          poster={poster_url(@item)}
          controls
          playsinline
          preload="metadata"
          class="mt-4 max-h-64 w-full rounded bg-black"
        />
        <audio
          :if={MediaKind.of(@item.content_type) == :audio}
          id={"media-preview-#{@item.id}"}
          src={~p"/media/#{@item.id}/stream"}
          controls
          preload="metadata"
          class="mt-4 w-full"
        />
        <img
          :if={image?(@item) and !@item.width}
          src={@item.url}
          alt={@item.alt || @item.filename}
          class="mt-4 max-h-64 w-full rounded object-contain"
        />

        <div
          :if={image?(@item) and @item.width}
          class="mt-2 flex flex-wrap items-center justify-center gap-1"
        >
          <button
            :for={
              {op, label, icon} <- [
                {"rotate_left", gettext("Rotate left"), "hero-arrow-uturn-left"},
                {"rotate_right", gettext("Rotate right"), "hero-arrow-uturn-right"},
                {"flip_horizontal", gettext("Flip horizontally"), "hero-arrows-right-left"},
                {"flip_vertical", gettext("Flip vertically"), "hero-arrows-up-down"}
              ]
            }
            type="button"
            phx-click="transform"
            phx-value-op={op}
            title={label}
            aria-label={label}
            class="btn btn-sm btn-default"
          >
            <.icon name={icon} class="size-4" />
          </button>
          <span class="ml-1 text-[10px] text-base-content/50">
            {gettext("Edits keep the previous file for already-published content.")}
          </span>
        </div>

        <dl class="mt-4 grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-base-content/70">
          <dt class="text-base-content/70">{gettext("Type")}</dt>
          <dd>{@item.content_type || "—"}</dd>
          <dt class="text-base-content/70">{gettext("Size")}</dt>
          <dd>{humanize_bytes(@item.byte_size)}</dd>
          <dt :if={@item.width} class="text-base-content/70">{gettext("Dimensions")}</dt>
          <dd :if={@item.width}>{@item.width} × {@item.height} px</dd>
          <dt :if={duration_label(@item)} class="text-base-content/70">{gettext("Duration")}</dt>
          <dd :if={duration_label(@item)}>{duration_label(@item)}</dd>
          <dt class="text-base-content/70">{gettext("Uploaded")}</dt>
          <dd>
            <time
              id="media-detail-uploaded"
              phx-hook="LocalTime"
              datetime={DateTime.to_iso8601(@item.inserted_at)}
            >{Calendar.strftime(@item.inserted_at, "%Y-%m-%d %H:%M")} UTC</time>
          </dd>
        </dl>

        <div :if={@item.variants not in [nil, %{}]} class="mt-4">
          <p class="text-xs text-base-content/70">{gettext("Responsive variants")}</p>
          <%!-- Preview each variant inline rather than linking to it. Media blobs carry
               `content-disposition: attachment` on both storage adapters — from
               KilnCMSWeb.Endpoint for Local, from object metadata for S3 — so
               navigating to a variant downloads a UUID-named file. That header is
               ignored for subresource loads, so an <img> previews it in place, which
               is how the rest of the library renders media anyway. Decorative alt: the
               label and dimensions name the row, and the full-size preview above
               carries the real alt text. --%>
          <ul class="mt-1 space-y-1">
            <li :for={{label, v} <- @item.variants} class="flex items-center gap-2 text-xs">
              <img
                src={v["url"]}
                alt=""
                loading="lazy"
                class="size-10 shrink-0 rounded border border-base-300 object-cover"
              />
              <span class="font-medium capitalize">{label}</span>
              <span class="ml-auto text-base-content/70">{v["width"]} × {v["height"]}</span>
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
              class="field-input min-w-0 flex-1"
            />
            <button
              type="button"
              id="copy-url"
              phx-hook="Clipboard"
              data-clipboard-text={@item.url}
              class="btn btn-sm btn-default shrink-0"
            >
              {gettext("Copy")}
            </button>
          </div>
          <p class="mt-1 text-[10px] text-base-content/50">
            {gettext(
              "Use this in content. Pasting it into the address bar downloads the file instead of displaying it."
            )}
          </p>
        </div>

        <form phx-submit="save_meta" class="mt-5 space-y-3">
          <div>
            <label for="media-alt" class="text-sm font-medium">{gettext("Alt text")}</label>
            <input
              id="media-alt"
              name="alt"
              value={@item.alt}
              placeholder={gettext("Describe the image for screen readers")}
              class="field-input mt-1"
            />
          </div>
          <%!-- Decorative is a recorded decision, not an inference from a blank
                field (#403): a divider or a texture correctly has no alt text,
                and without somewhere to say so it is indistinguishable from an
                oversight. The publish check reads this. --%>
          <label class="flex items-start gap-2 text-sm">
            <input type="hidden" name="decorative" value="false" />
            <input
              type="checkbox"
              name="decorative"
              value="true"
              checked={@item.decorative}
              class="mt-0.5"
            />
            <span>
              {gettext("Decorative — no alt text needed")}
              <span class="block text-[11px] text-base-content/50">
                {gettext("For dividers, textures, and images that only repeat nearby text.")}
              </span>
            </span>
          </label>
          <div>
            <label for="media-caption" class="text-sm font-medium">{gettext("Caption")}</label>
            <textarea
              id="media-caption"
              name="caption"
              rows="2"
              class="field-input mt-1"
            >{@item.caption}</textarea>
          </div>
          <.button type="submit" variant="primary">{gettext("Save details")}</.button>
        </form>

        <%!-- "Where is this used" (#403). Read from the reference graph the fire
              path already maintains, so it is an exact answer rather than a
              scan — and it is here because deleting or replacing an image
              without knowing what it appears on is how a page loses its hero. --%>
        <div class="mt-6 border-t border-base-content/10 pt-4">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            {gettext("Used by")}
          </h3>
          <p :if={@usages.total == 0} class="mt-2 text-sm text-base-content/60">
            {gettext("Not used by any published document.")}
          </p>
          <ul :if={@usages.items != []} class="mt-2 space-y-1">
            <li :for={usage <- @usages.items} class="flex items-center gap-2 text-sm">
              <.link
                :if={usage.kind}
                navigate={~p"/editor/content/#{usage.kind}/#{usage.id}"}
                class="link truncate"
              >
                {usage.title}
              </.link>
              <span :if={!usage.kind} class="truncate">{usage.title}</span>
              <span class="shrink-0 text-[11px] text-base-content/50">{usage.state}</span>
            </li>
          </ul>
          <p
            :if={@usages.total > length(@usages.items)}
            class="mt-2 text-[11px] text-base-content/50"
          >
            {gettext("and %{count} more", count: @usages.total - length(@usages.items))}
          </p>
          <p :if={@usages.total > 0} class="mt-2 text-[11px] text-base-content/50">
            {gettext("Drafts that have never been published are not listed.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Shown next to the regenerate button so an admin can see what a run would
  # produce before starting one.
  defp variant_format_summary do
    case KilnCMS.ImageProcessor.variant_formats() do
      [] -> gettext("source format only")
      formats -> Enum.map_join(formats, ", ", &String.upcase(to_string(&1)))
    end
  end
end
