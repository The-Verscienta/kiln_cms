defmodule KilnCMS.Backups.WorkerTest do
  @moduledoc """
  The backup worker (#484).

  It really does run `pg_dump` against the test database — a mocked backup
  proves nothing, because the whole premise of this feature is that the file
  it writes is one `scripts/restore.sh` can restore. Skipped when the client
  tools aren't installed, which is a real state on a machine that hasn't
  installed them and is exactly what `availability/0` reports.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Manifest
  alias KilnCMS.Backups.Worker

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
      assert :ok = Worker.run("manual")

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
    test "names artifacts exactly the way scripts/backup.sh does", %{dir: dir} do
      # The interchange guarantee: `scripts/restore.sh` finds a backup by
      # globbing these names, so a divergence here means the shell tooling
      # silently stops seeing app-made backups.
      assert :ok = Worker.run("manual")

      assert [dump] = Path.wildcard(Path.join([dir, "db", "kiln-db-*.dump"]))
      assert Path.basename(dump) =~ ~r/\Akiln-db-\d{8}-\d{6}\.dump\z/

      assert [archive] = Path.wildcard(Path.join([dir, "media", "kiln-media-*.tar.gz"]))
      assert Path.basename(archive) =~ ~r/\Akiln-media-\d{8}-\d{6}\.tar\.gz\z/
    end

    @tag :pg_tools
    test "leaves no .partial behind", %{dir: dir} do
      assert :ok = Worker.run("manual")
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

      assert :ok = Worker.run("manual")
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

      assert {:error, _reason} = Worker.run("manual")

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

      Worker.run("manual")
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

      Worker.run("manual")

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

      assert {:error, :disabled} = Worker.run("manual")

      assert %Manifest{ok: true, trigger: "cron"} = Manifest.read(dir)
    end
  end

  describe "retention" do
    @tag :pg_tools
    test "deletes artifacts past keep_days and keeps the rest", %{dir: dir} do
      old = Path.join([dir, "db", "kiln-db-20200101-000000.dump"])
      recent = Path.join([dir, "db", "kiln-db-20991231-000000.dump"])
      File.mkdir_p!(Path.dirname(old))
      File.write!(old, "old")
      File.write!(recent, "recent")

      # mtime is what the script's `find -mtime` uses, so this uses it too —
      # a filename-derived date would disagree with the shell path.
      ancient = System.os_time(:second) - 365 * 24 * 3600
      File.touch!(old, ancient)

      assert :ok = Worker.run("manual")

      refute File.exists?(old)
      assert File.exists?(recent)
    end

    @tag :pg_tools
    test "a RECENT .partial survives — it may be a concurrent run's work", %{dir: dir} do
      partial = Path.join([dir, "db", "kiln-db-20200101-000000.dump.partial"])
      File.mkdir_p!(Path.dirname(partial))
      File.write!(partial, "in progress")

      assert :ok = Worker.run("manual")
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

      assert :ok = Worker.run("manual")
      refute File.exists?(partial)
    end
  end
end
