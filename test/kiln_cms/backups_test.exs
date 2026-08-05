defmodule KilnCMS.BackupsTest do
  @moduledoc """
  In-app backups (#484).

  The manifest is the contract between two writers (cron's shell script and
  the Oban worker) and one reader (the console), so most of what matters here
  is that reading is **total** — a console that raises on a malformed manifest
  can't report "no backup has ever run", which is the single most important
  thing it has to be able to say.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Manifest

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_backups_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, dir: dir, media_dir: nil, keep_days: 14, stale_after_hours: 36)
    )

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
  end

  defp write!(dir, contents), do: File.write!(Manifest.path(dir), contents)

  defp manifest(overrides \\ []) do
    struct(
      %Manifest{
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        trigger: "cron",
        ok: true,
        artifacts: [%{kind: "db", path: "db/kiln-db-x.dump", bytes: 100, verified: true}]
      },
      overrides
    )
  end

  describe "reading a manifest is total" do
    test "a missing file is nil, not an error", %{dir: dir} do
      assert Manifest.read(dir) == nil
    end

    test "a directory that doesn't exist is nil" do
      assert Manifest.read("/nonexistent/#{System.unique_integer()}") == nil
    end

    test "malformed JSON is nil", %{dir: dir} do
      write!(dir, "{not json at all")
      assert Manifest.read(dir) == nil
    end

    test "valid JSON that isn't an object is nil", %{dir: dir} do
      write!(dir, ~s(["a", "list"]))
      assert Manifest.read(dir) == nil
    end

    test "an object with every field missing still parses, with defaults", %{dir: dir} do
      write!(dir, "{}")

      assert %Manifest{ok: false, artifacts: [], trigger: "unknown", finished_at: nil} =
               Manifest.read(dir)
    end

    test "junk field types are dropped rather than crashing", %{dir: dir} do
      write!(dir, ~s({"version": "one", "ok": "yes", "finished_at": 12345, "artifacts": "nope"}))

      assert %Manifest{version: 1, ok: false, finished_at: nil, artifacts: []} =
               Manifest.read(dir)
    end

    test "an artifact entry missing kind or path is skipped, the rest survive", %{dir: dir} do
      write!(
        dir,
        ~s({"artifacts": [{"kind": "db"}, {"path": "x"}, {"kind": "db", "path": "ok"}]})
      )

      assert %Manifest{artifacts: [%{kind: "db", path: "ok"}]} = Manifest.read(dir)
    end
  end

  describe "round-tripping" do
    test "write then read preserves the facts the panel renders", %{dir: dir} do
      written = manifest(trigger: "manual", offsite: "r2:kiln-backups", keep_days: 30)

      assert :ok = Manifest.write(dir, written)
      read = Manifest.read(dir)

      assert read.trigger == "manual"
      assert read.ok == true
      assert read.offsite == "r2:kiln-backups"
      assert read.keep_days == 30
      assert [%{kind: "db", bytes: 100, verified: true}] = read.artifacts
      # Second precision, deliberately: the manifest is a human-readable
      # operational record, and ISO-8601 with fractional seconds in it reads
      # like a measurement rather than a timestamp.
      assert read.finished_at == DateTime.truncate(written.finished_at, :second)
    end

    test "writing leaves no .partial behind", %{dir: dir} do
      assert :ok = Manifest.write(dir, manifest())
      assert Path.wildcard(Path.join(dir, "*.partial")) == []
    end

    test "writing creates the directory when it doesn't exist yet" do
      dir = Path.join(System.tmp_dir!(), "kiln_bk_new_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok = Manifest.write(dir, manifest())
      assert %Manifest{} = Manifest.read(dir)
    end
  end

  describe "verified?/1" do
    test "true only when every artifact verified" do
      assert Manifest.verified?(manifest())

      refute Manifest.verified?(
               manifest(
                 artifacts: [
                   %{kind: "db", path: "a", bytes: 1, verified: true},
                   %{kind: "media", path: "b", bytes: 1, verified: false}
                 ]
               )
             )
    end

    test "a backup that produced NOTHING is not verified" do
      # `Enum.all?/2` over an empty list is true, which would call a run that
      # wrote no files a success.
      refute Manifest.verified?(manifest(artifacts: []))
      refute Manifest.verified?(nil)
    end
  end

  describe "staleness" do
    test "a fresh backup is not stale" do
      refute Backups.stale?(manifest(finished_at: DateTime.utc_now()))
    end

    test "an old one is" do
      old = DateTime.add(DateTime.utc_now(), -40 * 3600, :second)
      assert Backups.stale?(manifest(finished_at: old))
    end

    test "NEVER having run is stale, not fine" do
      # The most alarming state this can be in. Defaulting it to green is how
      # a deployment goes a year without a backup and nobody notices.
      assert Backups.stale?(nil)
      assert Backups.stale?(manifest(finished_at: nil))
    end
  end

  describe "status/0" do
    test "reports no manifest without raising", %{dir: _dir} do
      status = Backups.status()

      assert status.manifest == nil
      assert status.stale? == true
      assert status.configured? == true
    end

    test "reason is nil when everything is fine, never :ok" do
      # `with({:error, r} <- availability, do: r)` returns the non-matching
      # value, so a healthy deployment would report its reason as `:ok` and
      # the panel would render "ok" as though it were a fault.
      status = Backups.status()
      assert status.reason in [nil, :no_pg_dump, :no_pg_restore, :no_database_url]
      refute status.reason == :ok
    end

    test "a disabled deployment is not configured and not available" do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      status = Backups.status()

      refute status.configured?
      refute status.available?
      assert status.reason == :disabled
    end

    test "enqueue refuses rather than queueing a job that must fail" do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      assert {:error, :disabled} = Backups.enqueue()
    end
  end

  describe "the database URL" do
    test "resolves to the database this app is actually connected to" do
      # An operator who configured the app's database should not have to state
      # the connection a second time for backups.
      assert url = Backups.database_url()
      assert url =~ KilnCMS.Repo.config()[:database]
    end

    test "ignores a DATABASE_URL that points somewhere else" do
      # `config/test.exs` configures discrete fields while a stale
      # `DATABASE_URL` can linger in the shell. Backing up whatever that
      # points at, rather than the database being served, is the worst
      # possible way to be wrong about a backup.
      original = System.get_env("DATABASE_URL")
      System.put_env("DATABASE_URL", "postgres://someone:pw@elsewhere:5432/a_different_database")

      on_exit(fn ->
        if original,
          do: System.put_env("DATABASE_URL", original),
          else: System.delete_env("DATABASE_URL")
      end)

      refute Backups.database_url() =~ "a_different_database"
      assert Backups.database_url() =~ KilnCMS.Repo.config()[:database]
    end

    test "an explicitly configured URL wins" do
      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(original, :database_url, "postgres://someone@elsewhere/db")
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      assert Backups.database_url() == "postgres://someone@elsewhere/db"
    end
  end
end
