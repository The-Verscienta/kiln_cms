defmodule KilnCMS.CMS.SavedView.CleanParams do
  @moduledoc """
  Reduces a saved view's `params` to the keys and shapes
  `KilnCMS.CMS.SavedView.clean_params/1` allows, on every write that sets them.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :params) do
      params = Ash.Changeset.get_attribute(changeset, :params)

      Ash.Changeset.force_change_attribute(
        changeset,
        :params,
        KilnCMS.CMS.SavedView.clean_params(params)
      )
    else
      changeset
    end
  end
end
