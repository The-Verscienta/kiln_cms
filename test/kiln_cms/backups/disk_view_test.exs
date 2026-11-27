defmodule KilnCMS.Backups.DiskViewTest do
  @moduledoc """
  One read of the backup directory for a page of history (#2416, #2417,
  #2799): markers, presence, Resume and cron's keep days, without the database.
  """
  # `async: false`: `Backups.work_state?/1` reads `:kiln_cms, KilnCMS.Backups,
  # :dir`, pointed at a temp directory here (`Application.put_env` is VM-global).
  use ExUnit.Case, async: false

  alias KilnCMS.Backups.{Artifact, DiskView, Manifest, Markers, Presence, Run, WorkState}

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_dv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, dir: dir, keep_days: 14)
    )

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
  end

  defp touch(dir, sub, name), do: File.write!(Path.join([dir, sub, name]), "x")

  defp run(stamp, attrs \\ []) do
    struct(
      %Run{
        id: Ecto.UUID.generate(),
        stamp: stamp,
        origin: :app,
        status: :succeeded,
        started_at: DateTime.utc_now(),
        artifacts: [
          %Artifact{
            kind: :db,
            name: "kiln-db-#{stamp}.dump",
            bytes: 1,
            destinations: %{"local" => %{"status" => "ok"}}
          }
        ]
      },
      attrs
    )
  end

  test "presence per run id, markers and Resume in one read", %{dir: dir} do
    here = run("20260801-031700")
    gone = run("20260802-031700")
    failed = run("20260803-031700", status: :failed)
    touch(dir, "db", "kiln-db-20260801-031700.dump")
    touch(dir, "db", "kiln-20260801-031700.good")

    work = WorkState.path(dir, failed.stamp)
    File.mkdir_p!(work)
    :ok = WorkState.write(work, WorkState.new(failed.stamp))

    view = DiskView.read(dir, [here, gone, failed])

    assert view.presence[here.id].state == :present
    assert view.presence[gone.id].state == :missing
    assert Markers.last_good(view.markers, :db) == "20260801-031700"
    assert Markers.unreadable(view.markers) == []
    # Only a resumable status with its state file kept.
    assert view.resumable == MapSet.new([failed.id])
  end

  # Part of #2225: the page names a row pinned to another server's directory
  # before anyone clicks Download.
  test "reports the directory's own id, or why it has none", %{dir: dir} do
    assert DiskView.read(dir, []).dir_id == {:error, :enoent}

    {:ok, id} = KilnCMS.Backups.DirId.local(dir)
    assert DiskView.read(dir, []).dir_id == {:ok, id}
  end

  test "cron's keep days come from a manifest backup.sh wrote, not Kiln's", %{dir: dir} do
    :ok = Manifest.write(dir, %Manifest{trigger: "cron", ok: true, keep_days: 3})
    assert DiskView.read(dir, []).cron_keep_days == 3

    :ok =
      Manifest.write(dir, %Manifest{trigger: "manual", ok: true, keep_days: 3, components: ["db"]})

    assert DiskView.read(dir, []).cron_keep_days == nil

    File.rm!(Manifest.path(dir))
    assert DiskView.read(dir, []).cron_keep_days == nil
  end

  test "an imported run past cron's window, with a newer dump on disk, reads expired", %{
    dir: dir
  } do
    :ok = Manifest.write(dir, %Manifest{trigger: "cron", ok: true, keep_days: 3})
    touch(dir, "db", "kiln-db-20260901-031700.dump")

    old =
      run("20260801-031700",
        origin: :imported,
        started_at: DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      )

    assert DiskView.read(dir, [old]).presence[old.id].state == :expired
  end

  test "a later cron run's keep days judge an imported row, not manifest.json (#3113)", %{
    dir: dir
  } do
    # The latest manifest is Kiln's, so cron's window is unknown from it.
    :ok = Manifest.write(dir, %Manifest{trigger: "manual", ok: true, components: ["db"]})
    touch(dir, "db", "kiln-db-20260901-031700.dump")
    now = DateTime.utc_now()
    old = run("20260801-031700", origin: :imported, started_at: DateTime.add(now, -30 * 86_400))

    later = %Run{
      origin: :imported,
      started_at: DateTime.add(now, -10 * 86_400),
      finished_at: DateTime.add(now, -10 * 86_400),
      keep_days: 7
    }

    prunes = Presence.cron_prunes([later], later.started_at)

    assert DiskView.read(dir, [old], now).presence[old.id].state == :probably_expired
    assert DiskView.read(dir, [old], now, cron_prunes: prunes).presence[old.id].state == :expired
  end

  test "an unlistable db/ is unreadable and unknown, and never raises (#2799)", %{dir: dir} do
    File.rm_rf!(Path.join(dir, "db"))
    File.write!(Path.join(dir, "db"), "")
    touch(dir, "media", "kiln-20260801-031700.good")
    run = run("20260801-031700")

    view = DiskView.read(dir, [run])

    assert Markers.unreadable(view.markers) == [:db]
    assert Markers.last_good(view.markers, :media) == "20260801-031700"
    assert view.presence[run.id].state == :unknown
  end

  test "a directory that isn't there reads as empty", %{dir: dir} do
    missing = Path.join(dir, "nowhere")
    run = run("20260801-031700")

    view = DiskView.read(missing, [run])

    assert view.markers == Markers.empty()
    assert view.presence[run.id].state == :missing
  end
end
