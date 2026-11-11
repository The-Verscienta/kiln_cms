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
end
