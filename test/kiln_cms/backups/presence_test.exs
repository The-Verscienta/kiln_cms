defmodule KilnCMS.Backups.PresenceTest do
  @moduledoc "Which of a run's files are still on disk, and why not (#2217)."
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.{Artifact, Presence, Run}

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_pres_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp artifact(kind, name, destinations \\ %{"local" => %{"status" => "ok"}}),
    do: %Artifact{kind: kind, name: name, bytes: 1, destinations: destinations}

  defp run(artifacts, attrs \\ []) do
    struct(
      %Run{
        origin: :app,
        started_at: DateTime.utc_now(),
        artifacts: artifacts
      },
      attrs
    )
  end

  defp touch(dir, sub, name), do: File.write!(Path.join([dir, sub, name]), "x")

  test "present when every file exists", %{dir: dir} do
    touch(dir, "db", "kiln-db-20260805-031700.dump")
    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert Presence.for(run, dir, 14) == :present
  end

  test "a symlink named like an artifact is not the artifact", %{dir: dir} do
    target = Path.join(dir, "elsewhere")
    File.write!(target, "x")
    File.ln_s!(target, Path.join([dir, "db", "kiln-db-20260805-031700.dump"]))

    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert Presence.for(run, dir, 14) == :missing
  end

  test "missing when a file was deleted out-of-band", %{dir: dir} do
    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert Presence.for(run, dir, 14) == :missing
  end

  test "a directory with the artifact's name is not a file", %{dir: dir} do
    File.mkdir_p!(Path.join([dir, "db", "kiln-db-20260805-031700.dump"]))
    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert Presence.for(run, dir, 14) == :missing
  end

  test "some files present and some gone is missing", %{dir: dir} do
    touch(dir, "db", "kiln-db-20260805-031700.dump")

    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump"),
        artifact(:media, "kiln-media-20260805-031700.tar.gz")
      ])

    assert Presence.for(run, dir, 14) == :missing
  end

  test "pruned when retention marked the local copy", %{dir: dir} do
    run =
      run([artifact(:db, "kiln-db-a.dump", %{"local" => %{"status" => "pruned"}})])

    assert Presence.for(run, dir, 14) == :pruned
  end

  test "off-site only when nothing is local and an rclone copy succeeded", %{dir: dir} do
    destinations = %{
      "local" => %{"status" => "ok"},
      "rclone:remote" => %{"status" => "ok"}
    }

    assert Presence.for(run([artifact(:db, "a.dump", destinations)]), dir, 14) == :off_site_only

    failed = Map.put(destinations, "rclone:remote", %{"status" => "failed"})
    assert Presence.for(run([artifact(:db, "a.dump", failed)]), dir, 14) == :missing
  end

  test "expired only for an imported run older than the retention window plus a day", %{dir: dir} do
    now = DateTime.utc_now()
    old = DateTime.add(now, -16 * 86_400, :second)
    recent = DateTime.add(now, -3 * 86_400, :second)

    assert Presence.for(
             run([artifact(:db, "a.dump")], origin: :imported, started_at: old),
             dir,
             14
           ) ==
             :expired

    assert Presence.for(
             run([artifact(:db, "a.dump")], origin: :imported, started_at: recent),
             dir,
             14
           ) == :missing

    # An app-made run has a recorded prune; age alone is not a reason.
    assert Presence.for(run([artifact(:db, "a.dump")], origin: :app, started_at: old), dir, 14) ==
             :missing
  end

  test "none for a run with no artifacts", %{dir: dir} do
    assert Presence.for(run([]), dir, 14) == :none
  end
end
