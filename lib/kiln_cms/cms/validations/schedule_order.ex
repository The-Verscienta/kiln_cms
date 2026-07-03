defmodule KilnCMS.CMS.Validations.ScheduleOrder do
  @moduledoc """
  When both schedule fields are set, the embargo end must come after the
  scheduled publish (`unpublish_at > scheduled_at`) — otherwise the minute
  cron would publish the record and immediately take it back down.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    scheduled = Ash.Changeset.get_attribute(changeset, :scheduled_at)
    unpublish = Ash.Changeset.get_attribute(changeset, :unpublish_at)

    if is_nil(scheduled) or is_nil(unpublish) or DateTime.after?(unpublish, scheduled) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :unpublish_at,
         message: "must be after the scheduled publish time"
       )}
    end
  end
end
