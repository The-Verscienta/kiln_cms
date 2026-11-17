defmodule KilnCMS.Backups.PresenceTest do
  @moduledoc "Which of a run's files are still on disk, and why not (#2217, #2416)."
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

  defp presence(run, dir, opts \\ []),
    do: Presence.for(run, Presence.context(dir, Keyword.put_new(opts, :app_keep_days, 14)))

  defp state(run, dir, opts \\ []), do: presence(run, dir, opts).state

  defp artifact_states(run, dir, opts \\ []),
    do: for(a <- presence(run, dir, opts).artifacts, do: {a.kind, a.state})

  test "present when every file exists", %{dir: dir} do
    touch(dir, "db", "kiln-db-20260805-031700.dump")
    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert state(run, dir) == :present
  end

  test "a symlink named like an artifact is not the artifact", %{dir: dir} do
    target = Path.join(dir, "elsewhere")
    File.write!(target, "x")
    File.ln_s!(target, Path.join([dir, "db", "kiln-db-20260805-031700.dump"]))

    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert state(run, dir) == :missing
  end

  test "missing when a file was deleted out-of-band", %{dir: dir} do
    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert state(run, dir) == :missing
  end

  test "a directory with the artifact's name is not a file", %{dir: dir} do
    File.mkdir_p!(Path.join([dir, "db", "kiln-db-20260805-031700.dump"]))
    run = run([artifact(:db, "kiln-db-20260805-031700.dump")])
    assert state(run, dir) == :missing
  end

  # #2416: one verdict per artifact, so the row can say which one is gone.
  test "a dump on disk and its media gone: mixed, and each artifact says its own", %{dir: dir} do
    touch(dir, "db", "kiln-db-20260805-031700.dump")

    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump"),
        artifact(:media, "kiln-media-20260805-031700.tar.gz")
      ])

    assert state(run, dir) == :mixed
    assert artifact_states(run, dir) == [db: :present, media: :missing]
  end

  # Retention ages a stamp's dump and its media separately (#2219).
  test "a pruned dump beside media still on disk: mixed, pruned and present", %{dir: dir} do
    touch(dir, "media", "kiln-media-20260805-031700.tar.gz")

    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump", %{"local" => %{"status" => "pruned"}}),
        artifact(:media, "kiln-media-20260805-031700.tar.gz")
      ])

    assert state(run, dir) == :mixed
    assert artifact_states(run, dir) == [db: :pruned, media: :present]
  end

  test "pruned and off-site artifacts in one run read mixed, not missing (#2416)", %{dir: dir} do
    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump", %{"local" => %{"status" => "pruned"}}),
        artifact(:media, "kiln-media-20260805-031700.tar.gz", %{
          "local" => %{"status" => "ok"},
          "rclone:r" => %{"status" => "ok"}
        })
      ])

    assert state(run, dir) == :mixed
    assert artifact_states(run, dir) == [db: :pruned, media: :off_site_only]
  end

  test "one artifact present, one pruned and one gone out-of-band", %{dir: dir} do
    touch(dir, "db", "kiln-db-20260805-031700.dump")

    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump"),
        artifact(:media, "kiln-media-20260805-031700.part01.tar.gz", %{
          "local" => %{"status" => "pruned"}
        }),
        artifact(:media, "kiln-media-20260805-031700.part02.tar.gz")
      ])

    assert state(run, dir) == :mixed
    assert artifact_states(run, dir) == [db: :present, media: :pruned, media: :missing]
  end

  test "a db/ that can't be listed is unknown, and media is still judged (#2416)", %{dir: dir} do
    touch(dir, "media", "kiln-media-20260805-031700.tar.gz")
    File.rm_rf!(Path.join(dir, "db"))
    File.write!(Path.join(dir, "db"), "")

    run =
      run([
        artifact(:db, "kiln-db-20260805-031700.dump"),
        artifact(:media, "kiln-media-20260805-031700.tar.gz")
      ])

    assert artifact_states(run, dir) == [db: :unknown, media: :present]
    assert state(run([artifact(:db, "kiln-db-20260805-031700.dump")]), dir) == :unknown
  end

  test "a missing db/ is a directory with nothing in it, not unknown", %{dir: dir} do
    File.rm_rf!(Path.join(dir, "db"))
    assert state(run([artifact(:db, "kiln-db-20260805-031700.dump")]), dir) == :missing
  end

  test "pruned when retention marked the local copy", %{dir: dir} do
    run =
      run([artifact(:db, "kiln-db-a.dump", %{"local" => %{"status" => "pruned"}})])

    assert state(run, dir) == :pruned
  end

  test "off-site only when nothing is local and an rclone copy succeeded", %{dir: dir} do
    destinations = %{
      "local" => %{"status" => "ok"},
      "rclone:remote" => %{"status" => "ok"}
    }

    assert state(run([artifact(:db, "a.dump", destinations)]), dir) == :off_site_only

    failed = Map.put(destinations, "rclone:remote", %{"status" => "failed"})
    assert state(run([artifact(:db, "a.dump", failed)]), dir) == :missing
  end

  test "off-site only when a stored destination's copy succeeded (#2220)", %{dir: dir} do
    key = "dest:" <> Ash.UUID.generate()
    destinations = %{"local" => %{"status" => "ok"}, key => %{"status" => "ok"}}

    assert state(run([artifact(:db, "a.dump", destinations)]), dir) == :off_site_only

    for status <- ["failed", "pending", "pruned"] do
      other = Map.put(destinations, key, %{"status" => status})
      assert state(run([artifact(:db, "a.dump", other)]), dir) == :missing
    end
  end

  describe "expired: what cron's prune removed (#2416)" do
    @old "20260701-031700"
    @newer "20260720-031700"

    defp imported(age_days, attrs \\ []) do
      at = DateTime.add(DateTime.utc_now(), -age_days * 86_400, :second)

      run(
        [artifact(:db, "kiln-db-#{@old}.dump")],
        Keyword.merge([origin: :imported, stamp: @old, started_at: at], attrs)
      )
    end

    setup %{dir: dir} do
      touch(dir, "db", "kiln-db-#{@newer}.dump")
      :ok
    end

    test "older than cron's own keep days plus one, with a newer dump: expired", %{dir: dir} do
      assert state(imported(5), dir, cron_keep_days: 3) == :expired
      assert state(imported(3), dir, cron_keep_days: 3) == :missing
      # Cron's window, not the app's 14 days.
      assert state(imported(5), dir, cron_keep_days: 3, app_keep_days: 14) == :expired
    end

    test "without cron's keep days, the app's stands in and only says probably", %{dir: dir} do
      assert state(imported(16), dir) == :probably_expired
      assert state(imported(5), dir) == :missing
    end

    test "finished_at is the age when there is one", %{dir: dir} do
      finished = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      assert state(imported(10, finished_at: finished), dir, cron_keep_days: 3) == :missing
    end

    test "prune keeps the newest complete unit: without a newer one, missing", %{dir: dir} do
      File.rm!(Path.join([dir, "db", "kiln-db-#{@newer}.dump"]))
      assert state(imported(30), dir, cron_keep_days: 3) == :missing

      # A newer dump still being written is not complete, whoever writes it.
      touch(dir, "db", "kiln-db-#{@newer}.dump.48211-2.partial")
      assert state(imported(30), dir, cron_keep_days: 3) == :missing
      touch(dir, "db", "kiln-db-#{@newer}.dump.partial")
      assert state(imported(30), dir, cron_keep_days: 3) == :missing

      # A newer media set does not stand in for a dump.
      touch(dir, "media", "kiln-media-#{@newer}.tar.gz")
      assert state(imported(30), dir, cron_keep_days: 3) == :missing
    end

    test "a media set in parts counts as newer only when complete", %{dir: dir} do
      run =
        run([artifact(:media, "kiln-media-#{@old}.tar.gz")],
          origin: :imported,
          stamp: @old,
          started_at: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
        )

      touch(dir, "media", Artifact.part_name(@newer, 1))
      touch(dir, "media", Artifact.part_name(@newer, 2))
      assert state(run, dir, cron_keep_days: 3) == :missing

      touch(dir, "media", Artifact.sidecar_name(:media, @newer))
      assert state(run, dir, cron_keep_days: 3) == :expired
    end

    test "a recovery point, or a last-good or hold marker in its own directory, pins it",
         %{dir: dir} do
      touch(dir, "media", "kiln-#{@old}.keep")
      assert state(imported(30), dir, cron_keep_days: 3) == :missing
      File.rm!(Path.join([dir, "media", "kiln-#{@old}.keep"]))

      touch(dir, "db", "kiln-#{@old}.good")
      assert state(imported(30), dir, cron_keep_days: 3) == :missing
      File.rm!(Path.join([dir, "db", "kiln-#{@old}.good"]))

      touch(dir, "db", "kiln-#{@old}.hold")
      assert state(imported(30), dir, cron_keep_days: 3) == :missing
      File.rm!(Path.join([dir, "db", "kiln-#{@old}.hold"]))

      # Media's last-good marker keeps media, not this dump.
      touch(dir, "media", "kiln-#{@old}.good")
      assert state(imported(30), dir, cron_keep_days: 3) == :expired
    end

    test "with a marker directory unreadable, a pin can't be ruled out", %{dir: dir} do
      File.rm_rf!(Path.join(dir, "media"))
      File.write!(Path.join(dir, "media"), "")
      assert state(imported(30), dir, cron_keep_days: 3) == :missing
    end

    test "an app-made run is never expired: its prunes are recorded", %{dir: dir} do
      assert state(imported(30, origin: :app), dir, cron_keep_days: 3) == :missing
    end
  end

  test "none for a run with no artifacts", %{dir: dir} do
    assert presence(run([]), dir) == %{state: :none, artifacts: []}
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
      assert state(run([set()]), dir) == :present
    end

    test "one missing part makes the set missing, and names the part (#2416)", %{dir: dir} do
      land_parts(dir, [1, 3])
      assert state(run([set()]), dir) == :missing

      assert [%{kind: :media, state: :missing, parts: 3, gone: [gone]}] =
               presence(run([set()]), dir).artifacts

      assert gone == Artifact.part_name(@stamp, 2)
    end

    test "some parts pruned and the rest on disk is partly pruned", %{dir: dir} do
      land_parts(dir, [3])
      pruned = %{"local" => %{"status" => "pruned"}}
      art = set()
      [one, two, three] = art.parts

      art = %{
        art
        | parts: [
            Map.put(one, "destinations", pruned),
            Map.put(two, "destinations", pruned),
            three
          ]
      }

      assert state(run([art]), dir) == :partly_pruned
    end

    test "parts partly gone, though copied off-site, still say which are gone", %{dir: dir} do
      land_parts(dir, [1])
      remote = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}

      assert [%{state: :missing, gone: gone}] = presence(run([set(remote)]), dir).artifacts
      assert gone == [Artifact.part_name(@stamp, 2), Artifact.part_name(@stamp, 3)]
    end

    test "a sidecar alone is not the artifact", %{dir: dir} do
      touch(dir, "media", Artifact.sidecar_name(:media, @stamp))
      assert state(run([set()]), dir) == :missing
    end

    test "an unrelated sidecar missing does not matter: parts present, no sidecar", %{dir: dir} do
      land_parts(dir, 1..3)
      refute File.exists?(Path.join([dir, "media", Artifact.sidecar_name(:media, @stamp)]))
      assert state(run([set()]), dir) == :present
    end

    test "all parts pruned reads pruned", %{dir: dir} do
      assert state(run([set(%{"local" => %{"status" => "pruned"}})]), dir) == :pruned
    end

    test "parts pruned per part (artifact still ok) read pruned", %{dir: dir} do
      pruned = %{"local" => %{"status" => "pruned"}}

      assert state(run([set(%{"local" => %{"status" => "ok"}}, pruned)]), dir) ==
               :pruned
    end

    test "a part missing but not pruned among pruned ones is missing", %{dir: dir} do
      art = set(%{"local" => %{"status" => "ok"}}, %{"local" => %{"status" => "pruned"}})
      [first | rest] = art.parts
      first = Map.put(first, "destinations", %{"local" => %{"status" => "ok"}})
      assert state(run([%{art | parts: [first | rest]}]), dir) == :missing
    end

    test "all parts gone but off-site everywhere reads off-site only", %{dir: dir} do
      remote = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}
      assert state(run([set(remote)]), dir) == :off_site_only
    end

    test "one part never reached off-site is missing, not off-site only", %{dir: dir} do
      art = set(%{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "failed"}})
      assert state(run([art]), dir) == :missing

      ok = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}
      failed = %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "failed"}}
      art = set(%{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}, ok)
      [one, two, three] = art.parts
      art = %{art | parts: [one, Map.put(two, "destinations", failed), three]}
      assert state(run([art]), dir) == :missing
    end

    test "a symlink named like a part is not the part", %{dir: dir} do
      land_parts(dir, [1, 2])
      target = Path.join(dir, "elsewhere")
      File.write!(target, "x")
      File.ln_s!(target, Path.join([dir, "media", Artifact.part_name(@stamp, 3)]))
      assert state(run([set()]), dir) == :missing
    end

    test "db plus a part set: present only when both are", %{dir: dir} do
      land_parts(dir, 1..3)
      db = artifact(:db, "kiln-db-#{@stamp}.dump")
      assert state(run([db, set()]), dir) == :mixed
      assert artifact_states(run([db, set()]), dir) == [db: :missing, media: :present]
      touch(dir, "db", "kiln-db-#{@stamp}.dump")
      assert state(run([db, set()]), dir) == :present
    end
  end
end
