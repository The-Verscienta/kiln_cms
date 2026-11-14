defmodule KilnCMS.Backups.Schedule.Validations.IntervalAvailable do
  @moduledoc """
  Refuses a sub-daily interval (every 2, 4, 8 or 12 hours) when a schedule is
  created or its interval changed, until keep N retention exists (#2219,
  part 3). Every run is a full set and retention is age-only
  (`BACKUP_KEEP_DAYS`), so a two-hourly schedule would keep twelve sets of
  each component per day of retention. Checked only when the interval is set
  or changed, so a schedule a later release saved with one can still be
  paused or deleted.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Backups.Schedule

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    interval = Ash.Changeset.get_attribute(changeset, :interval)

    if Ash.Changeset.changing_attribute?(changeset, :interval) and
         interval in Schedule.sub_daily_intervals(),
       do: {:error, field: :interval, message: message()},
       else: :ok
  end

  # Translated where the form shows it (`translate_error/1`).
  defp message,
    do:
      dgettext_noop(
        "errors",
        "sub-daily schedules arrive with keep-N retention; choose daily or longer"
      )
end
