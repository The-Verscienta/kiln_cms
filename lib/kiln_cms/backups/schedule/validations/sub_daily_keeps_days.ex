defmodule KilnCMS.Backups.Schedule.Validations.SubDailyKeepsDays do
  @moduledoc """
  A schedule that runs more often than daily (every 2, 4, 8 or 12 hours) must
  set its own `keep_days` (#2219). Every run is a full set, and a schedule's
  keep N is a minimum, not a cap: kept for `BACKUP_KEEP_DAYS` alone, a
  two-hourly schedule would keep twelve sets of each component per day of it.

  Refused, on `:keep_days`, when the resulting interval is sub-daily, the
  resulting `keep_days` is not set, and either:

    * the action is a create, or
    * the update changes, **by value** against the stored row
      (`Changes.Rebaseline.same?/2`), any editable field other than
      `enabled`. A form resubmits every field, so `changing_attribute?/2`
      would see an unchanged field as changed.

  So switching a schedule to a sub-daily interval without `keep_days`,
  clearing `keep_days` on a sub-daily one, and any edit of a sub-daily row
  that has none are refused until it is set. Pausing, resuming, an unchanged
  resubmit and a destroy always pass: a sub-daily row without `keep_days`
  (written from a console, or by a release that allowed it) can still be
  paused, resumed or deleted, and keeps firing meanwhile, its backups kept
  for `BACKUP_KEEP_DAYS` like any schedule's without its own days.

  An interval this release doesn't know (`KilnCMS.Types.UnknownAtom`) is not
  sub-daily here.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Backups.Schedule
  alias KilnCMS.Backups.Schedule.Changes.Rebaseline

  # The fields an edit form submits, but `enabled`: pausing and resuming
  # never need `keep_days`.
  @checked [:components, :interval, :time_of_day, :starts_on, :time_zone, :keep_count, :keep_days]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :interval) in Schedule.sub_daily_intervals() and
         is_nil(Ash.Changeset.get_attribute(changeset, :keep_days)) and edits?(changeset),
       do: {:error, field: :keep_days, message: message()},
       else: :ok
  end

  defp edits?(%Ash.Changeset{action_type: :create}), do: true

  defp edits?(changeset) do
    Enum.any?(@checked, fn field ->
      not Rebaseline.same?(
        Ash.Changeset.get_attribute(changeset, field),
        Map.get(changeset.data, field)
      )
    end)
  end

  # Translated where the form shows it (`translate_error/1`).
  defp message,
    do: dgettext_noop("errors", "is required for a schedule that runs more often than daily")
end
