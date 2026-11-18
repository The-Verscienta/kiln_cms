defmodule KilnCMS.Backups.StatusTest do
  @moduledoc """
  `Backups.status/0` per component (#2219): a backup may cover only the
  database or only the media, so the last good backup, the last attempt and
  staleness are each component's own, from the run history and the manifest
  together; and when the history can't be read the status falls back to the
  manifest alone instead of raising or calling anything healthy.

  `async: false`: it changes the VM-wide `Application` env.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Manifest}

  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bks_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(dir)
    File.mkdir_p!(media)

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: media, stale_after_hours: 36)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{dir: dir}
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

  # A finished run covering `components`, `hours` ago, with a verified
  # artifact of each (unless `artifacts:` says otherwise).
  defp run!(components, hours, opts \\ []) do
    at = hours_ago(hours)
    stamp = Artifact.stamp(at)
    status = Keyword.get(opts, :status, :succeeded)

    artifacts =
      Keyword.get_lazy(opts, :artifacts, fn ->
        for component <- components, do: artifact(component, stamp, status == :succeeded)
      end)

    Backups.import_run!(
      %{
        stamp: stamp,
        trigger: "cron",
        status: status,
        components: components,
        started_at: at,
        finished_at: at,
        artifacts: artifacts,
        error: if(status == :failed, do: "boom")
      },
      actor: Backups.system()
    )
  end

  defp artifact(:db, stamp, verified?),
    do: %{kind: :db, name: "kiln-db-#{stamp}.dump", bytes: 10, verified: verified?}

  defp artifact(:media, stamp, verified?),
    do: %{kind: :media, name: "kiln-media-#{stamp}.tar.gz", bytes: 10, verified: verified?}

  defp manifest!(dir, attrs) do
    :ok =
      Manifest.write(
        dir,
        struct(
          %Manifest{
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            trigger: "cron",
            ok: true,
            artifacts: [
              %{kind: "db", path: "db/kiln-db-20260805-031700.dump", bytes: 1, verified: true}
            ]
          },
          attrs
        )
      )
  end

  test "one entry per component this deployment backs up" do
    assert %{expected: [:db, :media], components: %{db: _, media: _}, source: :runs} =
             Backups.status()

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :media_dir, nil)
    )

    assert %{expected: [:db], components: components} = Backups.status()
    assert Map.keys(components) == [:db]
  end

  test "nothing at all: every component never backed up, stale, and not failed" do
    status = Backups.status()

    for component <- [:db, :media] do
      assert %{never?: true, stale?: true, failed?: false, last_good: nil} =
               status.components[component]
    end

    assert status.stale?
    refute status.failed?
  end

  test "a database-only backup after a full one keeps media's last good from the full one",
       %{dir: dir} do
    full = run!([:db, :media], 10)
    db_only = run!([:db], 2)
    manifest!(dir, components: ["db"], finished_at: db_only.finished_at)

    status = Backups.status()

    assert %{last_good: %{stamp: db_stamp}, stale?: false} = status.components.db
    assert db_stamp == db_only.stamp
    assert %{last_good: %{stamp: media_stamp}, stale?: false} = status.components.media
    assert media_stamp == full.stamp
    refute status.stale?
  end

  test "stale media and a fresh database: media is stale, and so is the whole" do
    run!([:db, :media], 72)
    run!([:db], 1)

    status = Backups.status()

    refute status.components.db.stale?
    assert status.components.media.stale?
    refute status.components.media.never?
    assert status.stale?
    assert status.components.media.stale_after_hours == 36
    assert status.components.media.stale_source == {:env, "BACKUP_STALE_AFTER_HOURS"}
  end

  # An in-app run that failed, covering `components`, `hours` ago.
  defp app_failed!(components, hours) do
    at = hours_ago(hours)

    run =
      Backups.start_run!(
        %{stamp: Artifact.stamp(at), trigger: "manual", components: components, started_at: at},
        actor: Backups.system()
      )

    Backups.fail_run!(run, %{error: "boom"}, actor: Backups.system())
  end

  test "a failed attempt after a good one is failed for the components it covered" do
    run!([:db, :media], 10)
    app_failed!([:media], 1)

    status = Backups.status()

    refute status.components.db.failed?
    assert %{failed?: true, last_attempt: %{ok?: false}, last_good: %{}} = status.components.media
    assert status.failed?
  end

  test "an app-made failed database-only run doesn't fail media" do
    run!([:db, :media], 10)
    app_failed!([:db], 1)

    status = Backups.status()

    assert status.components.db.failed?
    refute status.components.media.failed?
  end

  # A failed cron run imported from a failure manifest names no component.
  test "a failed imported run that names no component fails every component, even after a " <>
         "newer database-only success" do
    run!([:db, :media], 30)
    run!([], 10, status: :failed)
    run!([:db], 1)

    status = Backups.status()

    refute status.components.db.failed?
    assert %{failed?: true, last_attempt: %{ok?: false}} = status.components.media
  end

  # A failed cron run lists only the kinds of the files it left.
  test "a failed imported run that left only a dump still fails media" do
    run!([:db, :media], 30)
    run!([:db], 10, status: :failed)

    assert Backups.status().components.media.failed?
  end

  test "a succeeded run with no verified artifact of a component is not its last good" do
    run!([:db, :media], 5)

    run!([:db, :media], 1,
      artifacts: [%{kind: :db, name: "kiln-db-x.dump", bytes: 1, verified: true}]
    )

    status = Backups.status()

    assert DateTime.diff(DateTime.utc_now(), status.components.db.last_good.at, :hour) < 2
    assert DateTime.diff(DateTime.utc_now(), status.components.media.last_good.at, :hour) >= 4
  end

  test "a cron manifest newer than every run counts for the components it covered", %{dir: dir} do
    run!([:db, :media], 72)

    manifest!(dir,
      artifacts: [
        %{kind: "db", path: "db/kiln-db-20260805-031700.dump", bytes: 1, verified: true}
      ]
    )

    status = Backups.status()

    assert %{last_good: %{source: :manifest}, stale?: false} = status.components.db
    assert %{last_good: %{source: :run}, stale?: true} = status.components.media
  end

  test "a failed manifest that doesn't say what it covered counts against every component",
       %{dir: dir} do
    run!([:db, :media], 5)
    manifest!(dir, ok: false, artifacts: [], error: "boom")

    status = Backups.status()

    assert status.components.db.failed?
    assert status.components.media.failed?
  end

  test "a failed manifest that names its components counts against those only", %{dir: dir} do
    run!([:db, :media], 5)
    manifest!(dir, ok: false, components: ["media"], artifacts: [], error: "boom")

    status = Backups.status()

    refute status.components.db.failed?
    assert status.components.media.failed?
  end

  test "an unreadable history is a telemetry event every time, and a warning once in a while" do
    :persistent_term.erase({Backups, :history_warned_at})
    on_exit(fn -> :persistent_term.erase({Backups, :history_warned_at}) end)

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:kiln_cms, :backups, :status, :history_unreadable]
      ])

    revoked = KilnCMS.SystemActor.new(:billing)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..3, do: Backups.with_actor(revoked, fn -> Backups.status() end)
      end)

    for _ <- 1..3 do
      assert_received {[:kiln_cms, :backups, :status, :history_unreadable], ^ref, %{count: 1}, _}
    end

    assert length(String.split(log, "Backup status from the manifest alone")) == 2
  end

  test "a run history that can't be read falls back to the manifest, never raises", %{dir: dir} do
    run!([:db, :media], 1)
    manifest!(dir, finished_at: hours_ago(2))

    status =
      Backups.with_actor(KilnCMS.SystemActor.new(:billing), fn -> Backups.status() end)

    assert status.source == :manifest
    # The manifest covered the database only: media has nothing to show for
    # itself, whatever the unreadable history holds.
    assert %{last_good: %{source: :manifest}, stale?: false} = status.components.db
    assert %{never?: true, stale?: true} = status.components.media
    assert status.stale?
  end

  # Part of #2219: in-app schedules set a component's staleness threshold
  # while they are known to run, and say when it is backed up next. Needs
  # `pg_dump` and `pg_restore` on PATH: without them backups are unavailable
  # here and no schedule counts.
  describe "in-app schedules" do
    @describetag :pg_tools

    import Ecto.Query
    import KilnCMS.Test.BackupSchedules

    @baseline ~U[2026-01-01 00:00:00.000000Z]

    defp scheduled!(attrs),
      do:
        force!(schedule!(Map.merge(%{starts_on: ~D[2026-01-01]}, attrs)), baseline_at: @baseline)

    # A good backup made by neither host cron nor a schedule: no cron evidence.
    defp manual_run!(components, hours) do
      run = run!(components, hours)
      {:ok, id} = Ecto.UUID.dump(run.id)

      {1, _} =
        KilnCMS.Repo.update_all(from(r in "backup_runs", where: r.id == ^id),
          set: [trigger: "manual"]
        )

      run
    end

    defp put_cron(value) do
      original = Application.fetch_env(:kiln_cms, :backup_scheduler_cron)
      Application.put_env(:kiln_cms, :backup_scheduler_cron, value)

      on_exit(fn ->
        case original do
          {:ok, old} -> Application.put_env(:kiln_cms, :backup_scheduler_cron, old)
          :error -> Application.delete_env(:kiln_cms, :backup_scheduler_cron)
        end
      end)
    end

    defp set_config(overrides) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups), overrides)
      )
    end

    test "a weekly media schedule: not stale at 40 h, stale at 253 h, stale_source {:schedule, id}" do
      s = scheduled!(%{components: [:media], interval: :weekly})
      manual_run!([:media], 40)

      media = Backups.status().components.media
      assert %{stale?: false, stale_after_hours: 252, stale_source: {:schedule, id}} = media
      assert id == s.id

      # Only a 253-hour-old media backup: past the weekly threshold.
      KilnCMS.Repo.delete_all("backup_runs")
      manual_run!([:media], 253)
      assert %{stale?: true, stale_after_hours: 252} = Backups.status().components.media

      # The database has no schedule: the environment's threshold.
      assert %{stale_after_hours: 36, stale_source: {:env, "BACKUP_STALE_AFTER_HOURS"}} =
               Backups.status().components.db
    end

    test "a two-hourly db schedule: not stale at 7 h, stale at 9 h, stale_source {:schedule, id} (#2219)" do
      s = scheduled!(%{components: [:db], interval: :every_2h, keep_days: 3})
      manual_run!([:db], 7)

      db = Backups.status().components.db
      assert %{stale?: false, stale_after_hours: 8, stale_source: {:schedule, id}} = db
      assert id == s.id

      KilnCMS.Repo.delete_all("backup_runs")
      manual_run!([:db], 9)
      assert %{stale?: true, stale_after_hours: 8} = Backups.status().components.db
    end

    test "W-i: with a cron import in the last 8 days, the threshold is min(env, schedule) and the source names the winner" do
      weekly = scheduled!(%{components: [:media], interval: :weekly})
      daily = scheduled!(%{components: [:db]})
      # `run!/2` imports cron's backups.
      run!([:db, :media], 40)

      status = Backups.status()

      assert %{
               stale_after_hours: 36,
               stale_source: {:cron, "BACKUP_STALE_AFTER_HOURS"},
               stale?: true
             } =
               status.components.media

      # Daily (36) is not above the environment's 36: the schedule's.
      assert %{stale_after_hours: 36, stale_source: {:schedule, id}} = status.components.db
      assert id == daily.id
      refute id == weekly.id
    end

    test "no schedules: the environment's threshold and source, and :none" do
      status = Backups.status()
      assert status.schedules == :none
      assert status.next_at == nil

      assert %{stale_source: {:env, "BACKUP_STALE_AFTER_HOURS"}, next_at: nil} =
               status.components.db
    end

    test "a paused schedule is ignored, and has no next run" do
      s = scheduled!(%{components: [:db], interval: :weekly})
      {:ok, _} = Backups.update_backup_schedule(s, %{enabled: false}, actor: platform_admin())

      status = Backups.status()
      assert %{stale_source: {:env, _}, next_at: nil} = status.components.db
      assert [%{next_at: nil}] = status.schedules
    end

    test "scheduler cron off: schedules are ignored" do
      scheduled!(%{components: [:db], interval: :weekly})
      put_cron("false")

      status = Backups.status()
      refute status.scheduler_enabled?
      assert %{stale_source: {:env, _}, next_at: nil} = status.components.db
      assert [%{next_at: nil}] = status.schedules
    end

    test "D1: BACKUP_ENABLED=false, a start date ahead, or a refused last window: the environment's threshold" do
      s = scheduled!(%{components: [:db], interval: :weekly})
      set_config(enabled: false)
      assert %{stale_source: {:env, _}} = Backups.status().components.db
      set_config(enabled: true)
      assert %{stale_source: {:schedule, _}} = Backups.status().components.db

      force!(s, last_outcome: "refused")
      assert %{stale_source: {:env, _}} = Backups.status().components.db

      KilnCMS.Repo.delete_all("backup_schedules")
      next_month = Date.utc_today() |> Date.end_of_month() |> Date.add(1)
      scheduled!(%{components: [:db], interval: :weekly, starts_on: next_month})
      assert %{stale_source: {:env, _}, next_at: next_at} = Backups.status().components.db
      assert Date.compare(DateTime.to_date(next_at), next_month) != :lt
    end

    test "D1: no pg_dump on the node computing the status: the environment's threshold" do
      scheduled!(%{components: [:db], interval: :weekly})
      assert %{stale_source: {:schedule, _}} = Backups.status().components.db

      without_pg_tools(fn ->
        assert %{stale_source: {:env, _}} = Backups.status().components.db
      end)
    end

    test "an unreadable schedule list falls back to the environment with schedules: :unreadable" do
      scheduled!(%{components: [:db], interval: :weekly})
      :persistent_term.erase({Backups, :schedules_warned_at})
      on_exit(fn -> :persistent_term.erase({Backups, :schedules_warned_at}) end)

      status = Backups.with_actor(KilnCMS.SystemActor.new(:billing), fn -> Backups.status() end)
      assert status.schedules == :unreadable
      assert %{stale_source: {:env, _}, next_at: nil} = status.components.db
    end

    test "next_at per component and at the top; an overdue (deferred) window is due now" do
      now = DateTime.utc_now()
      db = scheduled!(%{components: [:db]})
      media = scheduled!(%{components: [:media], interval: :weekly})

      # The database's latest window was claimed: its next is tomorrow's.
      {:ok, latest} = KilnCMS.Backups.Schedule.Window.latest(db, now)
      force!(db, last_window_at: latest)
      # The media's latest window is still due (waiting): due now.
      {:ok, media_due} = KilnCMS.Backups.Schedule.Window.latest(media, now)

      status = Backups.status()
      assert status.components.media.next_at == media_due
      assert DateTime.compare(status.components.db.next_at, now) == :gt
      assert status.next_at == media_due

      entries = Map.new(status.schedules, &{&1.schedule.id, &1.next_at})
      assert entries[media.id] == media_due
      assert entries[db.id] == status.components.db.next_at
    end
  end

  # #2220: how the newest finished in-app run that had off-site destinations
  # fared there. The rest of the status is untouched by it.
  describe "off-site destinations" do
    @env_key "rclone:offsite:kiln"

    # An in-app run, `hours` ago, finished with `destinations` (Run-level
    # entries) and `offsite_status`.
    defp offsite_run!(hours, destinations, offsite_status, opts \\ []) do
      at = hours_ago(hours)
      stamp = Artifact.stamp(at)

      run =
        Backups.start_run!(
          %{stamp: stamp, trigger: "manual", components: [:db], started_at: at},
          actor: Backups.system()
        )

      attrs = %{
        artifacts: [artifact(:db, stamp, true)],
        destinations: destinations,
        offsite_status: offsite_status
      }

      case Keyword.get(opts, :status, :succeeded) do
        :succeeded -> Backups.finish_run!(run, attrs, actor: Backups.system())
        :failed -> Backups.fail_run!(run, Map.put(attrs, :error, "boom"), actor: Backups.system())
      end
    end

    defp dest(key, label, status, error \\ nil),
      do: %{key: key, kind: "rclone", label: label, status: status, error: error}

    @nas_id "6c1f6a52-6a44-4d3e-9b39-0b1f8c1a7e11"
    @nas "dest:" <> @nas_id

    # Both destinations the runs below name are configured, so a failed one
    # still counts (#2951): `BACKUP_RCLONE_REMOTE` and a stored "NAS".
    setup do
      remote!("offsite:kiln")

      nas =
        Ash.Seed.seed!(KilnCMS.Backups.DestinationConfig, %{
          id: @nas_id,
          name: "NAS",
          kind: "local",
          settings: %{},
          enabled: true
        })

      %{nas: nas}
    end

    defp remote!(remote) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, remote)
      )
    end

    defp remove!(row), do: Ash.Seed.update!(row, %{enabled: false})

    defp unreadable_entry,
      do: %{
        key: KilnCMS.Backups.RunDestination.unreadable_key(),
        label: "Stored destinations",
        status: :failed,
        error: "couldn't read the backup destinations; this backup was not sent to them"
      }

    test "no in-app run with destinations: none, and every other key as before" do
      run!([:db, :media], 1)

      assert %{state: :none, stamp: nil, ok: 0, total: 0, failed: [], destinations: []} =
               Backups.status().offsite

      # A run with no destinations at all (no remote configured) is none too.
      offsite_run!(0, [], nil)
      assert Backups.status().offsite.state == :none
    end

    test "complete: every destination reached" do
      run = offsite_run!(1, [dest(@env_key, "offsite:kiln", :ok)], :complete)

      status = Backups.status()
      assert %{state: :complete, ok: 1, total: 1, failed: []} = status.offsite
      assert status.offsite.stamp == run.stamp
      refute status.failed?
    end

    test "partial: says how many of how many, and which failed with its error" do
      offsite_run!(
        1,
        [
          dest(@env_key, "offsite:kiln", :ok),
          dest(@nas, "NAS", :failed, "the store refused it")
        ],
        :partial
      )

      status = Backups.status()

      assert %{
               state: :partial,
               ok: 1,
               total: 2,
               failed: [%{key: @nas, label: "NAS", error: "the store refused it"}]
             } = status.offsite

      assert [%{label: "offsite:kiln", status: :ok}, %{label: "NAS", status: :failed}] =
               status.offsite.destinations

      # Partly off-site is the backup alarm's, not a failed backup.
      refute status.failed?
    end

    test "skipped destinations count for nothing" do
      offsite_run!(
        1,
        [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :skipped)],
        :complete
      )

      assert %{state: :complete, ok: 1, total: 1} = Backups.status().offsite
    end

    test "a succeeded run with destinations and no recorded outcome is unknown" do
      offsite_run!(1, [dest(@env_key, "offsite:kiln", :pending)], nil)

      assert %{state: :unknown, total: 1} = Backups.status().offsite
    end

    test "the alarm clears when the next run reaches every destination" do
      offsite_run!(
        5,
        [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :failed, "down")],
        :partial
      )

      assert Backups.status().offsite.state == :partial

      offsite_run!(1, [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :ok)], :complete)

      assert %{state: :complete, failed: []} = Backups.status().offsite
    end

    test "a later run that failed before its off-site step doesn't hide the outcome" do
      offsite_run!(
        5,
        [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :failed, "down")],
        :partial
      )

      offsite_run!(1, [dest(@env_key, "offsite:kiln", :pending)], nil, status: :failed)

      assert Backups.status().offsite.state == :partial

      # One that failed at the off-site step says so.
      offsite_run!(0, [dest(@env_key, "offsite:kiln", :failed, "rclone exited 1")], :failed,
        status: :failed
      )

      assert %{state: :failed, ok: 0, total: 1} = Backups.status().offsite
    end

    # #2951, the broad rule: a failed destination nobody can fix any more
    # (removed, disabled, the env unset) no longer holds the alarm up.
    test "a failed destination removed since moves to gone; the reached one stays", %{nas: nas} do
      offsite_run!(
        1,
        [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :failed, "down")],
        :partial
      )

      remove!(nas)

      assert %{
               state: :partial,
               configured?: true,
               ok: 1,
               total: 2,
               failed: [],
               gone: [%{key: @nas, label: "NAS"}]
             } = Backups.status().offsite
    end

    test "every destination removed: nothing configured, nothing failed", %{nas: nas} do
      offsite_run!(
        1,
        [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :failed, "down")],
        :partial
      )

      remove!(nas)
      remote!(nil)

      assert %{state: :partial, configured?: false, failed: [], gone: [%{key: @nas}]} =
               Backups.status().offsite
    end

    test "a failed destination still configured keeps the alarm" do
      offsite_run!(
        1,
        [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :failed, "down")],
        :partial
      )

      assert %{configured?: true, failed: [%{key: @nas}], gone: []} = Backups.status().offsite
    end

    test "destinations that can't be read filter nothing, and are counted" do
      offsite_run!(
        1,
        [dest(@env_key, "offsite:kiln", :ok), dest(@nas, "NAS", :failed, "down")],
        :partial
      )

      remote!(nil)

      # A row no release could load: every read of the table fails.
      KilnCMS.Repo.query!(
        "INSERT INTO backup_destinations (name, kind, settings) VALUES ('Broken', 'fake', '\"x\"')"
      )

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:kiln_cms, :backups, :status, :destinations_unreadable]
        ])

      assert %{state: :partial, configured?: true, failed: [%{key: @nas}], gone: []} =
               Backups.status().offsite

      assert_received {[:kiln_cms, :backups, :status, :destinations_unreadable], ^ref,
                       %{count: 1}, _}
    end

    test "a failed run's outcome is not filtered" do
      offsite_run!(1, [dest(@env_key, "offsite:kiln", :failed, "rclone exited 1")], :failed,
        status: :failed
      )

      remote!(nil)

      assert %{state: :failed, succeeded?: false, configured?: true, failed: [%{}]} =
               Backups.status().offsite
    end

    # #2951: the stored destinations couldn't be read and there was no env
    # remote, so the run reached nothing. It succeeded, off-site failed.
    test "unreadable alone: failed, and counts while a stored destination is enabled", %{
      nas: nas
    } do
      offsite_run!(1, [unreadable_entry()], :failed)

      assert %{
               state: :failed,
               succeeded?: true,
               configured?: true,
               ok: 0,
               total: 1,
               failed: [%{key: "unreadable"}]
             } = Backups.status().offsite

      remove!(nas)

      assert %{state: :failed, configured?: true, failed: [], gone: [%{key: "unreadable"}]} =
               Backups.status().offsite

      remote!(nil)
      assert %{configured?: false, failed: []} = Backups.status().offsite
    end

    # Critic change 11: a run a release before #2951 stored as partial with
    # only the unreadable entry reads failed, without being rewritten.
    test "an old run stored partial with only the unreadable entry reads failed" do
      run = offsite_run!(1, [unreadable_entry()], :partial)

      assert %{state: :failed, succeeded?: true, failed: [%{key: "unreadable"}]} =
               Backups.status().offsite

      assert Backups.get_run_by_stamp!(run.stamp, actor: Backups.system()).offsite_status ==
               :partial
    end

    test "imported (cron) runs are not in-app runs" do
      run!([:db], 1)
      assert Backups.status().offsite.state == :none
    end

    test "an unreadable history is unknown, never a crash" do
      offsite_run!(1, [dest(@env_key, "offsite:kiln", :ok)], :complete)

      status = Backups.with_actor(KilnCMS.SystemActor.new(:billing), fn -> Backups.status() end)

      assert %{state: :unknown, stamp: nil, failed: []} = status.offsite
    end
  end

  # #2487 / #2931: the notices, as `status/0` says them.
  describe "notices" do
    alias KilnCMS.Backups.{DestinationConfig, DirId, Notices}

    defp report!(attrs) do
      Backups.report_backup_notice!(
        Map.merge(
          %{
            kind: :retention,
            scope: "local",
            outcome: :skipped,
            reason: "why",
            at: DateTime.utc_now()
          },
          attrs
        ),
        actor: Backups.system()
      )
    end

    defp destination!(attrs) do
      Ash.Seed.seed!(
        DestinationConfig,
        Map.merge(
          %{
            name: "NAS #{System.unique_integer([:positive])}",
            kind: "local",
            settings: %{},
            enabled: true,
            prune: true
          },
          attrs
        )
      )
    end

    defp beat!(dir_id) do
      Backups.beat_node!(
        %{
          node: "node-#{System.unique_integer([:positive])}",
          boot_id: Ash.UUID.generate(),
          dir_id: dir_id
        },
        actor: Backups.system()
      )
    end

    test "none: both empty" do
      assert %{retention: [], held_deleted: []} = Backups.status()
    end

    test "a local skip is listed with what the panels need" do
      report!(%{stamp: "20261116-020000", reason: "couldn't read the backup history"})

      assert [
               %{
                 scope: :local,
                 label: nil,
                 outcome: :skipped,
                 reason: "couldn't read the backup history",
                 stamp: "20261116-020000",
                 dir_id: nil
               }
             ] = Backups.status().retention
    end

    test "a local notice whose directory no live node reports is hidden; a reported one, or this node's, is shown",
         %{dir: dir} do
      gone = Ash.UUID.generate()
      live = Ash.UUID.generate()
      own = Ash.UUID.generate()
      File.write!(DirId.path(dir), own)
      beat!(live)

      for id <- [gone, live, own], do: report!(%{scope: "local:" <> id, dir_id: id})

      assert ids = Enum.map(Backups.status().retention, & &1.dir_id)
      assert Enum.sort(ids) == Enum.sort([live, own])
    end

    test "a destination's notice shows while it is pruned, under its current name" do
      pruned = destination!(%{name: "Renamed NAS"})
      off = destination!(%{prune: false})
      disabled = destination!(%{enabled: false})

      for row <- [pruned, off, disabled],
          do: report!(%{scope: DestinationConfig.key(row), label: "NAS"})

      report!(%{scope: "dest:" <> Ash.UUID.generate(), label: "Deleted"})
      report!(%{scope: "local", outcome: :stopped, deleted: 2})

      key = DestinationConfig.key(pruned)

      assert [
               %{scope: :local, outcome: :stopped, deleted: 2},
               %{scope: {:destination, ^key}, label: "Renamed NAS"}
             ] = Backups.status().retention
    end

    test "held-deleted notices show for eight days" do
      report!(%{kind: :held_deleted, outcome: nil, units: ["db:20261110-020000"], total: 1})

      old = DateTime.add(DateTime.utc_now(), -(Notices.held_deleted_days() + 1) * 86_400, :second)
      report!(%{kind: :held_deleted, scope: "local:x", outcome: nil, units: ["media:x"], at: old})

      assert [%{units: ["db:20261110-020000"], total: 1, dir_id: nil}] =
               Backups.status().held_deleted
    end

    test "unreadable notices are empty and counted, never a crash" do
      report!(%{})

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:kiln_cms, :backups, :status, :notices_unreadable]
        ])

      status = Backups.with_actor(KilnCMS.SystemActor.new(:billing), fn -> Backups.status() end)

      assert %{retention: [], held_deleted: []} = status
      assert_received {[:kiln_cms, :backups, :status, :notices_unreadable], ^ref, %{count: 1}, _}
    end
  end
end
