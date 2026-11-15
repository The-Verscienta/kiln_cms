defmodule KilnCMS.Backups.KeepNAcceptanceTest do
  @moduledoc """
  A schedule's keep N, end to end (#2219): real `Schedule` rows, app runs
  made for them, cron-made (imported) and manual backups, a recovery point and
  a deleted schedule's backups, through `Retention.run/2` (the exact
  survivors, the `.hold` markers, the run history), then `scripts/backup.sh
  prune` over the result, which must delete nothing more. A second test runs a
  scheduled backup through the chain, whose prune step sees its own run in
  flight: N kept backups plus the new one.

  `async: false`: points the VM-wide backup config at a temp directory.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Retention}
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log

  @day 86_400
  @script Path.expand("../../../scripts/backup.sh", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_keepn_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))
    File.mkdir_p!(media)
    File.write!(Path.join(media, "f.bin"), "media")

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: media, keep_days: 14)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{dir: dir, media: media, now: System.os_time(:second)}
  end

  defp stamp(now, days),
    do: (now - days * @day) |> DateTime.from_unix!() |> Calendar.strftime("%Y%m%d-%H%M%S")

  defp put(dir, sub, name, days, now) do
    path = Path.join([dir, sub, name])
    File.write!(path, "x")
    File.touch!(path, now - days * @day)
    name
  end

  # The unit's files on disk, `days` old: a dump and its sidecar, or an archive.
  defp files!(dir, :db, st, days, now),
    do: [
      put(dir, "db", "kiln-db-#{st}.dump", days, now),
      put(dir, "db", Artifact.sidecar_name(:db, st), days, now)
    ]

  defp files!(dir, :media, st, days, now),
    do: [put(dir, "media", "kiln-media-#{st}.tar.gz", days, now)]

  # A succeeded app run of `kind`, verified, as the chain records one.
  defp app_run!(kind, st, trigger, schedule_ids) do
    scheduled = if schedule_ids == [], do: [], else: [kind]

    run =
      Backups.start_run!(
        %{
          stamp: st,
          trigger: trigger,
          components: [kind],
          scheduled_components: scheduled,
          schedule_ids: schedule_ids
        },
        actor: Backups.system()
      )

    name = if kind == :db, do: "kiln-db-#{st}.dump", else: "kiln-media-#{st}.tar.gz"
    {:ok, attrs} = Artifact.from_manifest(%{kind: to_string(kind), path: name, verified: true})
    Backups.finish_run!(run, %{artifacts: [attrs]}, actor: Backups.system())
  end

  defp listing(dir) do
    for sub <- ["db", "media"],
        name <- File.ls!(Path.join(dir, sub)),
        into: MapSet.new(),
        do: "#{sub}/#{name}"
  end

  defp holds(dir, sub) do
    for name <- Enum.sort(File.ls!(Path.join(dir, sub))),
        {:ok, st} <- [Artifact.parse_hold_name(name)],
        do: st
  end

  defp local_status(st) do
    [artifact] = Backups.get_run_by_stamp!(st, actor: Backups.system()).artifacts
    artifact.destinations["local"]["status"]
  end

  test "keep N across schedules, cron, manual, a recovery point and a deleted schedule",
       %{dir: dir, now: now} do
    admin = platform_admin()
    daily_db = schedule!(%{components: [:db], interval: :daily, keep_count: 3}, admin)

    weekly_media =
      schedule!(
        %{components: [:media], interval: :weekly, keep_count: 2, keep_days: 30},
        admin
      )

    gone = schedule!(%{components: [:db], interval: :daily, time_of_day: ~T[05:00:00]}, admin)
    :ok = Backups.destroy_backup_schedule(gone, actor: admin)

    # {name, kind, age in days, how it was made}
    units = [
      {:db1, :db, 1, {:schedule, daily_db.id}},
      {:manual3, :db, 3, :manual},
      {:gone10, :db, 10, {:schedule, gone.id}},
      {:db16, :db, 16, {:schedule, daily_db.id}},
      {:manual20, :db, 20, :manual},
      {:cron25, :db, 25, :cron},
      {:db30, :db, 30, {:schedule, daily_db.id}},
      {:db45, :db, 45, {:schedule, daily_db.id}},
      {:pinned50, :db, 50, {:schedule, daily_db.id}},
      {:m2, :media, 2, {:schedule, weekly_media.id}},
      {:m8, :media, 8, {:schedule, weekly_media.id}},
      {:m15, :media, 15, {:schedule, weekly_media.id}},
      {:manual18, :media, 18, :manual},
      {:cron21, :media, 21, :cron},
      {:m40, :media, 40, {:schedule, weekly_media.id}}
    ]

    made =
      Map.new(units, fn {key, kind, days, how} ->
        st = stamp(now, days)
        names = files!(dir, kind, st, days, now)

        case how do
          {:schedule, id} -> app_run!(kind, st, "schedule", [id])
          :manual -> app_run!(kind, st, "manual", [])
          # No row: the importer records it, as it would a backup.sh backup.
          :cron -> :ok
        end

        {key, %{stamp: st, kind: kind, names: names}}
      end)

    put(dir, "db", Artifact.keep_name(made.pinned50.stamp), 50, now)
    st = fn key -> made[key].stamp end

    assert {:ok, %{deleted: deleted, stopped: nil}} = Retention.run(dir)

    # The database (keep 3, BACKUP_KEEP_DAYS 14): its own newest three (db1,
    # db16, db30) and, counted with the cron-like ones, gone10 (a deleted
    # schedule's run counts like cron's). manual3 is young; the recovery point
    # stays. db45, manual20 and cron25 are past 14 days and held by nothing.
    # The media (keep 2, 30 days): m2 and m8 by the count, m15 by its age,
    # cron21 by the floor its schedule raises to 30 days; manual18 ages at 14
    # and m40 past 30.
    gone_keys = [:db45, :manual20, :cron25, :manual18, :m40]
    expected = gone_keys |> Enum.flat_map(&made[&1].names) |> Enum.sort()
    assert Enum.sort(deleted) == expected

    for key <- Map.keys(made) -- gone_keys, name <- made[key].names do
      assert File.exists?(Path.join([dir, to_string(made[key].kind), name])), "#{key} kept"
    end

    assert holds(dir, "db") == Enum.sort([st.(:db1), st.(:gone10), st.(:db16), st.(:db30)])
    assert holds(dir, "media") == Enum.sort([st.(:m2), st.(:m8), st.(:m15), st.(:cron21)])

    for key <- gone_keys, do: assert(local_status(st.(key)) == "pruned", "#{key} marked")
    for key <- [:db1, :db30, :cron21, :m15], do: assert(local_status(st.(key)) == "ok")

    # Cron, given the markers, deletes nothing more.
    if System.find_executable("bash") do
      before = listing(dir)

      assert {_out, 0} =
               System.cmd("bash", [@script, "prune"],
                 env: [{"BACKUP_DIR", dir}, {"BACKUP_KEEP_DAYS", "14"}],
                 stderr_to_stdout: true
               )

      assert listing(dir) == before
    end
  end

  @tag :pg_tools
  test "through the chain: N kept, plus the run that is pruning", %{dir: dir, now: now} do
    s =
      force!(schedule!(%{components: [:db], keep_count: 2}),
        baseline_at: ~U[2026-01-01 00:00:00.000000Z]
      )

    [st30, st40, st50] =
      for days <- [30, 40, 50] do
        st = stamp(now, days)
        files!(dir, :db, st, days, now)
        app_run!(:db, st, "schedule", [s.id])
        st
      end

    assert {:ok, %{status: :started}} =
             Backups.request_scheduled([s.id], DateTime.utc_now(), Backups.system())

    BackupChain.drain()

    assert [new] =
             Backups.list_runs!(actor: Backups.system())
             |> Enum.filter(&(&1.stamp not in [st30, st40, st50]))

    assert new.status == :succeeded

    # The prune step ran while the new run was in flight: it kept the two
    # newest finished ones, so three sets are on disk until the next prune.
    dumps =
      for name <- File.ls!(Path.join(dir, "db")),
          {:ok, %{stamp: st, partial?: false}} <- [Artifact.parse_file(name)],
          do: st

    assert Enum.sort(dumps) == Enum.sort([st30, st40, new.stamp])
    assert local_status(st50) == "pruned"

    # Once it succeeded the markers moved on: the hold now names the new run
    # and the newest older one, so the next prune takes st40.
    assert holds(dir, "db") == Enum.sort([st30, new.stamp])
  end
end
