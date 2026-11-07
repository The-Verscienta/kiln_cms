defmodule KilnCMS.Backups.ImporterTest do
  @moduledoc """
  Cron-made backups become history (#2217): the file scan is the truth, the
  manifest only enriches, and nothing the application already recorded is touched.
  """
  # `async: false`: it points `:kiln_cms, KilnCMS.Backups, :dir` at a temp
  # directory (`Application.put_env` is VM-global).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Importer, Manifest}

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
