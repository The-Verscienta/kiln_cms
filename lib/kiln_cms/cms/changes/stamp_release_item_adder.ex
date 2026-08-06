defmodule KilnCMS.CMS.Changes.StampReleaseItemAdder do
  @moduledoc """
  Records the user who added a record to a release (#500) from the acting
  actor, never from input.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    case context.actor do
      %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :added_by_id, id)
      _ -> changeset
    end
  end
end
