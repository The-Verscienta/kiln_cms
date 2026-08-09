defmodule KilnCMS.CMS.Xliff.Units do
  @moduledoc """
  The **unit-id scheme** behind XLIFF export/import (#502) — how a content
  record is cut into addressable translation units, and how translated units
  are put back.

  This is the design centre of the vendor seam. A trans-unit id has to identify
  a slot of prose well enough that a file which comes back three weeks later,
  after the source has been edited, lands every string where it belongs — or
  says it could not.

  ## The addressing scheme

  A unit id is a `/`-joined path. Record fields are their own name
  (`title`, `seo_description`); everything else descends the block tree:

      b:9f3c…                      a top-level block, by its stable id
      b:9f3c…/text                 a plain string field on it
      b:9f3c…/body/k:b2            one Portable Text block inside a rich-text field
      b:9f3c…/body/k:b2/r0c1       one cell of a Portable Text table
      b:9f3c…/items/i0/question    one key of one item of a map-array field
      b:9f3c…/columns/i1/b:ab12…   a nested child block inside a `columns` column

  Blocks carry a writable uuid primary key precisely so identity survives
  reordering (`Kiln.Block` — `uuid_primary_key :id, writable?: true`), and
  Portable Text blocks carry a `_key`, so the path above is stable under both
  block reordering *and* paragraph reordering. That is the property that makes
  a returned file safe to apply: the vendor's unit ids are matched against
  identity, never against position.

  ## The positional fallback, and why it is not the primary scheme

  Every slot also gets a **positional** path — the same shape with `b#0` for a
  block and `p#0` for a paragraph — and `apply/2` falls back to it when the
  id path misses. That covers exactly one real case: a translation created
  before ids were carried across locales (see
  `KilnCMS.CMS.Translations.create_translation!/4`, which now preserves them),
  whose blocks are structural clones of the source under different ids.

  It is a fallback and it is *reported* as one, because it is the mode that can
  put a paragraph in the wrong place: it is right only while the two trees are
  still shaped the same. An id match cannot be wrong; a positional match can be
  wrong in a way nobody notices until a reader does.

  ## Runs, not strings

  Every slot's value is a list of **runs** — `%{text: binary, marks: [binary]}` —
  so plain fields and marked-up prose have one shape. `marks` are Portable Text
  mark names verbatim (`"strong"`, or a `markDefs` key like `"lk0"`), which is
  what makes the round trip lossless: `apply/2` keeps each block's `markDefs`
  exactly as it found them and restores marks by name, so a link survives
  translation without a vendor ever being able to retarget it. The href travels
  into the file as *context* (`KilnCMS.CMS.Xliff.Document` writes it into
  `<originalData>`), not as something the file can change.

  ## What is not a unit

  A rich-text block whose prose is still in `legacy_html`, and a `custom`
  block's opaque payload, are declared `translatable: :unsupported` on the
  field (`Kiln.Block.Info.translatable/1`) and come back from `extract/1` as
  **warnings**. An operator sending a file to a vendor needs to know which text
  is not in it; silence there is the failure mode the whole feature exists to
  avoid.
  """

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks

  @typedoc "One run of text and the Portable Text marks covering it."
  @type run :: %{text: String.t(), marks: [String.t()]}

  @typedoc """
  One translation unit: an id-addressed slot of prose, its positional
  fallback address, a translator-facing label, and its source runs.
  `mark_defs` is the slot's Portable Text `markDefs` (empty for plain fields) —
  the exporter resolves link hrefs from it for translator context.
  """
  @type unit :: %{
          id: String.t(),
          position_id: String.t(),
          label: String.t(),
          runs: [run()],
          mark_defs: [map()]
        }

  @typedoc "Prose the exporter deliberately did not put in the file."
  @type warning :: %{path: String.t(), field: atom(), reason: :unsupported_field}

  # Record-level translatable attributes, in the order a translator reads them.
  # `seo_image`, `slug` and `canonical_url` are deliberately absent: a slug is
  # generated per locale by the type's own pattern, and the other two are URLs.
  @record_fields [:title, :excerpt, :seo_title, :seo_description, :seo_keywords]

  @doc "The record-level attributes that become trans-units."
  @spec record_fields() :: [atom()]
  def record_fields, do: @record_fields

  @doc """
  Every translation unit in `record`, in document order, plus the prose that
  was left out (see the moduledoc).

  Blank slots are skipped — an empty `seo_description` is not a translation
  job, and a vendor charging per unit should not be billed for it.
  """
  @spec extract(struct()) :: {[unit()], [warning()]}
  def extract(record) do
    {units, warnings} =
      Enum.reduce(@record_fields, {[], []}, fn field, acc ->
        collect(acc, record_unit(record, field))
      end)

    {_blocks, {block_units, block_warnings}} =
      walk(blocks_input(record), &collect_slot/2, {[], []})

    {Enum.reverse(units) ++ Enum.reverse(block_units),
     Enum.reverse(warnings) ++ Enum.reverse(block_warnings)}
  end

  @doc """
  Apply `translations` (a `unit id => [run]` map) to `record`, returning the
  update attrs to write and a report of what happened to every unit.

  The attrs map holds only what actually changed, so applying a file whose
  targets are all identical to what is stored produces `%{}` and the caller can
  skip the write entirely.

  Every id in `translations` lands in exactly one of `applied`, `unchanged` and
  `unknown` — nothing is dropped quietly, which is the point. `by_position` is
  a *qualifier* over the first two, not a fourth bucket: it lists the ids that
  only resolved through the positional fallback and therefore deserve a human
  look (see the moduledoc).
  """
  @spec apply_translations(struct(), %{String.t() => [run()]}, %{String.t() => String.t()}) ::
          {%{atom() => term()},
           %{
             applied: [String.t()],
             unchanged: [String.t()],
             by_position: [String.t()],
             unknown: [String.t()]
           }}
  def apply_translations(record, translations, aliases \\ %{})
      when is_map(translations) and is_map(aliases) do
    {attrs, state} =
      Enum.reduce(@record_fields, {%{}, new_state()}, fn field, {attrs, state} ->
        apply_record_field(record, field, translations, attrs, state)
      end)

    {blocks, state} =
      walk(blocks_input(record), &apply_slot(&1, &2, translations, aliases), state)

    attrs = if state.blocks_changed?, do: Map.put(attrs, :blocks, blocks), else: attrs

    {attrs, report(state, translations)}
  end

  # ── record-level fields ────────────────────────────────────────────────────

  defp record_unit(record, field) do
    case Map.get(record, field) do
      value when is_binary(value) ->
        text = String.trim(value)

        if text == "" do
          nil
        else
          id = Atom.to_string(field)

          %{
            id: id,
            position_id: id,
            label: id,
            runs: [%{text: value, marks: []}],
            mark_defs: []
          }
        end

      _absent ->
        nil
    end
  end

  defp apply_record_field(record, field, translations, attrs, state) do
    id = Atom.to_string(field)

    case Map.fetch(translations, id) do
      {:ok, runs} ->
        current = Map.get(record, field)
        text = plain(runs)

        # An empty target is "not translated yet", not "clear this field" — a
        # vendor's file is full of them while a job is in progress, and an
        # import that blanked the title on every partial delivery would be
        # unusable.
        cond do
          blank?(runs) -> {attrs, consume(state, :unchanged, id)}
          text == current -> {attrs, consume(state, :unchanged, id)}
          true -> {Map.put(attrs, field, text), consume(state, :applied, id)}
        end

      :error ->
        {attrs, state}
    end
  end

  # ── the shared walk ────────────────────────────────────────────────────────
  #
  # One traversal serves both directions. `fun.(slot, acc)` returns
  # `{runs_or_:keep, acc}`; extraction never replaces, application replaces the
  # slots it has a translation for. Keeping it to one function is the only way
  # the two sides cannot drift apart on the id scheme, which is the whole
  # correctness argument here.

  # `%Ash.NotLoaded{}` is a map and survives `List.wrap/1` as a one-element
  # list, so an unselected `blocks` would walk as a single junk block rather
  # than as nothing. Match the list explicitly.
  defp blocks_input(%{blocks: blocks}) when is_list(blocks),
    do: Enum.map(blocks, &TypedBlocks.input_map/1)

  defp blocks_input(_record), do: []

  defp walk(blocks, fun, acc), do: walk_blocks(blocks, ctx("", ""), fun, acc)

  defp walk_blocks(blocks, ctx, fun, acc) do
    blocks
    |> Enum.with_index()
    |> Enum.map_reduce(acc, fn {block, index}, acc -> walk_block(block, index, ctx, fun, acc) end)
  end

  # The `is_map` guard has to sit here rather than one call deeper: nested
  # children are raw jsonb, so a hand-written (or API-written) `columns` column
  # can hold something that is not a block map at all, and addressing it would
  # raise before any clause got to decline it. Anything unrecognized travels
  # through untouched.
  defp walk_block(block, index, ctx, fun, acc) when is_map(block) do
    ctx = push(ctx, block_segment(block, index), "b##{index}")

    case block_module(block) do
      nil ->
        {block, acc}

      module ->
        translatable = Map.new(Kiln.Block.Info.translatable(module))

        module
        |> Kiln.Block.Info.fields()
        |> Enum.reduce({block, acc}, fn field, {block, acc} ->
          walk_field(block, field, Map.get(translatable, field.name), ctx, fun, acc)
        end)
    end
  end

  defp walk_block(other, _index, _ctx, _fun, acc), do: {other, acc}

  # A `{:array, :map}` field is walked twice over: once for its declared
  # translatable keys, and once for child blocks. A `columns` block has only
  # the second; a hypothetical container with captioned columns would have
  # both, which is why they are separate passes rather than a branch.
  defp walk_field(block, %{type: {:array, :map}} = field, kind, ctx, fun, acc) do
    key = Atom.to_string(field.name)
    ctx = push(ctx, key, key)

    {items, acc} =
      block
      |> Map.get(key)
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map_reduce(acc, fn {item, index}, acc ->
        walk_item(item, kind, push(ctx, "i#{index}", "i#{index}"), fun, acc)
      end)

    {Map.put(block, key, items), acc}
  end

  defp walk_field(block, field, :rich_text, ctx, fun, acc) do
    key = Atom.to_string(field.name)
    ctx = push(ctx, key, key)

    {body, acc} =
      block
      |> Map.get(key)
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map_reduce(acc, fn {pt, index}, acc ->
        walk_pt(pt, push(ctx, pt_segment(pt, index), "p##{index}"), fun, acc)
      end)

    {Map.put(block, key, body), acc}
  end

  defp walk_field(block, field, :text, ctx, fun, acc),
    do: walk_text(block, Atom.to_string(field.name), ctx, fun, acc)

  defp walk_field(block, field, :unsupported, ctx, fun, acc) do
    if present?(block, Atom.to_string(field.name)) do
      {_keep, acc} = fun.(unsupported(ctx, field.name), acc)
      {block, acc}
    else
      {block, acc}
    end
  end

  defp walk_field(block, _field, _kind, _ctx, _fun, acc), do: {block, acc}

  # One item of an `{:array, :map}` field: its declared translatable keys, and
  # any child blocks parked under a `"blocks"` list (the container convention
  # `columns` established and the block policy traversal already follows).
  defp walk_item(item, kind, ctx, fun, acc) when is_map(item) do
    {item, acc} = walk_item_keys(item, kind, ctx, fun, acc)

    case Map.get(item, "blocks") do
      children when is_list(children) ->
        {children, acc} = walk_blocks(children, ctx, fun, acc)
        {Map.put(item, "blocks", children), acc}

      _none ->
        {item, acc}
    end
  end

  defp walk_item(other, _kind, _ctx, _fun, acc), do: {other, acc}

  defp walk_item_keys(item, {:map_keys, keys}, ctx, fun, acc) do
    Enum.reduce(keys, {item, acc}, fn name, {item, acc} ->
      walk_text(item, Atom.to_string(name), ctx, fun, acc)
    end)
  end

  defp walk_item_keys(item, _kind, _ctx, _fun, acc), do: {item, acc}

  # One plain-text slot at `key` of `map` — a block field or a map-array item's
  # key, which behave identically once the path is built. Blank stays blank in
  # both directions: it is not a translation job going out and it is not a
  # field to clear coming back.
  defp walk_text(map, key, ctx, fun, acc) do
    if present?(map, key) do
      slot = slot(ctx, key, key, [%{text: Map.fetch!(map, key), marks: []}], [])

      case fun.(slot, acc) do
        {:keep, acc} -> {map, acc}
        {runs, acc} -> {Map.put(map, key, plain(runs)), acc}
      end
    else
      {map, acc}
    end
  end

  defp present?(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _absent -> false
    end
  end

  # ── Portable Text ──────────────────────────────────────────────────────────

  # A text block: one unit for the whole paragraph, spans flattened to runs.
  defp walk_pt(%{"_type" => "block"} = pt, ctx, fun, acc) do
    defs = pt |> Map.get("markDefs") |> List.wrap()

    case runs_from_children(Map.get(pt, "children")) do
      :unsupported ->
        {pt, fun.(unsupported(ctx, :children), acc) |> elem(1)}

      [] ->
        {pt, acc}

      runs ->
        case fun.(slot(ctx, nil, label_for(pt), runs, defs), acc) do
          {:keep, acc} -> {pt, acc}
          {runs, acc} -> {Map.put(pt, "children", children_from_runs(runs)), acc}
        end
    end
  end

  # A table: one unit per cell, addressed `r<row>c<col>`.
  defp walk_pt(%{"_type" => "table"} = pt, ctx, fun, acc) do
    {rows, acc} =
      pt
      |> Map.get("rows")
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map_reduce(acc, fn {row, r}, acc -> walk_pt_row(row, r, ctx, fun, acc) end)

    {Map.put(pt, "rows", rows), acc}
  end

  defp walk_pt(other, _ctx, _fun, acc), do: {other, acc}

  defp walk_pt_row(row, r, ctx, fun, acc) when is_map(row) do
    {cells, acc} =
      row
      |> Map.get("cells")
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map_reduce(acc, fn {cell, c}, acc ->
        walk_pt_cell(cell, push(ctx, "r#{r}c#{c}", "r#{r}c#{c}"), fun, acc)
      end)

    {Map.put(row, "cells", cells), acc}
  end

  defp walk_pt_row(other, _r, _ctx, _fun, acc), do: {other, acc}

  defp walk_pt_cell(cell, ctx, fun, acc) when is_map(cell) do
    defs = cell |> Map.get("markDefs") |> List.wrap()

    case runs_from_children(Map.get(cell, "children")) do
      :unsupported ->
        {cell, fun.(unsupported(ctx, :children), acc) |> elem(1)}

      [] ->
        {cell, acc}

      runs ->
        case fun.(slot(ctx, nil, "table cell", runs, defs), acc) do
          {:keep, acc} -> {cell, acc}
          {runs, acc} -> {Map.put(cell, "children", children_from_runs(runs)), acc}
        end
    end
  end

  defp walk_pt_cell(other, _ctx, _fun, acc), do: {other, acc}

  # Spans in, runs out. Anything that is not a span makes the whole slot
  # untranslatable rather than partially translatable: `children` is rebuilt
  # wholesale from the returned runs, so emitting a unit for a block holding
  # something this function cannot represent would delete it on the way back.
  # Nothing in the current TipTap → Portable Text conversion produces one; this
  # is the guard for stored data that does.
  defp runs_from_children(children) when is_list(children) do
    Enum.reduce_while(children, [], fn
      %{"_type" => "span"} = span, acc ->
        text = Map.get(span, "text")

        if is_binary(text) do
          {:cont, acc ++ [%{text: text, marks: marks_of(span)}]}
        else
          {:halt, :unsupported}
        end

      _other, _acc ->
        {:halt, :unsupported}
    end)
    |> case do
      :unsupported -> :unsupported
      runs -> if Enum.all?(runs, &(&1.text == "")), do: [], else: runs
    end
  end

  defp runs_from_children(_other), do: []

  defp marks_of(span) do
    span
    |> Map.get("marks")
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp children_from_runs(runs) do
    Enum.map(runs, fn run ->
      %{"_type" => "span", "text" => run.text, "marks" => run.marks}
    end)
  end

  # ── slot plumbing ──────────────────────────────────────────────────────────

  defp ctx(id, position), do: %{id: id, position: position, labels: []}

  defp push(ctx, id_segment, position_segment) do
    %{
      ctx
      | id: join(ctx.id, id_segment),
        position: join(ctx.position, position_segment)
    }
  end

  defp join("", segment), do: segment
  defp join(prefix, segment), do: prefix <> "/" <> segment

  # `segment` is nil for a slot that *is* the current path (a Portable Text
  # paragraph, a table cell) rather than a named field under it.
  defp slot(ctx, segment, label, runs, mark_defs) do
    {id, position_id} =
      case segment do
        nil -> {ctx.id, ctx.position}
        segment -> {join(ctx.id, segment), join(ctx.position, segment)}
      end

    %{id: id, position_id: position_id, label: label, runs: runs, mark_defs: mark_defs}
  end

  defp unsupported(ctx, field), do: %{unsupported: %{path: ctx.id, field: field}}

  defp block_segment(block, index) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> "b:" <> id
      _none -> "b##{index}"
    end
  end

  defp pt_segment(pt, index) when is_map(pt) do
    case Map.get(pt, "_key") do
      key when is_binary(key) and key != "" -> "k:" <> key
      _none -> "p##{index}"
    end
  end

  defp pt_segment(_other, index), do: "p##{index}"

  defp block_module(block) do
    with type when is_binary(type) <- Map.get(block, "_type"),
         {:ok, atom} <- to_existing(type),
         {:ok, module} <- Blocks.fetch(atom) do
      module
    else
      _none -> nil
    end
  end

  defp to_existing(type) do
    {:ok, String.to_existing_atom(type)}
  rescue
    ArgumentError -> :error
  end

  defp label_for(%{"style" => style}) when is_binary(style), do: style
  defp label_for(_pt), do: "paragraph"

  # No trimming: leading/trailing space can be significant in a run of prose,
  # and a serializer that quietly reshapes what a translator sent back is a
  # serializer nobody can reconcile against their own file.
  defp plain(runs), do: Enum.map_join(runs, & &1.text)

  defp blank?(runs), do: runs |> plain() |> String.trim() == ""

  # ── extraction / application callbacks ─────────────────────────────────────

  defp collect_slot(%{unsupported: warning}, {units, warnings}),
    do: {:keep, {units, [Map.put(warning, :reason, :unsupported_field) | warnings]}}

  defp collect_slot(slot, {units, warnings}), do: {:keep, {[slot | units], warnings}}

  defp collect({units, warnings}, nil), do: {units, warnings}
  defp collect({units, warnings}, unit), do: {[unit | units], warnings}

  defp new_state,
    do: %{
      applied: [],
      unchanged: [],
      by_position: [],
      consumed: MapSet.new(),
      blocks_changed?: false
    }

  defp apply_slot(%{unsupported: _warning}, state, _translations, _aliases), do: {:keep, state}

  defp apply_slot(slot, state, translations, aliases) do
    case lookup(slot, translations, aliases) do
      :error ->
        {:keep, state}

      {:ok, id, runs, matched_by} ->
        runs = restore_marks(runs, slot.runs)
        state = if matched_by == :position, do: consume(state, :by_position, id), else: state

        if runs == slot.runs or blank?(runs) do
          {:keep, consume(state, :unchanged, id)}
        else
          {runs, %{consume(state, :applied, id) | blocks_changed?: true}}
        end
    end
  end

  # The id path wins outright. Only when it misses entirely does the positional
  # address get a look, and then through `aliases` — the file's own
  # `unit id => positional address` mapping, inverted — so the id reported as
  # consumed is always the one the vendor's file actually carries.
  defp lookup(slot, translations, aliases) do
    case Map.fetch(translations, slot.id) do
      {:ok, runs} -> {:ok, slot.id, runs, :id}
      :error -> lookup_by_position(slot, translations, aliases)
    end
  end

  defp lookup_by_position(slot, translations, aliases) do
    with {:ok, id} <- Map.fetch(aliases, slot.position_id),
         {:ok, runs} <- Map.fetch(translations, id) do
      {:ok, id, runs, :position}
    end
  end

  # A returned unit's marks are advisory: the vendor may have dropped, split or
  # duplicated the inline codes, and a mark naming a `markDefs` key that no
  # longer exists in this block would produce a span pointing at nothing. Marks
  # are therefore filtered to the set the *stored* slot already had, which is
  # also what stops a returned file from introducing a link.
  defp restore_marks(runs, source_runs) do
    allowed = source_runs |> Enum.flat_map(& &1.marks) |> MapSet.new()

    Enum.map(runs, fn run ->
      %{run | marks: Enum.filter(run.marks, &MapSet.member?(allowed, &1))}
    end)
  end

  defp consume(state, bucket, id) do
    %{
      state
      | bucket => [id | Map.fetch!(state, bucket)],
        consumed: MapSet.put(state.consumed, id)
    }
  end

  defp report(state, translations) do
    unknown =
      translations
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(state.consumed, &1))
      |> Enum.sort()

    %{
      applied: Enum.reverse(state.applied),
      unchanged: Enum.reverse(state.unchanged),
      by_position: Enum.reverse(state.by_position),
      unknown: unknown
    }
  end
end
