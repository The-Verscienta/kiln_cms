defmodule KilnCMSWeb.ContentEditor.BlockOps do
  @moduledoc """
  The content editor's block-canvas operations — insert, duplicate, remove,
  reorder and keyboard-move blocks; GEO/gallery row edits; and the `columns`
  container's nested-children events — delegated out of
  `KilnCMSWeb.ContentEditorLive` as a `handle_event` lifecycle hook (#1311).
  Events this module doesn't own pass through to the LiveView untouched.

  Bodies are moved verbatim from the LiveView's `handle_event/3` heads, with
  `{:noreply, socket}` returns becoming the hook contract's `{:halt, socket}`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  import KilnCMSWeb.ContentEditor.BlockParams

  import KilnCMSWeb.ContentEditor.Preview,
    only: [broadcast_preview: 1, broadcast_preview_and_refresh: 1, refresh_preview: 1]

  import KilnCMSWeb.ContentEditor.Session, only: [mark_dirty: 1]

  use Gettext, backend: KilnCMSWeb.Gettext

  # Canonical definitions live in `KilnCMSWeb.ContentEditor.BlockParams`;
  # re-materialized as module attributes so the event-head guards below can
  # keep using them (guards need compile-time values).
  @row_fields KilnCMSWeb.ContentEditor.BlockParams.row_fields()
  @nested_child_types KilnCMSWeb.ContentEditor.BlockParams.nested_child_types()

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :editor_block_ops, :handle_event, &on_event/3)}
  end

  # A columns block carries a socket-managed child tree, so it's inserted with a
  # stable id (seeded into `block_children`) and a default two-column layout.
  # `after` (a block id, "start", or absent) positions the new block (B2).
  defp on_event("add_block", %{"type" => "columns"} = p, socket) do
    id = Ash.UUID.generate()
    cols = [%{"blocks" => []}, %{"blocks" => []}]

    form =
      socket.assigns.form
      |> AshPhoenix.Form.add_form(socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => "columns", "id" => id, "columns" => cols}
      )
      |> position_new_block(p["after"])

    socket =
      socket
      |> assign(:form, form)
      |> assign(:block_children, Map.put(socket.assigns.block_children, id, cols))

    broadcast_preview(socket)
    {:halt, socket |> refresh_preview() |> mark_dirty()}
  end

  defp on_event("add_block", %{"type" => type} = p, socket) when is_binary(type) do
    # Every block carries a stable id from the moment it's added, so the picker,
    # delete, and keyboard-move can address it by identity rather than by a
    # position that a concurrent reorder can invalidate (audit T5.1/T5.2). The
    # optional `after` anchor lets it land inline rather than only at the end (B2).
    form =
      socket.assigns.form
      |> AshPhoenix.Form.add_form(socket.assigns.form.name <> "[blocks]",
        params: %{"_union_type" => type, "id" => Ash.UUID.generate()}
      )
      |> position_new_block(p["after"])

    socket = assign(socket, :form, form)
    broadcast_preview(socket)
    {:halt, socket |> refresh_preview() |> mark_dirty()}
  end

  # Duplicate the block with stable id `bid`: copy its full field set, give the
  # copy (and, for a columns block, its nested children) fresh ids, and drop it in
  # right after the original.
  defp on_event("duplicate_block", %{"bid" => bid}, socket) when is_binary(bid) do
    case Enum.find(
           full_blocks_input(socket.assigns.form),
           &(to_string(&1["id"]) == to_string(bid))
         ) do
      nil ->
        {:halt, socket}

      source ->
        new_id = Ash.UUID.generate()
        copy = Map.put(source, "id", new_id)
        children = dup_children(socket.assigns.block_children[bid])

        form =
          socket.assigns.form
          |> AshPhoenix.Form.add_form(socket.assigns.form.name <> "[blocks]", params: copy)
          |> position_new_block(bid)

        block_children =
          if children,
            do: Map.put(socket.assigns.block_children, new_id, children),
            else: socket.assigns.block_children

        socket = socket |> assign(:form, form) |> assign(:block_children, block_children)

        # Re-inject the copy's fresh-id children into the form params now, so a draft
        # autosave firing before the next validate persists the duplicate's own
        # children rather than the original's (do_autosave submits raw params).
        socket = revalidate(socket, AshPhoenix.Form.params(socket.assigns.form))
        broadcast_preview(socket)

        {:halt, socket |> refresh_preview() |> mark_dirty()}
    end
  end

  # No `bid` (a block that reached the editor without a stable id) — no-op rather
  # than crash the session (audit theme 4). ensure_block_ids/1 backfills on load,
  # so this is defence in depth.
  defp on_event("duplicate_block", _params, socket), do: {:halt, socket}

  # ── GEO item rows (faq items / how_to steps, #357) ──────────────────────────
  # Rows are bound form inputs; add/remove mutate the form params directly (the
  # same targeted-update pattern as `pick_image` at an index), so there's no
  # parallel socket state to keep in sync.

  defp on_event("item_row_add", %{"index" => index, "field" => field}, socket)
       when field in @row_fields and is_binary(index) do
    halt(update_item_rows(socket, index, field, &(&1 ++ [%{}])))
  end

  defp on_event(
         "item_row_remove",
         %{"index" => index, "field" => field, "item" => item},
         socket
       )
       when field in @row_fields and is_binary(index) and is_binary(item) do
    halt(update_item_rows(socket, index, field, &List.delete_at(&1, to_int(item))))
  end

  # ── gallery image rows (#482) ───────────────────────────────────────────────

  defp on_event("gallery_remove", %{"bid" => bid, "item" => item}, socket)
       when is_binary(bid) and is_binary(item) do
    halt(update_gallery_images(socket, bid, &List.delete_at(&1, to_int(item))))
  end

  defp on_event("gallery_move", %{"bid" => bid, "item" => item, "dir" => dir}, socket)
       when is_binary(bid) and is_binary(item) and is_binary(dir) do
    from = to_int(item)
    to = if dir == "up", do: from - 1, else: from + 1

    update_gallery_images(socket, bid, fn images ->
      # BOTH ends checked. `to_int/1` accepts a negative, and `Enum.at(images,
      # -1)` is the last row rather than an error — so an unchecked `from` moves
      # the wrong image, and one past the end inserts a `nil` into an
      # `{:array, :map}` the resource refuses to save.
      bounds = 0..(length(images) - 1)//1

      if from in bounds and to in bounds do
        moved = Enum.at(images, from)
        images |> List.delete_at(from) |> List.insert_at(to, moved)
      else
        images
      end
    end)
    |> halt()
  end

  # The client reports the new order as a list of the *previous* row indices,
  # and the server rebuilds from those — never from row content, which the
  # client could have edited between the drag and the event.
  defp on_event("gallery_reorder", %{"bid" => bid, "order" => order}, socket)
       when is_binary(bid) and is_list(order) do
    update_gallery_images(socket, bid, fn images ->
      # Deduped and rejected by INDEX, never by value. Two rows pointing at the
      # same media item are identical maps, so matching on the map itself
      # collapses them into one and then drops both from the tail — a drag on a
      # gallery holding one image twice would silently delete a copy.
      indices =
        order
        |> Enum.map(&to_int/1)
        |> Enum.filter(&(&1 in 0..(length(images) - 1)//1))
        |> Enum.uniq()

      # Any row the client failed to mention keeps its place at the end rather
      # than being dropped: a stale or partial order must not delete images.
      unmentioned = Enum.reject(0..(length(images) - 1)//1, &(&1 in indices))

      for index <- indices ++ Enum.to_list(unmentioned), do: Enum.at(images, index)
    end)
    |> halt()
  end

  defp on_event("gallery_reorder", _params, socket), do: {:halt, socket}

  # Remove the block with stable id `bid`. Resolving the id to a path now (rather
  # than trusting a path captured at render) means an in-flight reorder can't turn
  # a delete click into a delete of the wrong block (audit T5.2).
  defp on_event("remove_block", %{"bid" => bid}, socket) when is_binary(bid) do
    case block_index_by_id(socket.assigns.form, bid) do
      nil ->
        {:halt, socket}

      index ->
        path = "#{socket.assigns.form.name}[blocks][#{index}]"

        {:halt,
         socket
         |> assign(:form, AshPhoenix.Form.remove_form(socket.assigns.form, path))
         |> prune_block_children()
         |> mark_dirty()}
    end
  end

  defp on_event("remove_block", _params, socket), do: {:halt, socket}

  defp on_event("reorder", %{"order" => order}, socket) when is_list(order) do
    form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)
    {:halt, socket |> assign(:form, form) |> mark_dirty()}
  end

  # Keyboard-accessible alternative to drag-and-drop reordering (#171): swap a
  # block with its neighbour and announce the new position to screen readers.
  # The moved block is identified by its stable id and resolved to a live index
  # here, so the swap can't act on the wrong block after a reorder (T4.3/T5.2).
  defp on_event("move_block", %{"bid" => bid, "dir" => dir}, socket)
       when is_binary(bid) and is_binary(dir) do
    count = blocks_count(socket.assigns.form)

    # Bounds-check BOTH ends: an unknown id no-ops, and a source at either edge
    # can't wrap to the opposite end via Enum.at/-1 (audit T4.3).
    with i when is_integer(i) <- block_index_by_id(socket.assigns.form, bid),
         true <- i < count,
         j when j >= 0 and j < count <- if(dir == "up", do: i - 1, else: i + 1) do
      order = 0..(count - 1) |> Enum.map(&to_string/1) |> swap_at(i, j)
      form = AshPhoenix.Form.sort_forms(socket.assigns.form, [:blocks], order)

      {:halt,
       socket
       |> assign(:form, form)
       |> mark_dirty()
       |> assign(
         :moved_announcement,
         gettext("Moved block to position %{pos} of %{count}", pos: j + 1, count: count)
       )}
    else
      _ -> {:halt, socket}
    end
  end

  defp on_event("move_block", _params, socket), do: {:halt, socket}

  # ── columns container editing (#335) ────────────────────────────────────────
  # These mutate the socket-managed child tree of a `columns` block, then re-sync
  # it into the form (so the live preview + save reflect it). Blocks and columns
  # are addressed by their stable ids; nothing here relies on positional indices
  # surviving a concurrent reorder.

  defp on_event("col_add_child", %{"id" => id, "col" => col, "type" => type}, socket)
       when type in @nested_child_types and is_binary(id) and is_binary(col) do
    # Address the target column by a real index; a garbled `col` no-ops rather
    # than silently landing the child in column 0 (the old `to_int` fallback).
    case parse_index(col) do
      {:ok, ci} ->
        bc = update_column(socket.assigns.block_children, id, ci, &append_child(&1, type))
        {:halt, apply_children(socket, bc)}

      :error ->
        {:halt, socket}
    end
  end

  defp on_event("col_remove_child", %{"id" => id, "child" => child_id}, socket)
       when is_binary(id) and is_binary(child_id) do
    bc =
      update_columns(socket.assigns.block_children, id, fn blocks ->
        Enum.reject(blocks, &(&1["id"] == child_id))
      end)

    {:halt, apply_children(socket, bc)}
  end

  # The form-serialized shape (#893). A `<select>` inside the editor's form
  # cannot deliver `phx-value-*` — LiveView routes a form-associated
  # `phx-change` through `pushInput`, which scrapes those off the form rather
  # than the element — so the nested-child select carries its identifiers in its
  # `name` instead, and they arrive here as ordinary nested params.
  #
  # One entry at every level, because `pushInput` filters the serialized form to
  # the changed input's name. Anything else is a payload this event did not
  # send, and is refused rather than guessed at.
  defp on_event("col_update_child", %{"col_child" => payload}, socket)
       when is_map(payload) do
    with [{id, children}] when is_map(children) <- Map.to_list(payload),
         [{child_id, fields}] when is_map(fields) <- Map.to_list(children),
         [{field, value}] when is_binary(value) <- Map.to_list(fields) do
      bc =
        update_columns(socket.assigns.block_children, id, fn blocks ->
          Enum.map(blocks, &maybe_put_field(&1, child_id, field, value))
        end)

      {:halt, apply_children(socket, bc)}
    else
      # Logged, not swallowed. This head matches before `MalformedEvent`'s
      # catch-all can, so a payload that fails the shape below would otherwise
      # die here in total silence — which is the condition #893 was, and the
      # reason it survived. Same level and same non-prod gate as that fallback.
      unexpected ->
        KilnCMSWeb.MalformedEvent.log(__MODULE__, {"col_update_child", unexpected})
        {:halt, socket}
    end
  end

  defp on_event(
         "col_update_child",
         %{"id" => id, "child" => child_id, "field" => field} = p,
         socket
       )
       when is_binary(id) and is_binary(child_id) and is_binary(field) do
    value = Map.get(p, "value", "")

    bc =
      update_columns(socket.assigns.block_children, id, fn blocks ->
        Enum.map(blocks, &maybe_put_field(&1, child_id, field, value))
      end)

    {:halt, apply_children(socket, bc)}
  end

  # Nested SortableJS drop: `cols` is the new child-id order of every column of
  # this block. Rebuild each column from the flat id→child map so a child can
  # move within or across the block's columns without losing its edits.
  defp on_event("col_reorder", %{"id" => id, "cols" => cols}, socket)
       when is_binary(id) and is_list(cols) do
    bc = Map.update(socket.assigns.block_children, id, [], &rebuild_columns(&1, cols))
    {:halt, apply_children(socket, bc)}
  end

  defp on_event("col_add_column", %{"id" => id}, socket) when is_binary(id) do
    bc =
      Map.update(socket.assigns.block_children, id, [%{"blocks" => []}], fn cols ->
        if length(cols) >= max_columns(), do: cols, else: cols ++ [%{"blocks" => []}]
      end)

    {:halt, apply_children(socket, bc)}
  end

  defp on_event("col_remove_column", %{"id" => id, "col" => col}, socket)
       when is_binary(id) and is_binary(col) do
    case parse_index(col) do
      {:ok, ci} ->
        bc = Map.update(socket.assigns.block_children, id, [], &drop_column(&1, ci))
        {:halt, apply_children(socket, bc)}

      :error ->
        {:halt, socket}
    end
  end

  # Events that are not block-canvas ops fall through to the LiveView.
  defp on_event(_event, _params, socket), do: {:cont, socket}

  # The row/gallery helpers keep their `{:noreply, socket}` shape (the
  # LiveView's gallery multi-pick calls them too); the hook contract wants
  # `{:halt, socket}`.
  defp halt({:noreply, socket}), do: {:halt, socket}

  # Re-run form validation with the socket-held child blocks re-injected and GEO
  # item rows normalized — the shared path for events that rebuild block params
  # (e.g. an image pick) so a partial update can't drop the nested tree.
  def revalidate(socket, params) do
    params = params |> inject_children(socket.assigns.block_children) |> normalize_item_rows()
    assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
  end

  # Drop any socket-held child state whose parent block no longer exists in the
  # live form (e.g. after a block delete), so stale children can't resurface.
  defp prune_block_children(socket) do
    live_ids =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> Map.get("blocks")
      |> block_param_ids()
      |> MapSet.new()

    pruned = Map.filter(socket.assigns.block_children, fn {id, _} -> id in live_ids end)
    assign(socket, :block_children, pruned)
  end

  # ── GEO item rows: params helpers (#357) ────────────────────────────────────

  # Apply `fun` to the item list of one block (by index) and re-validate.
  defp update_item_rows(socket, index, field, fun) do
    # The FULL block set, not a partial params write. `AshPhoenix.Form.params/1`
    # is `only_touched?`, so a form freshly loaded from a saved record carries no
    # `blocks` key at all — and `validate/2` rebuilds the sub-forms from the keys
    # it is given, so writing `%{"blocks" => %{"0" => …}}` deletes every other
    # block in the document. `pick_image` already carries the full set through
    # for exactly this reason; these buttons need it just as much, and more
    # often, since the gallery's only route to its first image is one of them.
    #
    # Rebuilding also resolves the "params or stored value?" question: each
    # block's input map already carries its rows, whether they came from the
    # record or from something the editor typed.
    blocks = full_blocks_input(socket.assigns.form)
    index = to_int(index)

    case Enum.at(blocks, index) do
      nil ->
        {:noreply, socket}

      block ->
        current = block |> Map.get(field) |> stringify_rows()
        blocks = List.replace_at(blocks, index, Map.put(block, field, fun.(current)))

        params =
          socket.assigns.form
          |> AshPhoenix.Form.params()
          |> Map.put("blocks", blocks)

        socket = revalidate(socket, params)
        broadcast_preview(socket)
        {:noreply, mark_dirty(socket)}
    end
  end

  # Resolve the block id to an index *now* rather than trusting one captured at
  # render, for the reason `remove_block` gives: an in-flight reorder must not
  # turn a click on one block into an edit of another.
  def update_gallery_images(socket, bid, fun) do
    case block_index_by_id(socket.assigns.form, bid) do
      nil -> {:noreply, socket}
      index -> update_item_rows(socket, index, "images", fun)
    end
  end

  # ── columns children: socket state ⇄ form params ────────────────────────────

  # Re-sync the socket-managed children into the form (keeping the preview + a
  # future save current), then refresh the preview and mark the doc dirty. The
  # form's own params carry every other field, so injecting the children over
  # them is a lossless round-trip.
  defp apply_children(socket, block_children) do
    params =
      socket.assigns.form
      |> AshPhoenix.Form.params()
      |> inject_children(block_children)

    socket
    |> assign(:block_children, block_children)
    |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
    |> broadcast_preview_and_refresh()
    |> mark_dirty()
  end
end
