defmodule KilnCMS.Backups.Schedule.Changes.Rebaseline do
  @moduledoc """
  Moves `baseline_at` to now (node clock) when an update changes a schedule's
  timing: its interval, time of day, start date, time zone or components, or
  resumes it (`enabled` false to true). No window from before the change
  fires, so a schedule moved from 03:00 to 02:00 at 02:30 does not fire
  02:00 at once, and resuming a schedule paused for a week does not fire a
  window it missed while paused.

  Compared **by value** with the stored row, after `Changes.Normalize`, so a
  form that resubmits unchanged fields does not rebaseline. Not
  `changing_attributes([...])`, which requires every listed attribute to
  change. Pausing does not rebaseline.
  """
  use Ash.Resource.Change

  @timing [:interval, :time_of_day, :starts_on, :time_zone, :components]

  @impl true
  def change(changeset, _opts, _context) do
    if retimed?(changeset) or resumed?(changeset),
      do: Ash.Changeset.force_change_attribute(changeset, :baseline_at, DateTime.utc_now()),
      else: changeset
  end

  @doc false
  # Whether `changeset` changes one of the timing fields by value.
  @spec retimed?(Ash.Changeset.t()) :: boolean()
  def retimed?(changeset) do
    Enum.any?(@timing, fn field ->
      not same?(Ash.Changeset.get_attribute(changeset, field), Map.get(changeset.data, field))
    end)
  end

  defp resumed?(changeset) do
    Ash.Changeset.get_attribute(changeset, :enabled) == true and changeset.data.enabled == false
  end

  @doc false
  # Equal by value: a loaded time may carry a precision the input lacks.
  @spec same?(term(), term()) :: boolean()
  def same?(%Time{} = a, %Time{} = b), do: Time.compare(a, b) == :eq
  def same?(%Date{} = a, %Date{} = b), do: Date.compare(a, b) == :eq
  def same?(a, b), do: a == b
end
