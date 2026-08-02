defmodule KilnCMS.CMS.VersionDiff do
  @moduledoc """
  Compares two `KilnCMS.CMS.VersionSnapshot` maps and reports what changed (#467).

  Pure computation over stored shapes — no reads, no rendering, no gettext. The
  caller supplies two snapshots and the resource they came from; field labels and
  markup are the web layer's job (`KilnCMS.CMS.VersionDiff` is used by the editor's
  compare modal and is safe to reuse anywhere a diff is wanted).

  ## What it reports

    * **Fields** — every diffable attribute of the resource, scalar-compared.
      Long text values additionally carry `:inline`, a word-level run-length diff.
      `custom_fields` (a map) is compared key by key instead of as one blob.
    * **Blocks** — the block tree, keyed on each block's stable `id` so a block
      that moved is reported as *moved* rather than as a delete plus an insert.
      A changed rich-text block carries an `:inline` diff of its prose.

  Not every reported field is one a restore writes back — workflow and
  attribution are deliberately left alone. `KilnCMS.CMS.VersionFields.restorable?/1`
  is the answer, and the compare modal marks those rows (#691).

  Both use `List.myers_difference/2` from the standard library; no diff dependency
  is involved.

  ## Bounds

  Myers is O(N × D) in the size of the inputs and their distance, so inline text
  diffing is bounded twice: per string (2,000 tokens a side) *and* per document
  (a shared budget across every block). One block's worth of tokens is cheap; a
  400-block article where every block was rewritten is not, and only the second
  bound catches that. Past either, the entry still reports *changed* with its
  field-level values — it just doesn't get word-level runs.
  """

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.CMS.BlockText
  alias KilnCMS.CMS.VersionFields
  alias KilnCMS.CMS.VersionSnapshot

  @typedoc "A run of unchanged / removed / added text."
  @type run :: {:eq | :del | :ins, String.t()}

  @typedoc "Whether an entry was added, removed, changed, or left alone."
  @type status :: :added | :removed | :changed | :unchanged

  defmodule Field do
    @moduledoc """
    One attribute's before/after in a `KilnCMS.CMS.VersionDiff`.

    `restorable?` is answered here rather than by the renderer because it is a
    fact about the *resource* (`KilnCMS.CMS.VersionFields.restorable?/2`), and
    the resource is in hand at diff time and gone by render time (#691).
    """
    @derive {Inspect, optional: [:inline, :entries]}
    defstruct [:name, :status, :old, :new, inline: nil, entries: [], restorable?: true]

    @type t :: %__MODULE__{
            name: atom(),
            status: KilnCMS.CMS.VersionDiff.status(),
            old: term(),
            new: term(),
            restorable?: boolean(),
            inline: [KilnCMS.CMS.VersionDiff.run()] | nil,
            entries: [
              %{
                key: String.t(),
                status: KilnCMS.CMS.VersionDiff.status(),
                old: term(),
                new: term()
              }
            ]
          }
  end

  defmodule Block do
    @moduledoc """
    One block's before/after in a `KilnCMS.CMS.VersionDiff`.

    `moved?` is orthogonal to `status`: a block can be moved and unchanged, moved
    and changed, or changed in place.

    Deliberately holds no copy of the block maps themselves — `inline` and
    `fields` are computed up front and are everything a renderer needs, so a
    comparison of a long document doesn't pin two whole block trees in the
    caller's process for as long as the view is open.
    """
    defstruct [
      :key,
      :status,
      :type,
      :old_index,
      :new_index,
      moved?: false,
      inline: nil,
      fields: []
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            status: KilnCMS.CMS.VersionDiff.status(),
            type: String.t() | nil,
            old_index: non_neg_integer() | nil,
            new_index: non_neg_integer() | nil,
            moved?: boolean(),
            inline: [KilnCMS.CMS.VersionDiff.run()] | nil,
            fields: [%{name: String.t(), old: term(), new: term()}]
          }
  end

  defstruct fields: [], blocks: [], changed?: false

  @type t :: %__MODULE__{
          fields: [Field.t()],
          blocks: [Block.t()],
          changed?: boolean()
        }

  # Compared key-by-key rather than as one opaque value.
  @map_fields ~w(custom_fields)a

  # Fields whose text the block-level inline diff already renders. Listing them
  # again in the field table would print a Portable Text AST directly beneath its
  # own rendered diff.
  @prose_fields ~w(body legacy_html content text)

  # Past this many whitespace-separated tokens on either side, report the change
  # without word-level runs. Note `tokenize/1` captures separators, so a token is
  # roughly half a word.
  @inline_token_limit 2_000

  # And past this many tokens across the whole block tree, stop computing runs
  # entirely — the per-string bound says nothing about a document that blew its
  # budget four hundred blocks at a time.
  @document_token_budget 20_000

  @doc """
  Diffs `old` against `new`, both `KilnCMS.CMS.VersionSnapshot` maps from `resource`.

  Fields that are equal are omitted; blocks are all returned, `:unchanged` ones
  included, so the caller can render the tree in context.
  """
  @spec between(VersionSnapshot.t(), VersionSnapshot.t(), module()) :: t()
  def between(old, new, resource) when is_map(old) and is_map(new) do
    fields = diff_fields(old, new, resource)
    blocks = diff_blocks(Map.get(old, "blocks"), Map.get(new, "blocks"))

    %__MODULE__{
      fields: fields,
      blocks: blocks,
      changed?: fields != [] or Enum.any?(blocks, &(&1.status != :unchanged or &1.moved?))
    }
  end

  @doc """
  Word-level diff of two strings as `{:eq | :del | :ins, text}` runs.

  Splitting on whitespace *with* the separators captured means joining every run
  reproduces the original text, so a renderer can highlight without reflowing.
  Returns `nil` when either side is past `#{@inline_token_limit}` tokens.
  """
  @spec inline_runs(String.t() | nil, String.t() | nil) :: [run()] | nil
  def inline_runs(old, new) do
    old_tokens = tokenize(old)
    new_tokens = tokenize(new)

    if length(old_tokens) > @inline_token_limit or length(new_tokens) > @inline_token_limit do
      nil
    else
      runs(old_tokens, new_tokens)
    end
  end

  defp runs(old_tokens, new_tokens) do
    old_tokens
    |> List.myers_difference(new_tokens)
    |> Enum.map(fn {op, tokens} -> {op, Enum.join(tokens)} end)
  end

  @doc """
  The attributes of `resource` this module compares, in display order.

  Declared in `KilnCMS.CMS.VersionFields`, alongside the restorable set it has
  to stay in step with (#691).
  """
  @spec diffable_fields(module()) :: [atom()]
  defdelegate diffable_fields(resource), to: VersionFields

  # ── Fields ────────────────────────────────────────────────────────────────

  defp diff_fields(old, new, resource) do
    # Resolved once per diff, not once per row: `restorable_fields/1` walks the
    # resource, and a long comparison renders dozens of rows.
    restorable = VersionFields.restorable_fields(resource)

    resource
    |> diffable_fields()
    |> Enum.flat_map(fn name ->
      key = to_string(name)
      old_value = Map.get(old, key)
      new_value = Map.get(new, key)

      cond do
        old_value == new_value ->
          []

        # A key the fold never wrote reads back as `nil`, while `current/1`
        # always emits the attribute's default — so `nil` vs `%{}` vs `""` is a
        # representation change, not an edit. Reporting it renders a "Changed"
        # row whose entire body is an em dash.
        blank?(old_value) and blank?(new_value) ->
          []

        name in @map_fields ->
          [map_field(name, old_value, new_value, name in restorable)]

        true ->
          [scalar_field(name, old_value, new_value, name in restorable)]
      end
    end)
  end

  defp scalar_field(name, old_value, new_value, restorable?) do
    %Field{
      name: name,
      status: status(old_value, new_value),
      old: old_value,
      new: new_value,
      restorable?: restorable?,
      inline: maybe_inline(old_value, new_value)
    }
  end

  # A map field diffs to one entry per key that differs, so "added a `subtitle`"
  # doesn't render as two walls of JSON.
  defp map_field(name, old_value, new_value, restorable?) do
    old_map = if is_map(old_value), do: old_value, else: %{}
    new_map = if is_map(new_value), do: new_value, else: %{}

    entries =
      old_map
      |> Map.keys()
      |> Enum.concat(Map.keys(new_map))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn key ->
        old_entry = Map.get(old_map, key)
        new_entry = Map.get(new_map, key)

        if old_entry == new_entry do
          []
        else
          [
            %{
              key: to_string(key),
              status: entry_status(Map.has_key?(old_map, key), Map.has_key?(new_map, key)),
              old: old_entry,
              new: new_entry
            }
          ]
        end
      end)

    %Field{
      name: name,
      status: status(old_value, new_value),
      old: old_value,
      new: new_value,
      restorable?: restorable?,
      entries: entries
    }
  end

  defp entry_status(false, true), do: :added
  defp entry_status(true, false), do: :removed
  defp entry_status(_present_before, _present_after), do: :changed

  # `nil` and `""` both read as "there was nothing here" — an editor filling in an
  # empty SEO description added it, they didn't change it from blank.
  defp status(old_value, new_value) do
    case {blank?(old_value), blank?(new_value)} do
      {true, false} -> :added
      {false, true} -> :removed
      _both -> :changed
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(_value), do: false

  # Word-level runs only pay for themselves on prose. A slug or a timestamp is
  # better read as two whole values side by side.
  defp maybe_inline(old_value, new_value)
       when is_binary(old_value) and is_binary(new_value) do
    if String.length(old_value) > 40 or String.length(new_value) > 40 do
      inline_runs(old_value, new_value)
    end
  end

  defp maybe_inline(_old_value, _new_value), do: nil

  defp tokenize(nil), do: []

  defp tokenize(text) when is_binary(text),
    do: String.split(text, ~r/(\s+)/u, include_captures: true, trim: true)

  defp tokenize(_other), do: []

  # ── Blocks ────────────────────────────────────────────────────────────────

  defp diff_blocks(old_blocks, new_blocks) do
    old_list = List.wrap(old_blocks)
    new_list = List.wrap(new_blocks)

    old_keyed = key_blocks(old_list)
    new_keyed = key_blocks(new_list)

    old_by_key = Map.new(old_keyed, fn {key, block, index} -> {key, {block, index}} end)
    new_by_key = Map.new(new_keyed, fn {key, block, index} -> {key, {block, index}} end)

    script =
      List.myers_difference(Enum.map(old_keyed, &elem(&1, 0)), Enum.map(new_keyed, &elem(&1, 0)))

    # A key that Myers reports as both a delete and an insert didn't leave the
    # document — it changed position. It's rendered once, at its new index.
    moved = moved_keys(script)

    # The inline budget is threaded through rather than applied per block: each
    # run of word-level diffing spends from one document-wide pool, so a long
    # article gets runs for the blocks near the top and plain field values after
    # the pool is dry, instead of pinning the caller's process for seconds.
    script
    |> Enum.flat_map(fn {op, keys} -> Enum.map(keys, &{op, &1}) end)
    |> Enum.map_reduce(@document_token_budget, fn
      {:del, key}, budget ->
        if MapSet.member?(moved, key),
          do: {nil, budget},
          else: removed_block(key, old_by_key, budget)

      {:ins, key}, budget ->
        present_block(key, old_by_key, new_by_key, MapSet.member?(moved, key), budget)

      {:eq, key}, budget ->
        present_block(key, old_by_key, new_by_key, false, budget)
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp moved_keys(script) do
    deleted = script |> Keyword.get_values(:del) |> List.flatten() |> MapSet.new()
    inserted = script |> Keyword.get_values(:ins) |> List.flatten() |> MapSet.new()
    MapSet.intersection(deleted, inserted)
  end

  # Myers needs distinct keys to reason about position; blocks predating stable
  # ids (and any duplicated content) fall back to a content hash, disambiguated by
  # how many times that hash has already been seen in the same list.
  defp key_blocks(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map_reduce(%{}, fn {block, index}, seen ->
      base = block_key(block)
      count = Map.get(seen, base, 0)
      key = if count == 0, do: base, else: "#{base}##{count}"
      {{key, block, index}, Map.put(seen, base, count + 1)}
    end)
    |> elem(0)
  end

  defp block_key(block) do
    case block do
      %{"value" => %{"id" => id}} when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      other -> "hash:" <> Integer.to_string(:erlang.phash2(other))
    end
  end

  defp removed_block(key, old_by_key, budget) do
    {block, index} = Map.fetch!(old_by_key, key)
    {inline, budget} = block_inline(block, nil, budget)

    {%Block{
       key: key,
       status: :removed,
       type: block_type(block),
       old_index: index,
       inline: inline,
       fields: block_fields(block, nil, inline)
     }, budget}
  end

  defp present_block(key, old_by_key, new_by_key, moved?, budget) do
    {new_block, new_index} = Map.fetch!(new_by_key, key)

    case Map.fetch(old_by_key, key) do
      :error ->
        # An added block reports its own contents against nothing. "Quote added"
        # on its own tells the editor a block appeared but not what it says.
        {inline, budget} = block_inline(nil, new_block, budget)

        {%Block{
           key: key,
           status: :added,
           type: block_type(new_block),
           new_index: new_index,
           inline: inline,
           fields: block_fields(nil, new_block, inline)
         }, budget}

      {:ok, {old_block, old_index}} ->
        changed? = block_value(old_block) != block_value(new_block)

        {inline, budget} =
          if changed?, do: block_inline(old_block, new_block, budget), else: {nil, budget}

        {%Block{
           key: key,
           status: if(changed?, do: :changed, else: :unchanged),
           type: block_type(new_block),
           old_index: old_index,
           new_index: new_index,
           moved?: moved?,
           inline: inline,
           fields: if(changed?, do: block_fields(old_block, new_block, inline), else: [])
         }, budget}
    end
  end

  defp block_type(%{"type" => type}) when is_binary(type), do: type
  defp block_type(%{"value" => %{"_type" => type}}) when is_binary(type), do: type
  defp block_type(%{"_type" => type}) when is_binary(type), do: type
  defp block_type(_block), do: nil

  defp block_value(%{"value" => value}) when is_map(value), do: value
  defp block_value(block) when is_map(block), do: block
  defp block_value(_block), do: %{}

  # `id`/`_type` never differ between the two sides of a matched block (they're
  # what matched it), and `_version` is the block schema's, not the author's.
  @block_meta_fields ~w(id _type _version)

  # `inline` decides whether the prose fields are redundant here: when the block
  # got word-level runs they'd print a Portable Text AST underneath its own
  # rendered diff, and when it didn't — too long, or the change was in a mark
  # rather than the text — they're the only record of what moved.
  defp block_fields(old_block, new_block, inline) do
    old_value = block_value(old_block)
    new_value = block_value(new_block)
    skip = if inline, do: @block_meta_fields ++ @prose_fields, else: @block_meta_fields

    old_value
    |> Map.keys()
    |> Enum.concat(Map.keys(new_value))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in skip))
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      old_field = Map.get(old_value, name)
      new_field = Map.get(new_value, name)

      if old_field == new_field do
        []
      else
        [%{name: to_string(name), old: old_field, new: new_field}]
      end
    end)
  end

  # Prose is the whole point of a block-level diff, so a changed block gets
  # word-level runs over its flattened text.
  #
  # Flattening goes through `KilnCMS.CMS.BlockText`, the same projection firing,
  # search and word count use: it dispatches to each block's own `search_text/1`,
  # so a quote's citation, a FAQ's question/answer pairs, a nested column tree
  # and a plugin block's prose all flatten correctly. Naming the prose fields
  # here instead would silently return "" for every block type not on the list.
  defp block_inline(old_block, new_block, budget) do
    old_text = block_text(old_block)
    new_text = block_text(new_block)

    cond do
      old_text == "" and new_text == "" -> {nil, budget}
      budget <= 0 -> {nil, budget}
      true -> spend(old_text, new_text, budget)
    end
  end

  defp spend(old_text, new_text, budget) do
    old_tokens = tokenize(old_text)
    new_tokens = tokenize(new_text)
    cost = length(old_tokens) + length(new_tokens)

    if length(old_tokens) > @inline_token_limit or length(new_tokens) > @inline_token_limit do
      {nil, budget - cost}
    else
      {runs(old_tokens, new_tokens), budget - cost}
    end
  end

  defp block_text(nil), do: ""

  defp block_text(block) do
    BlockText.to_text([block_value(block)])
  rescue
    # `to_text/1` casts through the typed-block registry; a stored block from a
    # plugin that is no longer installed must degrade to "no inline diff", not
    # take the whole comparison down.
    _error -> fallback_text(block_value(block))
  end

  # Legacy/unregistered blocks the typed registry can't project: read the prose
  # off the raw stored map instead.
  defp fallback_text(value) do
    [
      portable_text(Map.get(value, "body")),
      strip_html(Map.get(value, "legacy_html")),
      strip_html(Map.get(value, "content")),
      string_or_empty(Map.get(value, "text"))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp portable_text(body) when is_list(body), do: PortableText.to_plain_text(body)
  defp portable_text(_body), do: ""

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp strip_html(_html), do: ""

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_value), do: ""
end
