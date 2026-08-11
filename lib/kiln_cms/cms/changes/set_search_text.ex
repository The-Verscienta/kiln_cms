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

  @text_fields [:title, :seo_title, :seo_description, :seo_keywords, :excerpt]

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

    Ash.Changeset.force_change_attribute(changeset, :search_text, join(field_text, blocks_text))
  end

  @doc """
  The same `search_text` computation as `change/3`, over a loaded **struct**
  and pre-derived block text rather than a changeset (#910).

  For `KilnCMS.Firing.Engine.fire/2`, whose `blocks_text` comes from the
  fragment-expanded tree (`body_text/1` there) rather than `record.blocks`
  raw — a `%Fragment{}` block's own `search_text/1` is always `""`, so
  `search_text` never carried a fragment's words until something recomputed
  it against the expanded tree. Kept in this module rather than duplicated so
  `@text_fields` has one definition either way a caller arrives.
  """
  @spec compute(struct(), String.t()) :: String.t()
  def compute(record, blocks_text) do
    field_text =
      @text_fields
      |> Enum.filter(&Ash.Resource.Info.attribute(record.__struct__, &1))
      |> Enum.map(&Map.get(record, &1))

    join(field_text, blocks_text)
  end

  defp join(field_text, blocks_text) do
    (field_text ++ [blocks_text])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end
end
