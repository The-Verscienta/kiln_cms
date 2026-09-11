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

  Or `:body_markdown`: the body as Markdown, converted by `KilnCMS.Markdown`
  (the converter the editor's paste and `.md` import use) into the same block
  maps, then cast the same way. Front matter is dropped and nothing else is
  read from it — title and slug are their own attributes. Sending both
  arguments is an error rather than a precedence rule a caller has to know.

  Omitted argument = no change, so a metadata-only PATCH never wipes the body.
  An explicit empty list (or empty Markdown) clears the body (an intentional
  "remove all blocks").
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
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
          Ash.Changeset.change_attribute(changeset, :blocks, KilnCMS.Markdown.to_blocks(markdown))
        end

      {blocks, _markdown} when is_list(blocks) ->
        # `change_attribute` casts through the `blocks` union type, which
        # sanitizes untrusted rich-text/media inside each member's cast.
        Ash.Changeset.change_attribute(changeset, :blocks, blocks)

      _ ->
        changeset
    end
  end

  defp argument(changeset, name) do
    case Ash.Changeset.fetch_argument(changeset, name) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
