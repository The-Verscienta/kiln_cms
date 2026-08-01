defmodule KilnCMS.CMS.Changes.NormalizeTagArguments do
  @moduledoc """
  De-duplicates the tag id lists before `manage_relationship` sees them (#521).

  A repeated id makes `manage_relationship` try to insert the same `Tagging`
  join row twice, and the unique index rejects the second one — surfacing to
  the caller as `"Invalid value provided for subject_id: has already been
  taken"`, naming an internal join column the caller never sent. "Tag it as
  Elixir and Elixir" is exactly what an LLM emits, and #521 is about LLM
  callers, so the repeat is de-duplicated rather than reported.

  This is a normalization, not a validation: sending an id twice expresses one
  unambiguous intent, unlike sending it in both `add_tag_ids` and
  `remove_tag_ids` (which `KilnCMS.CMS.Validations.TagMergeArguments` refuses).

  Declared ahead of every `manage_relationship` on `:tags` so all three
  arguments are normalized on the way in. `nil` is left alone — on `tag_ids`
  it means "clear", which is not the same as `[]` being empty of duplicates.
  """
  use Ash.Resource.Change

  @arguments [:tag_ids, :add_tag_ids, :remove_tag_ids]

  @impl true
  def change(changeset, _opts, _context), do: Enum.reduce(@arguments, changeset, &dedupe(&2, &1))

  defp dedupe(changeset, argument) do
    case Ash.Changeset.fetch_argument(changeset, argument) do
      {:ok, ids} when is_list(ids) ->
        Ash.Changeset.set_argument(changeset, argument, Enum.uniq(ids))

      _ ->
        changeset
    end
  end
end
