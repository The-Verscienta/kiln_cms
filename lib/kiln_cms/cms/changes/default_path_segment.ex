defmodule KilnCMS.CMS.Changes.DefaultPathSegment do
  @moduledoc """
  Defaults a `TypeDefinition.path_segment` to the naive plural of its `name`
  (`"recipe"` → `"recipes"`) when the admin leaves it blank. Irregular nouns
  just set the segment explicitly — same stance as the Content macro's
  `:plural` option.
  """
  use Ash.Resource.Change

  @doc """
  The URL segment a machine name suggests: its naive plural, or `""` for a
  blank name. The content-types screen shows it while the admin types, so the
  segment it previews is the one a blank segment is saved as.

      iex> KilnCMS.CMS.Changes.DefaultPathSegment.for_name("recipe")
      "recipes"

      iex> KilnCMS.CMS.Changes.DefaultPathSegment.for_name("")
      ""
  """
  @spec for_name(String.t() | nil) :: String.t()
  def for_name(name) when is_binary(name) and name != "", do: name <> "s"
  def for_name(_name), do: ""

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :path_segment) do
      blank when blank in [nil, ""] ->
        case Ash.Changeset.get_attribute(changeset, :name) do
          nil ->
            changeset

          name ->
            Ash.Changeset.force_change_attribute(changeset, :path_segment, for_name(name))
        end

      _present ->
        changeset
    end
  end
end
