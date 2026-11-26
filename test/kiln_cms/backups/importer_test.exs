defmodule KilnCMS.Backups.ImporterTest do
  @moduledoc """
  Cron-made backups become history (#2217): the file scan is the truth, the
  manifest only enriches, and nothing the application already recorded is touched.
  """
  # `async: false`: it points `:kiln_cms, KilnCMS.Backups, :dir` at a temp
  # directory (`Application.put_env` is VM-global).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Importer, Manifest}

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_imp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(original, dir: dir))

    on_exit(fn ->
      # An `eacces` test leaves a 0000 directory behind.
      File.chmod(Path.join(dir, "db"), 0o700)
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
  end

  # A file named the way `backup.sh` names it, `age` minutes old.
  defp put(dir, kind, stamp, opts \\ []) do
    {sub, ext} = if kind == :db, do: {"db", "dump"}, else: {"media", "tar.gz"}
    name = "kiln-#{kind}-#{stamp}.#{ext}#{opts[:suffix]}"
    path = Path.join([dir, sub, name])
    File.write!(path, String.duplicate("x", Keyword.get(opts, :size, 100)))
    File.touch!(path, System.os_time(:second) - Keyword.get(opts, :age, 60) * 60)
    path
  end

  defp run!(stamp), do: Backups.get_run_by_stamp!(stamp, actor: Backups.system())
  defp all_runs, do: Backups.list_runs!(actor: Backups.system())

  defp manifest!(dir, attrs) do
    :ok = Manifest.write(dir, struct!(Manifest, attrs))
  end

  describe "a cron backup with its manifest" do
    test "is enriched from the manifest", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      put(dir, :media, "20260801-031700", age: 0)

      manifest!(dir,
        trigger: "cron-nightly",
        ok: true,
        started_at: ~U[2026-08-01 03:17:00Z],
        finished_at: ~U[2026-08-01 03:18:42Z],
        offsite: "r2:kiln-backups",
        artifacts: [
          %{kind: "db", path: "db/kiln-db-20260801-031700.dump", bytes: 5, verified: true},
          %{
            kind: "media",
            path: "media/kiln-media-20260801-031700.tar.gz",
            bytes: 5,
            verified: true
          }
        ]
      )

      # The newest file is brand new, but the manifest speaks for the stamp, so
      # there is no settle wait.
      assert {:ok, %{imported: 1, pending: 0}} = Importer.run()

      run = run!("20260801-031700")
      assert run.origin == :imported
      assert run.status == :succeeded
      assert run.trigger == "cron-nightly"
      assert run.started_at == ~U[2026-08-01 03:17:00.000000Z]
      assert run.finished_at == ~U[2026-08-01 03:18:42.000000Z]
      assert run.components == [:db, :media]

      assert [%{kind: :db, verified: true, bytes: 100} = db, %{kind: :media}] = run.artifacts
      assert db.destinations["rclone:r2:kiln-backups"]["status"] == "ok"
      assert db.destinations["local"]["status"] == "ok"
    end

    test "a failed manifest with stamped artifacts marks the run failed, secrets redacted",
         %{dir: dir} do
      put(dir, :db, "20260801-031700")

      manifest!(dir,
        trigger: String.duplicate("t", 200),
        ok: false,
        started_at: ~U[2026-08-01 03:17:00Z],
        error: "media failed postgres://u:pw12345@h/db " <> String.duplicate("e", 9_000),
        artifacts: [
          %{kind: "db", path: "db/kiln-db-20260801-031700.dump", bytes: 5, verified: true}
        ]
      )

      assert {:ok, %{imported: 1}} = Importer.run()

      run = run!("20260801-031700")
      assert run.status == :failed
      assert String.length(run.trigger) == 64
      assert String.length(run.error) <= 4_000
      refute run.error =~ "pw12345"
    end

    test "a failed manifest's remote does not mark its files as copied off-site (#2218)",
         %{dir: dir} do
      # An older backup.sh named the remote in its failure manifests too.
      put(dir, :db, "20260801-031700")

      manifest!(dir,
        ok: false,
        started_at: ~U[2026-08-01 03:17:00Z],
        error: "REFUSING off-site copy of kiln-media-20260801-031700.part02.tar.gz",
        offsite: "r2:kiln",
        artifacts: [
          %{kind: "db", path: "db/kiln-db-20260801-031700.dump", bytes: 5, verified: true}
        ]
      )

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :failed, artifacts: [db]} = run!("20260801-031700")
      assert Map.keys(db.destinations) == ["local"]
    end

    test "a succeeded manifest's remote does mark its files as copied off-site", %{dir: dir} do
      put(dir, :db, "20260801-031700")

      manifest!(dir,
        ok: true,
        started_at: ~U[2026-08-01 03:17:00Z],
        offsite: "r2:kiln",
        artifacts: [
          %{kind: "db", path: "db/kiln-db-20260801-031700.dump", bytes: 5, verified: true}
        ]
      )

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{artifacts: [db]} = run = run!("20260801-031700")
      assert %{"status" => "ok"} = db.destinations["rclone:r2:kiln"]

      # #2220: a cron run has no Run-level destinations and no off-site
      # outcome; History reads its artifacts' maps, as before.
      assert run.destinations == []
      assert run.offsite_status == nil
    end

    test "a failed manifest with no files becomes a failed run keyed by its start", %{dir: dir} do
      manifest!(dir,
        trigger: "cron",
        ok: false,
        started_at: ~U[2026-08-02 03:00:05Z],
        finished_at: ~U[2026-08-02 03:00:09Z],
        error: "pg_dump: connection refused",
        artifacts: []
      )

      assert {:ok, %{imported: 1}} = Importer.run()
      assert {:ok, %{imported: 0}} = Importer.run()

      assert %{status: :failed, error: "pg_dump: connection refused", artifacts: []} =
               run!("20260802-030005")
    end

    test "a failed manifest is keyed by its stamp, not the second of its start", %{dir: dir} do
      # The application's run: its stamp was taken at lease time, a second
      # before the manifest's `started_at` (CI saw `…145226` vs `…145227`).
      run =
        Backups.start_run!(%{stamp: "20261111-145226", trigger: "manual"},
          actor: Backups.system()
        )

      Backups.fail_run!(run, %{error: "pg_dump: connection refused"}, actor: Backups.system())

      manifest!(dir,
        stamp: "20261111-145226",
        trigger: "manual",
        ok: false,
        started_at: ~U[2026-11-11 14:52:27.412000Z],
        finished_at: ~U[2026-11-11 14:52:29Z],
        error: "pg_dump: connection refused",
        artifacts: []
      )

      assert {:ok, %{imported: 0}} = Importer.run()
      assert [%{id: id}] = all_runs()
      assert id == run.id
    end

    test "the application's failure manifest names its run's stamp, so no second run appears",
         %{dir: dir} do
      # The lease took the stamp at second X; the chain recorded its start at
      # X+1. Written through the application's own failure path.
      stamp = "20261111-145226"
      chain = Ecto.UUID.generate()

      Backups.start_run!(%{stamp: stamp, trigger: "manual", chain_id: chain},
        actor: Backups.system()
      )

      {:ok, dir_id} = KilnCMS.Backups.DirId.local(dir)
      work_dir = KilnCMS.Backups.WorkState.path(dir, stamp)
      File.mkdir_p!(work_dir)

      :ok =
        KilnCMS.Backups.WorkState.write(
          work_dir,
          KilnCMS.Backups.WorkState.new(stamp, %{
            "chain" => chain,
            "trigger" => "manual",
            "started_at" => "2026-11-11T14:52:27.412000Z"
          })
        )

      # An older backup.sh mid-write: the interruption's manifest goes through
      # a name of its own (#2832).
      cron = Manifest.path(dir) <> ".partial"
      File.write!(cron, "cron, half written")

      assert :ok = KilnCMS.Backups.Steps.interrupt(stamp, chain, dir_id, "Interrupted")
      assert %Manifest{ok: false, stamp: ^stamp} = Manifest.read(dir)
      assert File.read!(cron) == "cron, half written"
      File.rm!(cron)

      assert {:ok, %{imported: 0}} = Importer.run()
      assert [%{stamp: ^stamp, status: :failed}] = all_runs()
    end

    test "a failed manifest with no files and no stamp is keyed by its start", %{dir: dir} do
      File.write!(
        Manifest.path(dir),
        Jason.encode!(%{
          "version" => 1,
          "started_at" => "2026-08-02T03:00:05Z",
          "ok" => false,
          "error" => "boom",
          "artifacts" => []
        })
      )

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :failed} = run!("20260802-030005")
    end

    test "a manifest for another stamp does not enrich this one", %{dir: dir} do
      put(dir, :db, "20260701-000000")
      put(dir, :db, "20260801-031700")

      manifest!(dir,
        trigger: "special",
        ok: true,
        started_at: ~U[2026-08-01 03:17:00Z],
        artifacts: [
          %{kind: "db", path: "db/kiln-db-20260801-031700.dump", bytes: 5, verified: true}
        ]
      )

      assert {:ok, %{imported: 2}} = Importer.run()
      assert run!("20260701-000000").trigger == "cron"
      assert run!("20260801-031700").trigger == "special"
    end

    test "a garbage manifest is ignored; the files still import", %{dir: dir} do
      File.write!(Manifest.path(dir), "{not json")
      put(dir, :db, "20260801-031700")

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{trigger: "cron", status: :succeeded} = run!("20260801-031700")
    end
  end

  describe "cron's keep_days on the imported run (#3113)" do
    defp covering(stamp, attrs) do
      Keyword.merge(
        [
          trigger: "cron",
          ok: true,
          started_at: ~U[2026-08-01 03:17:00Z],
          finished_at: ~U[2026-08-01 03:18:42Z],
          keep_days: 7,
          artifacts: [
            %{kind: "db", path: "db/kiln-db-#{stamp}.dump", bytes: 5, verified: true}
          ]
        ],
        attrs
      )
    end

    test "a covering manifest of cron's records its keep_days", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      manifest!(dir, covering("20260801-031700", []))

      assert {:ok, %{imported: 1}} = Importer.run()
      assert run!("20260801-031700").keep_days == 7
    end

    test "a covering manifest of Kiln's (components set) records none", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      manifest!(dir, covering("20260801-031700", components: ["db"]))

      assert {:ok, %{imported: 1}} = Importer.run()
      assert run!("20260801-031700").keep_days == nil
    end

    test "a failed cron manifest records none: its prune may not have run", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      manifest!(dir, covering("20260801-031700", ok: false, error: "media failed"))

      assert {:ok, %{imported: 1}} = Importer.run()
      assert run!("20260801-031700").keep_days == nil
    end

    test "a stamp the manifest doesn't cover records none", %{dir: dir} do
      put(dir, :db, "20260731-031700", age: 60)
      put(dir, :db, "20260801-031700")
      manifest!(dir, covering("20260801-031700", []))

      assert {:ok, %{imported: 2}} = Importer.run()
      assert run!("20260731-031700").keep_days == nil
      assert run!("20260801-031700").keep_days == 7
    end

    test "no manifest records none", %{dir: dir} do
      put(dir, :db, "20260801-031700")

      assert {:ok, %{imported: 1}} = Importer.run()
      assert run!("20260801-031700").keep_days == nil
    end

    test "a row imported before is never updated with it", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      assert {:ok, %{imported: 1}} = Importer.run()
      assert run!("20260801-031700").keep_days == nil

      manifest!(dir, covering("20260801-031700", []))
      assert {:ok, %{imported: 0}} = Importer.run()
      assert run!("20260801-031700").keep_days == nil
    end
  end

  describe "files only" do
    test "become a succeeded, unverified, imported run", %{dir: dir} do
      # Both mtimes are set here, not read from two `put/4` clock reads that
      # can land a second apart (#3184); `finished_at` is the newest one.
      newest = System.os_time(:second) - 60 * 60
      dir |> put(:db, "20260801-031700") |> File.touch!(newest - 30)
      dir |> put(:media, "20260801-031700") |> File.touch!(newest)

      assert {:ok, %{imported: 1}} = Importer.run()

      run = run!("20260801-031700")
      assert run.origin == :imported
      assert run.status == :succeeded
      assert run.trigger == "cron"
      assert run.started_at == ~U[2026-08-01 03:17:00.000000Z]
      assert DateTime.to_unix(run.finished_at) == newest
      assert run.components == [:db, :media]
      assert Enum.all?(run.artifacts, &(&1.verified == false and is_nil(&1.sha256)))
    end

    test "a db-only stamp is a db-only run", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{components: [:db], artifacts: [%{kind: :db}]} = run!("20260801-031700")
    end

    test "a zero-byte file fails the run", %{dir: dir} do
      put(dir, :db, "20260801-031700", size: 0)
      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :failed, error: "empty artifact"} = run!("20260801-031700")
    end

    test "importing twice leaves the same rows", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      put(dir, :db, "20260802-031700")

      assert {:ok, %{imported: 2}} = Importer.run()
      before = all_runs() |> Enum.map(&{&1.id, &1.updated_at}) |> Enum.sort()

      assert {:ok, %{imported: 0, pending: 0}} = Importer.run()
      assert before == all_runs() |> Enum.map(&{&1.id, &1.updated_at}) |> Enum.sort()
    end
  end

  describe "what is not an artifact" do
    test "a .partial alone is pending, not imported (#2478)", %{dir: dir} do
      put(dir, :db, "20260801-031700", suffix: ".partial")
      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
      assert all_runs() == []
    end

    test "a .partial alone with an impossible stamp is ignored, and not warned about",
         %{dir: dir} do
      put(dir, :db, "20261399-031700", suffix: ".partial", age: 600)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{imported: 0, pending: 0, skipped: 0}} = Importer.run()
        end)

      refute log =~ "20261399-031700"
      assert all_runs() == []
    end

    test "a .partial beside a settled file holds the stamp back until it is gone", %{dir: dir} do
      put(dir, :db, "20260801-031700")
      partial = put(dir, :media, "20260801-031700", suffix: ".partial")

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
      assert all_runs() == []

      File.rm!(partial)
      assert {:ok, %{imported: 1}} = Importer.run()
    end

    test "a directory or symlink named like an artifact is not one", %{dir: dir} do
      File.mkdir_p!(Path.join([dir, "db", "kiln-db-20260801-031700.dump"]))
      File.write!(Path.join(dir, "target"), "x")

      File.ln_s!(
        Path.join(dir, "target"),
        Path.join([dir, "media", "kiln-media-20260802-031700.tar.gz"])
      )

      # A manifest speaking for both stamps lifts the settle wait, so only the
      # file-type check keeps these out.
      manifest!(dir,
        ok: true,
        started_at: ~U[2026-08-02 03:17:00Z],
        artifacts: [
          %{kind: "db", path: "db/kiln-db-20260801-031700.dump", bytes: 5, verified: true},
          %{
            kind: "media",
            path: "media/kiln-media-20260802-031700.tar.gz",
            bytes: 5,
            verified: true
          }
        ]
      )

      assert {:ok, %{imported: 0}} = Importer.run()
      assert all_runs() == []
    end

    # Where a backup step moves a file aside before deleting it (#2818).
    test "a .kiln-trash directory, and the artifacts in it, are not imported", %{dir: dir} do
      for {sub, name} <- [
            {"db", "kiln-db-20260801-031700.dump"},
            {"media", Artifact.part_name("20260801-031700", 1)}
          ] do
        entry = Path.join([dir, sub, ".kiln-trash", "20260801-031700.7-1.#{sub}"])
        File.mkdir_p!(entry)
        File.write!(Path.join(entry, name), "x")
        File.touch!(Path.join(entry, name), System.os_time(:second) - 7200)
      end

      assert {:ok, %{imported: 0, pending: 0}} = Importer.run()
      assert all_runs() == []
    end

    test "a kind/extension mismatch and stray files are ignored", %{dir: dir} do
      File.write!(Path.join([dir, "db", "kiln-db-20260801-031700.tar.gz"]), "x")
      File.write!(Path.join([dir, "db", "notes.txt"]), "x")
      assert {:ok, %{imported: 0}} = Importer.run()
    end

    test "a last-good marker is never imported (#2219)", %{dir: dir} do
      stamp = "20260801-031700"

      for sub <- ["db", "media"] do
        path = Path.join([dir, sub, Artifact.good_name(stamp)])
        File.write!(path, "")
        File.touch!(path, System.os_time(:second) - 3600)
      end

      assert {:ok, %{imported: 0, pending: 0, skipped: 0}} = Importer.run()
      assert all_runs() == []
    end

    test "a hold marker is never imported (#2219)", %{dir: dir} do
      stamp = "20260801-031700"

      for sub <- ["db", "media"] do
        path = Path.join([dir, sub, Artifact.hold_name(stamp)])
        File.write!(path, "")
        File.touch!(path, System.os_time(:second) - 3600)
      end

      assert {:ok, %{imported: 0, pending: 0, skipped: 0}} = Importer.run()
      assert all_runs() == []
    end

    test "an impossible stamp is skipped with a count, never a crash", %{dir: dir} do
      put(dir, :db, "20261340-996199")
      put(dir, :db, "20260801-031700")

      assert {:ok, %{imported: 1, skipped: 1}} = Importer.run()
      assert [%{stamp: "20260801-031700"}] = all_runs()
    end
  end

  describe "the settle window" do
    test "a brand-new file with no manifest waits", %{dir: dir} do
      put(dir, :db, "20260801-031700", age: 1)

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
      assert all_runs() == []
    end

    test "is judged on the newest file of the stamp", %{dir: dir} do
      put(dir, :db, "20260801-031700", age: 120)
      put(dir, :media, "20260801-031700", age: 1)

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
    end
  end

  describe "runs the application owns" do
    test "a running run for the same stamp is not clobbered", %{dir: dir} do
      run =
        Backups.start_run!(%{stamp: "20260801-031700", trigger: "manual"},
          actor: Backups.system()
        )

      put(dir, :db, "20260801-031700")

      assert {:ok, %{imported: 0}} = Importer.run()

      stored = run!("20260801-031700")
      assert stored.id == run.id
      assert stored.status == :running
      assert stored.origin == :app
      assert stored.trigger == "manual"
      assert stored.artifacts == []
    end

    test "two concurrent imports write one row per stamp", %{dir: dir} do
      for n <- 1..20, do: put(dir, :db, "20260801-03#{String.pad_leading("#{n}", 4, "0")}")

      results =
        1..2
        |> Enum.map(fn _ -> Task.async(&Importer.run/0) end)
        |> Task.await_many(30_000)

      assert [{:ok, _}, {:ok, _}] = results
      assert length(all_runs()) == 20
    end
  end

  describe "media part sets (#2218)" do
    @set "20260801-031700"
    @hex_a String.duplicate("a", 64)
    @hex_b String.duplicate("b", 64)

    defp put_part(dir, stamp, n, opts \\ []) do
      name = Artifact.part_name(stamp, n) <> (opts[:suffix] || "")
      path = Path.join([dir, "media", name])
      File.write!(path, String.duplicate("x", Keyword.get(opts, :size, 100)))
      File.touch!(path, System.os_time(:second) - Keyword.get(opts, :age, 60) * 60)
      path
    end

    defp put_sidecar(dir, kind, stamp, contents, age \\ 60) do
      sub = Artifact.subdir(kind)
      path = Path.join([dir, sub, Artifact.sidecar_name(kind, stamp)])
      File.write!(path, contents)
      File.touch!(path, System.os_time(:second) - age * 60)
      path
    end

    # The sidecar every finished part set is written with.
    defp put_set_sidecar(dir, stamp, parts) do
      put_sidecar(
        dir,
        :media,
        stamp,
        Enum.map_join(parts, &"#{@hex_a}  #{Artifact.part_name(stamp, &1)}\n")
      )
    end

    test "the parts of a stamp import as ONE media artifact, in numeric order", %{dir: dir} do
      # past part99, where lexicographic order is wrong
      for n <- [100, 2, 1, 99, 3], do: put_part(dir, @set, n, size: n)
      for n <- 4..98, do: put_part(dir, @set, n, size: n)
      put_set_sidecar(dir, @set, 1..100)

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :succeeded, components: [:media], artifacts: [artifact]} = run!(@set)
      assert artifact.name == "kiln-media-#{@set}"
      assert artifact.kind == :media
      assert artifact.verified == false
      assert artifact.sha256 == nil
      assert artifact.bytes == Enum.sum(1..100)
      assert length(artifact.parts) == 100
      assert List.first(artifact.parts)["name"] == Artifact.part_name(@set, 1)
      assert List.last(artifact.parts)["name"] == Artifact.part_name(@set, 100)
      assert Artifact.files(artifact) == Enum.map(1..100, &Artifact.part_name(@set, &1))
    end

    test "a gap fails the run, naming the part that is missing", %{dir: dir} do
      for n <- [1, 2, 4], do: put_part(dir, @set, n)

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :failed, error: "incomplete media set: missing part03"} = run!(@set)
      # what is on disk is still shown
      assert [%{parts: [_, _, _]}] = run!(@set).artifacts
    end

    test "a set without its first part is incomplete too", %{dir: dir} do
      for n <- [2, 3], do: put_part(dir, @set, n)
      assert {:ok, _} = Importer.run()
      assert %{status: :failed, error: "incomplete media set: missing part01"} = run!(@set)
    end

    test "a far-away part number does not cost a loop over every number", %{dir: dir} do
      put_part(dir, @set, 1)
      put_part(dir, @set, 99_999_999)

      assert {:ok, _} = Importer.run()
      assert %{status: :failed, error: "incomplete media set: missing part02, " <> _} = run!(@set)
    end

    test "a legacy single archive beside parts is an ambiguous, failed set", %{dir: dir} do
      put(dir, :media, @set)
      for n <- [1, 2], do: put_part(dir, @set, n)

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :failed, error: "ambiguous media set: " <> _, artifacts: artifacts} =
               run!(@set)

      assert length(artifacts) == 2
    end

    test "a legacy single-file archive imports as before", %{dir: dir} do
      put(dir, :media, @set)
      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :succeeded, artifacts: [artifact]} = run!(@set)
      assert artifact.name == "kiln-media-#{@set}.tar.gz"
      assert artifact.parts == []
    end

    test "a .partNN partial holds the stamp's settle window", %{dir: dir} do
      for n <- [1, 2], do: put_part(dir, @set, n)
      partial = put_part(dir, @set, 3, suffix: ".partial")

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
      assert all_runs() == []

      File.rm!(partial)
      put_part(dir, @set, 3)
      put_set_sidecar(dir, @set, 1..3)
      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :succeeded} = run!(@set)
    end

    test "a sidecar being written holds the stamp too", %{dir: dir} do
      put(dir, :db, @set)
      sidecar = put_sidecar(dir, :db, @set, "x")
      File.rename!(sidecar, sidecar <> ".partial")

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
    end

    test "mixed db and parts under one stamp are one run with both artifacts", %{dir: dir} do
      put(dir, :db, @set)
      for n <- [1, 2, 3], do: put_part(dir, @set, n)
      put_set_sidecar(dir, @set, 1..3)

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :succeeded, components: [:db, :media], artifacts: [db, media]} =
               run!(@set)

      assert db.kind == :db
      assert media.name == "kiln-media-#{@set}"
      assert length(media.parts) == 3
    end

    test "contiguous parts with no sidecar (a killed run, its marker swept) fail the run",
         %{dir: dir} do
      put(dir, :db, @set)
      for n <- [1, 2], do: put_part(dir, @set, n, age: 90)

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :failed, error: "incomplete media set: parts but no sidecar"} =
               run!(@set)

      # what is on disk is still shown
      assert [%{kind: :db}, %{parts: [_, _]}] = run!(@set).artifacts
    end

    test "a manifest saying the parts verified does not stand in for the sidecar", %{dir: dir} do
      for n <- [1, 2], do: put_part(dir, @set, n)

      manifest!(dir,
        ok: true,
        started_at: ~U[2026-08-01 03:17:00Z],
        finished_at: ~U[2026-08-01 03:18:42Z],
        artifacts:
          for n <- [1, 2] do
            %{
              kind: "media",
              path: "media/#{Artifact.part_name(@set, n)}",
              bytes: 100,
              verified: true,
              sha256: @hex_a,
              part: n,
              parts_total: 2
            }
          end
      )

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :failed, error: "incomplete media set: parts but no sidecar"} =
               run!(@set)
    end

    test "a legacy single archive without a sidecar still succeeds", %{dir: dir} do
      put(dir, :db, @set)
      put(dir, :media, @set)

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :succeeded} = run!(@set)
    end

    test "a sidecar alone is not an artifact and makes no run", %{dir: dir} do
      put_sidecar(dir, :media, @set, "#{@hex_a}  #{Artifact.part_name(@set, 1)}\n")
      assert {:ok, %{imported: 0, pending: 0, skipped: 0}} = Importer.run()
      assert all_runs() == []
    end

    test "a sidecar supplies per-part sha256, and the run stays unverified", %{dir: dir} do
      for n <- [1, 2], do: put_part(dir, @set, n)

      put_sidecar(
        dir,
        :media,
        @set,
        "#{@hex_a}  #{Artifact.part_name(@set, 1)}\n#{@hex_b}  #{Artifact.part_name(@set, 2)}\n"
      )

      put(dir, :db, @set)

      :ok =
        Checksum.write_sidecar(Path.join([dir, "db", Artifact.sidecar_name(:db, @set)]), [
          {"kiln-db-#{@set}.dump", @hex_b}
        ])

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{artifacts: [db, media]} = run!(@set)
      assert db.sha256 == @hex_b
      assert db.verified == false
      assert [%{"sha256" => @hex_a}, %{"sha256" => @hex_b}] = media.parts
      assert media.verified == false
    end

    test "a malformed sidecar is ignored with a warning and never crashes", %{dir: dir} do
      for n <- [1, 2], do: put_part(dir, @set, n)
      put_sidecar(dir, :media, @set, "not a checksum line\n\0\xff")

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :succeeded, artifacts: [media]} = run!(@set)
      assert Enum.all?(media.parts, &is_nil(&1["sha256"]))
    end

    test "a sidecar in the wrong directory is not read", %{dir: dir} do
      for n <- [1, 2], do: put_part(dir, @set, n)
      wrong = Path.join([dir, "db", Artifact.sidecar_name(:media, @set)])
      File.write!(wrong, "#{@hex_a}  #{Artifact.part_name(@set, 1)}\n")

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{artifacts: [media]} = run!(@set)
      assert Enum.all?(media.parts, &is_nil(&1["sha256"]))
    end

    test "importing a part set twice leaves the same rows", %{dir: dir} do
      for n <- [1, 2, 3], do: put_part(dir, @set, n)
      assert {:ok, %{imported: 1}} = Importer.run()
      before = all_runs() |> Enum.map(&{&1.id, &1.updated_at})

      assert {:ok, %{imported: 0}} = Importer.run()
      assert before == all_runs() |> Enum.map(&{&1.id, &1.updated_at})
    end

    test "two concurrent imports of a part set write one row", %{dir: dir} do
      for n <- [1, 2, 3], do: put_part(dir, @set, n)

      results =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn -> Backups.with_actor(Backups.system(), &Importer.run/0) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert [_one] = all_runs()
    end

    test "a manifest listing the parts enriches them; the sidecar fills the gaps", %{dir: dir} do
      for n <- [1, 2], do: put_part(dir, @set, n)
      put_sidecar(dir, :media, @set, "#{@hex_b}  #{Artifact.part_name(@set, 2)}\n")

      manifest!(dir,
        trigger: "cron-nightly",
        ok: true,
        started_at: ~U[2026-08-01 03:17:00Z],
        finished_at: ~U[2026-08-01 03:18:42Z],
        artifacts: [
          %{
            kind: "media",
            path: "media/#{Artifact.part_name(@set, 1)}",
            bytes: 5,
            verified: false,
            sha256: @hex_a,
            part: 1,
            parts_total: 2
          },
          %{
            kind: "media",
            path: "media/#{Artifact.part_name(@set, 2)}",
            bytes: 5,
            verified: false,
            part: 2,
            parts_total: 2
          }
        ]
      )

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{trigger: "cron-nightly", artifacts: [media]} = run!(@set)
      assert [%{"sha256" => @hex_a}, %{"sha256" => @hex_b}] = media.parts
      assert media.bytes == 200
    end
  end

  describe "interrupted (#2478)" do
    @stamp "20260801-031700"
    @interrupted "Interrupted: the backup stopped before it finished and left .partial files behind"

    defp marker!(dir, stamp, age),
      do: put_named(dir, "media", "kiln-media-#{stamp}.sha256.partial", age)

    defp put_named(dir, sub, name, age) do
      path = Path.join([dir, sub, name])
      File.write!(path, "x")
      File.touch!(path, System.os_time(:second) - age * 60)
      path
    end

    test "quiet for 2 h 59 min is pending; for 3 h 01 min it is a failed run", %{dir: dir} do
      put_named(dir, "media", Artifact.part_name(@stamp, 1), 179)
      marker!(dir, @stamp, 179)

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
      assert all_runs() == []

      for f <- Path.wildcard(Path.join(dir, "media/kiln-media-#{@stamp}*")),
          do: File.touch!(f, System.os_time(:second) - 181 * 60)

      assert {:ok, %{imported: 1, pending: 0}} = Importer.run()

      run = run!(@stamp)
      assert run.origin == :imported
      assert run.status == :failed
      assert run.error == @interrupted
      assert run.components == [:media]

      assert [%{kind: :media, parts: [%{"name" => "kiln-media-#{@stamp}.part01.tar.gz"}]}] =
               run.artifacts

      assert DateTime.diff(DateTime.utc_now(), run.finished_at) in (181 * 60 - 5)..(181 * 60 + 5)

      assert Enum.any?(
               run.log,
               &(&1.level == :error and
                   &1.message =~ "kiln-media-#{@stamp}.sha256.partial (181 min old)")
             )

      assert Importer.interrupted_after_s() == 3 * 3600
    end

    test "a backup step's tagged partials (#2819) hold the stamp like any partial", %{dir: dir} do
      put_named(dir, "media", Artifact.part_name(@stamp, 1), 200)
      put_named(dir, "media", "kiln-media-#{@stamp}.sha256.48211-2.partial", 200)
      put_named(dir, "media", "kiln-media-#{@stamp}.part02.tar.gz.48211-2.partial", 200)

      assert {:ok, %{imported: 1, pending: 0}} = Importer.run()
      run = run!(@stamp)
      assert run.error == @interrupted
      assert [%{parts: [%{"name" => "kiln-media-#{@stamp}.part01.tar.gz"}]}] = run.artifacts
      assert Enum.any?(run.log, &(&1.message =~ "kiln-media-#{@stamp}.sha256.48211-2.partial"))
    end

    test "judged on the newest of all its files: a part finished 10 minutes ago keeps it " <>
           "pending however old the marker",
         %{dir: dir} do
      put(dir, :db, @stamp, age: 600)
      marker!(dir, @stamp, 600)
      put(dir, :media, @stamp, age: 10)

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()
    end

    test "only partials: pending, then a failed run with no artifacts", %{dir: dir} do
      put(dir, :db, @stamp, suffix: ".partial", age: 60)

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run()

      put(dir, :db, @stamp, suffix: ".partial", age: 200)
      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :failed, error: @interrupted, artifacts: [], components: [:db]} =
               run!(@stamp)
    end

    test "a partial that vanishes between the listing and the stat leaves the stamp pending",
         %{dir: dir} do
      # A run renaming its partials into place as it finishes: the dump is
      # done, the media part's partial is listed and gone before its stat.
      # Dated by the old dump alone, the stamp would be recorded interrupted.
      put(dir, :db, @stamp, age: 200)
      marker = marker!(dir, @stamp, 200)

      list_then_finish = fn dir ->
        {:ok, listed} = Importer.list(dir)
        File.rm!(marker)
        {:ok, listed}
      end

      assert {:ok, %{imported: 0, pending: 1}} = Importer.run(dir, list: list_then_finish)
      assert all_runs() == []
    end

    test "a finished dump with the media marker beside it is both components", %{dir: dir} do
      put(dir, :db, @stamp, age: 200)
      marker!(dir, @stamp, 200)

      assert {:ok, %{imported: 1}} = Importer.run()

      assert %{status: :failed, error: @interrupted, components: [:db, :media]} =
               run = run!(@stamp)

      assert [%{kind: :db, name: "kiln-db-#{@stamp}.dump"}] = run.artifacts
    end

    test "a sidecar's partial counts like any other", %{dir: dir} do
      put(dir, :db, @stamp, age: 200)
      put_named(dir, "db", "kiln-db-#{@stamp}.sha256.partial", 200)

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :failed, error: @interrupted, components: [:db]} = run!(@stamp)
    end

    test "a manifest covering the stamp still wins", %{dir: dir} do
      put(dir, :db, @stamp, age: 600)
      marker!(dir, @stamp, 600)

      manifest!(dir,
        trigger: "cron",
        ok: true,
        started_at: ~U[2026-08-01 03:17:00Z],
        finished_at: ~U[2026-08-01 03:18:42Z],
        artifacts: [%{kind: "db", path: "db/kiln-db-#{@stamp}.dump", bytes: 100, verified: true}]
      )

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{status: :succeeded, error: nil} = run!(@stamp)
    end

    test "a stamp the application owns is never looked at", %{dir: dir} do
      Backups.start_run!(%{stamp: @stamp, trigger: "manual"}, actor: Backups.system())
      put(dir, :db, @stamp, suffix: ".partial", age: 600)

      assert {:ok, %{imported: 0, pending: 0}} = Importer.run()
      assert %{status: :running, origin: :app, error: nil} = run!(@stamp)
    end

    test "a second run is a no-op", %{dir: dir} do
      put(dir, :db, @stamp, age: 600)
      marker!(dir, @stamp, 600)

      assert {:ok, %{imported: 1}} = Importer.run()
      before = run!(@stamp)

      assert {:ok, %{imported: 0, pending: 0}} = Importer.run()
      assert run!(@stamp).updated_at == before.updated_at
    end

    test "a file dated in the future reads as fresh, with one warning per call", %{dir: dir} do
      put(dir, :db, @stamp, age: 600)
      marker!(dir, @stamp, -60)
      put(dir, :db, "20260802-031700", suffix: ".partial", age: -60)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{imported: 0, pending: 2}} = Importer.run()
        end)

      assert [_one] = Regex.scan(~r/dated in the future/, log)
      assert log =~ "#{@stamp}, 20260802-031700"
      assert all_runs() == []
    end

    test "with the grant revoked nothing is written", %{dir: dir} do
      put(dir, :db, @stamp, suffix: ".partial", age: 600)

      assert {:error, _} = Backups.with_actor(nil, &Importer.run/0)
      assert all_runs() == []
    end
  end

  describe "an Interrupted row whose stamp finished after all (#2846)" do
    @late "20260801-031700"
    @reevaluated "Re-evaluated: the stamp's .partial files are gone and its set is complete"

    defp db_partial!(dir, stamp),
      do: put_named(dir, "db", "kiln-db-#{stamp}.sha256.partial", 200)

    defp db_sidecar!(dir, stamp, age \\ 60),
      do: put_sidecar(dir, :db, stamp, "#{@hex_b}  kiln-db-#{stamp}.dump\n", age)

    # A finished dump whose sidecar was still being written when the stamp
    # went quiet: recorded as a killed, db-only run.
    defp interrupted_db!(dir) do
      put(dir, :db, @late, age: 200)
      partial = db_partial!(dir, @late)

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{error: @interrupted, components: [:db]} = run = run!(@late)
      {run, partial}
    end

    # A finished dump with the media marker beside it: a cron `all` killed
    # during media, recorded as a killed run of both kinds.
    defp interrupted_all!(dir) do
      put(dir, :db, @late, age: 200)
      marker = marker!(dir, @late, 200)

      assert {:ok, %{imported: 1}} = Importer.run()
      assert %{error: @interrupted, components: [:db, :media]} = run = run!(@late)
      {run, marker}
    end

    test "with the partials gone and a covering manifest that succeeded, it is rewritten once",
         %{dir: dir} do
      {before, partial} = interrupted_db!(dir)
      File.rm!(partial)

      manifest!(dir, covering(@late, started_at: ~U[2026-08-01 03:17:09Z], keep_days: 7))

      assert {:ok, %{reevaluated: 1, imported: 0, failed: 0}} = Importer.run()

      run = run!(@late)
      assert run.id == before.id
      assert %{origin: :imported, status: :succeeded, error: nil, components: [:db]} = run
      assert run.finished_at == ~U[2026-08-01 03:18:42.000000Z]
      # Never the stamp's start, nor cron's window: only `:import` sets those.
      assert run.started_at == before.started_at
      assert run.keep_days == nil
      assert [%{kind: :db, verified: true}] = run.artifacts

      # The row's own log, plus one line.
      assert Enum.map(run.log, & &1.message) ==
               Enum.map(before.log, & &1.message) ++ [@reevaluated]

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late).updated_at == run.updated_at
    end

    test "with the partials gone and every kind complete with its sidecar, it is rewritten",
         %{dir: dir} do
      {_before, marker} = interrupted_all!(dir)
      File.rm!(marker)
      db_sidecar!(dir, @late)
      for n <- 1..2, do: put_part(dir, @late, n, age: 30)
      put_set_sidecar(dir, @late, 1..2)

      assert {:ok, %{reevaluated: 1}} = Importer.run()

      assert %{status: :succeeded, error: nil, components: [:db, :media]} = run = run!(@late)
      assert [%{kind: :db, sha256: @hex_b}, %{kind: :media, parts: [_, _]}] = run.artifacts
      assert List.last(run.log).message == @reevaluated
    end

    test "a single media archive with its sidecar is a complete media set", %{dir: dir} do
      {_before, marker} = interrupted_all!(dir)
      File.rm!(marker)
      db_sidecar!(dir, @late)
      put(dir, :media, @late, age: 30)
      put_sidecar(dir, :media, @late, "#{@hex_a}  kiln-media-#{@late}.tar.gz\n")

      assert {:ok, %{reevaluated: 1}} = Importer.run()
      assert %{status: :succeeded, components: [:db, :media]} = run!(@late)
    end

    test "not while any .partial of the stamp remains", %{dir: dir} do
      {before, _marker} = interrupted_all!(dir)
      db_sidecar!(dir, @late)
      for n <- 1..2, do: put_part(dir, @late, n, age: 30)
      put_set_sidecar(dir, @late, 1..2)

      # The marker is still there, however complete the rest looks.
      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before

      # So is a part's, in the other directory, once the marker goes.
      File.rm!(Path.join([dir, "media", "kiln-media-#{@late}.sha256.partial"]))
      put_named(dir, "media", Artifact.part_name(@late, 3) <> ".partial", 30)

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before
    end

    test "not when one of the row's components has no finished set", %{dir: dir} do
      # A cron `all` killed during media, whose marker was swept since: the
      # dump is complete, the media never was. Not "succeeded, db only".
      {before, marker} = interrupted_all!(dir)
      File.rm!(marker)
      db_sidecar!(dir, @late)

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before

      # Parts with no sidecar are not a finished set either.
      for n <- 1..2, do: put_part(dir, @late, n, age: 30)

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before
    end

    test "not a part set with a gap, sidecar or not", %{dir: dir} do
      {before, marker} = interrupted_all!(dir)
      File.rm!(marker)
      db_sidecar!(dir, @late)
      for n <- [1, 3], do: put_part(dir, @late, n, age: 30)
      put_set_sidecar(dir, @late, 1..3)

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before
    end

    test "not a legacy set with no sidecar and no manifest", %{dir: dir} do
      {before, partial} = interrupted_db!(dir)
      File.rm!(partial)

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before
    end

    test "not a covering manifest that failed", %{dir: dir} do
      {before, partial} = interrupted_db!(dir)
      File.rm!(partial)
      manifest!(dir, covering(@late, ok: false, error: "media failed"))

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before
    end

    test "not an in-app run, nor an imported run that failed for another reason", %{dir: dir} do
      app = Backups.start_run!(%{stamp: @late, trigger: "manual"}, actor: Backups.system())
      app = Backups.fail_run!(app, %{error: @interrupted}, actor: Backups.system())
      put(dir, :db, @late, age: 200)
      db_sidecar!(dir, @late)

      other = "20260802-031700"

      empty =
        Backups.import_run!(
          %{stamp: other, trigger: "cron", status: :failed, error: "empty artifact"},
          actor: Backups.system()
        )

      put(dir, :db, other, age: 200)
      db_sidecar!(dir, other)

      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert %{error: @interrupted, origin: :app} = run!(@late)
      assert run!(@late).updated_at == app.updated_at
      assert run!(other).updated_at == empty.updated_at

      # The action's own guard refuses them too, not only the importer's read.
      for run <- [app, empty] do
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
                 Backups.reevaluate_interrupted_run(run, %{status: :succeeded, error: nil},
                   actor: Backups.system()
                 )
      end

      assert %{error: @interrupted, origin: :app} = run!(@late)
      assert run!(@late).updated_at == app.updated_at
      assert run!(other).updated_at == empty.updated_at
    end

    test "not until its newest file has settled", %{dir: dir} do
      {before, partial} = interrupted_db!(dir)
      File.rm!(partial)
      db_sidecar!(dir, @late)
      dump = Path.join([dir, "db", "kiln-db-#{@late}.dump"])

      File.touch!(dump, System.os_time(:second) - 9 * 60)
      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before

      # In the future reads as fresh too.
      File.touch!(dump, System.os_time(:second) + 3600)
      assert {:ok, %{reevaluated: 0}} = Importer.run()
      assert run!(@late) == before

      File.touch!(dump, System.os_time(:second) - 11 * 60)
      assert {:ok, %{reevaluated: 1}} = Importer.run()
      assert %{status: :succeeded} = run!(@late)
    end

    test "not when a listed file is gone by the time it is stat'ed", %{dir: dir} do
      {before, marker} = interrupted_all!(dir)
      File.rm!(marker)
      db_sidecar!(dir, @late)
      for n <- 1..3, do: put_part(dir, @late, n, age: 30)
      put_set_sidecar(dir, @late, 1..3)

      # Retention deleting the last part between the listing and the stat:
      # parts 1..2 alone would look like a complete set.
      list_then_prune = fn dir ->
        {:ok, listed} = Importer.list(dir)
        File.rm!(Path.join([dir, "media", Artifact.part_name(@late, 3)]))
        {:ok, listed}
      end

      assert {:ok, %{reevaluated: 0}} = Importer.run(dir, list: list_then_prune)
      assert run!(@late) == before
    end

    test "a write that fails is counted, warned about and backed off like an import",
         %{dir: dir} do
      {before, partial} = interrupted_db!(dir)
      File.rm!(partial)
      db_sidecar!(dir, @late)
      refuse = fn _run, _attrs -> {:error, :boom} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{reevaluated: 0, failed: 1}} = Importer.run(dir, reevaluate: refuse)
        end)

      assert log =~ "#{@late} (attempt 1)"

      assert {:ok, %{reevaluated: 0, failed: 0, deferred: 1}} =
               Importer.run(dir, reevaluate: refuse)

      assert run!(@late) == before

      Importer.reset_failures()
      assert {:ok, %{reevaluated: 1}} = Importer.run()
    end
  end

  describe "failure" do
    test "an unreadable directory is an error, not a raise", %{dir: dir} do
      File.chmod!(Path.join(dir, "db"), 0o000)
      assert {:error, {:ls, "db", :eacces}} = Importer.run()
    end

    test "a missing backup directory is nothing to import" do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :dir, "/nonexistent/kiln")
      )

      assert {:ok, %{imported: 0}} = Importer.run()
    end

    test "with the grant revoked it fails closed and writes nothing", %{dir: dir} do
      put(dir, :db, "20260801-031700")

      assert {:error, _} = Backups.with_actor(nil, &Importer.run/0)
      assert all_runs() == []

      assert {:ok, %{imported: 1}} = Importer.run()
    end
  end

  describe "a stamp whose write keeps failing (#2417)" do
    @bad "20260801-031700"
    @good "20260802-031700"
    @min 60_000

    # The real write, except for `@bad`, which fails the way a constraint the
    # row breaks would.
    defp failing do
      fn attrs ->
        if attrs.stamp == @bad,
          do: {:error, RuntimeError.exception("value too long: password=hunter2secret")},
          else: Backups.import_run(attrs, actor: Backups.system())
      end
    end

    defp run_at(dir, now_ms, opts \\ []),
      do: Importer.run(dir, Keyword.merge([import: failing(), now_ms: now_ms], opts))

    test "the first failure warns once with the redacted cause, attempt and next try",
         %{dir: dir} do
      put(dir, :db, @bad)
      now = System.os_time(:millisecond)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{imported: 0, failed: 1, deferred: 0}} = run_at(dir, now)
        end)

      assert [_one] = Regex.scan(~r/Couldn't import backup/, log)
      assert log =~ "Couldn't import backup #{@bad} (attempt 1): value too long: password=***"
      refute log =~ "hunter2secret"

      next = (now + 15 * @min) |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
      assert log =~ "Next try after #{DateTime.to_iso8601(next)}"
    end

    test "a second call inside the backoff defers the stamp without a word", %{dir: dir} do
      put(dir, :db, @bad)
      now = System.os_time(:millisecond)
      assert {:ok, %{failed: 1}} = run_at(dir, now)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{imported: 0, failed: 0, deferred: 1}} = run_at(dir, now + 14 * @min)
        end)

      refute log =~ @bad
      assert all_runs() == []
    end

    test "past the backoff it is tried again as attempt 2, then waits twice as long",
         %{dir: dir} do
      put(dir, :db, @bad)
      now = System.os_time(:millisecond)
      assert {:ok, %{failed: 1}} = run_at(dir, now)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{failed: 1, deferred: 0}} = run_at(dir, now + 15 * @min)
        end)

      assert log =~ "Couldn't import backup #{@bad} (attempt 2)"

      assert {:ok, %{deferred: 1}} = run_at(dir, now + 44 * @min)
      assert {:ok, %{failed: 1}} = run_at(dir, now + 45 * @min)
    end

    test "the backoff stops growing at six hours", %{dir: dir} do
      put(dir, :db, @bad)
      six_hours = 6 * 60 * @min

      # Attempts 1 to 8, each as soon as the previous backoff allows (none is
      # longer than six hours, so six hours later is always due).
      last =
        Enum.reduce(1..8, System.os_time(:millisecond), fn _attempt, at ->
          assert {:ok, %{failed: 1}} = run_at(dir, at)
          at + six_hours
        end) - six_hours

      # 15 min x 2^7 would be 32 hours; the eighth waits six.
      assert {:ok, %{deferred: 1}} = run_at(dir, last + six_hours - 1)
      assert {:ok, %{failed: 1}} = run_at(dir, last + six_hours)
    end

    test "other stamps still import while one is deferred", %{dir: dir} do
      put(dir, :db, @bad)
      now = System.os_time(:millisecond)
      assert {:ok, %{failed: 1}} = run_at(dir, now)

      put(dir, :db, @good)
      assert {:ok, %{imported: 1, deferred: 1}} = run_at(dir, now + @min)
      assert %{status: :succeeded} = run!(@good)
    end

    test "a success clears the backoff", %{dir: dir} do
      put(dir, :db, @bad)
      now = System.os_time(:millisecond)
      assert {:ok, %{failed: 1}} = run_at(dir, now)

      # A write that reports success without leaving a row, so the stamp is
      # still a candidate below.
      written = fn _attrs -> {:ok, :written} end
      assert {:ok, %{imported: 1}} = Importer.run(dir, import: written, now_ms: now + 15 * @min)

      # Its entry is gone: the next failure is not deferred and counts from 1.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{failed: 1}} = run_at(dir, now + 16 * @min)
        end)

      assert log =~ "(attempt 1)"
    end

    test "retry_failed/0 forgets the backoff and imports at once", %{dir: dir} do
      put(dir, :db, @bad)
      assert {:ok, %{failed: 1}} = run_at(dir, System.os_time(:millisecond))
      assert {:ok, %{deferred: 1}} = Importer.run(dir)

      assert {:ok, %{imported: 1, deferred: 0}} = Importer.retry_failed()
      assert %{status: :succeeded} = run!(@bad)
    end

    test "each real failure emits telemetry", %{dir: dir} do
      put(dir, :db, @bad)
      event = [:kiln_cms, :backups, :import, :failed]
      ref = :telemetry_test.attach_event_handlers(self(), [event])
      now = System.os_time(:millisecond)

      assert {:ok, _} = run_at(dir, now)
      assert {:ok, %{deferred: 1}} = run_at(dir, now + @min)
      assert {:ok, _} = run_at(dir, now + 15 * @min)

      assert_received {^event, ^ref, %{count: 1}, %{stamp: @bad, attempt: 1} = meta}
      assert meta.error =~ "password=***"
      assert %DateTime{} = meta.retry_at
      assert_received {^event, ^ref, %{count: 1}, %{stamp: @bad, attempt: 2}}
      refute_received {^event, ^ref, _, _}
    end

    test "the table holds at most 500 stamps, dropping the soonest due", %{dir: dir} do
      [first | _rest] =
        for n <- 0..500 do
          pad = &String.pad_leading("#{&1}", 2, "0")
          stamp = "20250101-00#{pad.(div(n, 60))}#{pad.(rem(n, 60))}"
          put(dir, :db, stamp)
          stamp
        end

      now = System.os_time(:millisecond)
      fail_all = fn attrs -> {:error, RuntimeError.exception("no #{attrs.stamp}")} end

      # The first fails a minute before the other 500, so it is due soonest;
      # with them the table would hold 501, and it is the one dropped.
      assert {:ok, %{failed: 1}} =
               Importer.run(dir, import: fail_all, now_ms: now, list: only(first))

      assert {:ok, %{failed: 500, deferred: 1}} =
               Importer.run(dir, import: fail_all, now_ms: now + @min)

      assert {:ok, %{failed: 1, deferred: 500}} =
               Importer.run(dir, import: fail_all, now_ms: now + 2 * @min)
    end

    test "with the grant revoked it is an error and records no backoff", %{dir: dir} do
      put(dir, :db, @bad)

      assert {:error, _} =
               Backups.with_actor(nil, fn ->
                 run_at(dir, System.os_time(:millisecond))
               end)

      assert {:ok, %{failed: 1, deferred: 0}} = run_at(dir, System.os_time(:millisecond))
    end

    test "the backoff is per directory: the same stamp elsewhere is tried", %{dir: dir} do
      other = Path.join(System.tmp_dir!(), "kiln_imp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(other, "db"))
      on_exit(fn -> File.rm_rf!(other) end)

      put(dir, :db, @bad)
      put(other, :db, @bad)
      now = System.os_time(:millisecond)

      assert {:ok, %{failed: 1}} = run_at(dir, now)
      assert {:ok, %{failed: 1, deferred: 0}} = run_at(other, now + @min)
      assert {:ok, %{deferred: 1}} = run_at(dir, now + 2 * @min)
    end

    test "a deferred stamp never makes the call an error", %{dir: dir} do
      put(dir, :db, @bad)
      now = System.os_time(:millisecond)
      assert {:ok, _} = run_at(dir, now)
      assert {:ok, %{deferred: 1}} = run_at(dir, now + @min)
    end
  end

  # A `list` seam that hides every stamp but `stamp`.
  defp only(stamp) do
    fn dir ->
      {:ok, listed} = Importer.list(dir)
      {:ok, Enum.filter(listed, fn {_sub, name} -> name =~ stamp end)}
    end
  end

  describe "scale" do
    test "500 files import inside a time budget, and a second pass is a cheap no-op", %{dir: dir} do
      for n <- 1..250 do
        stamp =
          "2025#{String.pad_leading("#{rem(n, 12) + 1}", 2, "0")}#{String.pad_leading("#{rem(n, 28) + 1}", 2, "0")}-" <>
            "#{String.pad_leading("#{div(n, 60)}", 2, "0")}#{String.pad_leading("#{rem(n, 60)}", 2, "0")}00"

        put(dir, :db, stamp)
        put(dir, :media, stamp)
      end

      {first, {:ok, summary}} = :timer.tc(&Importer.run/0)
      assert summary.imported == 250
      assert length(all_runs()) == 250
      assert first < 20_000_000

      {second, {:ok, %{imported: 0}}} = :timer.tc(&Importer.run/0)
      assert second < 2_000_000
    end
  end
end
