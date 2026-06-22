defmodule KilnCMS.CMS.Changes.SanitizeBlocks do
  @moduledoc """
  Sanitizes embedded block payloads before persistence so stored content is safe
  regardless of which code path renders it later.
  """
  use Ash.Resource.Change

  alias KilnCMS.HTMLSanitizer

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &sanitize/1)
  end

  defp sanitize(changeset) do
    case Ash.Changeset.get_attribute(changeset, :blocks) do
      blocks when is_list(blocks) ->
        Ash.Changeset.force_change_attribute(changeset, :blocks, sanitize_blocks(blocks))

      _ ->
        changeset
    end
  end

  defp sanitize_blocks(blocks), do: Enum.map(blocks, &sanitize_block/1)

  defp sanitize_block(%{type: type} = block) do
    block
    |> Map.update(:content, nil, &sanitize_content(type, &1))
    |> Map.update(:children, [], fn
      children when is_list(children) -> sanitize_blocks(children)
      other -> other
    end)
  end

  defp sanitize_block(block) when is_map(block), do: block

  defp sanitize_content(:rich_text, content), do: HTMLSanitizer.sanitize_rich_text(content)
  defp sanitize_content(:image, content), do: HTMLSanitizer.safe_image_src(content) || ""
  defp sanitize_content(:embed, content), do: HTMLSanitizer.safe_embed_url(content) || ""
  defp sanitize_content(_type, content), do: content
end
