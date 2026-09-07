defmodule KilnCMSWeb.ContentEditor.BlockParams do
  @moduledoc """
  Pure helpers over the content editor's block form and params: reading the
  union sub-forms, addressing blocks by stable id, reconciling client `blocks`
  params against the server's forms, re-injecting socket-held state (columns
  children, rich-text bodies), and normalizing indexed row params back into
  lists.

  Extracted verbatim from `KilnCMSWeb.ContentEditorLive` (#1311). Everything
  here is a pure function over forms/params — no socket, no side effects — so
  the LiveView, its delegated event modules, and its components can share one
  copy without drifting.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  # Block types edited by `item_rows_editor/1` — a repeating label + body row —
  # and the `{:array, :map}` param names those rows bind into. Both lists are
  # load-bearing beyond the component: `normalize_item_rows/1` needs the field
  # names to turn indexed maps back into lists, and the add/remove handlers
  # guard on them. A block added to one and not the other silently loses its
  # rows on save, which is why they sit together here rather than inline.
  @row_editor_types ~w(faq how_to accordion)
  @row_fields ~w(items steps panels)

  # Child block types offerable inside a `columns` container (#335). A curated
  # subset with simple field editors — nested blocks get functional inputs, not
  # the top-level TipTap/media-picker treatment. Columns-in-columns is supported
  # by the model/renderer but intentionally not offered here (one nesting level
  # keeps the nested editor legible).
  @nested_child_types ~w(heading rich_text quote image embed divider)

  # Bounds on the columns editor, so the nested UI (and any hostile client event)
  # can't create a pathological tree. The storage cast has its own depth guard.
  @max_columns 4
  @max_children_per_column 20

  # Compile-time constants above, re-exported so the LiveView can keep using
  # them in guards (via module attributes evaluated at compile time) and the
  # column handlers can read the bounds.
  def row_fields, do: @row_fields
  def row_editor_types, do: @row_editor_types
  def nested_child_types, do: @nested_child_types
  def max_columns, do: @max_columns

  # Backfill a stable id onto any block that reached the editor without one
  # (legacy content predating the uuid_primary_key), so every block can be
  # addressed by identity (picker/move/remove/duplicate carry `bid`).
  def ensure_block_ids(%{blocks: blocks} = record) when is_list(blocks),
    do: %{record | blocks: Enum.map(blocks, &ensure_block_id/1)}

  def ensure_block_ids(record), do: record

  defp ensure_block_id(%Ash.Union{value: value} = union),
    do: %{union | value: ensure_block_id(value)}

  defp ensure_block_id(%{id: nil} = block), do: %{block | id: Ash.UUID.generate()}
  defp ensure_block_id(block), do: block

  # The typed block module backing a block sub-form (its union member resource).
  # `inputs_for` yields a Phoenix.HTML.Form wrapping an AshPhoenix.Form; the
  # preview path holds the AshPhoenix.Form directly.
  def block_member(%Phoenix.HTML.Form{source: source}), do: block_member(source)
  def block_member(%AshPhoenix.Form{resource: resource}), do: resource

  # `AshPhoenix.Form.value(form, :blocks)` yields the **nested forms**, not
  # maps, so the id has to be asked for the same way the template's
  # `bf[:id].value` asks. Reading `.id` off the struct instead silently gives
  # nil for every block, which makes every discussed block look orphaned — it
  # renders each one's panel twice, under duplicate DOM ids.
  def block_form_id(%AshPhoenix.Form{} = block_form),
    do: AshPhoenix.Form.value(block_form, :id)

  def block_form_id(%{"id" => id}), do: id
  def block_form_id(%{id: id}), do: id
  def block_form_id(_block), do: nil

  # Number of block sub-forms currently in the form (#171 keyboard reorder).
  def blocks_count(form) do
    case AshPhoenix.Form.value(form, :blocks) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  # Current positional index of the block whose stable id is `bid`, or nil if no
  # block carries it. Resolves against the live nested forms (which reflect the
  # id from either loaded data or add-form params, and the current order after a
  # reorder) rather than a position captured at render time — this is what makes
  # the picker/delete/move resilient to a concurrent reorder (audit T5.1/T5.2).
  def block_index_by_id(form, bid) do
    bid = to_string(bid)

    form
    |> ash_form()
    |> Map.get(:forms, %{})
    |> Map.get(:blocks, [])
    |> List.wrap()
    |> Enum.find_index(fn sub -> to_string(AshPhoenix.Form.value(sub, :id)) == bid end)
  end

  # Move a just-appended block (currently last) to the requested insert position
  # (B2 inline insertion): `nil`/absent leaves it at the end (append), "start"
  # moves it to the top, and a block id moves it directly after that block. The
  # anchor id is resolved against the live forms, so insertion stays correct even
  # if the list was reordered since the "+" was rendered.
  def position_new_block(form, anchor) when anchor in [nil, ""], do: form
  def position_new_block(form, "start"), do: reposition_last(form, 0)

  def position_new_block(form, anchor) do
    case block_index_by_id(form, anchor) do
      nil -> form
      i -> reposition_last(form, i + 1)
    end
  end

  # Reorder the block sub-forms so the last one (the newly added block) sits at
  # `target`, preserving the order of the others.
  defp reposition_last(form, target) do
    last = blocks_count(form) - 1
    target = target |> max(0) |> min(last)
    existing = if last > 0, do: Enum.map(0..(last - 1), &to_string/1), else: []
    order = List.insert_at(existing, target, to_string(last))
    AshPhoenix.Form.sort_forms(form, [:blocks], order)
  end

  # A copy of a columns block's socket-managed child tree with every nested child
  # re-keyed, so a duplicated columns block's children stay independent of the
  # original's (block duplication).
  def dup_children(columns) when is_list(columns) do
    Enum.map(columns, fn column ->
      blocks =
        column
        |> Map.get("blocks", [])
        |> Enum.map(&Map.put(&1, "id", Ash.UUID.generate()))

      Map.put(column, "blocks", blocks)
    end)
  end

  def dup_children(_), do: nil

  # `socket.assigns.form` is a Phoenix.HTML.Form wrapping the AshPhoenix.Form
  # (nested forms live on the latter); unwrap so we can read the block sub-forms.
  defp ash_form(%Phoenix.HTML.Form{source: %AshPhoenix.Form{} = source}), do: source
  defp ash_form(%AshPhoenix.Form{} = form), do: form

  # The complete current block set as a list of union input maps (string keys,
  # `_union_type` discriminator, stable `id`), read from the live sub-forms. This
  # is the payload a caller merges a targeted edit into so that validating it
  # preserves every other block and its identity — a form that hasn't been
  # submitted has empty `params`, so a partial blocks param would drop the rest.
  def full_blocks_input(form) do
    form
    |> ash_form()
    |> Map.get(:forms, %{})
    |> Map.get(:blocks, [])
    |> List.wrap()
    |> Enum.map(&block_input_map/1)
  end

  defp block_input_map(%AshPhoenix.Form{} = sub), do: block_field_map(sub, "_union_type")

  # ── Stale block params (#1334) ──────────────────────────────────────────────
  #
  # A phx-change/phx-submit's `blocks` params are a snapshot of the DOM the
  # CLIENT had rendered when the event fired — never an instruction to add or
  # remove a block, which have their own server events (add_block /
  # duplicate_block / remove_block; order is server-owned too, via
  # reorder / move_block). `AshPhoenix.Form.validate/2` doesn't know that: once
  # `blocks` is touched, its params are authoritative — a nested form with no
  # matching entry is REMOVED, and an entry matching no form has a fresh form
  # CREATED from it (which raises, since the DOM entries carry no
  # `_union_type`). So a keystroke that raced `add_block` — fired between the
  # click and the patch that renders the new block — silently deleted the
  # block the user just chose, a Save in the same window persisted the loss,
  # and a keystroke racing `remove_block` crashed the whole editor session.
  #
  # Reconcile instead of trusting the snapshot: client entries are kept
  # verbatim, in their order (they carry the user's newest keystrokes); a
  # server-side block whose id the client never rendered is re-inserted at its
  # server position, with the sub-form's own params; and a client entry whose
  # id the server no longer knows is dropped rather than turned into a new
  # form. Every rendered block carries its id as a hidden input, so an entry
  # without one (or any `blocks` shape this doesn't recognize) passes through
  # untouched, exactly as before.
  def reconcile_blocks(params, form) do
    case block_entry_list(params["blocks"]) do
      {:ok, client} -> do_reconcile_blocks(params, form, client)
      :error -> params
    end
  end

  defp do_reconcile_blocks(params, form, client) do
    subforms =
      form
      |> ash_form()
      |> Map.get(:forms, %{})
      |> Map.get(:blocks, [])
      |> List.wrap()

    server_ids = subforms |> Enum.map(&block_form_id/1) |> Enum.map(&stable_id/1)
    known = MapSet.new(server_ids) |> MapSet.delete(nil)
    client_ids = client |> Enum.map(&entry_id/1) |> MapSet.new() |> MapSet.delete(nil)

    kept =
      Enum.reject(client, fn entry ->
        case entry_id(entry) do
          nil -> false
          id -> not MapSet.member?(known, id)
        end
      end)

    merged =
      server_ids
      |> Enum.zip(subforms)
      |> Enum.with_index()
      |> Enum.reduce(kept, fn {{id, sub}, index}, acc ->
        if is_nil(id) or MapSet.member?(client_ids, id) do
          acc
        else
          List.insert_at(acc, min(index, length(acc)), missing_block_entry(form, sub, id))
        end
      end)

    if merged == client do
      params
    else
      blocks =
        merged
        |> Enum.with_index()
        |> Map.new(fn {entry, index} -> {Integer.to_string(index), entry} end)

      Map.put(params, "blocks", blocks)
    end
  end

  # The params to re-insert for a block the client hasn't rendered yet: the
  # form's own serialized entry (for a just-added block that is exactly what
  # `add_block` passed to `add_form` — `_union_type` + id), falling back to the
  # sub-form's full field map (the same shape `duplicate_block` feeds back in).
  defp missing_block_entry(form, sub, id) do
    with {:ok, entries} <- block_entry_list(AshPhoenix.Form.params(form)["blocks"]),
         %{} = entry <- Enum.find(entries, &(entry_id(&1) == id)) do
      entry
    else
      _ -> block_input_map(sub)
    end
  end

  # `blocks` params as an ordered list of map entries: the DOM submits an
  # index-keyed map, `AshPhoenix.Form.params/1` returns a list. Anything else
  # (junk keys, non-map entries) is `:error` — the caller then leaves the
  # params exactly as they arrived.
  defp block_entry_list(nil), do: {:ok, []}

  defp block_entry_list(blocks) when is_list(blocks) do
    if Enum.all?(blocks, &is_map/1), do: {:ok, blocks}, else: :error
  end

  defp block_entry_list(blocks) when is_map(blocks) do
    blocks
    |> Enum.reduce_while([], fn {key, entry}, acc ->
      with true <- is_map(entry),
           {index, ""} <- Integer.parse(to_string(key)) do
        {:cont, [{index, entry} | acc]}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      indexed -> {:ok, indexed |> Enum.sort() |> Enum.map(&elem(&1, 1))}
    end
  end

  defp block_entry_list(_other), do: :error

  defp entry_id(%{"id" => id}), do: stable_id(id)
  defp entry_id(_entry), do: nil

  defp stable_id(id) when is_binary(id) and id != "", do: id
  defp stable_id(nil), do: nil
  defp stable_id(id), do: to_string(id)

  # The declared fields of a block sub-form as a string-keyed map, tagged with its
  # block type under `type_key` and carrying the stable `id`. The only thing that
  # varies between the union-input shape (`_union_type`) and the typed-preview
  # shape (`_type`) is that key, so both go through here.
  def block_field_map(%AshPhoenix.Form{} = sub, type_key) do
    mod = block_member(sub)

    Kiln.Block.Info.fields(mod)
    |> Map.new(fn field -> {to_string(field.name), AshPhoenix.Form.value(sub, field.name)} end)
    |> Map.put(type_key, to_string(Kiln.Block.Info.name(mod)))
    |> Map.put("id", AshPhoenix.Form.value(sub, :id))
  end

  # Swap the two list elements at positions `i` and `j`.
  def swap_at(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  def block_param_ids(blocks) when is_map(blocks),
    do: blocks |> Map.values() |> block_param_ids()

  def block_param_ids(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &block_param_id/1)
  def block_param_ids(_blocks), do: []

  defp block_param_id(%{"id" => id}) when is_binary(id), do: [id]
  defp block_param_id(_block), do: []

  def stringify_rows(value) do
    value
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.new(&1, fn {k, v} -> {to_string(k), v} end))
  end

  # Item rows are bound inputs, so a DOM submit delivers them as indexed maps
  # (`"items" => %{"0" => %{…}}`) — convert to the ordered lists the blocks'
  # `{:array, :map}` fields cast. Non-numeric keys (the always-present sentinel
  # that keeps the param submitted when every row is removed) are dropped.
  def normalize_item_rows(params) do
    # `Map.update/4` would *insert* a nil `blocks` key on block-less params
    # (title-only edits), which AshPhoenix's nested-form validate chokes on.
    case params do
      %{"blocks" => blocks} when is_map(blocks) ->
        Map.put(params, "blocks", Map.new(blocks, fn {k, b} -> {k, normalize_block_items(b)} end))

      %{"blocks" => blocks} when is_list(blocks) ->
        Map.put(params, "blocks", Enum.map(blocks, &normalize_block_items/1))

      _ ->
        params
    end
  end

  defp normalize_block_items(%{} = block) do
    # `images` is the gallery's row field. It is not in `@row_fields` because it
    # is not edited by `item_rows_editor/1` — but it is still an indexed map on
    # the wire, so it needs the same flattening or a gallery loses every image
    # on save.
    @row_fields
    |> Kernel.++(["images"])
    |> Enum.reduce(block, fn key, block ->
      case block do
        %{^key => %{} = indexed} -> Map.put(block, key, indexed_items_to_list(indexed))
        _ -> block
      end
    end)
    |> normalize_fragment_ref()
  end

  defp normalize_block_items(other), do: other

  # The fragment picker (#479) is a single `<select>`, because a reference is
  # one choice — so it posts one `"type:id"` string, which becomes the
  # `%{"type" => …, "id" => …}` map the `:reference` field stores and
  # `Firing.References` extracts its edge from. An empty selection clears the
  # reference rather than storing a half-shape the resolver would silently drop.
  defp normalize_fragment_ref(%{"ref" => ref} = block) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      [type, id] when type != "" and id != "" ->
        Map.put(block, "ref", %{"type" => type, "id" => id})

      _blank ->
        Map.put(block, "ref", nil)
    end
  end

  defp normalize_fragment_ref(block), do: block

  defp indexed_items_to_list(indexed) do
    indexed
    |> Enum.filter(fn {k, v} -> is_map(v) and Regex.match?(~r/\A\d+\z/, k) end)
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  # Set the `columns` param of every `columns` block to its socket-managed
  # children, matched by the block's stable id. Tolerates params where `blocks`
  # is the usual indexed map or a list.
  def inject_children(params, block_children) when map_size(block_children) == 0, do: params

  def inject_children(params, block_children) do
    Map.update(params, "blocks", params["blocks"], fn
      blocks when is_map(blocks) ->
        Map.new(blocks, fn {k, v} -> {k, inject_block(v, block_children)} end)

      blocks when is_list(blocks) ->
        Enum.map(blocks, &inject_block(&1, block_children))

      other ->
        other
    end)
  end

  # Overlay pending rich-text bodies (Portable Text lists, from the TipTap
  # hook's rich_text_body pushes) onto the block params, matched by block id —
  # falling back to the positional key for blocks that haven't been saved yet.
  # legacy_html is cleared in the same stroke: body becomes this block's single
  # source of truth (the cast enforces the same rule).
  def inject_rich_bodies(params, rich_bodies) when map_size(rich_bodies) == 0, do: params
  def inject_rich_bodies(%{"blocks" => nil} = params, _rich_bodies), do: params

  def inject_rich_bodies(%{"blocks" => _} = params, rich_bodies) do
    Map.update(params, "blocks", params["blocks"], fn
      blocks when is_map(blocks) ->
        Map.new(blocks, fn {k, v} -> {k, inject_rich_body(v, k, rich_bodies)} end)

      blocks when is_list(blocks) ->
        blocks
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> inject_rich_body(v, to_string(i), rich_bodies) end)

      other ->
        other
    end)
  end

  def inject_rich_bodies(params, _rich_bodies), do: params

  defp inject_rich_body(%{} = block, key, rich_bodies) do
    case rich_bodies[block["id"]] || rich_bodies["idx-" <> key] do
      nil -> block
      body -> block |> Map.put("body", body) |> Map.put("legacy_html", "")
    end
  end

  defp inject_rich_body(other, _key, _rich_bodies), do: other

  defp inject_block(%{} = block, block_children) do
    case block["id"] && Map.get(block_children, block["id"]) do
      nil -> block
      cols -> Map.put(block, "columns", cols)
    end
  end

  defp inject_block(other, _block_children), do: other

  # Apply `fun` to the child-block list of one column (by index) of a block.
  def update_column(block_children, block_id, col_index, fun) do
    Map.update(block_children, block_id, [], fn cols ->
      List.update_at(cols, col_index, &update_col_blocks(&1, fun))
    end)
  end

  # Apply `fun` to every column's child-block list of a block.
  # `Map.update/4`'s default would *create* an entry for a block id that is not
  # in the tree. The id comes from a client event, and on a published record —
  # which never autosaves, so `assign_record/2` never re-seeds this map — a
  # fabricated one would sit in socket state for the whole session.
  #
  # Defensive, and deliberately untested: a phantom entry matches no block, so
  # `inject_children/2` blanks nothing and there is no observable damage to
  # assert on today. A test for it could not fail, and one that cannot fail is
  # worse than none. The guard is here because the *next* reader of this map
  # should not have to re-derive that argument.
  def update_columns(block_children, block_id, fun) do
    if Map.has_key?(block_children, block_id) do
      Map.update!(block_children, block_id, fn cols ->
        Enum.map(cols, &update_col_blocks(&1, fun))
      end)
    else
      block_children
    end
  end

  defp update_col_blocks(col, fun) do
    Map.update(col || %{"blocks" => []}, "blocks", [], fn blocks -> fun.(List.wrap(blocks)) end)
  end

  # Rebuild every column of a block from a per-column list of child ids (a nested
  # drag result), preserving each child's current attrs by id.
  def rebuild_columns(current, cols) do
    by_id = current |> Enum.flat_map(& &1["blocks"]) |> Map.new(&{&1["id"], &1})
    Enum.map(cols, fn ids -> %{"blocks" => pick_children(by_id, ids)} end)
  end

  defp pick_children(by_id, ids),
    do: ids |> List.wrap() |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)

  # Set `field` on the child whose id matches; leave every other child untouched.
  def maybe_put_field(%{"id" => id} = child, id, field, value),
    do: put_child_field(child, field, value)

  def maybe_put_field(child, _id, _field, _value), do: child

  # Normalize a stored/def columns value to the editor shape: a non-empty list of
  # `%{"blocks" => [child maps]}`, every child carrying a stable id (backfilled if
  # a legacy child lacks one, so the nested Sortable can address it).
  def normalize_columns(cols) do
    case List.wrap(cols) do
      [] ->
        [%{"blocks" => []}, %{"blocks" => []}]

      list ->
        Enum.map(list, fn col ->
          blocks =
            col
            |> child_blocks_of()
            |> Enum.map(&ensure_child_id/1)

          %{"blocks" => blocks}
        end)
    end
  end

  defp child_blocks_of(col) when is_map(col),
    do: (Map.get(col, "blocks") || Map.get(col, :blocks) || []) |> List.wrap()

  defp child_blocks_of(_), do: []

  defp ensure_child_id(child) do
    child = stringify_child(child)
    Map.put_new_lazy(child, "id", &Ash.UUID.generate/0)
  end

  defp stringify_child(%{} = child), do: Map.new(child, fn {k, v} -> {to_string(k), v} end)
  defp stringify_child(_), do: %{}

  # A fresh child block map (string keys) with its type-appropriate defaults.
  defp new_child(type) do
    base = %{"_type" => type, "id" => Ash.UUID.generate()}

    case type do
      "heading" -> Map.merge(base, %{"text" => "", "level" => 2})
      "rich_text" -> Map.merge(base, %{"legacy_html" => "", "body" => []})
      "quote" -> Map.merge(base, %{"text" => "", "citation" => ""})
      "image" -> Map.merge(base, %{"url" => "", "alt" => ""})
      "embed" -> Map.merge(base, %{"url" => ""})
      _ -> base
    end
  end

  # Coerce an editable child field, keeping `level` an integer (headings clamp on
  # render, so an out-of-range value is harmless, but a non-integer would fail the
  # embedded cast).
  defp put_child_field(child, "level", value), do: Map.put(child, "level", to_int(value))

  # Only the fields this child's own editor renders. `field` arrives from a
  # client event, and a bare `Map.put/3` let one name a *structural* key:
  # `_type` rewrites the union discriminator, so the next save fails its typed
  # cast — and on the autosave path that surfaces as `save_state: :error` with
  # no field to point at, leaving the document unsaveable until the block is
  # deleted; `id` collides two children's DOM ids and their drag addressing.
  # Neither is reachable from the rendered markup, which is exactly why nothing
  # would have noticed.
  defp put_child_field(child, field, value) do
    if field in Enum.map(nested_fields_for(child["_type"]), &elem(&1, 0)) do
      Map.put(child, field, value)
    else
      child
    end
  end

  def to_int(value) when is_integer(value), do: value

  def to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  def to_int(_), do: 0

  # Parse a non-negative integer index from a client value, or :error — so a
  # stale/garbled index no-ops instead of silently acting on position 0 (which
  # `to_int/1` would do).
  #
  # Binary-only: both callers (`col_add_child`, `col_remove_column`) now guard
  # `is_binary(col)` on the head (#764), so the integer and catch-all clauses
  # this used to carry were dead code. `:error` still covers the live case —
  # an unparseable *string*, which a stale client can genuinely send.
  def parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end

  def append_child(blocks, _type) when length(blocks) >= @max_children_per_column, do: blocks
  def append_child(blocks, type), do: blocks ++ [new_child(type)]

  # Keep at least one column so the block stays a valid container.
  def drop_column(cols, _ci) when length(cols) <= 1, do: cols
  def drop_column(cols, ci), do: List.delete_at(cols, ci)

  # The typed block name (string) for a sub-form's union member.
  def block_type_string(bf), do: bf |> block_member() |> Kiln.Block.Info.name() |> to_string()

  # The current item rows of an `{:array, :map}` field value, tolerating nil
  # (fresh block) and non-map junk.
  def item_row_maps(value), do: value |> List.wrap() |> Enum.filter(&is_map/1)

  # A function rather than `@row_editor_types` inline in the template: inside a
  # `~H` sigil `@name` means `assigns.name`, so referencing the module attribute
  # there reads a socket assign that does not exist and raises at render.
  def row_editor_type?(type), do: type in @row_editor_types

  # {field, placeholder} pairs for a nested child type's text inputs.
  def nested_fields_for("heading"), do: [{"text", gettext("Heading text")}]
  def nested_fields_for("rich_text"), do: [{"legacy_html", gettext("HTML / text")}]

  def nested_fields_for("quote"),
    do: [{"text", gettext("Quote")}, {"citation", gettext("Citation")}]

  def nested_fields_for("image"),
    do: [{"url", gettext("Image URL")}, {"alt", gettext("Alt text")}]

  def nested_fields_for("embed"), do: [{"url", gettext("Embed URL")}]
  def nested_fields_for(_), do: []
end
