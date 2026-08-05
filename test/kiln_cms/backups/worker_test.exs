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

  defp tools?, do: Backups.availability() == :ok

  describe "a real run" do
    @tag :tmp_dir
    test "produces a verified dump and media archive, and a manifest describing them", %{dir: dir} do
      if tools?() do
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
      else
        assert {:error, reason} = Backups.availability()
        assert reason in [:no_pg_dump, :no_pg_restore]
      end
    end

    test "names artifacts exactly the way scripts/backup.sh does", %{dir: dir} do
      # The interchange guarantee: `scripts/restore.sh` finds a backup by
      # globbing these names, so a divergence here means the shell tooling
      # silently stops seeing app-made backups.
      if tools?() do
        assert :ok = Worker.run("manual")

        assert [dump] = Path.wildcard(Path.join([dir, "db", "kiln-db-*.dump"]))
        assert Path.basename(dump) =~ ~r/\Akiln-db-\d{8}-\d{6}\.dump\z/

        assert [archive] = Path.wildcard(Path.join([dir, "media", "kiln-media-*.tar.gz"]))
        assert Path.basename(archive) =~ ~r/\Akiln-media-\d{8}-\d{6}\.tar\.gz\z/
      end
    end

    test "leaves no .partial behind", %{dir: dir} do
      if tools?() do
        assert :ok = Worker.run("manual")
        assert Path.wildcard(Path.join([dir, "**", "*.partial"])) == []
      end
    end

    test "skips the media archive when no media directory is configured", %{dir: dir} do
      # The S3 case: the bucket is backed up provider-side, and tarring the
      # wrong directory would yield an archive that looks like a media backup
      # and restores nothing.
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :media_dir, nil))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      if tools?() do
        assert :ok = Worker.run("manual")
        assert [%{kind: "db"}] = Manifest.read(dir).artifacts
      end
    end
  end

  describe "failure" do
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

      if tools?() do
        assert {:error, _reason} = Worker.run("manual")

        manifest = Manifest.read(dir)

        refute manifest.ok
        assert manifest.artifacts == []
        assert is_binary(manifest.error)
        refute Manifest.verified?(manifest)
      end
    end

    test "a failed run leaves no .partial to be mistaken for a backup", %{dir: dir} do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(original, :database_url, "postgres://nobody:nope@127.0.0.1:1/nope")
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      if tools?() do
        Worker.run("manual")
        assert Path.wildcard(Path.join([dir, "**", "*.partial"])) == []
      end
    end

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

      if tools?() do
        Worker.run("manual")

        error = Manifest.read(dir).error || ""
        refute error =~ "hunter2"
      end
    end

    test "a disabled deployment records why rather than running", %{dir: dir} do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      assert {:error, :disabled} = Worker.run("manual")
      assert %Manifest{ok: false, error: "disabled"} = Manifest.read(dir)
    end
  end

  describe "retention" do
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

      if tools?() do
        assert :ok = Worker.run("manual")

        refute File.exists?(old)
        assert File.exists?(recent)
      end
    end

    test "a .partial is never pruned out from under a running backup", %{dir: dir} do
      # Pruning runs after the artifacts land, and a concurrent run's
      # in-progress file must survive it.
      partial = Path.join([dir, "db", "kiln-db-20200101-000000.dump.partial"])
      File.mkdir_p!(Path.dirname(partial))
      File.write!(partial, "in progress")
      File.touch!(partial, System.os_time(:second) - 365 * 24 * 3600)

      if tools?() do
        assert :ok = Worker.run("manual")
        assert File.exists?(partial)
      end
    end
  end
end
