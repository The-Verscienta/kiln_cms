defmodule KilnCMSWeb.MediaLive do
  @moduledoc """
  Media library — upload images (LiveView direct uploads), browse the library,
  and delete items. Reachable only by editors/admins (`:live_editor_required`).

  Browsing is faceted (#1316): filter chips for kind / tag / uploader / date
  range / unused run server-side through `MediaItem`'s `:library` read action
  (the same filters the JSON:API `/media-items/library` route exposes), and a
  selection mode turns the grid into bulk delete / bulk tag.
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr, only: [expr: 1]

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Media.Ingest
  alias KilnCMS.MediaKind
  alias KilnCMS.Storage
  alias KilnCMS.Unsplash
  alias KilnCMSWeb.Params

  @accept ~w(.jpg .jpeg .png .webp .gif .pdf .docx .xlsx .pptx .doc .xls .ppt .zip .mp4 .m4a .webm .mp3 .vtt)
  @max_entries 10
  # Phoenix's `allow_upload` takes one ceiling for every entry (there's no
  # per-accept-type cap in the API), so this is the LARGEST of the per-type
  # caps — `KilnCMS.Media.Ingest` enforces the tighter one for whichever type
  # an upload turns out to be, after byte-sniffing it. Video is the outlier and
  # the reason the ceiling is what it is (#494), which makes this also the
  # practical statement of "how big a file will Kiln accept" — see
  # docs/media-pipeline.md.
  @max_file_size Ingest.max_upload_size()
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
     # `filters: nil` is a sentinel: the first handle_params always loads.
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Media library"))
     |> assign(:is_admin, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     |> assign(:filters, nil)
     |> assign(:tag_options, [])
     |> assign(:uploader_options, [])
     |> assign(:selecting?, false)
     |> assign(:selected_ids, MapSet.new())
     |> put_selected(nil)
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

  # The library filters and the open item live in the URL (audit U-M3) so
  # refresh/back/share keep them; the filter patches use `replace: true` to
  # avoid one history entry per debounced keystroke. Filters run in the
  # database (audit U-M2), so they find items beyond the loaded pages.
  @impl true
  def handle_params(params, _uri, socket) do
    # Every parameter goes through `Params.string/3` + its own parser:
    # `?q[a]=1` decodes to a MAP, which flowed into `search_filter/1`'s
    # `String.replace/3` and raised (#764), and an unparseable kind/uuid/date
    # reads as "no filter on that axis" — same as the omitted parameter.
    filters = parse_filters(params)
    first_load? = is_nil(socket.assigns.filters)

    socket =
      if filters == socket.assigns.filters,
        do: socket,
        else: socket |> assign(:filters, filters) |> load_media()

    # Filter options (tags, uploaders) depend on org data, not on the
    # filters, so they load once here rather than on every debounced
    # keystroke's load_media; the mutation paths that can change them go
    # through refresh_library/1.
    socket = if first_load?, do: assign_filter_options(socket), else: socket

    # `?id[]=1` is the same bookmarkable shape, and `assign_selected/2`'s only
    # other clause is `nil` — so the list reached `CMS.get_media_item/2` as a
    # primary key. Absent reads as "nothing selected", which is what the
    # omitted parameter does.
    {:noreply, assign_selected(socket, Params.string(params, "id"))}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # The free-text input plus the tag/uploader/date controls, one form — any
  # change patches the URL and reloads. Kind and unused are chip buttons with
  # their own events; carry them over from the current filters.
  def handle_event("filter_change", params, socket) do
    filters = socket.assigns.filters

    filters = %{
      filters
      | q: Params.string(params, "q", filters.q),
        tag_id: form_value(params, "tag", filters.tag_id, &parse_uuid/1),
        uploader_id: form_value(params, "uploader", filters.uploader_id, &parse_uuid/1),
        from: form_value(params, "from", filters.from, &parse_date/1),
        to: form_value(params, "to", filters.to, &parse_date/1)
    }

    {:noreply, push_patch(socket, to: media_path(filters, nil), replace: true)}
  end

  # Kind chips are single-select; clicking the active one clears it.
  def handle_event("set_kind", %{"kind" => kind}, socket) when is_binary(kind) do
    filters = socket.assigns.filters
    kind = parse_kind(kind)
    kind = if filters.kind == kind, do: nil, else: kind

    {:noreply, push_patch(socket, to: media_path(%{filters | kind: kind}, nil), replace: true)}
  end

  def handle_event("toggle_unused", _params, socket) do
    filters = socket.assigns.filters

    {:noreply,
     push_patch(socket,
       to: media_path(%{filters | unused: !filters.unused}, nil),
       replace: true
     )}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: media_path(parse_filters(%{}), nil), replace: true)}
  end

  def handle_event("load_more", _params, socket) do
    case List.last(socket.assigns.media) do
      nil ->
        {:noreply, assign(socket, :more?, false)}

      last ->
        {page, more?} = fetch_media(socket, last.inserted_at, @page_size)

        # Extend the usage-count map for the new page, or every item past the
        # first page renders the bare "Delete X?" confirmation with no
        # used-by warning — the exact #403 failure the count exists to
        # prevent.
        counts =
          Map.merge(
            socket.assigns.usage_counts,
            usage_counts(page, socket.assigns.current_org, socket.assigns.actor)
          )

        {:noreply,
         socket
         |> assign(:media, socket.assigns.media ++ page)
         |> assign(:usage_counts, counts)
         |> assign(:more?, more?)}
    end
  end

  def handle_event("cancel", %{"ref" => ref}, socket) when is_binary(ref) do
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

    # Each ingest deferred its published-cache clear (`cache_bust: :defer` in
    # `store_entry/4`) — a 10-file drop must not full-clear the cache 10
    # times. One compensating clear for the batch.
    if ok != [], do: KilnCMS.CMS.Changes.BustMediaCache.bust()

    socket =
      socket
      |> refresh_library()
      |> flash_for_upload(length(ok), failures)

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor

    socket =
      case CMS.get_media_item(id, actor: actor, tenant: socket.assigns.current_org) do
        {:ok, item} -> delete_item(socket, item, actor)
        _ -> put_flash(socket, :error, gettext("That item no longer exists."))
      end

    {:noreply, socket |> put_selected(nil) |> refresh_library()}
  end

  # --- bulk selection (#1316) -------------------------------------------------

  def handle_event("toggle_selecting", _params, socket) do
    {:noreply,
     socket
     |> assign(:selecting?, !socket.assigns.selecting?)
     |> assign(:selected_ids, MapSet.new())}
  end

  def handle_event("toggle_selected", %{"id" => id}, socket) when is_binary(id) do
    selected = socket.assigns.selected_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected_ids, selected)}
  end

  # "All" means all *loaded* items — what the checkboxes on screen show, not
  # rows beyond Load more the editor has never seen.
  def handle_event("select_all", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new(socket.assigns.media, & &1.id))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  # Soft-deletes each selected item, like the per-tile delete. Per-item results
  # rather than all-or-nothing: one item another admin already trashed must not
  # sink the other nineteen. `Media.Bulk.delete/2` owns the loop and the
  # skip-and-compensate cache contract (one published-cache clear for the
  # whole operation, even if a destroy raises mid-loop).
  def handle_event("bulk_delete", _params, socket) do
    {ok, failed} =
      socket
      |> selected_items()
      |> KilnCMS.Media.Bulk.delete(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org
      )

    socket =
      cond do
        ok == 0 and failed == 0 ->
          socket

        failed == 0 ->
          put_flash(
            socket,
            :info,
            ngettext("Moved %{count} item to trash.", "Moved %{count} items to trash.", ok,
              count: ok
            )
          )

        true ->
          put_flash(
            socket,
            :error,
            gettext("Moved %{ok} to trash; %{failed} couldn't be deleted.",
              ok: ok,
              failed: failed
            )
          )
      end

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> put_selected(nil)
     |> refresh_library()}
  end

  # Add/remove one tag across the selection. Batched through
  # `KilnCMS.Media.Bulk` (one read + one bulk join write, same Tagging
  # policies) rather than a full per-item update pipeline — the semantics
  # match the merge verbs: other tags are left alone, and adding a carried
  # tag / removing an absent one are idempotent no-ops.
  def handle_event("bulk_tag", %{"tag_id" => tag_id, "op" => op}, socket)
      when is_binary(tag_id) and op in ~w(add remove) do
    items = selected_items(socket)

    case {parse_uuid(tag_id), items} do
      {nil, _items} ->
        {:noreply, put_flash(socket, :error, gettext("Choose a tag first."))}

      # Buttons are disabled at zero selected; a crafted event must not
      # flash "Tagged 0 items." (mirrors bulk_delete's empty branch).
      {_tag_id, []} ->
        {:noreply, socket}

      {tag_id, items} ->
        opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

        {ok, failed} =
          case op do
            "add" -> KilnCMS.Media.Bulk.add_tag(items, tag_id, opts)
            "remove" -> KilnCMS.Media.Bulk.remove_tag(items, tag_id, opts)
          end

        # Selection survives a tag pass so the editor can chain another one —
        # and if the open drawer's item was in the selection, its tags just
        # changed, so re-read it rather than rendering the stale struct. The
        # grid itself can only have changed when a tag filter is active
        # (membership), so skip the reload otherwise — a tag write touches
        # only the join table.
        socket = socket |> bulk_tag_flash(op, ok, failed) |> refresh_open_drawer()
        socket = if socket.assigns.filters.tag_id, do: reload_media(socket), else: socket

        {:noreply, socket}
    end
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
    if socket.assigns.unsplash_enabled? do
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
    else
      {:noreply, socket}
    end
  end

  def handle_event("unsplash_load_more", _params, socket) do
    if socket.assigns.unsplash_enabled? do
      %{unsplash_query: query, unsplash_page: page} = socket.assigns
      next = page + 1

      {:noreply,
       socket
       |> assign(:unsplash_searching?, true)
       |> start_async(:unsplash_search, fn -> {query, next, Unsplash.search(query, next)} end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("unsplash_import", %{"id" => id}, socket) when is_binary(id) do
    if socket.assigns.unsplash_enabled? do
      photo = Enum.find(socket.assigns.unsplash_photos, &(&1.id == id))

      if is_nil(photo) or MapSet.member?(socket.assigns.unsplash_importing, id) do
        {:noreply, socket}
      else
        actor = socket.assigns.actor
        org = socket.assigns.current_org

        {:noreply,
         socket
         |> assign(:unsplash_importing, MapSet.put(socket.assigns.unsplash_importing, id))
         |> start_async({:unsplash_import, id}, fn ->
           Unsplash.import_photo(photo, actor: actor, tenant: org)
         end)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) when is_binary(id) do
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
     |> refresh_library()}
  end

  def handle_event("purge", %{"id" => id}, socket) when is_binary(id) do
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
  def handle_event("select", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, push_patch(socket, to: media_path(socket.assigns.filters, id))}

  def handle_event("close", _params, socket),
    do: {:noreply, push_patch(socket, to: media_path(socket.assigns.filters, nil))}

  # Tagging one item from its drawer — same merge verbs the bulk bar uses.
  def handle_event("item_tag", %{"op" => op, "tag_id" => tag_id}, socket)
      when op in ~w(add remove) and is_binary(tag_id) do
    with tag_id when not is_nil(tag_id) <- parse_uuid(tag_id),
         %{} = item <- socket.assigns.selected do
      argument = if op == "add", do: :add_tag_ids, else: :remove_tag_ids

      case CMS.update_media_item(item, %{argument => [tag_id]},
             actor: socket.assigns.actor,
             tenant: socket.assigns.current_org,
             load: [tags: [:name]]
           ) do
        {:ok, item} -> {:noreply, socket |> put_selected(item) |> reload_media()}
        _error -> {:noreply, put_flash(socket, :error, gettext("Couldn't update the tags."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Click on the focal editor: move the point the focal-aware crops center on.
  def handle_event("set_focal", %{"x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    case KilnCMS.Media.Transform.set_focal_point(socket.assigns.selected, x, y,
           actor: socket.assigns.actor
         ) do
      {:ok, item} ->
        {:noreply,
         socket |> put_selected(preserve_tags(item, socket.assigns.selected)) |> reload_media()}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't set the focal point."))}
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
         |> put_selected(preserve_tags(item, socket.assigns.selected))
         |> reload_media()
         |> put_flash(:info, gettext("Image updated — variants are regenerating."))}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't edit that image."))}
    end
  end

  def handle_event("save_meta", %{"alt" => alt, "caption" => caption} = params, socket)
      when is_binary(alt) and is_binary(caption) do
    save_meta(socket, %{
      alt: alt,
      caption: caption,
      decorative: params["decorative"] in [true, "true"]
    })
  end

  # #822 renders the alt field only where it can mean something, so a plain
  # non-image row submits caption alone. Absent has to mean *unchanged* here,
  # not empty: passing `alt: nil` would clear a stored value, and reading the
  # missing `decorative` hidden input as `false` would silently un-mark a
  # decorative row. Caption is the only thing this form can still edit.
  def handle_event("save_meta", %{"caption" => caption}, socket) when is_binary(caption) do
    save_meta(socket, %{caption: caption})
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
         |> refresh_library()
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
  #
  # The open drawer follows the broadcast too (#1314): `width`/`height` and the
  # variants are written by the worker, so an item opened straight after upload
  # was rendered from the pre-measurement row — no dimensions, no focal-point
  # editor — and stayed that way until closed and reopened, while the grid
  # behind it had already refreshed. Only when the broadcast is about the OPEN
  # item, though: re-reading it costs the reference-graph fan-out
  # (`assign_selected/2` → `References.usages/3`), which a bulk regeneration
  # of a large library would otherwise charge every open drawer every 200 ms.
  @impl true
  def handle_info({:media_processed, id}, socket) do
    socket =
      case socket.assigns.selected do
        %{id: ^id} -> assign(socket, :selected_stale?, true)
        _ -> socket
      end

    if socket.assigns.refresh_timer do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :refresh_timer, Process.send_after(self(), :refresh_media, 200))}
    end
  end

  def handle_info(:refresh_media, socket) do
    socket = socket |> assign(:refresh_timer, nil) |> reload_media()

    case socket.assigns do
      %{selected_stale?: true, selected: %{id: id}} ->
        {:noreply, assign_selected(socket, id)}

      _ ->
        {:noreply, socket}
    end
  end

  # --- helpers ---------------------------------------------------------------

  # --- ingest ----------------------------------------------------------------

  # The upload pipeline (sniff -> cap -> strip -> store -> item -> derive) is
  # `KilnCMS.Media.Ingest`, shared with `Unsplash.import_photo/2` and the bulk
  # importers (#487). This module keeps only the LiveView-shaped edges: what a
  # temp file is called, and what the editor is told when one fails.
  #
  # The returned reason reaches the failure flash so editors learn WHICH file
  # failed and why, not just a count (audit U-M5).
  defp store_entry(path, entry, actor, org) do
    # `cache_bust: :defer`: the save handler issues one clear for the batch.
    case Ingest.store_file(path, entry.client_name,
           actor: actor,
           tenant: org,
           cache_bust: :defer
         ) do
      {:ok, _item} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp save_meta(socket, params) do
    actor = socket.assigns.actor

    socket =
      case CMS.update_media_item(
             socket.assigns.selected,
             params,
             actor: actor,
             tenant: socket.assigns.current_org,
             load: [tags: [:name]]
           ) do
        {:ok, item} ->
          socket
          |> put_selected(item)
          |> reload_media()
          |> put_flash(:info, gettext("Saved details."))

        _ ->
          put_flash(socket, :error, gettext("Couldn't save those details."))
      end

    {:noreply, socket}
  end

  defp image?(item), do: MediaKind.of(item.content_type) == :image

  # #822 narrowed the alt field to images, but a non-image row can already
  # carry an `alt` — it was unconditional before, `Ingest` takes it as an
  # option, and it is `public?` and in `default_accept`, so the JSON API and
  # MCP can set it. Hiding the input on those rows would leave the value
  # indexed (the search tsvector coalesces filename || alt || caption) and
  # served, with nowhere left to see or clear it. So: images always, plus any
  # row that already has something to show.
  defp alt_editable?(item),
    do: image?(item) or (is_binary(item.alt) and item.alt != "") or item.decorative == true

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

  # First page under the current filters.
  defp load_media(socket) do
    {items, more?} = fetch_media(socket, nil, @page_size)

    socket
    |> assign(:media, items)
    |> assign(:more?, more?)
    |> assign(
      :usage_counts,
      usage_counts(items, socket.assigns.current_org, socket.assigns.actor)
    )
    |> assign(:total, count_media(socket))
    |> prune_selection()
  end

  # Selection is meaningful only over the loaded grid (`selected_items/1`
  # intersects with it), so when a filter change or reload drops rows, drop
  # their ids too — the "N selected" badge and the bulk-delete confirmation
  # must count exactly what the action would touch, not carry invisible
  # stale ids that re-arm when the filter clears.
  defp prune_selection(socket) do
    selected = socket.assigns.selected_ids

    if MapSet.size(selected) == 0 do
      socket
    else
      loaded = MapSet.new(socket.assigns.media, & &1.id)
      assign(socket, :selected_ids, MapSet.intersection(selected, loaded))
    end
  end

  # Re-read the drawer's item after a write that changed it outside the
  # drawer's own events (bulk tagging) — the assigned struct is stale. Only
  # the item is re-read, deliberately NOT `assign_selected/2`: that would
  # charge the reference-graph fan-out (`References.usages/3` — edges read
  # plus up to 25 whole-document loads) to every chained tag pass, and a tag
  # write cannot change usages (same cost this file already dodges on
  # variant broadcasts, #1314). A miss (item deleted concurrently) leaves
  # the socket alone rather than flashing over the tag pass's own report.
  defp refresh_open_drawer(socket) do
    with %{id: id} <- socket.assigns.selected,
         true <- MapSet.member?(socket.assigns.selected_ids, id),
         {:ok, item} <-
           CMS.get_media_item(id,
             actor: socket.assigns.actor,
             tenant: socket.assigns.current_org,
             load: [tags: [:name]]
           ) do
      put_selected(socket, item)
    else
      _miss_or_closed -> socket
    end
  end

  # What the tag and uploader controls offer. Tags are the org's whole
  # taxonomy (shared with content); uploaders are only people who actually
  # uploaded something — an empty select is noise, a 200-user roster worse.
  # Loaded once per mount (first handle_params) and refreshed only by
  # `refresh_library/1`'s mutation paths, never per filter change.
  defp assign_filter_options(socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    tags =
      CMS.list_tags!(actor: actor, tenant: org, query: [sort: [name: :asc]])

    socket
    |> assign(:tag_options, Enum.map(tags, &{&1.name, &1.id}))
    |> assign(:uploader_options, uploader_options(actor, org))
  end

  # A library mutation (upload, delete, restore, Unsplash import) can add or
  # remove an uploader, so those paths refresh the filter options along with
  # the grid. Everything else (focal point, transforms, tagging, variant
  # broadcasts) reloads the grid alone — it cannot change the options.
  defp refresh_library(socket) do
    socket |> reload_media() |> assign_filter_options()
  end

  # Distinct uploaders across the org's media (read as the editor), then their
  # names. `User`'s read policy is self-only, so — like the content editor's
  # `assignable_users`/`mention_roster` — resolving ids the actor may already
  # see into display names takes a system read (`authorize?: false`); it
  # surfaces only `name` for users whose uploads this org's library shows.
  #
  # Deliberately NEVER seeded from the URL: splicing `?uploader=<uuid>` into
  # this read would let any editor resolve any user uuid on the instance to
  # a name/email through the policy bypass. An active filter absent from
  # this list stays representable via the render-time placeholder option
  # (`ensure_current_option/3`) instead.
  defp uploader_options(actor, org) do
    ids =
      KilnCMS.CMS.MediaItem
      |> Ash.Query.do_filter(expr(not is_nil(uploaded_by_id)))
      |> Ash.Query.select([:uploaded_by_id])
      |> Ash.Query.distinct([:uploaded_by_id])
      |> Ash.read!(actor: actor, tenant: org)
      |> Enum.map(& &1.uploaded_by_id)

    case ids do
      [] ->
        []

      ids ->
        # `authorize?: false`: system read for display data — `User`'s read
        # policy is self-only (same bypass as the content editor's
        # `assignable_users`), the ids come off media rows the actor's own
        # tenant-scoped read just returned, and only `name`/email-as-label
        # surfaces, to editors.
        KilnCMS.Accounts.User
        |> Ash.Query.do_filter(expr(id in ^ids))
        |> Ash.Query.select([:id, :name, :email])
        |> Ash.read!(authorize?: false)
        |> Enum.map(&{user_label(&1), &1.id})
        |> Enum.sort()
    end
  rescue
    # Best-effort: a filter dropdown must not stop the library from rendering
    # — but a silent [] would also hide a real regression forever, so say so.
    error ->
      Logger.warning("media library uploader options unavailable: #{Exception.message(error)}")
      []
  end

  # Same label the content editor's assignment dropdown shows (name, else the
  # editor-visible email).
  defp user_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_label(%{email: email}), do: to_string(email)

  defp uploader_name(options, id) do
    Enum.find_value(options, fn {name, option_id} -> option_id == id && name end)
  end

  # One query for the whole grid, so the delete confirmation can say what a
  # delete affects. Best-effort: the count is context, and an unreadable
  # reference graph must not stop the library from rendering — but the failure
  # is logged, because an empty map renders exactly like "nothing is used" and
  # a silent one would hide that the check never ran.
  defp usage_counts(items, org_id, actor) do
    KilnCMS.Firing.References.usage_counts(tenant_id(org_id), Enum.map(items, & &1.id), actor)
  rescue
    error ->
      Logger.warning("media usage counts unavailable: #{inspect(error)}")
      %{}
  end

  # Refresh the loaded items in place (after uploads, deletes, metadata edits,
  # variant completions) without collapsing Load more depth. The usage counts
  # are re-read too: they describe the items on screen, and a map frozen at
  # the last filter change would keep warning about a reference another tab
  # removed — or miss one it added — for as long as the socket lives.
  defp reload_media(socket) do
    depth = max(@page_size, length(socket.assigns.media))
    {items, more?} = fetch_media(socket, nil, depth)

    socket
    |> assign(:media, items)
    |> assign(:more?, more?)
    |> assign(
      :usage_counts,
      usage_counts(items, socket.assigns.current_org, socket.assigns.actor)
    )
    |> assign(:total, count_media(socket))
    |> prune_selection()
  end

  # Total items under the current filters, so the heading can say
  # "Library (60 of 679)" rather than passing the loaded page off as the
  # whole library.
  defp count_media(socket) do
    CMS.library_media_items!(
      library_args(socket.assigns.filters),
      actor: socket.assigns.actor,
      tenant: socket.assigns.current_org,
      query: media_query(socket.assigns.filters, nil, nil),
      page: [limit: 1, count: true]
    ).count
  end

  defp fetch_media(socket, cursor, limit) do
    items =
      CMS.library_media_items!(
        library_args(socket.assigns.filters),
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: media_query(socket.assigns.filters, cursor, limit)
      )

    {items, length(items) >= limit}
  end

  # The `:library` action's argument map. Absent (not nil) means "don't filter
  # on that axis", and the unused chip is a toggle — off is "everything", not
  # "only used".
  defp library_args(filters) do
    [
      kind: filters.kind,
      tag_ids: filters.tag_id && [filters.tag_id],
      uploaded_by_id: filters.uploader_id,
      uploaded_after: filters.from,
      uploaded_before: filters.to,
      unused: if(filters.unused, do: true)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # The free-text leg and the load-more cursor ride the action query on top of
  # the `:library` facets.
  defp media_query(filters, cursor, limit) do
    [
      filters.q not in [nil, ""] && {:filter, search_filter(filters.q)},
      cursor && {:filter, expr(inserted_at < ^cursor)},
      limit && {:limit, limit}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Kernel.++(sort: [inserted_at: :desc])
  end

  # Case-insensitive match on filename, alt text or caption — what the filter
  # placeholder promises; %, _ and \ in the input match literally.
  defp search_filter(q) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"
    expr(ilike(filename, ^pattern) or ilike(alt, ^pattern) or ilike(caption, ^pattern))
  end

  # --- filter parsing/serialization -------------------------------------------

  @kinds ~w(image video audio captions document)

  defp parse_filters(params) do
    %{
      q: Params.string(params, "q", ""),
      kind: parse_kind(Params.string(params, "kind", "")),
      tag_id: parse_uuid(Params.string(params, "tag", "")),
      uploader_id: parse_uuid(Params.string(params, "uploader", "")),
      from: parse_date(Params.string(params, "from", "")),
      to: parse_date(Params.string(params, "to", "")),
      unused: Params.string(params, "unused", "") == "1"
    }
  end

  defp parse_kind(kind) when kind in @kinds, do: String.to_existing_atom(kind)
  defp parse_kind(_other), do: nil

  # For `filter_change`: a control the form didn't render (the tag/uploader
  # selects only exist when there are options) sends no key at all — that
  # axis must stay as it is, not be read as "cleared": a bookmarked ?tag=/
  # ?uploader= filter would otherwise be silently erased by the first
  # keystroke in the search box. A rendered control DOES send "" to clear.
  #
  # Built on `Params.string/2`'s nil default rather than `Map.has_key?`, so
  # both malformed shapes read as ABSENT (keep current), matching the house
  # doctrine and this handler's own `q:` line: a non-map top-level payload
  # must not raise (the #764 crash class `Params`' catch-all absorbs), and a
  # map-shaped value (`?tag[a]=1`) must not clear the filter.
  defp form_value(params, key, current, parser) do
    case Params.string(params, key) do
      nil -> current
      raw -> parser.(raw)
    end
  end

  # The select options for an axis, with the ACTIVE filter id appended as an
  # opaque placeholder when it isn't otherwise representable — a select whose
  # current value has no matching <option> submits "" on the next form change
  # and silently erases the filter (the uploader may have only trashed items
  # left; the tag may have been deleted; the options may predate a
  # live-patch, or the options read may have been rescued to []). Computed at
  # render time so it tracks every filters change, and label-only: the id is
  # NOT resolved to a name (that resolution runs `authorize?: false`, and a
  # URL-supplied uuid must never reach it).
  defp ensure_current_option(options, nil, _label), do: options

  defp ensure_current_option(options, id, label) do
    if Enum.any?(options, fn {_name, option_id} -> option_id == id end),
      do: options,
      else: options ++ [{label, id}]
  end

  defp parse_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp parse_uuid(_other), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp parse_date(_other), do: nil

  defp filtering?(filters) do
    filters.q not in [nil, ""] or filters.kind != nil or filters.tag_id != nil or
      filters.uploader_id != nil or filters.from != nil or filters.to != nil or
      filters.unused
  end

  defp media_path(filters, id) do
    params =
      [
        q: filters.q,
        kind: filters.kind,
        tag: filters.tag_id,
        uploader: filters.uploader_id,
        from: filters.from && Date.to_iso8601(filters.from),
        to: filters.to && Date.to_iso8601(filters.to),
        unused: if(filters.unused, do: "1"),
        id: id
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    ~p"/media?#{params}"
  end

  # The loaded rows the bulk bar acts on. Grid order, so per-item failures
  # report deterministically.
  defp selected_items(socket) do
    Enum.filter(socket.assigns.media, &MapSet.member?(socket.assigns.selected_ids, &1.id))
  end

  # The ONLY way to change what the drawer holds. `selected_stale?` is a claim
  # about the item currently in `:selected`, so it has to be re-established
  # wherever that item is swapped — including the close path
  # (`assign_selected(socket, nil)`), where a flag set for the item being
  # closed used to survive and then be spent re-reading whichever item the
  # editor opened next.
  defp put_selected(socket, item),
    do: socket |> assign(:selected, item) |> assign(:selected_stale?, false)

  # A write that didn't load tags (focal point, transform) hands back a struct
  # whose `tags` is `%Ash.NotLoaded{}` — carry the drawer's already-loaded list
  # forward instead of rendering the section empty. Tags themselves are
  # untouched by those writes.
  defp preserve_tags(%{tags: %Ash.NotLoaded{}} = item, %{tags: tags}) when is_list(tags),
    do: %{item | tags: tags}

  defp preserve_tags(item, _previous), do: item

  # Tolerant reader for the drawer: any path that assigned an item without
  # tags loaded renders "no tags" rather than raising on `%Ash.NotLoaded{}`.
  defp item_tags(%{tags: tags}) when is_list(tags), do: tags
  defp item_tags(_item), do: []

  # What the drawer's add-select offers: the org's tags minus the ones already
  # on the item.
  defp addable_tags(tag_options, item) do
    applied = MapSet.new(item_tags(item), & &1.id)
    Enum.reject(tag_options, fn {_name, id} -> MapSet.member?(applied, id) end)
  end

  defp assign_selected(socket, nil),
    do: socket |> put_selected(nil) |> assign(:usages, empty_usages())

  defp assign_selected(socket, id) do
    case CMS.get_media_item(id,
           actor: socket.assigns.actor,
           tenant: socket.assigns.current_org,
           load: [tags: [:name]]
         ) do
      {:ok, item} ->
        socket
        |> put_selected(item)
        |> assign(:usages, usages(item, socket.assigns.current_org, socket.assigns.actor))

      _ ->
        socket
        |> put_selected(nil)
        |> assign(:usages, empty_usages())
        |> put_flash(:error, gettext("That item no longer exists."))
    end
  end

  # Best-effort: the "used by" list is context, and an editor must still be
  # able to open a media item when the reference graph can't be read — logged,
  # because the empty fallback renders as an affirmative "not used by any
  # published document". The tenant is `tenant_id(org_id)` with no fallback,
  # matching `usage_counts/3` above: since #1309 the tenant also selects which
  # org the read POLICY authorizes against, and a per-call-site fallback would
  # let the drawer and the grid judge different orgs (`current_org` is always
  # assigned on this LiveView — `:assign_current_org` raises otherwise).
  defp usages(item, org_id, actor) do
    KilnCMS.Firing.References.usages(tenant_id(org_id), item.id, actor)
  rescue
    error ->
      Logger.warning("media usage list unavailable for #{item.id}: #{inspect(error)}")
      empty_usages()
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

  defp bulk_tag_flash(socket, _op, ok, failed) when failed > 0 do
    put_flash(
      socket,
      :error,
      gettext("Tagged %{ok}; %{failed} couldn't be updated.", ok: ok, failed: failed)
    )
  end

  defp bulk_tag_flash(socket, "add", ok, _failed) do
    put_flash(
      socket,
      :info,
      ngettext("Tagged %{count} item.", "Tagged %{count} items.", ok, count: ok)
    )
  end

  defp bulk_tag_flash(socket, "remove", ok, _failed) do
    put_flash(
      socket,
      :info,
      ngettext(
        "Removed the tag from %{count} item.",
        "Removed the tag from %{count} items.",
        ok,
        count: ok
      )
    )
  end

  # The bulk twin of `delete_confirm/2`: the per-tile delete button is hidden
  # in selection mode, so this confirmation is the ONLY place the "used by
  # published documents" warning can reach an admin bulk-trashing a hero
  # image — losing it here is how a page loses its hero (#403), at scale.
  defp bulk_delete_confirm(media, selected_ids, usage_counts) do
    items = Enum.filter(media, &MapSet.member?(selected_ids, &1.id))
    count = length(items)
    used = Enum.count(items, &Map.get(usage_counts, &1.id))

    confirm =
      ngettext(
        "Move %{count} selected item to trash?",
        "Move %{count} selected items to trash?",
        count,
        count: count
      )

    if used > 0 do
      confirm <>
        " " <>
        ngettext(
          "%{used} of them is used by published documents.",
          "%{used} of them are used by published documents.",
          used,
          used: used
        )
    else
      confirm
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

  # #820. Same shape as `:unavailable` above, but for A/V — and it has to be
  # its own message, because the PDF wording names the wrong subsystem and an
  # editor reading "PDF" about their MP4 learns nothing.
  defp upload_failure_reason(:av_strip_unavailable),
    do:
      gettext(
        "can't be stored — video and audio metadata stripping isn't available on this server"
      )

  # #1100. The one A/V refusal that is worth retrying: the strip needs a second
  # full copy of the upload on temp disk and there was not room for it. So the
  # message says "try again" — the others above never resolve by retrying, and
  # this one usually does.
  defp upload_failure_reason(:av_strip_no_space),
    do:
      gettext(
        "can't be stored right now — the server is out of temporary disk space. Try again shortly."
      )

  # #918. Unlike the two above, this one IS about the file, and it is the only
  # refusal here the uploader can actually resolve — so it says what to do
  # instead of blaming the server.
  defp upload_failure_reason(:encrypted),
    do:
      gettext("is password-protected, so its metadata can't be removed — upload an unlocked copy")

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
    assigns =
      assigns
      |> assign(:filtering?, filtering?(assigns.filters))
      # Per-axis select options with the active filter kept representable —
      # see `ensure_current_option/3`. Render-time so it tracks live patches.
      |> assign(
        :tag_select_options,
        ensure_current_option(
          assigns.tag_options,
          assigns.filters.tag_id,
          gettext("(current tag filter)")
        )
      )
      |> assign(
        :uploader_select_options,
        ensure_current_option(
          assigns.uploader_options,
          assigns.filters.uploader_id,
          gettext("(current uploader filter)")
        )
      )

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
              {gettext("Documents: PDF, Word, Excel, PowerPoint, ZIP up to 25 MB")}
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
            <div class="flex items-center gap-2">
              <button
                :if={@media != [] or @selecting?}
                type="button"
                phx-click="toggle_selecting"
                aria-pressed={to_string(@selecting?)}
                class={["btn btn-sm", (@selecting? && "btn-primary") || "btn-default"]}
              >
                {if @selecting?, do: gettext("Done selecting"), else: gettext("Select")}
              </button>
            </div>
          </div>

          <%!-- Filter chips (#1316). Everything is server-side and lives in
                the URL, so a filtered view is bookmarkable and reaches items
                beyond the loaded pages. --%>
          <div :if={@media != [] or @filtering?} class="mb-4 space-y-2">
            <div
              class="flex flex-wrap items-center gap-1.5"
              role="group"
              aria-label={gettext("Filter by kind")}
            >
              <button
                :for={
                  {kind, label} <- [
                    {:image, gettext("Images")},
                    {:video, gettext("Video")},
                    {:audio, gettext("Audio")},
                    {:document, gettext("Documents")},
                    {:captions, gettext("Captions")}
                  ]
                }
                type="button"
                phx-click="set_kind"
                phx-value-kind={kind}
                aria-pressed={to_string(@filters.kind == kind)}
                class={[
                  "btn btn-sm",
                  (@filters.kind == kind && "btn-primary") || "btn-default"
                ]}
              >
                {label}
              </button>
              <button
                type="button"
                phx-click="toggle_unused"
                aria-pressed={to_string(@filters.unused)}
                title={
                  gettext(
                    "Items with no recorded reference from a published document. Drafts don't count as uses; a document that published a reference keeps counting until it is published again without it."
                  )
                }
                class={["btn btn-sm", (@filters.unused && "btn-primary") || "btn-default"]}
              >
                {gettext("Unused")}
              </button>
              <button
                :if={@filtering?}
                type="button"
                phx-click="clear_filters"
                class="btn btn-sm btn-ghost text-base-content/70"
              >
                {gettext("Clear filters")}
              </button>
            </div>
            <form
              id="media-filter"
              phx-change="filter_change"
              class="flex flex-wrap items-end gap-2"
            >
              <div class="min-w-0 grow sm:max-w-xs">
                <label for="media-filter-input" class="sr-only">
                  {gettext("Filter by filename, alt text or caption")}
                </label>
                <input
                  id="media-filter-input"
                  type="text"
                  name="q"
                  value={@filters.q}
                  placeholder={gettext("Filter by filename, alt or caption")}
                  aria-label={gettext("Filter by filename, alt text or caption")}
                  phx-debounce="200"
                  autocomplete="off"
                  class="field-input w-full"
                />
              </div>
              <div :if={@tag_select_options != []}>
                <label for="media-filter-tag" class="sr-only">{gettext("Filter by tag")}</label>
                <select id="media-filter-tag" name="tag" class="field-input">
                  <option value="">{gettext("Any tag")}</option>
                  <option
                    :for={{name, id} <- @tag_select_options}
                    value={id}
                    selected={@filters.tag_id == id}
                  >
                    {name}
                  </option>
                </select>
              </div>
              <div :if={@uploader_select_options != []}>
                <label for="media-filter-uploader" class="sr-only">
                  {gettext("Filter by uploader")}
                </label>
                <select id="media-filter-uploader" name="uploader" class="field-input">
                  <option value="">{gettext("Any uploader")}</option>
                  <option
                    :for={{name, id} <- @uploader_select_options}
                    value={id}
                    selected={@filters.uploader_id == id}
                  >
                    {name}
                  </option>
                </select>
              </div>
              <div>
                <label for="media-filter-from" class="block text-[10px] text-base-content/60">
                  {gettext("Uploaded from")}
                </label>
                <input
                  id="media-filter-from"
                  type="date"
                  name="from"
                  value={@filters.from && Date.to_iso8601(@filters.from)}
                  class="field-input"
                />
              </div>
              <div>
                <label for="media-filter-to" class="block text-[10px] text-base-content/60">
                  {gettext("Uploaded until")}
                </label>
                <input
                  id="media-filter-to"
                  type="date"
                  name="to"
                  value={@filters.to && Date.to_iso8601(@filters.to)}
                  class="field-input"
                />
              </div>
            </form>
          </div>

          <%!-- Bulk bar (#1316): acts on the checked tiles. Delete is
                admin-only (matching the destroy policy), tagging is any
                editor. --%>
          <div
            :if={@selecting?}
            class="mb-4 flex flex-wrap items-center gap-2 rounded border border-base-content/10 bg-base-200 p-2 text-sm"
          >
            <span role="status">
              {ngettext("%{count} selected", "%{count} selected", MapSet.size(@selected_ids),
                count: MapSet.size(@selected_ids)
              )}
            </span>
            <button type="button" phx-click="select_all" class="btn btn-sm btn-default">
              {gettext("Select all loaded")}
            </button>
            <button
              type="button"
              phx-click="clear_selection"
              disabled={MapSet.size(@selected_ids) == 0}
              class="btn btn-sm btn-default"
            >
              {gettext("Clear")}
            </button>
            <form
              :if={@tag_options != []}
              id="bulk-tag-form"
              phx-submit="bulk_tag"
              class="flex items-center gap-1"
            >
              <label for="bulk-tag-select" class="sr-only">{gettext("Tag to apply")}</label>
              <select id="bulk-tag-select" name="tag_id" class="field-input">
                <option value="">{gettext("Choose a tag…")}</option>
                <option :for={{name, id} <- @tag_options} value={id}>{name}</option>
              </select>
              <button
                type="submit"
                name="op"
                value="add"
                disabled={MapSet.size(@selected_ids) == 0}
                class="btn btn-sm btn-default"
              >
                {gettext("Add tag")}
              </button>
              <button
                type="submit"
                name="op"
                value="remove"
                disabled={MapSet.size(@selected_ids) == 0}
                class="btn btn-sm btn-default"
              >
                {gettext("Remove tag")}
              </button>
            </form>
            <p :if={@tag_options == []} class="text-xs text-base-content/60">
              {gettext("Create tags under Taxonomy to tag media.")}
            </p>
            <button
              :if={@is_admin}
              type="button"
              phx-click="bulk_delete"
              disabled={MapSet.size(@selected_ids) == 0}
              data-confirm={bulk_delete_confirm(@media, @selected_ids, @usage_counts)}
              class="btn btn-sm btn-danger ml-auto"
            >
              {gettext("Delete selected")}
            </button>
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
            {if @filters.q not in [nil, ""],
              do: gettext("No media matches “%{query}”.", query: @filters.q),
              else: gettext("No media matches the current filters.")}
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
              class={[
                "group relative overflow-hidden rounded border",
                if(@selecting? and MapSet.member?(@selected_ids, item.id),
                  do: "border-primary ring-2 ring-primary",
                  else: "border-base-content/10"
                )
              ]}
            >
              <button
                type="button"
                phx-click={if @selecting?, do: "toggle_selected", else: "select"}
                phx-value-id={item.id}
                aria-label={
                  if @selecting?,
                    do: gettext("Select %{name}", name: item.filename),
                    else: gettext("View details for %{name}", name: item.filename)
                }
                aria-pressed={@selecting? && to_string(MapSet.member?(@selected_ids, item.id))}
                class="block w-full focus-visible:ring-2 focus-visible:ring-primary"
              >
                <span
                  :if={@selecting?}
                  class={[
                    "absolute left-1 top-1 z-10 flex size-5 items-center justify-center rounded border bg-base-100/90",
                    if(MapSet.member?(@selected_ids, item.id),
                      do: "border-primary bg-primary text-primary-content",
                      else: "border-base-content/30"
                    )
                  ]}
                >
                  <.icon
                    :if={MapSet.member?(@selected_ids, item.id)}
                    name="hero-check"
                    class="size-4"
                  />
                </span>
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
                  <%!-- Images only (#822). A document is reached through a
                        download link whose accessible name is the `file`
                        block's title; a video/audio item has no `alt` in its
                        rendered markup at all; a WebVTT track IS an
                        accessibility artifact. Flagging those permanently is
                        the failure #403 warned about — a badge that is
                        sometimes noise is one editors learn to ignore on the
                        images that really are missing alt. --%>
                  <span
                    :if={(image?(item) and !item.alt) && !item.decorative}
                    class="text-warning"
                    title={gettext("Missing alt text")}
                  >
                    {gettext("· no alt")}
                  </span>
                </p>
              </div>
              <button
                :if={!@selecting?}
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

      <.media_detail
        :if={@selected}
        item={@selected}
        usages={@usages}
        tag_options={@tag_options}
        uploader={uploader_name(@uploader_options, @selected.uploaded_by_id)}
      />
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
  attr :tag_options, :list, required: true
  attr :uploader, :string, default: nil

  # Detail drawer for a single media item: preview, metadata, copyable URL,
  # an alt-text / caption editor (accessibility + SEO), and tags (#1316).
  defp media_detail(assigns) do
    ~H"""
    <.modal id="media-detail-dialog" on_close="close" variant={:drawer}>
      <:title>{@item.filename}</:title>

      <div class="flex-1 overflow-y-auto p-6">
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
        <%!-- A quarantined A/V upload (#1122): its metadata strip is still
             pending, its bytes are in private storage and the stream route
             404s until it is promoted — so say so instead of rendering a
             player that cannot load. The library refreshes on the worker's
             broadcast when it lands. --%>
        <div
          :if={@item.quarantined}
          class="mt-4 rounded-lg border border-base-300 bg-base-200 p-4 text-sm"
          role="status"
        >
          <p class="font-medium">{gettext("Processing…")}</p>
          <p class="mt-1 text-base-content/70">
            {gettext(
              "This upload's metadata is being stripped in the background. It is not visible on the site or in the API until that finishes."
            )}
          </p>
        </div>
        <%!-- A/V (#494) previews in a real player rather than an <img>, and
             plays through the authorized stream route so a gated item
             previews here exactly as it would on a page. `preload="metadata"`
             keeps opening the drawer from pulling down a whole video. --%>
        <video
          :if={MediaKind.of(@item.content_type) == :video and not @item.quarantined}
          id={"media-preview-#{@item.id}"}
          src={~p"/media/#{@item.id}/stream"}
          poster={poster_url(@item)}
          controls
          playsinline
          preload="metadata"
          class="mt-4 max-h-64 w-full rounded bg-black"
        />
        <audio
          :if={MediaKind.of(@item.content_type) == :audio and not @item.quarantined}
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
          <dt :if={@uploader} class="text-base-content/70">{gettext("Uploaded by")}</dt>
          <dd :if={@uploader}>{@uploader}</dd>
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
          <%!-- Images only (#822): `MediaItem.alt` reaches rendered markup for
                nothing else. Offering the field on a PDF or an MP4 invites an
                editor to write a description that is never read out. --%>
          <div :if={alt_editable?(@item)}>
            <label for="media-alt" class="text-sm font-medium">{gettext("Alt text")}</label>
            <input
              id="media-alt"
              name="alt"
              value={@item.alt}
              placeholder={gettext("Describe the image for screen readers")}
              class="field-input mt-1"
            />
            <p :if={!image?(@item)} class="mt-1 text-[11px] text-base-content/50">
              {gettext(
                "This isn't an image, so nothing reads this out. It's shown because a value was set — clear it if it doesn't belong."
              )}
            </p>
          </div>
          <%!-- Decorative is a recorded decision, not an inference from a blank
                field (#403): a divider or a texture correctly has no alt text,
                and without somewhere to say so it is indistinguishable from an
                oversight. The publish check reads this. --%>
          <label :if={alt_editable?(@item)} class="flex items-start gap-2 text-sm">
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

        <%!-- Tags (#1316): the same taxonomy content uses, so tagging media
              here immediately feeds the library's tag filter chips. --%>
        <div class="mt-6 border-t border-base-content/10 pt-4">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            {gettext("Tags")}
          </h3>
          <div :if={item_tags(@item) != []} class="mt-2 flex flex-wrap gap-1.5">
            <span
              :for={tag <- item_tags(@item)}
              class="inline-flex items-center gap-1 rounded bg-base-200 px-2 py-0.5 text-xs"
            >
              {tag.name}
              <button
                type="button"
                phx-click="item_tag"
                phx-value-op="remove"
                phx-value-tag_id={tag.id}
                aria-label={gettext("Remove tag %{name}", name: tag.name)}
                class="text-base-content/50 hover:text-error"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </span>
          </div>
          <p :if={item_tags(@item) == []} class="mt-2 text-sm text-base-content/60">
            {gettext("No tags yet.")}
          </p>
          <form
            :if={addable_tags(@tag_options, @item) != []}
            id="media-detail-tag-form"
            phx-change="item_tag"
            class="mt-2"
          >
            <input type="hidden" name="op" value="add" />
            <label for="media-detail-add-tag" class="sr-only">{gettext("Add a tag")}</label>
            <select id="media-detail-add-tag" name="tag_id" class="field-input">
              <option value="">{gettext("Add a tag…")}</option>
              <option :for={{name, id} <- addable_tags(@tag_options, @item)} value={id}>
                {name}
              </option>
            </select>
          </form>
        </div>

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
    </.modal>
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
