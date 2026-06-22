defmodule KilnCMS.CMS.Changes.SetSearchText do
  @moduledoc """
  Maintains the denormalized `search_text` attribute used for full-text search.

  Combines the resource's textual fields (whichever of `title`, `seo_title`,
  `seo_description`, `excerpt` exist) with the plain text of the embedded block
  tree. Runs before the action so it sees the effective (merged) values on both
  create and update.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.BlockText

  @text_fields [:title, :seo_title, :seo_description, :excerpt]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &set_search_text/1)
  end

  defp set_search_text(changeset) do
    field_text =
      @text_fields
      |> Enum.filter(&Ash.Resource.Info.attribute(changeset.resource, &1))
      |> Enum.map(&Ash.Changeset.get_attribute(changeset, &1))

    blocks_text = BlockText.to_text(Ash.Changeset.get_attribute(changeset, :blocks))

    search_text =
      (field_text ++ [blocks_text])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    Ash.Changeset.force_change_attribute(changeset, :search_text, search_text)
  end
end
