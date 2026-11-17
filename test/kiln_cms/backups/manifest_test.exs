defmodule KilnCMS.Backups.ManifestTest do
  # Pure file I/O in a private tmp dir.
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.{Artifact, Manifest}

  @hex String.duplicate("cd", 32)

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_manifest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A manifest exactly as the writer produced it before #2218: four keys per
  # artifact. A reader change must keep reading this identically.
  @pre_change """
  {
    "version": 1,
    "started_at": "2026-08-05T03:17:00Z",
    "finished_at": "2026-08-05T03:18:42Z",
    "trigger": "cron",
    "ok": true,
    "artifacts": [
      {"kind": "db", "path": "db/kiln-db-20260805-031700.dump", "bytes": 48317216, "verified": true},
      {"kind": "media", "path": "media/kiln-media-20260805-031700.tar.gz", "bytes": 1000, "verified": false}
    ],
    "offsite": "r2:kiln-backups",
    "keep_days": 14,
    "error": null
  }
  """

  test "a pre-#2218 manifest reads identically: no new keys appear", %{dir: dir} do
    File.write!(Manifest.path(dir), @pre_change)
    manifest = Manifest.read(dir)

    assert manifest.version == 1

    assert manifest.artifacts == [
             %{
               kind: "db",
               path: "db/kiln-db-20260805-031700.dump",
               bytes: 48_317_216,
               verified: true
             },
             %{
               kind: "media",
               path: "media/kiln-media-20260805-031700.tar.gz",
               bytes: 1000,
               verified: false
             }
           ]

    assert Manifest.total_bytes(manifest) == 48_318_216
    refute Manifest.verified?(manifest)
  end

  test "writing entries without the new keys emits the old four-key shape", %{dir: dir} do
    entry = %{kind: "db", path: "db/a.dump", bytes: 1, verified: true}
    :ok = Manifest.write(dir, %Manifest{artifacts: [entry]})

    assert [written] =
             dir |> Manifest.path() |> File.read!() |> Jason.decode!() |> Map.fetch!("artifacts")

    assert Map.keys(written) |> Enum.sort() == ["bytes", "kind", "path", "verified"]
  end

  test "sha256, part and parts_total round-trip on flat entries in part order", %{dir: dir} do
    artifacts =
      for n <- 1..3 do
        %{
          kind: "media",
          path: "media/kiln-media-20260805-031700.part0#{n}.tar.gz",
          bytes: 100 * n,
          verified: true,
          sha256: @hex,
          part: n,
          parts_total: 3
        }
      end

    :ok = Manifest.write(dir, %Manifest{ok: true, version: 1, artifacts: artifacts})

    json = dir |> Manifest.path() |> File.read!() |> Jason.decode!()
    assert json["version"] == 1
    assert [%{"sha256" => @hex, "part" => 1, "parts_total" => 3} | _] = json["artifacts"]

    read = Manifest.read(dir)
    assert read.artifacts == artifacts
    assert Manifest.total_bytes(read) == 600
    assert Manifest.verified?(read)
  end

  test "one unverified part makes the manifest unverified", %{dir: dir} do
    artifacts = [
      %{kind: "media", path: "media/a.part01.tar.gz", bytes: 1, verified: true, part: 1},
      %{kind: "media", path: "media/a.part02.tar.gz", bytes: 1, verified: false, part: 2}
    ]

    :ok = Manifest.write(dir, %Manifest{artifacts: artifacts})
    refute dir |> Manifest.read() |> Manifest.verified?()
  end

  test "malformed new keys are dropped, not trusted", %{dir: dir} do
    File.write!(Manifest.path(dir), ~s({"artifacts": [
      {"kind": "db", "path": "db/a.dump", "bytes": 1, "verified": true,
       "sha256": "short", "part": 0, "parts_total": "x"}]}))

    assert [entry] = Manifest.read(dir).artifacts
    assert Map.keys(entry) |> Enum.sort() == [:bytes, :kind, :path, :verified]
  end

  test "keep_days is a whole number of days, 1 or more, or absent (#2727)", %{dir: dir} do
    # The type says `pos_integer | nil`; a hand-edited or pre-#2727 cron
    # manifest could say 0 or -1, which no retention ever meant.
    for {raw, expected} <- [{14, 14}, {1, 1}, {0, nil}, {-1, nil}, {"14", nil}, {1.5, nil}] do
      File.write!(Manifest.path(dir), Jason.encode!(%{"ok" => true, "keep_days" => raw}))
      assert Manifest.read(dir).keep_days == expected, inspect(raw)
    end
  end

  describe "stamp" do
    test "round-trips, and a manifest without it reads nil and writes no key", %{dir: dir} do
      :ok = Manifest.write(dir, %Manifest{stamp: "20261111-145226"})
      assert Manifest.read(dir).stamp == "20261111-145226"

      :ok = Manifest.write(dir, %Manifest{})
      refute dir |> Manifest.path() |> File.read!() |> Jason.decode!() |> Map.has_key?("stamp")

      File.write!(Manifest.path(dir), @pre_change)
      assert Manifest.read(dir).stamp == nil
    end

    test "one that is not a real instant reads as absent", %{dir: dir} do
      for bad <- ["20261340-996199", "../../etc", 20_261_111, ""] do
        File.write!(Manifest.path(dir), Jason.encode!(%{"stamp" => bad}))
        assert Manifest.read(dir).stamp == nil
      end
    end
  end

  describe "tagged writes (#2818)" do
    test "a refused rename leaves the manifest standing and no temporary file", %{dir: dir} do
      :ok =
        Manifest.write(dir, %Manifest{finished_at: DateTime.utc_now(), trigger: "cron", ok: true})

      before = File.read!(Manifest.path(dir))
      parent = self()

      refuse = fn from, _to ->
        send(parent, {:tmp, from})
        {:error, :superseded}
      end

      failed = %Manifest{finished_at: DateTime.utc_now(), trigger: "manual", ok: false}
      assert {:error, :superseded} = Manifest.write(dir, failed, tag: "48211-2", rename: refuse)

      assert_received {:tmp, tmp}
      assert tmp == Manifest.path(dir) <> ".48211-2.partial"
      assert File.read!(Manifest.path(dir)) == before
      refute File.exists?(tmp)
    end

    # A fenced rename raises when its lock query times out: the temporary file
    # must not outlive it at the directory's root.
    test "a rename that raises leaves no temporary file, and the raise goes on", %{dir: dir} do
      parent = self()

      raising = fn from, _to ->
        send(parent, {:tmp, from})
        raise DBConnection.ConnectionError, "timed out"
      end

      manifest = %Manifest{finished_at: DateTime.utc_now(), trigger: "manual", ok: true}

      assert_raise DBConnection.ConnectionError, fn ->
        Manifest.write(dir, manifest, tag: "48211-2", rename: raising)
      end

      assert_received {:tmp, tmp}
      refute File.exists?(tmp)
      refute File.exists?(Manifest.path(dir))
    end

    test "a tagged write lands through its rename function", %{dir: dir} do
      manifest = %Manifest{finished_at: DateTime.utc_now(), trigger: "manual", ok: true}
      assert :ok = Manifest.write(dir, manifest, tag: 5, rename: &File.rename/2)
      assert %Manifest{trigger: "manual", ok: true} = Manifest.read(dir)
      assert Path.wildcard(Path.join(dir, "*.partial")) == []
    end
  end

  describe "untagged writes get a temporary name of their own (#2832)" do
    test "a random digits tag, different on every write", %{dir: dir} do
      parent = self()

      spy = fn from, to ->
        send(parent, {:tmp, from})
        File.rename(from, to)
      end

      for _ <- 1..2, do: assert(:ok = Manifest.write(dir, %Manifest{ok: true}, rename: spy))

      assert_received {:tmp, first}
      assert_received {:tmp, second}
      assert first != second

      for tmp <- [first, second] do
        assert Path.dirname(tmp) == dir
        assert [_, tag] = Regex.run(~r/\Amanifest\.json\.(\d+)\.partial\z/, Path.basename(tmp))
        assert Artifact.tag?(tag)
      end

      assert Path.wildcard(Path.join(dir, "*.partial")) == []
    end

    # The untagged name is an older backup.sh's, possibly mid-write.
    test "never touches manifest.json.partial, whether the write lands or fails", %{dir: dir} do
      cron = Manifest.path(dir) <> ".partial"
      File.write!(cron, "cron, half written")

      assert :ok = Manifest.write(dir, %Manifest{ok: true})

      assert {:error, :x} =
               Manifest.write(dir, %Manifest{ok: false}, rename: fn _, _ -> {:error, :x} end)

      assert File.read!(cron) == "cron, half written"
      assert Manifest.read(dir).ok == true
    end

    test "a writer paused before its rename keeps its own file while another publishes",
         %{dir: dir} do
      parent = self()

      paused = fn from, to ->
        send(parent, {:paused, self(), from})

        receive do
          :go -> File.rename(from, to)
        end
      end

      a = %Manifest{trigger: "cron", ok: true, keep_days: 1}
      b = %Manifest{trigger: "manual", ok: false, keep_days: 2}

      task = Task.async(fn -> Manifest.write(dir, a, rename: paused) end)
      assert_receive {:paused, pid, a_tmp}, 5_000
      a_json = File.read!(a_tmp)

      assert :ok = Manifest.write(dir, b)
      assert %Manifest{trigger: "manual"} = Manifest.read(dir)
      assert File.read!(a_tmp) == a_json

      send(pid, :go)
      assert :ok = Task.await(task)
      assert %Manifest{trigger: "cron", ok: true, keep_days: 1} = Manifest.read(dir)
      assert Path.wildcard(Path.join(dir, "*.partial")) == []
    end

    test "many writers racing: every read is one writer's complete manifest", %{dir: dir} do
      written = for n <- 1..50, do: %Manifest{trigger: "w#{n}", ok: rem(n, 2) == 0, keep_days: n}

      # Each one's exact bytes, written alone.
      expected =
        MapSet.new(written, fn m ->
          alone = Path.join(dir, "alone")
          :ok = Manifest.write(alone, m)
          File.read!(Manifest.path(alone))
        end)

      path = Manifest.path(dir)
      :ok = Manifest.write(dir, hd(written))

      reader = Task.async(fn -> for _ <- 1..2_000, do: File.read(path) end)

      results =
        written
        |> Enum.map(fn m -> Task.async(fn -> Manifest.write(dir, m) end) end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &(&1 == :ok))

      reads = for {:ok, raw} <- Task.await(reader, 30_000), do: raw
      assert reads != []
      for raw <- reads, do: assert(MapSet.member?(expected, raw), raw)
      assert MapSet.member?(expected, File.read!(path))
      assert Path.wildcard(Path.join(dir, "*.partial")) == []
    end
  end
end
