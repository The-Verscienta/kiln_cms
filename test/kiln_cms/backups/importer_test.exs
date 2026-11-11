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
      assert %{artifacts: [db]} = run!("20260801-031700")
      assert %{"status" => "ok"} = db.destinations["rclone:r2:kiln"]
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

      assert :ok = KilnCMS.Backups.Steps.interrupt(stamp, chain, dir_id, "Interrupted")
      assert %Manifest{ok: false, stamp: ^stamp} = Manifest.read(dir)

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

  describe "files only" do
    test "become a succeeded, unverified, imported run", %{dir: dir} do
      path = put(dir, :db, "20260801-031700")
      put(dir, :media, "20260801-031700")

      assert {:ok, %{imported: 1}} = Importer.run()

      run = run!("20260801-031700")
      assert run.origin == :imported
      assert run.status == :succeeded
      assert run.trigger == "cron"
      assert run.started_at == ~U[2026-08-01 03:17:00.000000Z]
      assert DateTime.to_unix(run.finished_at) == File.stat!(path, time: :posix).mtime
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
    test "a .partial alone is ignored", %{dir: dir} do
      put(dir, :db, "20260801-031700", suffix: ".partial")
      assert {:ok, %{imported: 0, pending: 0}} = Importer.run()
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
