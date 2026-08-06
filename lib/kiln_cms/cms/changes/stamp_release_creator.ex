defmodule KilnCMS.CMS.Changes.StampReleaseCreator do
  @moduledoc """
  Records the user who started a release (#500) from the acting actor, never
  from input. A tenant-less/system create simply leaves it blank.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    case context.actor do
      %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :creator_id, id)
      _ -> changeset
    end
  end
end
