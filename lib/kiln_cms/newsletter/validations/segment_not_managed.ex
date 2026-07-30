defmodule KilnCMS.Newsletter.Validations.SegmentNotManaged do
  @moduledoc """
  Refuses hand edits to a tier-backed segment (#337 Phase 2).

  A `managed_by: :tier` segment's membership tracks active paid memberships, and
  its `audience` is derived from its tier — which
  the send guard in `KilnCMS.Newsletter` matches against a document's audience to
  decide whether gated content may be sent. Letting an admin edit either by hand
  would turn the send guard into something they could aim wherever they liked.

  Lives on the **resource**, not in the LiveView, so AshAdmin and every future
  caller are covered too.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case changeset.data do
      %{managed_by: :tier} ->
        {:error,
         field: :managed_by,
         message: "this segment is maintained by its membership tier and can't be edited by hand"}

      _other ->
        :ok
    end
  end
end
