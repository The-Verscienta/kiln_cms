defmodule KilnCMS.Backups.Schedule.Validations.KeepCoversInterval do
  @moduledoc """
  A schedule that keeps its backups for a number of days and sets no number
  of backups to keep must keep them at least one interval long (#2219): a
  weekly schedule keeping 3 days would keep nothing of its own but the newest
  backup, which retention keeps anyway. Days per interval: 1 for daily and
  shorter, 7 weekly, 14 fortnightly, 31 monthly. Any `keep_days` covers a
  sub-daily interval; whether a sub-daily schedule must set one at all is
  `Validations.SubDailyKeepsDays`'s rule.

  Checked when the interval or either keep field is set or changed, so a
  schedule saved before this rule (or by a newer release, with an interval
  this one doesn't know) can still be paused or deleted.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  @days %{
    every_2h: 1,
    every_4h: 1,
    every_8h: 1,
    every_12h: 1,
    daily: 1,
    weekly: 7,
    fortnightly: 14,
    monthly: 31
  }

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    keep_days = Ash.Changeset.get_attribute(changeset, :keep_days)
    keep_count = Ash.Changeset.get_attribute(changeset, :keep_count)
    interval = Ash.Changeset.get_attribute(changeset, :interval)

    if changed?(changeset) and is_integer(keep_days) and is_nil(keep_count) and
         keep_days < Map.get(@days, interval, 0),
       do: {:error, field: :keep_days, message: message()},
       else: :ok
  end

  @doc "The days one `interval` spans, for this rule; `nil` for one it doesn't know."
  @spec interval_days(term()) :: pos_integer() | nil
  def interval_days(interval), do: Map.get(@days, interval)

  defp changed?(changeset),
    do:
      Enum.any?(
        [:interval, :keep_days, :keep_count],
        &Ash.Changeset.changing_attribute?(changeset, &1)
      )

  # Translated where the form shows it (`translate_error/1`).
  defp message,
    do:
      dgettext_noop(
        "errors",
        "must be at least as long as the schedule's interval, unless a number of backups to keep is set"
      )
end
