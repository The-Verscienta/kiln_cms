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

  A `custom` block's opaque payload is declared `translatable: :unsupported` on
  the field (`Kiln.Block.Info.translatable/1`) and comes back from `extract/1`
  as a **warning**. An operator sending a file to a vendor needs to know which
  text is not in it; silence there is the failure mode the whole feature exists
  to avoid.

  A rich-text block whose prose is still in `legacy_html` used to be reported
  the same way. Since #1106 it is **converted** — `PortableText.from_html/1`,
  inside the walk — and cut into ordinary `body` units, so its prose is in the
  file with the same inline codes as everything else; the translation lands in
  `body` as Portable Text (see `materialize_legacy_html/2`).
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
  a *qualifier* over the first two, not a fourth bucket: it lists the ids whose
  match depended on ordering rather than identity, and therefore deserve a
  human look (see the moduledoc).

  `aliases` maps the file's positional addresses back to its unit ids, and is
  consulted **only when not one unit id in the file matches a slot in this
  record** — i.e. when the two trees genuinely do not share block identity.
  Mixing the two per unit is what makes positional matching dangerous: a block
  the target no longer holds frees its index for its neighbour, and that
  neighbour's slot then matches an alias belonging to a different paragraph,
  overwriting prose the file never addressed and applying one unit twice.
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
    aliases = if identity_matches?(record, translations), do: %{}, else: aliases

    {attrs, state} =
      Enum.reduce(@record_fields, {%{}, new_state()}, fn field, {attrs, state} ->
        apply_record_field(record, field, translations, attrs, state)
      end)

    {blocks, state} =
      walk(blocks_input(record), &apply_slot(&1, &2, translations, aliases), state)

    attrs = if state.blocks_changed?, do: Map.put(attrs, :blocks, blocks), else: attrs

    {attrs, report(state, translations)}
  end

  # Does this record share BLOCK identity with the file at all? One matching
  # block unit id is enough — ids are minted per record, so a collision by
  # accident is not a thing. Record-level fields (`title`, `seo_title`, …) are
  # excluded because their ids are the field name and always match, which would
  # make this answer "yes" for every file ever produced.
  #
  # When none match, the file was written against a translation
  # created before ids were carried across locales and the positional addresses
  # are the only way in; when some match, they are the *wrong* way in.
  defp identity_matches?(record, translations) do
    {units, _warnings} = extract(record)
    record_ids = MapSet.new(@record_fields, &Atom.to_string/1)

    units
    |> Enum.reject(&MapSet.member?(record_ids, &1.id))
    |> Enum.any?(&Map.has_key?(translations, &1.id))
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
          same_text?(text, current) -> {attrs, consume(state, :unchanged, id)}
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

  defp walk(blocks, fun, acc), do: walk_blocks(blocks, ctx(), fun, acc)

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
    {id_segment, positional?} = block_segment(block, index)
    ctx = push(ctx, id_segment, "b-#{index}", positional?)

    case block_module(block) do
      nil ->
        {block, acc}

      module ->
        translatable = Map.new(Kiln.Block.Info.translatable(module))
        {walked, materialized?} = materialize_legacy_html(block, module)

        {walked, acc} =
          module
          |> Kiln.Block.Info.fields()
          |> Enum.reduce({walked, acc}, fn field, {block, acc} ->
            walk_field(block, field, Map.get(translatable, field.name), ctx, fun, acc)
          end)

        # A legacy block whose converted body came back untouched — extraction,
        # or an import that addressed none of its paragraphs — is handed back
        # exactly as stored, so nothing is migrated that nothing translated.
        {legacy_result(block, walked, materialized?), acc}
    end
  end

  defp walk_block(other, _index, _ctx, _fun, acc), do: {other, acc}

  # #1106. A `rich_text` block whose prose still lives in `legacy_html` (the
  # transitional stored TipTap HTML) has nothing in `body` to cut units from —
  # and `legacy_html` is `translatable: :unsupported`, because a vendor editing
  # raw markup writes broken tags back. So the walk sees such a block through
  # `PortableText.from_html/1`: the converted body is cut into units under the
  # same `…/body/k:b0` addresses the editor's own body would have (the
  # converter emits the same `b0`/`b1` keys TipTap→PT does), inline markup
  # becomes the same `<pc>` codes every rich-text unit already carries, and an
  # applied translation lands in `body` — Portable Text, which render and
  # save both prefer, and which `TypedBlocks.sanitize_attrs/1` completes by
  # nilling `legacy_html` on the way in. Migrate-on-translate: the source keeps
  # its HTML, the translation is born as PT.
  defp materialize_legacy_html(block, KilnCMS.Blocks.RichText) do
    if carries_content?(block, "legacy_html") and not carries_content?(block, "body") do
      case Blocks.PortableText.from_html(Map.get(block, "legacy_html")) do
        [] -> {block, false}
        body -> {Map.put(block, "body", body), true}
      end
    else
      {block, false}
    end
  end

  defp materialize_legacy_html(block, _module), do: {block, false}

  defp legacy_result(_original, walked, false), do: walked

  defp legacy_result(original, walked, true) do
    if Map.get(walked, "body") == Blocks.PortableText.from_html(Map.get(original, "legacy_html")),
      do: original,
      else: walked
  end

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
        walk_item(item, kind, push(ctx, "i-#{index}", "i-#{index}", true), fun, acc)
      end)

    {put_existing(block, key, items), acc}
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
        {id_segment, positional?} = pt_segment(pt, index)
        walk_pt(pt, push(ctx, id_segment, "p-#{index}", positional?), fun, acc)
      end)

    {put_existing(block, key, body), acc}
  end

  defp walk_field(block, field, :text, ctx, fun, acc),
    do: walk_text(block, Atom.to_string(field.name), ctx, fun, acc)

  defp walk_field(block, field, :unsupported, ctx, fun, acc) do
    if carries_content?(block, Atom.to_string(field.name)) and not shadowed?(block, field) do
      {_keep, acc} = fun.(unsupported(ctx, field.name), acc)
      {block, acc}
    else
      {block, acc}
    end
  end

  defp walk_field(block, _field, _kind, _ctx, _fun, acc), do: {block, acc}

  # `legacy_html` with a non-empty `body` alongside is the materialized case
  # (`materialize_legacy_html/2`) — or a stale copy PT already shadows, which
  # `TypedBlocks` nils on save. Either way its prose IS in the file, as body
  # units, so it is not reported as left out (#1106).
  defp shadowed?(block, %{name: :legacy_html}), do: carries_content?(block, "body")
  defp shadowed?(_block, _field), do: false

  # `TypedBlocks.input_map/1` drops nil values, so a field that was never set is
  # simply absent — and `List.wrap(nil)` is `[]`. Putting that back would add an
  # explicit `[]` the record never had, turning a translation import into a
  # write on blocks the file never addressed: a version row, a re-fire and a
  # spurious entry in the version-compare diff, per import.
  defp put_existing(map, key, value) do
    if Map.has_key?(map, key), do: Map.put(map, key, value), else: map
  end

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
  # key, which behave identically once the path is built.
  #
  # The slot is built even when the stored value is blank or absent, and it is
  # the *callback* that decides: extraction skips blanks (an empty
  # `seo_description` is not a translation job, and a vendor charging per unit
  # should not be billed for it), while application must not, or a caption
  # added to the source after the target draft was created could never be
  # imported — the returned prose would be dropped and reported as an id this
  # record does not have.
  defp walk_text(map, key, ctx, fun, acc) do
    slot = slot(ctx, key, key, [%{text: value_at(map, key), marks: []}], [])

    case fun.(slot, acc) do
      {:keep, acc} -> {map, acc}
      {runs, acc} -> {Map.put(map, key, plain(runs)), acc}
    end
  end

  defp value_at(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent -> ""
    end
  end

  # Is there anything here to report as *not* exported? Type-agnostic, because
  # `:unsupported` is allowed on any field — `custom.data` is a map, and it is
  # exactly where an unmapped legacy block's prose ends up.
  defp carries_content?(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value) != ""
      value when is_map(value) -> map_size(value) > 0
      value when is_list(value) -> value != []
      nil -> false
      _other -> true
    end
  end

  # ── Portable Text ──────────────────────────────────────────────────────────

  # A text block: one unit for the whole paragraph, spans flattened to runs.
  defp walk_pt(%{"_type" => "block"} = pt, ctx, fun, acc) do
    defs = pt |> Map.get("markDefs") |> List.wrap()

    case runs_from_children(Map.get(pt, "children")) do
      :unsupported ->
        {pt, fun.(unsupported(ctx, :children), acc) |> elem(1)}

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
        walk_pt_cell(cell, push(ctx, "r#{r}c#{c}", "r#{r}c#{c}", true), fun, acc)
      end)

    {Map.put(row, "cells", cells), acc}
  end

  defp walk_pt_row(other, _r, _ctx, _fun, acc), do: {other, acc}

  defp walk_pt_cell(cell, ctx, fun, acc) when is_map(cell) do
    defs = cell |> Map.get("markDefs") |> List.wrap()

    case runs_from_children(Map.get(cell, "children")) do
      :unsupported ->
        {cell, fun.(unsupported(ctx, :children), acc) |> elem(1)}

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
      :unsupported ->
        :unsupported

      runs ->
        # Merged, because `Document.merge_runs/1` merges on the way back in: a
        # vendor tool re-serializing the same sentence as two text nodes must
        # not read as a change, and neither must our own hard breaks, which are
        # stored as their own unmarked span. Without this an untouched echo of
        # the exported file rewrote every paragraph holding one.
        if Enum.all?(runs, &(&1.text == "")), do: [], else: merge_runs(runs)
    end
  end

  defp runs_from_children(_other), do: []

  defp merge_runs(runs) do
    runs
    |> Enum.reduce([], fn
      run, [%{marks: marks} = previous | rest] when marks == run.marks ->
        [%{previous | text: previous.text <> run.text} | rest]

      run, acc ->
        [run | acc]
    end)
    |> Enum.reverse()
  end

  defp marks_of(span) do
    span
    |> Map.get("marks")
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  # The inverse of `runs_from_children/1`. A newline is re-split into the bare
  # unmarked span Portable Text uses for a hard break — `PortableText`'s HTML
  # renderer matches `%{"text" => "\n"}` exactly to emit `<br/>`, so leaving it
  # inside a longer span would render the line break away.
  defp children_from_runs(runs) do
    Enum.flat_map(runs, fn run ->
      run.text
      |> String.split("\n")
      |> Enum.map(&span(&1, run.marks))
      |> Enum.intersperse(span("\n", []))
      |> Enum.reject(&(&1["text"] == "" and &1["marks"] == run.marks))
    end)
  end

  defp span(text, marks), do: %{"_type" => "span", "text" => text, "marks" => marks}

  # ── slot plumbing ──────────────────────────────────────────────────────────

  defp ctx, do: %{id: "", position: "", positional?: false}

  # `positional?` is sticky: once any segment of the path is an index rather
  # than an identity, the whole slot is positionally addressed and a match on
  # it deserves the same "check this" flag an explicit fallback gets.
  defp push(ctx, id_segment, position_segment, positional? \\ false) do
    %{
      ctx
      | id: join(ctx.id, id_segment),
        position: join(ctx.position, position_segment),
        positional?: ctx.positional? or positional?
    }
  end

  # `.` and every character `segment/1` admits are XML `NameChar`s, because
  # XLIFF 2.0 types `unit/@id` as `xsd:NMTOKEN`. `/` and `#` — the obvious
  # separators — are not, and a tool that validates against the core schema on
  # ingest rejects the whole document rather than the offending unit.
  defp join("", segment), do: segment
  defp join(prefix, segment), do: prefix <> "." <> segment

  # Anything outside the NMTOKEN character set becomes `_`. Stored Portable Text
  # keys and block ids never need it; a hand-authored `_key` might.
  defp segment(value), do: String.replace(to_string(value), ~r/[^A-Za-z0-9_:.-]/u, "_")

  # `key` is nil for a slot that *is* the current path (a Portable Text
  # paragraph, a table cell) rather than a named field under it.
  defp slot(ctx, key, label, runs, mark_defs) do
    ctx = if key, do: push(ctx, key, key), else: ctx

    %{
      id: ctx.id,
      position_id: ctx.position,
      positional?: ctx.positional?,
      label: label,
      runs: runs,
      mark_defs: mark_defs
    }
  end

  defp unsupported(ctx, field), do: %{unsupported: %{path: ctx.id, field: field}}

  # `{id segment, positional?}`. A block with no readable `id` — every `columns`
  # child written by anything but the content editor (#865/#954) — has nothing
  # to address it by but its index, and saying so is what keeps the import
  # report honest: without the flag, `slot.id == slot.position_id` and a match
  # that is only as good as the ordering reports as an identity match.
  defp block_segment(block, index) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> {"b:" <> segment(id), false}
      _none -> {"b-#{index}", true}
    end
  end

  defp pt_segment(pt, index) when is_map(pt) do
    case Map.get(pt, "_key") do
      key when is_binary(key) and key != "" -> {"k:" <> segment(key), false}
      _none -> {"p-#{index}", true}
    end
  end

  defp pt_segment(_other, index), do: {"p-#{index}", true}

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

  # "Did the vendor actually change this?", answered modulo line endings.
  #
  # A carriage return cannot survive the round trip: XML 1.0 normalizes a
  # literal CR to LF before the parser sees it, and `xmerl` folds a `&#13;`
  # character reference the same way (non-conformantly, but it is the parser we
  # have). So a record holding CRLF — pasted from Word, or imported through
  # WXR — would compare unequal to an *untouched echo of its own export* and be
  # rewritten, bumping `updated_at` and clearing the document's staleness
  # marker for a translation nobody made. Comparing normalized means an echo is
  # correctly `unchanged`; a real translation still writes, in the LF form the
  # file actually carried.
  defp same_text?(a, b), do: newlines(a) == newlines(to_string(b))

  defp same_runs?(a, b) do
    Enum.map(a, &%{&1 | text: newlines(&1.text)}) == Enum.map(b, &%{&1 | text: newlines(&1.text)})
  end

  defp newlines(text), do: String.replace(text, "\r\n", "\n") |> String.replace("\r", "\n")

  # ── extraction / application callbacks ─────────────────────────────────────

  defp collect_slot(%{unsupported: warning}, {units, warnings}),
    do: {:keep, {units, [Map.put(warning, :reason, :unsupported_field) | warnings]}}

  # Blank slots exist in the walk so that `apply_translations/3` can fill one
  # the target does not have yet; they are not translation jobs, so extraction
  # drops them here rather than billing a vendor per empty unit.
  defp collect_slot(slot, {units, warnings}) do
    if blank?(slot.runs),
      do: {:keep, {units, warnings}},
      else: {:keep, {[slot | units], warnings}}
  end

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

        # Either an explicit fallback *or* an id whose own path is positional —
        # a map-array item, a table cell, an id-less nested child. Both are only
        # as good as the ordering having held, and the operator has no way to
        # tell them apart from the outside.
        state =
          if matched_by == :position or slot.positional?,
            do: consume(state, :by_position, id),
            else: state

        if same_runs?(runs, slot.runs) or blank?(runs) do
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
