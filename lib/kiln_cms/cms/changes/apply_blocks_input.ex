defmodule KilnCMS.CMS.Changes.ApplyBlocksInput do
  @moduledoc """
  Headless block-body writes (#330).

  The typed `blocks` union attribute is not `public?` — the auto JSON:API /
  GraphQL surface can't render a union of embedded resources cleanly on read, so
  it isn't exposed there (delivery reads the fired artifacts, not the raw tree).
  To still let a write-capable API set body content, `:create` / `:update`
  accept a public `:block_tree` argument: an array of plain block maps (the same
  shape the editor and MCP submit). When present it is cast into the `blocks`
  union — the cast sanitizes rich-text HTML and media URLs (see `BlockUnion`).
  Before that, every Portable Text value in it is checked (#2768): a shape a
  reader would have to repair is refused with its path on `:block_tree`
  (see the section comment below).

  Or `:body_markdown`: the body as Markdown, converted by `KilnCMS.Markdown`
  (the converter the editor's paste and `.md` import use) into the same block
  maps, then cast the same way. Front matter is dropped and nothing else is
  read from it — title and slug are their own attributes. Sending both
  arguments is an error rather than a precedence rule a caller has to know.

  Omitted argument = no change, so a metadata-only PATCH never wipes the body.
  An explicit empty list (or empty Markdown) clears the body (an intentional
  "remove all blocks").

  `target:` names the attribute the body lands in — `:blocks` (the default) or
  `:working_blocks`, for `:save_working_copy`'s MCP tools, which stage a live
  record's body in its working copy (docs/working-copy.md).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    target = Keyword.get(opts, :target, :blocks)

    case {argument(changeset, :block_tree), argument(changeset, :body_markdown)} do
      {blocks, markdown} when is_list(blocks) and is_binary(markdown) ->
        Ash.Changeset.add_error(changeset,
          field: :body_markdown,
          message: "send either block_tree or body_markdown, not both"
        )

      {_blocks, markdown} when is_binary(markdown) ->
        if byte_size(markdown) > KilnCMS.Markdown.max_bytes() do
          Ash.Changeset.add_error(changeset,
            field: :body_markdown,
            message: "is longer than %{max} bytes",
            vars: [max: KilnCMS.Markdown.max_bytes()]
          )
        else
          Ash.Changeset.change_attribute(changeset, target, KilnCMS.Markdown.to_blocks(markdown))
        end

      {blocks, _markdown} when is_list(blocks) ->
        case check_portable_text(blocks) do
          # `change_attribute` casts through the `blocks` union type, which
          # sanitizes untrusted rich-text/media inside each member's cast.
          {:ok, blocks} ->
            Ash.Changeset.change_attribute(changeset, target, blocks)

          {:error, errors} ->
            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :block_tree,
                message: portable_text_message(errors)
              )
            )
        end

      _ ->
        changeset
    end
  end

  # ── Portable Text write check (#2768) ──────────────────────────────────────
  #
  # Every Portable Text value in the tree — a `rich_text` block's `body`, any
  # block's `:rich_text` field, nested in `columns` too — is checked
  # (`Shape.check_body/2`): a shape every reader would have to repair by
  # dropping or rewriting it is refused with its path; what the repair only
  # coerces is coerced, and the coerced tree is what is cast. See ADR 0083
  # (docs/decisions/).
  #
  # Here, on the raw argument, and not in the `blocks` cast: the cast is also
  # how every internal writer (restore, promote, copy, envelope import) writes
  # back what is already stored, and those repair a stored body rather than
  # fail on it. Only this argument is a client's own fresh input.
  #
  # Only a list-shaped body is checked. A TipTap document (the editor's shape,
  # also accepted here) is converted by `PortableText.from_tiptap/1` in the
  # cast, and what that produces is repaired, not checked, so a path never
  # points into a body the client did not send.

  @max_reported 5

  defp check_portable_text(blocks) do
    {blocks, errors} = check_blocks(blocks, "block_tree")

    case errors do
      [] -> {:ok, blocks}
      errors -> {:error, errors}
    end
  end

  defp check_blocks(blocks, path) do
    {blocks, errors} =
      blocks
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {block, index}, errors ->
        {block, new} = check_block(block, "#{path}[#{index}]")
        {block, [new | errors]}
      end)

    {blocks, errors |> Enum.reverse() |> List.flatten()}
  end

  # A stored `type`/`value` envelope is accepted input too (what a version
  # holds); its attributes sit one level down. A `"_type": null` beside one
  # does not make it a typed block: the cast reads it as the envelope.
  defp check_block(%{} = block, path) do
    case {field(block, "_type"), field(block, "type"), field(block, "value")} do
      {{_key, type}, _envelope_type, _value}
      when not is_nil(type) and (is_binary(type) or is_atom(type)) ->
        check_typed(block, to_string(type), path)

      {untyped, {_key, type}, {value_key, %{} = value}}
      when untyped in [nil, {"_type", nil}, {:_type, nil}] and not is_nil(type) and
             (is_binary(type) or is_atom(type)) ->
        {value, errors} = check_typed(value, to_string(type), "#{path}.#{value_key}")
        {Map.put(block, value_key, value), errors}

      _other ->
        {block, []}
    end
  end

  defp check_block(block, _path), do: {block, []}

  defp check_typed(block, "columns", path) do
    case field(block, "columns") do
      {key, columns} when is_list(columns) ->
        {columns, errors} =
          columns
          |> Enum.with_index()
          |> Enum.map_reduce([], fn {column, index}, errors ->
            {column, new} = check_column(column, "#{path}.#{key}[#{index}]")
            {column, [new | errors]}
          end)

        {Map.put(block, key, columns), errors |> Enum.reverse() |> List.flatten()}

      _absent_or_other ->
        {block, []}
    end
  end

  defp check_typed(block, type, path) do
    type
    |> KilnCMS.CMS.TypedBlocks.rich_text_fields()
    |> Enum.reduce({block, []}, fn name, {block, errors} ->
      case field(block, name) do
        {key, value} ->
          {value, new} = check_rich_text(value, type, "#{path}.#{key}")
          {Map.put(block, key, value), errors ++ new}

        nil ->
          {block, errors}
      end
    end)
  end

  defp check_column(%{} = column, path) do
    case field(column, "blocks") do
      {key, blocks} when is_list(blocks) ->
        {blocks, errors} = check_blocks(blocks, "#{path}.#{key}")
        {Map.put(column, key, blocks), errors}

      _absent_or_other ->
        {column, []}
    end
  end

  defp check_column(column, _path), do: {column, []}

  # A core `rich_text` body may arrive as a JSON string of either shape (the
  # editor posts one); it is decoded so a list inside is checked too.
  defp check_rich_text(body, "rich_text", path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_list(decoded) -> check_rich_text(decoded, "rich_text", path)
      _tiptap_or_invalid -> {body, []}
    end
  end

  defp check_rich_text(body, _type, path) when is_list(body) do
    case KilnCMS.Blocks.PortableText.Shape.check_body(body, path) do
      {:ok, body} -> {body, []}
      {:error, errors} -> {body, errors}
    end
  end

  defp check_rich_text(other, _type, _path), do: {other, []}

  # Input maps are string-keyed off the wire, atom-keyed from Elixir callers.
  defp field(map, name) do
    atom = String.to_existing_atom(name)

    cond do
      Map.has_key?(map, name) -> {name, Map.fetch!(map, name)}
      Map.has_key?(map, atom) -> {atom, Map.fetch!(map, atom)}
      true -> nil
    end
  end

  defp portable_text_message(errors) do
    {shown, rest} = Enum.split(errors, @max_reported)

    more =
      case length(rest) do
        0 -> ""
        n -> "; and #{n} more"
      end

    "is not valid Portable Text: " <> Enum.join(shown, "; ") <> more
  end

  defp argument(changeset, name) do
    case Ash.Changeset.fetch_argument(changeset, name) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
