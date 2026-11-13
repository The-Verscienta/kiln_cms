defmodule KilnCMS.Backups.WorkerTest do
  @moduledoc """
  The backup pipeline (#484), run as its step chain (#2218) through
  `KilnCMS.Test.BackupChain`.

  It really does run `pg_dump` against the test database — a mocked backup
  proves nothing, because the whole premise of this feature is that the file
  it writes is one `scripts/restore.sh` can restore. Skipped when the client
  tools aren't installed, which is a real state on a machine that hasn't
  installed them and is exactly what `availability/0` reports.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Manifest}
  alias KilnCMS.Backups.Worker
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bkw_#{System.unique_integer([:positive])}")
    media = Path.join(System.tmp_dir!(), "kiln_bkm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(media)
    File.write!(Path.join(media, "an-upload.txt"), "pretend this is a jpeg")

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: media, keep_days: 14)
    )

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(media)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir, media: media}
  end

  describe "a real run" do
    @tag :pg_tools
    test "produces a verified dump and media archive, and a manifest describing them", %{dir: dir} do
      assert :ok = BackupChain.run()

      manifest = Manifest.read(dir)

      assert manifest.ok
      assert manifest.trigger == "manual"
      assert Manifest.verified?(manifest)
      assert [db, media] = manifest.artifacts

      assert db.kind == "db"
      assert media.kind == "media"

      # Relative to the backup directory, so the manifest survives the
      # directory being moved or read from another mount.
      refute String.starts_with?(db.path, "/")
      assert File.exists?(Path.join(dir, db.path))
      assert File.exists?(Path.join(dir, media.path))
      assert db.bytes > 0

      # 0600: a dump is a complete logical copy of the database.
      assert {:ok, %{mode: mode}} = File.stat(Path.join(dir, db.path))
      assert Bitwise.band(mode, 0o077) == 0
    end

    @tag :pg_tools
    test "dumps through an ecto:// URL, with and without a password (#2719)", %{dir: dir} do
      # `ecto://` is the documented DATABASE_URL form. Handed to pg_dump as it
      # is, libpq reads it as a database name on the local socket and every
      # in-app backup fails at the dump step.
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      # Without a password in the URL, the password comes from the
      # environment, the documented path (a server that trusts local
      # connections needs none, one that doesn't, CI's, does).
      original_pgpassword = System.get_env("PGPASSWORD")

      on_exit(fn ->
        if original_pgpassword,
          do: System.put_env("PGPASSWORD", original_pgpassword),
          else: System.delete_env("PGPASSWORD")
      end)

      for {url, pgpassword} <- [
            {ecto_url(password: true), nil},
            {ecto_url(password: false), KilnCMS.Repo.config()[:password]}
          ] do
        Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :database_url, url))
        if pgpassword, do: System.put_env("PGPASSWORD", pgpassword)

        assert :ok = BackupChain.run()

        manifest = Manifest.read(dir)
        assert manifest.ok, inspect(manifest.error)
        assert [%{kind: "db", verified: true} = db | _] = manifest.artifacts
        assert File.exists?(Path.join(dir, db.path))
      end
    end

    @tag :pg_tools
    test "names artifacts exactly the way scripts/backup.sh does", %{dir: dir} do
      # The interchange guarantee: `scripts/restore.sh` finds a backup by
      # globbing these names, so a divergence here means the shell tooling
      # silently stops seeing app-made backups.
      assert :ok = BackupChain.run()

      assert [dump] = Path.wildcard(Path.join([dir, "db", "kiln-db-*.dump"]))
      assert Path.basename(dump) =~ ~r/\Akiln-db-\d{8}-\d{6}\.dump\z/

      assert [archive] = Path.wildcard(Path.join([dir, "media", "kiln-media-*.tar.gz"]))
      assert Path.basename(archive) =~ ~r/\Akiln-media-\d{8}-\d{6}\.tar\.gz\z/
    end

    @tag :pg_tools
    test "a media set over the part size is split, hashed and sidecar'd", %{
      dir: dir,
      media: media
    } do
      for n <- 1..5,
          do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

      set_part_bytes(700)

      assert :ok = BackupChain.run()

      manifest = Manifest.read(dir)
      assert manifest.ok
      assert [db | parts] = manifest.artifacts
      assert length(parts) >= 2

      assert Enum.map(parts, & &1.part) == Enum.to_list(1..length(parts))
      assert Enum.all?(parts, &(&1.parts_total == length(parts) and &1.verified))

      stamp = db.path |> Path.basename() |> String.replace(~r/\Akiln-db-|\.dump\z/, "")
      assert Enum.map(parts, &Path.basename(&1.path)) == Artifact.set_names(stamp, length(parts))

      # The sidecar checks out with the system's own tool.
      sidecar = Path.join([dir, "media", Artifact.sidecar_name(:media, stamp)])

      assert {_, 0} =
               System.cmd("shasum", ["-a", "256", "-c", Path.basename(sidecar)],
                 cd: Path.dirname(sidecar),
                 stderr_to_stdout: true
               )

      # One Run artifact for the set, whose digest is that of the concatenation.
      assert [run] = Backups.list_runs!(actor: Backups.system())
      assert [%{kind: :db}, set] = run.artifacts
      assert set.name == "kiln-media-" <> stamp
      assert length(set.parts) == length(parts)

      concat = Enum.map(parts, &Path.join(dir, &1.path))
      assert {:ok, %{sha256: sha}} = Checksum.concat(concat)
      assert set.sha256 == sha
      assert set.verified

      # The work directory is cleaned up on success.
      assert Path.wildcard(Path.join([dir, ".work", "*"])) == []
    end

    @tag :pg_tools
    test "the database dump gets a sha256 sidecar", %{dir: dir} do
      assert :ok = BackupChain.run()

      assert [dump] = Path.wildcard(Path.join([dir, "db", "kiln-db-*.dump"]))
      sidecar = String.replace_suffix(dump, ".dump", ".sha256")
      assert {:ok, [{hex, name}]} = Checksum.parse_sidecar(sidecar)
      assert name == Path.basename(dump)
      assert {:ok, ^hex, _} = Checksum.file(dump)
    end

    @tag :pg_tools
    test "leaves no .partial behind", %{dir: dir} do
      assert :ok = BackupChain.run()
      assert Path.wildcard(Path.join([dir, "**", "*.partial"])) == []
    end

    @tag :pg_tools
    test "skips the media archive when no media directory is configured", %{dir: dir} do
      # The S3 case: the bucket is backed up provider-side, and tarring the
      # wrong directory would yield an archive that looks like a media backup
      # and restores nothing.
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :media_dir, nil))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      assert :ok = BackupChain.run()
      assert [%{kind: "db"}] = Manifest.read(dir).artifacts
    end
  end

  describe "failure" do
    @tag :pg_tools
    test "records a FAILED manifest rather than leaving the last success showing", %{dir: dir} do
      # An admin looking at this page after a failed run is asking "is my data
      # safe right now", and the previous successful backup does not answer it.
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(original, :database_url, "postgres://nobody:nope@127.0.0.1:1/nope")
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      assert {:error, _reason} = BackupChain.run()

      manifest = Manifest.read(dir)

      refute manifest.ok
      assert manifest.artifacts == []
      assert is_binary(manifest.error)
      refute Manifest.verified?(manifest)
    end

    @tag :pg_tools
    test "a failed run leaves no .partial to be mistaken for a backup", %{dir: dir} do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(original, :database_url, "postgres://nobody:nope@127.0.0.1:1/nope")
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      BackupChain.run()
      assert Path.wildcard(Path.join([dir, "**", "*.partial"])) == []
    end

    test "split_credentials moves the password out of argv into PGPASSWORD" do
      # argv is world-readable via /proc/<pid>/cmdline; the environment is not.
      assert {url, [{"PGPASSWORD", "hunter2"}]} =
               Worker.split_credentials("postgres://someone:hunter2@db.example.com:5432/kiln")

      refute url =~ "hunter2"
      assert url == "postgres://someone@db.example.com:5432/kiln"
    end

    test "split_credentials decodes a percent-encoded password" do
      # Ecto/URI encode it; libpq wants the real bytes in PGPASSWORD.
      assert {_url, [{"PGPASSWORD", "p@ss word"}]} =
               Worker.split_credentials("postgres://u:p%40ss%20word@h:5432/db")
    end

    test "split_credentials leaves a passwordless URL alone" do
      assert {"postgres://u@h:5432/db", []} = Worker.split_credentials("postgres://u@h:5432/db")
      assert {nil, []} = Worker.split_credentials(nil)
    end

    @tag :pg_tools
    test "the recorded error never carries the database password", %{dir: dir} do
      # `pg_dump`'s stderr echoes the connection string it was given, and this
      # string is rendered in the admin panel.
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(original, :database_url, "postgres://someone:hunter2@127.0.0.1:1/nope")
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      BackupChain.run()

      error = Manifest.read(dir).error || ""
      refute error =~ "hunter2"
    end

    test "a run that CAN'T START leaves the existing manifest untouched", %{dir: dir} do
      # "This image has no pg_dump" / "the in-app path is off" is a fact about
      # the APP, not about the backups — cron may be backing this deployment
      # up perfectly from the host. Writing `ok: false` here would overwrite
      # cron's record of a SUCCESSFUL backup and turn the overview red,
      # destroying the very information the panel exists to show.
      :ok =
        Manifest.write(dir, %Manifest{
          finished_at: DateTime.utc_now(),
          trigger: "cron",
          ok: true,
          artifacts: [%{kind: "db", path: "db/x.dump", bytes: 1, verified: true}]
        })

      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      assert {:error, :disabled} = BackupChain.run()

      assert %Manifest{ok: true, trigger: "cron"} = Manifest.read(dir)
    end
  end

  describe "retention" do
    @tag :pg_tools
    test "deletes artifacts past keep_days and keeps the rest", %{dir: dir} do
      older = Path.join([dir, "db", "kiln-db-20190101-000000.dump"])
      old = Path.join([dir, "db", "kiln-db-20200101-000000.dump"])
      recent = Path.join([dir, "db", "kiln-db-20991231-000000.dump"])
      File.mkdir_p!(Path.dirname(old))
      File.write!(older, "older")
      File.write!(old, "old")
      File.write!(recent, "recent")

      # mtime is what the script's `find -mtime` uses, so this uses it too —
      # a filename-derived date would disagree with the shell path.
      ancient = System.os_time(:second) - 365 * 24 * 3600
      File.touch!(older, ancient)
      File.touch!(old, ancient)

      assert :ok = BackupChain.run()

      # `old` is imported first and, with this run still running and `recent`
      # too fresh to import, it is the newest verified dump: kept (#2219).
      refute File.exists?(older)
      assert File.exists?(old)
      assert File.exists?(recent)

      assert [%{stamp: stamp}] = Enum.filter(runs(), &(&1.origin == :app))
      assert File.exists?(Path.join([dir, "db", "kiln-db-#{stamp}.dump"]))

      assert %{log: log} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert Enum.any?(
               log,
               &(&1.step == "prune" and
                   &1.message == "Retention removed 1 file(s) from 1 backup(s)")
             )
    end

    @tag :pg_tools
    test "a retention that can't run deletes nothing, and the backup still succeeds",
         %{dir: dir} do
      old = Path.join([dir, "db", "kiln-db-20190101-000000.dump"])
      File.mkdir_p!(Path.dirname(old))
      File.write!(old, "older")
      File.touch!(old, System.os_time(:second) - 365 * 24 * 3600)
      # Not a usable policy, so retention fails closed.
      set_config(keep_days: 0)

      assert :ok = BackupChain.run()
      assert File.exists?(old)

      assert [%{stamp: stamp, status: :succeeded}] =
               Enum.filter(runs(), &(&1.origin == :app))

      assert %{log: log} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert %{level: :error, message: message} = Enum.find(log, &(&1.step == "prune"))

      assert message ==
               "Retention skipped: the retention policy is invalid (BACKUP_KEEP_DAYS must " <>
                 "be a whole number of days, 1 or more); nothing was deleted"
    end

    @tag :pg_tools
    test "a RECENT .partial survives — it may be a concurrent run's work", %{dir: dir} do
      partial = Path.join([dir, "db", "kiln-db-20200101-000000.dump.partial"])
      File.mkdir_p!(Path.dirname(partial))
      File.write!(partial, "in progress")

      assert :ok = BackupChain.run()
      assert File.exists?(partial)
    end

    @tag :pg_tools
    test "an ABANDONED .partial is reclaimed", %{dir: dir} do
      # Left by a job Oban's timeout killed or a node that restarted mid-dump.
      # Nothing else collects these, and each is potentially a
      # full-database-sized file — which is how a backup directory fills a
      # disk. An hour's grace separates "abandoned" from "in flight"; this
      # queue runs one job at a time and `timeout/1` caps one well inside it.
      partial = Path.join([dir, "db", "kiln-db-20200101-000000.dump.partial"])
      File.mkdir_p!(Path.dirname(partial))
      File.write!(partial, "abandoned")
      File.touch!(partial, System.os_time(:second) - 7200)

      assert :ok = BackupChain.run()
      refute File.exists?(partial)
    end
  end

  describe "run history (#2217)" do
    defp runs, do: Backups.list_runs!(actor: Backups.system())

    defp set_part_bytes(bytes), do: set_config(media_part_bytes: bytes)

    defp set_config(overrides) do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(original, overrides))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)
    end

    # A directory of fake executables ahead of the real ones on PATH.
    defp fake_bin(scripts) do
      bin = Path.join(System.tmp_dir!(), "kiln_bkbin_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)

      for {name, body} <- scripts do
        path = Path.join(bin, name)
        File.write!(path, "#!/bin/sh\n" <> body)
        File.chmod!(path, 0o755)
      end

      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(bin)
      end)

      bin
    end

    # Hides `rclone` on a host or CI runner that has one installed. Each PATH
    # directory holding an `rclone` is swapped for a directory of symlinks to
    # everything else in it, so `pg_dump`, `tar` and the rest living beside
    # it (Homebrew's bin, Debian's /usr/bin) stay reachable.
    defp no_rclone_on_path do
      path = System.get_env("PATH")
      shims = Path.join(System.tmp_dir!(), "kiln_norclone_#{System.unique_integer([:positive])}")

      kept =
        path
        |> String.split(":")
        |> Enum.with_index()
        |> Enum.map_join(":", fn {dir, i} -> without_rclone(dir, Path.join(shims, "#{i}")) end)

      System.put_env("PATH", kept)

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(shims)
      end)
    end

    defp without_rclone(dir, shim) do
      if File.exists?(Path.join(dir, "rclone")) do
        File.mkdir_p!(shim)
        for name <- File.ls!(dir), name != "rclone", do: link!(dir, name, shim)
        shim
      else
        dir
      end
    end

    defp link!(dir, name, shim), do: File.ln_s!(Path.join(dir, name), Path.join(shim, name))

    @tag :pg_tools
    test "a successful run is recorded with its artifacts and local destinations", %{dir: dir} do
      assert :ok = BackupChain.run()

      assert [run] = runs()
      assert run.status == :succeeded
      assert run.origin == :app
      assert run.trigger == "manual"
      # The start step's job, and the chain that wrote it.
      assert is_integer(run.oban_job_id)
      assert is_binary(run.chain_id)
      assert run.components == [:db, :media]
      assert run.finished_at
      assert run.stamp =~ ~r/\A\d{8}-\d{6}\z/

      assert [%{kind: :db} = db, %{kind: :media}] = run.artifacts
      assert db.bytes > 0
      assert db.verified
      assert db.destinations == %{"local" => %{"status" => "ok"}}
      assert File.exists?(Path.join([dir, "db", db.name]))
      assert Enum.any?(run.log, &(&1.step == "dump"))
    end

    @tag :pg_tools
    test "the manifest keeps its exact shape", %{dir: dir} do
      assert :ok = BackupChain.run()

      raw = File.read!(Manifest.path(dir))
      decoded = Jason.decode!(raw)

      # `components` is #2219's, additive like #2218's keys; so is `stamp`.
      assert decoded |> Map.keys() |> Enum.sort() ==
               ~w(artifacts components error finished_at keep_days offsite ok stamp started_at trigger version)

      assert decoded["components"] == ["db", "media"]
      assert [%{stamp: stamp}] = runs()
      assert decoded["stamp"] == stamp

      # The original four keys are still there, unchanged (#2218 only adds).
      assert [db, media] = decoded["artifacts"]
      assert db |> Map.keys() |> Enum.sort() == ~w(bytes kind path sha256 verified)

      assert media |> Map.keys() |> Enum.sort() ==
               ~w(bytes kind part parts_total path sha256 verified)

      assert db["kind"] == "db"
      assert db["verified"] == true
      assert db["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, db["sha256"], db["bytes"]} == Checksum.file(Path.join(dir, db["path"]))
      assert media["part"] == 1 and media["parts_total"] == 1
      assert media["path"] =~ ~r/\Amedia\/kiln-media-\d{8}-\d{6}\.tar\.gz\z/

      # Byte-for-byte what `Manifest.write/2` produces from what it reads back.
      Manifest.write(dir, Manifest.read(dir))
      assert File.read!(Manifest.path(dir)) == raw
    end

    @tag :pg_tools
    test "a failure after the dump keeps the partial artifact and fails the run", %{dir: dir} do
      set_config(media_dir: Path.join(dir, "no-such-media-dir"))

      assert {:error, _} = BackupChain.run()

      assert [run] = runs()
      assert run.status == :failed
      assert run.error =~ "missing_media_dir"
      assert [%{kind: :db}] = run.artifacts
      refute Manifest.read(dir).ok
    end

    @tag :pg_tools
    test "a failure before anything lands records the redacted error" do
      set_config(database_url: "postgres://someone:hunter2@127.0.0.1:1/nope")

      assert {:error, _} = BackupChain.run()

      assert [run] = runs()
      assert run.status == :failed
      assert run.artifacts == []
      assert is_binary(run.error)
      refute run.error =~ "hunter2"
      refute inspect(run.log) =~ "hunter2"
    end

    test "a request the deployment can't run is refused up front: no run, no chain", %{dir: dir} do
      set_config(enabled: false)

      assert {:error, :disabled} = BackupChain.run()
      assert runs() == []
      assert Backups.in_flight() == nil
      refute File.exists?(Manifest.path(dir))
    end

    test "unavailable by the time the chain starts: a skipped run, the lock released, the manifest alone",
         %{dir: dir} do
      :ok =
        Manifest.write(dir, %Manifest{
          finished_at: DateTime.utc_now(),
          trigger: "cron",
          ok: true,
          artifacts: [%{kind: "db", path: "db/x.dump", bytes: 1, verified: true}]
        })

      before = File.read!(Manifest.path(dir))

      assert {:ok, %{status: :started, chain: chain}} =
               Backups.request([trigger: "manual"], Backups.system())

      # pg_dump disappears between the request and the start step.
      set_config(enabled: false)

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert {:error, :disabled} = BackupChain.settled(chain)
      end)

      assert [%{status: :skipped, error: "Refused: disabled", finished_at: %DateTime{}}] = runs()
      assert File.read!(Manifest.path(dir)) == before
      assert Backups.in_flight() == nil
    end

    @tag :pg_tools
    test "a run killed mid-flight is reconciled by the next one" do
      long_ago = DateTime.add(DateTime.utc_now(), -86_400, :second)

      killed =
        Backups.start_run!(
          %{stamp: "20200101-000000", trigger: "manual", started_at: long_ago},
          actor: Backups.system()
        )

      # Quiet since then too: staleness is measured from the later of
      # `started_at` and `updated_at`.
      import Ecto.Query

      KilnCMS.Repo.update_all(
        from(r in "backup_runs", where: r.id == type(^killed.id, :binary_id)),
        set: [updated_at: long_ago]
      )

      assert :ok = BackupChain.run()

      assert %{status: :failed, error: "Interrupted: " <> _} =
               Backups.get_run!(killed.id, actor: Backups.system())
    end

    @tag :pg_tools
    test "pruning marks the pruned run's local copy", %{dir: dir} do
      old = Path.join([dir, "db", "kiln-db-20200101-000000.dump"])
      File.mkdir_p!(Path.dirname(old))
      File.write!(old, "old")
      File.touch!(old, System.os_time(:second) - 365 * 24 * 3600)
      # A newer finished backup holds the newest slots; this run, still running,
      # never does (#2219).
      newer = Path.join([dir, "db", "kiln-db-20260101-000000.dump"])
      File.write!(newer, "newer")
      File.touch!(newer, System.os_time(:second) - 24 * 3600)

      {:ok, attrs} =
        Backups.Artifact.from_manifest(%{kind: "db", path: "db/#{Path.basename(old)}"})

      prior =
        Backups.start_run!(
          %{stamp: "20200101-000000", trigger: "cron", started_at: ~U[2020-01-01 00:00:00Z]},
          actor: Backups.system()
        )

      Backups.finish_run!(prior, %{artifacts: [attrs]}, actor: Backups.system())

      assert :ok = BackupChain.run()

      refute File.exists?(old)
      assert File.exists?(newer)
      stored = Backups.get_run_by_stamp!("20200101-000000", actor: Backups.system())
      assert [%{destinations: %{"local" => %{"status" => "pruned"}}}] = stored.artifacts
    end

    @tag :pg_tools
    test "cron-made backups beside it are imported at the end of a run", %{dir: dir} do
      cron = Path.join([dir, "db", "kiln-db-20260101-000000.dump"])
      File.mkdir_p!(Path.dirname(cron))
      File.write!(cron, "from cron")
      File.touch!(cron, System.os_time(:second) - 3600)

      assert :ok = BackupChain.run()

      assert %{origin: :imported, trigger: "cron"} =
               Backups.get_run_by_stamp!("20260101-000000", actor: Backups.system())
    end

    @tag :pg_tools
    test "a Run-write failure never fails the backup, and the chain still advances", %{dir: dir} do
      assert {:ok, %{status: :started, chain: chain}} =
               Backups.request([trigger: "manual"], Backups.system())

      # The start step only: it opens the run.
      BackupChain.drain(with_recursion: false)
      assert [%{status: :running} = run] = runs()

      # Every later Run write is refused (the row is no longer `running`).
      import Ecto.Query

      KilnCMS.Repo.update_all(
        from(r in "backup_runs", where: r.id == type(^run.id, :binary_id)),
        set: [status: "failed"]
      )

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      assert %Manifest{ok: true} = Manifest.read(dir)
      assert [_dump] = Path.wildcard(Path.join([dir, "db", "*.dump"]))
      assert [_archive] = Path.wildcard(Path.join([dir, "media", "*.tar.gz"]))
      assert Backups.in_flight() == nil
    end

    @tag :pg_tools
    test "a Run row deleted mid-run (a database restore) leaves the backup whole", %{dir: dir} do
      gate = Path.join(dir, "gate")
      real = System.find_executable("pg_dump")

      fake_bin([
        {"pg_dump", ~s|while [ ! -f "#{gate}" ]; do sleep 0.05; done\nexec "#{real}" "$@"\n|}
      ])

      task = Task.async(fn -> BackupChain.run() end)

      wait_until(fn -> Enum.any?(runs(), &(&1.status == :running)) end)
      KilnCMS.Repo.delete_all(Backups.Run)
      File.write!(gate, "")

      assert :ok = Task.await(task, 60_000)
      assert %Manifest{ok: true} = Manifest.read(dir)
      assert [_dump] = Path.wildcard(Path.join([dir, "db", "*.dump"]))
      assert [_archive] = Path.wildcard(Path.join([dir, "media", "*.tar.gz"]))
    end

    @tag :pg_tools
    test "a failed off-site copy fails the run; the verified local backup is kept and resumable",
         %{dir: dir} do
      remote = ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket"
      set_config(rclone_remote: remote)

      fake_bin([
        {"rclone",
         ~s|case "$*" in *kiln-media*) echo "Failed secret_access_key=SUPERSECRETVAL ($*)" >&2; exit 1;; esac\nexit 0\n|}
      ])

      assert {:error, {:offsite, %{failed: [_ | _], refused: []}}} = BackupChain.run()

      assert [run] = runs()
      assert run.status == :failed
      assert run.error =~ "Off-site copy FAILED for 2 files: kiln-media-"
      assert run.error =~ "Resume retries the off-site copy"
      assert [db, media] = run.artifacts
      # Nothing changed on disk: both are still the files it verified.
      assert db.verified and media.verified

      assert [key] = db.destinations |> Map.keys() |> Enum.reject(&(&1 == "local"))
      assert String.starts_with?(key, "rclone:")
      assert %{"status" => "ok"} = db.destinations[key]
      assert %{"status" => "failed", "error" => error} = media.destinations[key]
      assert error != ""

      manifest = Manifest.read(dir)
      refute manifest.ok
      assert manifest.offsite == nil
      assert manifest.error == run.error
      assert Enum.all?(manifest.artifacts, & &1.verified)

      # The files stay, and so does the state a Resume builds on.
      for artifact <- manifest.artifacts, do: assert(File.exists?(Path.join(dir, artifact.path)))
      assert Backups.work_state?(run.stamp)

      for haystack <- [inspect(run), File.read!(Path.join(dir, "manifest.json"))] do
        refute haystack =~ "SUPERSECRETVAL"
        refute haystack =~ "AKIAEXAMPLE1"
      end
    end

    @tag :pg_tools
    test "a remote set with no rclone in the image fails the run, keeping it resumable (#2482)",
         %{dir: dir} do
      remote = ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket"
      set_config(rclone_remote: remote)
      no_rclone_on_path()
      assert Backups.rclone_missing?()

      {result, output} = ExUnit.CaptureLog.with_log(fn -> BackupChain.run() end)
      assert {:error, {:offsite, :missing_rclone}} = result
      assert output =~ "rclone is not installed in this image"

      assert [run] = runs()
      assert run.status == :failed

      assert run.error ==
               "Off-site copy FAILED: BACKUP_RCLONE_REMOTE is set but rclone is not installed " <>
                 "in this image, so no file was copied. The local files are kept. Install " <>
                 "rclone in the image (the official image ships it) or unset " <>
                 "BACKUP_RCLONE_REMOTE, then Resume this backup."

      assert Enum.any?(
               run.log,
               &(&1.level == :error and &1.step == "offsite" and
                   &1.message =~ "rclone is not installed in this image")
             )

      assert [db, media] = run.artifacts
      assert db.verified and media.verified

      manifest = Manifest.read(dir)
      refute manifest.ok
      assert manifest.offsite == nil
      assert manifest.error == run.error
      assert Backups.work_state?(run.stamp)

      for haystack <- [inspect(run), output, File.read!(Path.join(dir, "manifest.json"))] do
        refute haystack =~ "SUPERSECRETVAL"
        refute haystack =~ "AKIAEXAMPLE1"
      end
    end

    @tag :pg_tools
    test "a file changed during the off-site copy is refused and fails the run loudly", %{
      dir: dir
    } do
      log = Path.join(dir, "rclone.log")
      set_config(rclone_remote: "r2:kiln")

      # While the dump uploads, something appends to the media archive.
      fake_bin([
        {"rclone",
         ~s|echo "$*" >> "#{log}"\ncase "$2" in *kiln-db-*.dump) for f in "#{dir}"/media/kiln-media-*.tar.gz; do printf x >> "$f"; done ;; esac\nexit 0\n|}
      ])

      {result, output} = ExUnit.CaptureLog.with_log(fn -> BackupChain.run() end)
      assert {:error, {:offsite, %{refused: [{archive, {:changed, _}}], failed: []}}} = result
      assert output =~ "REFUSED"
      assert output =~ archive

      assert [run] = runs()
      assert run.status == :failed
      assert run.error =~ "Off-site copy REFUSED for 1 file: #{archive} (changed on disk"
      assert run.error =~ "check the disk"
      assert [db, media] = run.artifacts
      assert db.verified
      refute media.verified
      assert media.destinations["rclone:r2:kiln"]["error"] =~ "Refused: "

      manifest = Manifest.read(dir)
      refute manifest.ok
      assert manifest.error == run.error

      assert [%{kind: "db", verified: true}, %{kind: "media", verified: false}] =
               manifest.artifacts

      # Never uploaded, never retried; everything else was.
      sent = File.read!(log)
      refute sent =~ archive
      assert sent =~ "kiln-media-#{run.stamp}.sha256"
      assert Backups.work_state?(run.stamp)
    end

    @tag :pg_tools
    test "a run that fails off-site still prunes expired sets", %{dir: dir} do
      older = Path.join([dir, "db", "kiln-db-20190101-000000.dump"])
      old = Path.join([dir, "db", "kiln-db-20200101-000000.dump"])
      File.mkdir_p!(Path.dirname(old))

      for path <- [older, old] do
        File.write!(path, "old")
        File.touch!(path, System.os_time(:second) - 365 * 24 * 3600)
      end

      set_config(rclone_remote: "r2:kiln")
      fake_bin([{"rclone", "exit 1\n"}])

      assert {:error, {:offsite, _}} = BackupChain.run()
      refute File.exists?(older)
      # The newest verified dump (imported; this run's own is not finished).
      assert File.exists?(old)
    end

    @tag :pg_tools
    test "a successful run leaves no work directory behind", %{dir: dir} do
      set_config(rclone_remote: "r2:kiln")
      fake_bin([{"rclone", "exit 0\n"}])

      assert :ok = BackupChain.run()
      assert [%{status: :succeeded, stamp: stamp}] = runs()
      refute Backups.work_state?(stamp)
      refute File.exists?(Path.join([dir, ".work", stamp]))
      assert Manifest.read(dir).offsite == "r2:kiln"
    end

    defp wait_until(fun, tries \\ 200) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition never held")
        true -> Process.sleep(25) && wait_until(fun, tries - 1)
      end
    end
  end

  describe "a legacy resume job right after a Cancel (#2538)" do
    @tag :pg_tools
    test "waits out the rest of the window instead of giving up", %{dir: dir} do
      stamp = "20260101-000000"

      Ash.Seed.seed!(KilnCMS.Backups.Run, %{
        stamp: stamp,
        status: :canceled,
        finished_at: DateTime.utc_now()
      })

      work = KilnCMS.Backups.WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = KilnCMS.Backups.WorkState.write(work, KilnCMS.Backups.WorkState.new(stamp))

      assert {:snooze, seconds} =
               Worker.perform(%Oban.Job{id: 1, args: %{"trigger" => "manual", "resume" => stamp}})

      assert seconds > 0 and seconds <= div(KilnCMS.Backups.Heartbeat.settled_after_ms(), 1000)
      assert Backups.in_flight() == nil
    end
  end

  # The test database as an `ecto://` URL, the way `.env.example` writes one.
  defp ecto_url(password: password?) do
    config = KilnCMS.Repo.config()
    user = config[:username] && URI.encode(config[:username], &URI.char_unreserved?/1)

    userinfo =
      case {user, password? && config[:password]} do
        {nil, _} -> ""
        {user, pw} when pw in [nil, false] -> user <> "@"
        {user, pw} -> user <> ":" <> URI.encode(pw, &URI.char_unreserved?/1) <> "@"
      end

    "ecto://#{userinfo}#{config[:hostname] || "localhost"}:#{config[:port] || 5432}/#{config[:database]}"
  end
end
