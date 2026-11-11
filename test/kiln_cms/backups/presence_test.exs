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

  # Retention ages a stamp's dump and its media separately (#2219).
  test "partly pruned when every missing file was removed by retention", %{dir: dir} do
    touch(dir, "media", "kiln-media-20260805-031700.tar.gz")

    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump", %{"local" => %{"status" => "pruned"}}),
        artifact(:media, "kiln-media-20260805-031700.tar.gz")
      ])

    assert Presence.for(run, dir, 14) == :partly_pruned
  end

  test "some files present, one pruned and one gone out-of-band is missing", %{dir: dir} do
    touch(dir, "db", "kiln-db-20260805-031700.dump")

    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump"),
        artifact(:media, "kiln-media-20260805-031700.part01.tar.gz", %{
          "local" => %{"status" => "pruned"}
        }),
        artifact(:media, "kiln-media-20260805-031700.part02.tar.gz")
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

  describe "media part sets" do
    @stamp "20260805-031700"

    defp set(destinations \\ %{"local" => %{"status" => "ok"}}, part_destinations \\ nil) do
      parts =
        for name <- Artifact.set_names(@stamp, 3) do
          part = %{"name" => name, "bytes" => 1, "sha256" => nil}
          if part_destinations, do: Map.put(part, "destinations", part_destinations), else: part
        end

      %Artifact{
        kind: :media,
        name: "kiln-media-#{@stamp}",
        bytes: 3,
        parts: parts,
        destinations: destinations
      }
    end

    defp land_parts(dir, indexes) do
      for i <- indexes, do: touch(dir, "media", Artifact.part_name(@stamp, i))
    end

    test "present when every part is on disk, whatever the sidecar does", %{dir: dir} do
      land_parts(dir, 1..3)
      assert Presence.for(run([set()]), dir, 14) == :present
    end

    test "one missing part makes the run missing", %{dir: dir} do
      land_parts(dir, [1, 3])
      assert Presence.for(run([set()]), dir, 14) == :missing
    end

    test "a sidecar alone is not the artifact", %{dir: dir} do
      touch(dir, "media", Artifact.sidecar_name(:media, @stamp))
      assert Presence.for(run([set()]), dir, 14) == :missing
    end

    test "an unrelated sidecar missing does not matter: parts present, no sidecar", %{dir: dir} do
      land_parts(dir, 1..3)
      refute File.exists?(Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)]))
      assert Presence.for(run([set()]), dir, 14) == :present
    end

    test "all parts pruned reads pruned", %{dir: dir} do
      assert Presence.for(run([set(%{"local" => %{"status" => "pruned"}})]), dir, 14) == :pruned
    end

    test "parts pruned per part (artifact still ok) read pruned", %{dir: dir} do
      pruned = %{"local" => %{"status" => "pruned"}}

      assert Presence.for(run([set(%{"local" => %{"status" => "ok"}}, pruned)]), dir, 14) ==
               :pruned
    end

    test "a part missing but not pruned among pruned ones is missing", %{dir: dir} do
      art = set(%{"local" => %{"status" => "ok"}}, %{"local" => %{"status" => "pruned"}})
      [first | rest] = art.parts
      first = Map.put(first, "destinations", %{"local" => %{"status" => "ok"}})
      assert Presence.for(run([%{art | parts: [first | rest]}]), dir, 14) == :missing
    end

    test "all parts gone but off-site everywhere reads off-site only", %{dir: dir} do
      remote = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}
      assert Presence.for(run([set(remote)]), dir, 14) == :off_site_only
    end

    test "one part never reached off-site is missing, not off-site only", %{dir: dir} do
      art = set(%{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "failed"}})
      assert Presence.for(run([art]), dir, 14) == :missing

      ok = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}
      failed = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "failed"}}
      art = set(%{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}, ok)
      [one, two, three] = art.parts
      art = %{art | parts: [one, Map.put(two, "destinations", failed), three]}
      assert Presence.for(run([art]), dir, 14) == :missing
    end

    test "a symlink named like a part is not the part", %{dir: dir} do
      land_parts(dir, [1, 2])
      target = Path.join(dir, "elsewhere")
      File.write!(target, "x")
      File.ln_s!(target, Path.join([dir, "media", Artifact.part_name(@stamp, 3)]))
      assert Presence.for(run([set()]), dir, 14) == :missing
    end

    test "db plus a part set: present only when both are", %{dir: dir} do
      land_parts(dir, 1..3)
      db = artifact(:db, "kiln-db-#{@stamp}.dump")
      assert Presence.for(run([db, set()]), dir, 14) == :missing
      touch(dir, "db", "kiln-db-#{@stamp}.dump")
      assert Presence.for(run([db, set()]), dir, 14) == :present
    end
  end
end
