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

  Omitted argument = no change, so a metadata-only PATCH never wipes the body.
  An explicit empty list clears the body (an intentional "remove all blocks").
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :block_tree) do
      {:ok, blocks} when is_list(blocks) ->
        # `change_attribute` casts through the `blocks` union type, which
        # sanitizes untrusted rich-text/media inside each member's cast.
        Ash.Changeset.change_attribute(changeset, :blocks, blocks)

      _ ->
        changeset
    end
  end
end
