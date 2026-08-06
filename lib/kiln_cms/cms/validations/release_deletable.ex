defmodule KilnCMS.CMS.Validations.ReleaseDeletable do
  @moduledoc """
  Refuses to delete a release that shipped, or one mid-flight (#500).

  A release's items cascade-delete with it, and for a release that went live
  those items are the *only* record of what each piece of content looked like
  before — the prior version and workflow state group rollback restores from.
  Deleting them would quietly destroy the undo. Archiving a shipped release is
  the supported way to get it out of the list.

  Mid-flight (`:publishing` / `:rolling_back`) is refused for the obvious
  reason: a worker is walking those rows right now.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges

  @in_flight [:publishing, :rolling_back]

  @impl true
  def validate(changeset, _opts, _context) do
    release = changeset.data

    cond do
      release.state in @in_flight ->
        {:error,
         InvalidChanges.exception(
           fields: [:state],
           message: "cannot be deleted while it is publishing; wait for it to finish"
         )}

      not is_nil(release.published_at) ->
        {:error,
         InvalidChanges.exception(
           fields: [:state],
           message: "cannot be deleted after it has been published; archive it instead"
         )}

      true ->
        :ok
    end
  end
end
