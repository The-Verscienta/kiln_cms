defmodule KilnCMS.CMS.Changes.DefaultPathSegment do
  @moduledoc """
  Defaults a `TypeDefinition.path_segment` to the naive plural of its `name`
  (`"recipe"` → `"recipes"`) when the admin leaves it blank. Irregular nouns
  just set the segment explicitly — same stance as the Content macro's
  `:plural` option.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :path_segment) do
      blank when blank in [nil, ""] ->
        case Ash.Changeset.get_attribute(changeset, :name) do
          nil -> changeset
          name -> Ash.Changeset.force_change_attribute(changeset, :path_segment, name <> "s")
        end

      _present ->
        changeset
    end
  end
end
