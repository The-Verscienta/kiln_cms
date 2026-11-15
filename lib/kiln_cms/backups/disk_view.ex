defmodule KilnCMS.Backups.DiskView do
  @moduledoc """
  Everything the Backups page reads from this host's backup directory for one
  page of history, in one pass (#2416, #2417, #2799): the retention markers,
  each run's presence, which runs can be resumed, and cron's retention window.

  It exists so the page can do that reading **off the LiveView process**
  (`KilnCMSWeb.BackupLive` runs it in `start_async/3`, one at a time, with a
  timeout). The directory may be a network mount, and one that hangs would
  otherwise freeze the page, its buttons and its poll with it.

  `db/` and `media/` are listed once each (`KilnCMS.Backups.Presence.context/2`)
  and `manifest.json` is read once. A file is `lstat`ed only when its name is
  listed, and a run's `.work/<stamp>/state.json` only for a run whose status
  could be resumed. No database reads: the caller passes the runs it read as
  its actor. Never raises; every filesystem failure is reported as data (an
  unreadable directory, an `:unknown` presence).
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Manifest, Markers, Presence, Run}

  @type t :: %{
          markers: Markers.t(),
          presence: %{optional(Ecto.UUID.t()) => Presence.t()},
          resumable: MapSet.t(Ecto.UUID.t()),
          cron_keep_days: pos_integer() | nil
        }

  @doc """
  Read `dir` for `runs` (`KilnCMS.Backups.Run` structs), at `now`.

  `cron_keep_days` is the `keep_days` of the directory's `manifest.json` when
  `scripts/backup.sh` wrote it (a manifest without `"components"`, which Kiln
  always writes), else `nil`: the app doesn't know cron's window then.
  """
  @spec read(Path.t(), [Run.t()], DateTime.t()) :: t()
  def read(dir, runs, now \\ DateTime.utc_now()) when is_binary(dir) and is_list(runs) do
    cron_keep_days = cron_keep_days(Manifest.read(dir))
    context = Presence.context(dir, now: now, cron_keep_days: cron_keep_days)

    %{
      markers: context.markers,
      presence: Map.new(runs, &{&1.id, Presence.for(&1, context)}),
      resumable: for(run <- runs, resumable?(run, now), into: MapSet.new(), do: run.id),
      cron_keep_days: cron_keep_days
    }
  end

  # A cheap status check first, so the one `stat` per row is only paid by the
  # (few) failed or running rows of the page.
  defp resumable?(run, now),
    do: Backups.run_resumable?(run, now) and Backups.work_state?(run.stamp)

  defp cron_keep_days(%Manifest{components: nil, keep_days: days}) when is_integer(days),
    do: days

  defp cron_keep_days(_kiln_or_none), do: nil
end
