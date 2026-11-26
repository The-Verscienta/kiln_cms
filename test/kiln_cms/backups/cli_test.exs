defmodule KilnCMS.Backups.CLITest do
  @moduledoc """
  `KilnCMS.Backups.CLI` (#2234): the commands behind `bin/backup` and
  `mix kiln.backup.*`, their exit codes and JSON, and where each may run.

  Every command runs in text and `--json` mode; the JSON must decode and
  carry the documented keys. `run` tests that start a backup need
  `pg_dump`/`pg_restore` on PATH (`:pg_tools`): `Backups.request/2` checks
  for them, though nothing here runs them (the step queue is not drained).

  `async: false`: it changes the VM-wide `KilnCMS.Backups` env.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, CLI, WorkState}
  alias KilnCMS.Test.{BackupDestinations, BackupSchedules}

  @moduletag :capture_log

  @envelope ~w(schema command ok exit_code error)

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_cli_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil, keep_days: 14)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{base: base, dir: dir}
  end

  defp put_backups(overrides) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups), overrides)
    )
  end

  # `CLI.main/2`, asserting it wrote nothing to stderr (under rpc that is the
  # server's, not the operator's).
  defp main(argv, opts \\ []) do
    test = self()
    err = capture_io(:stderr, fn -> send(test, {:main, CLI.main(argv, opts)}) end)
    assert err == ""
    assert_received {:main, {code, output}}
    {code, IO.iodata_to_binary(output)}
  end

  defp json(argv, opts \\ []) do
    {code, output} = main(argv ++ ["--json"], opts)
    assert String.ends_with?(output, "\n")
    decoded = Jason.decode!(output)
    for key <- @envelope, do: assert(Map.has_key?(decoded, key), "missing #{key}")
    assert decoded["schema"] == 1
    assert decoded["exit_code"] == code
    assert decoded["ok"] == (code == 0)
    {code, decoded}
  end

  defp keys!(decoded, keys), do: for(key <- keys, do: assert(Map.has_key?(decoded, key), key))

  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  defp import!(stamp, artifacts, attrs \\ %{}) do
    Backups.import_run!(
      Map.merge(
        %{
          stamp: stamp,
          trigger: "cron",
          status: :succeeded,
          components: artifacts |> Enum.map(& &1.kind) |> Enum.uniq(),
          started_at: stamp |> Artifact.parse_stamp() |> elem(1),
          artifacts: artifacts
        },
        attrs
      ),
      actor: Backups.system()
    )
  end

  # A verifiable media backup on disk and its row.
  defp media!(dir, stamp) do
    name = "kiln-media-#{stamp}.tar.gz"
    data = :crypto.strong_rand_bytes(300)
    File.write!(Path.join([dir, "media", name]), data)

    :ok =
      Checksum.write_sidecar(Path.join([dir, "media", Artifact.sidecar_name(:media, stamp)]), [
        {name, sha(data)}
      ])

    import!(stamp, [
      %{kind: :media, name: name, bytes: byte_size(data), sha256: sha(data), verified: true}
    ])
  end

  describe "usage errors exit 2" do
    for argv <- [
          [],
          ["bogus"],
          ["list", "--nope"],
          ["list", "--limit", "0"],
          ["list", "--limit", "101"],
          ["list", "--limit", "x"],
          ["list", "extra"],
          ["verify"],
          ["verify", "2026-bad"],
          ["verify", "20261118-031700", "b"],
          ["verify", "$(id)"],
          ["run", "--components", "db,db"],
          ["run", "--components", "disk"],
          ["run", "--components", ""],
          ["run", "--timeout", "60"],
          ["run", "--wait", "--timeout", "0"],
          ["prune", "--apply"],
          ["prune", "--delete"],
          ["prune", "--force"],
          ["rescan", "now"],
          ["--json", "run"]
        ] do
      test "#{inspect(argv)}" do
        argv = unquote(argv)
        {2, text} = main(argv)
        if "--json" not in argv, do: assert(text =~ "Usage:")

        {2, decoded} = json(argv)
        assert %{"code" => "usage", "message" => _} = decoded["error"]
      end
    end

    test "prune's usage says where a real prune runs" do
      {2, text} = main(["prune", "--apply"])
      assert text =~ "a real prune\n      runs inside every backup (bin/backup run)"
    end
  end

  test "help, --help and -h exit 0 with the usage" do
    for argv <- [["help"], ["--help"], ["-h"], ["list", "--help"]] do
      assert {0, "Usage:" <> _} = main(argv)
    end

    assert {0, "Usage:\n  mix kiln.backup.list" <> _} = main(["help"], mode: :mix)
  end

  describe "parse/1" do
    test "returns the command and its arguments, reading nothing" do
      assert {:ok, :list, %{limit: 20, json: false}} = CLI.parse(["list"])

      assert {:ok, :verify, %{target: {:stamp, "20261118-031700"}}} =
               CLI.parse(["verify", "20261118-031700"])

      id = Ecto.UUID.generate()

      assert {:ok, :verify, %{target: {:id, ^id}, json: true}} =
               CLI.parse(["verify", id, "--json"])

      assert {:ok, :run, %{components: ["db"], wait: true, timeout_s: 60}} =
               CLI.parse(["run", "--components", "db", "--wait", "--timeout", "60"])

      assert {:usage, _} = CLI.parse(["--json", "list"])
    end
  end

  describe "mode guards" do
    test "under eval, run, rescan and prune are refused, and nothing is called" do
      test = self()
      importer = fn -> send(test, :imported) end
      retention = fn _dir, _opts -> send(test, :retention) end

      for command <- ~w(run rescan prune) do
        assert {1, text} = main([command], mode: :eval, importer: importer, retention: retention)
        assert text =~ "needs the running application"

        {1, decoded} = json([command], mode: :eval, importer: importer, retention: retention)
        assert decoded["error"]["code"] == "needs_running_node"
      end

      refute_received :imported
      refute_received :retention
      assert Backups.in_flight() == nil
    end

    test "under rpc, verify is refused with 2" do
      assert {2, text} = main(["verify", "20261118-031700"], mode: :rpc)
      assert text =~ "runs beside the application"

      {2, decoded} = json(["verify", "20261118-031700"], mode: :rpc)
      assert decoded["error"]["code"] == "runs_beside_node"
    end
  end

  describe "list" do
    test "shows each run's presence", %{dir: dir} do
      here = media!(dir, "20261118-031700")

      gone =
        import!("20261117-031700", [
          %{kind: :db, name: "kiln-db-20261117-031700.dump", bytes: 5, sha256: sha("x")}
        ])

      {0, text} = main(["list"])
      assert text =~ ~r/20261118-031700\s+succeeded\s+imported\s+media\s+present/
      assert text =~ ~r/20261117-031700\s+succeeded\s+imported\s+db\s+missing/

      {0, decoded} = json(["list"])
      keys!(decoded, ~w(limit runs in_flight))
      assert decoded["in_flight"] == nil
      assert [first, second] = decoded["runs"]

      keys!(first, ~w(id stamp status origin trigger components started_at finished_at error
                      offsite_status dir_id presence in_flight resumable artifacts))

      assert %{"id" => id, "presence" => "present", "in_flight" => false} = first
      assert id == here.id
      assert %{"id" => gone_id, "presence" => "missing"} = second
      assert gone_id == gone.id

      assert [artifact] = first["artifacts"]
      keys!(artifact, ~w(kind name bytes verified sha256 parts presence gone))
    end

    test "--limit 1 returns one run", %{dir: dir} do
      media!(dir, "20261118-031700")
      media!(dir, "20261117-031700")

      {0, decoded} = json(["list", "--limit", "1"])
      assert [%{"stamp" => "20261118-031700"}] = decoded["runs"]
    end

    test "no runs" do
      assert {0, "No backups recorded.\n"} = main(["list"])
    end

    @tag :pg_tools
    test "shows what is running while the lock is held" do
      {:ok, %{status: :started}} = Backups.request([trigger: "console"], Backups.system())

      {0, decoded} = json(["list"])
      keys!(decoded["in_flight"], ~w(chain stamp resume trigger step part phase acquired_at
                                     components waiting))
      assert %{"trigger" => "console", "step" => "start"} = decoded["in_flight"]

      assert {0, "Running now: " <> _} = main(["list"])
    end

    test "a database that can't be reached says so" do
      refusing = fn _opts -> {:error, %DBConnection.ConnectionError{message: "refused"}} end

      {1, text} = main(["list"], read_runs: refusing)
      assert text =~ "the database is unreachable"

      wrapped = fn _opts ->
        {:error, Ash.Error.to_error_class(%DBConnection.ConnectionError{message: "refused"})}
      end

      {1, decoded} = json(["list"], read_runs: wrapped)
      assert decoded["error"]["code"] == "database_unreachable"
    end

    test "another read failure is reported as one" do
      {1, decoded} = json(["list"], read_runs: fn _opts -> {:error, :boom} end)
      assert decoded["error"]["code"] == "read_failed"
    end
  end

  describe "run" do
    @describetag :pg_tools

    test "starts a backup as the console" do
      {0, text} = main(["run", "--components", "db"])
      assert text =~ "Backup started (chain "
      assert %{trigger: "console", chain: chain} = Backups.in_flight()

      assert [%{args: %{"components" => ["db"]}}] =
               KilnCMS.Test.BackupChain.step_jobs(chain: chain)
    end

    test "--json reports the chain" do
      {0, decoded} = json(["run"])
      keys!(decoded, ~w(status chain stamp components waited outcome run))
      assert %{"status" => "started", "waited" => false, "outcome" => nil} = decoded
      assert decoded["chain"] == Backups.in_flight().chain
    end

    test "a second request is queued, and exits 0" do
      {0, _} = main(["run"])
      {0, decoded} = json(["run"])
      assert decoded["status"] == "queued"
    end

    test "a fresh request behind a queued resume is queue_busy, 1", %{dir: dir} do
      stamp = "20261101-101010"

      run =
        Backups.start_run!(%{stamp: stamp, trigger: "manual", components: [:db]},
          actor: Backups.system()
        )

      Backups.fail_run!(run, %{error: "tar exited 2"}, actor: Backups.system())
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))

      {:ok, %{status: :started}} = Backups.request([], Backups.system())
      {:ok, %{status: :queued}} = Backups.request([resume: stamp], Backups.system())

      {1, text} = main(["run"])
      assert text =~ "a resume of #{stamp} is queued"

      {1, decoded} = json(["run"])
      assert decoded["error"]["code"] == "queue_busy"
    end

    test "--wait follows the backup to its end" do
      ok = fn _chain, opts ->
        assert opts[:timeout] <= 10_000
        :ok
      end

      {0, decoded} = json(["run", "--wait"], await: ok)
      assert %{"waited" => true, "outcome" => "succeeded"} = decoded
    end

    test "--wait on a backup that ends canceled exits 1" do
      canceled = fn _chain, _opts -> {:error, :canceled} end
      {1, decoded} = json(["run", "--wait"], await: canceled)
      assert %{"outcome" => "canceled", "error" => %{"code" => "canceled"}} = decoded
    end

    test "--wait stops at --timeout" do
      slow = fn _chain, _opts ->
        Process.sleep(50)
        {:error, :timeout}
      end

      {1, decoded} = json(["run", "--wait", "--timeout", "1"], await: slow)
      assert %{"outcome" => "timeout", "error" => %{"code" => "timeout"}} = decoded
    end

    test "--wait stops within a chunk once the caller is gone, printing nothing" do
      caller = spawn(fn -> :ok end)
      ref = Process.monitor(caller)
      test = self()

      await = fn _chain, _opts ->
        send(test, :awaited)
        {:error, :timeout}
      end

      assert {1, ""} = main(["run", "--wait"], await: await, caller_ref: ref)
      refute_received :awaited
    end

    test "--wait on a queued request exits 1 with code queued, and never waits" do
      {0, _} = main(["run"])
      test = self()
      await = fn _chain, _opts -> send(test, :awaited) end

      {1, decoded} = json(["run", "--wait"], await: await)

      assert %{"status" => "queued", "error" => %{"code" => "queued", "message" => message}} =
               decoded

      assert message =~ "queued behind the running backup"
      refute_received :awaited
    end

    test "--wait on a folded request exits 1 with code not_started, and never waits" do
      {0, _} = main(["run"])
      {0, _} = main(["run"])
      test = self()
      await = fn _chain, _opts -> send(test, :awaited) end

      {1, decoded} = json(["run", "--wait"], await: await)

      assert %{"status" => "folded", "error" => %{"code" => "not_started", "message" => message}} =
               decoded

      assert message =~ "already queued behind the running one"
      refute_received :awaited
    end
  end

  test "run with backups turned off is refused" do
    put_backups(enabled: false)

    {1, text} = main(["run"])
    assert text =~ "BACKUP_ENABLED=false"

    {1, decoded} = json(["run"])
    assert decoded["error"]["code"] == "disabled"
  end

  describe "verify" do
    test "by stamp and by id", %{dir: dir} do
      run = media!(dir, "20261118-031700")

      {0, text} = main(["verify", run.stamp])
      assert text =~ "Backup 20261118-031700 verified here (1 file(s) hashed)."

      {0, decoded} = json(["verify", run.id])
      keys!(decoded, ~w(run verified hashed failed dir_id_mismatch dir_id_error artifacts checks))
      assert %{"verified" => true, "hashed" => 1} = decoded
      keys!(hd(decoded["checks"]), ~w(kind file check result code detail))
      keys!(hd(decoded["artifacts"]), ~w(kind name recorded_verified result))
    end

    test "a changed file exits 1", %{dir: dir} do
      run = media!(dir, "20261118-031700")
      File.write!(Path.join([dir, "media", "kiln-media-#{run.stamp}.tar.gz"]), "changed")

      {1, text} = main(["verify", run.stamp])
      assert text =~ "NOT verified"

      {1, decoded} = json(["verify", run.stamp])
      assert decoded["error"]["code"] == "not_verified"
    end

    test "nothing on this host's disk is not a pass" do
      import!("20261118-031700", [
        %{
          kind: :media,
          name: "kiln-media-20261118-031700.tar.gz",
          bytes: 3,
          sha256: sha("abc"),
          verified: true,
          destinations: %{"local" => %{"status" => "pruned"}}
        }
      ])

      {1, decoded} = json(["verify", "20261118-031700"])
      assert %{"hashed" => 0, "failed" => 0, "error" => %{"code" => "nothing_local"}} = decoded
    end

    test "an unknown backup exits 1" do
      {1, decoded} = json(["verify", "20261118-031700"])
      assert decoded["error"]["code"] == "not_found"
      assert {1, _} = main(["verify", Ecto.UUID.generate()])
    end

    test "a backup lock that can't be read refuses with lock_unreadable", %{dir: dir} do
      run = media!(dir, "20261118-031700")
      unreadable = fn -> {:error, :boom} end

      {1, text} = main(["verify", run.stamp], held_stamp: unreadable)
      assert text =~ "the backup lock couldn't be read"

      {1, decoded} = json(["verify", run.stamp], held_stamp: unreadable)
      assert %{"error" => %{"code" => "lock_unreadable"}} = decoded
      refute Map.has_key?(decoded, "checks")
    end

    test "a database that can't be reached says so" do
      refusing = fn _opts -> {:error, %DBConnection.ConnectionError{message: "refused"}} end
      {1, decoded} = json(["verify", "20261118-031700"], read_runs: refusing)
      assert decoded["error"]["code"] == "database_unreachable"
    end
  end

  describe "prune" do
    # Two old dumps the policy deletes and a new one it keeps.
    defp old_units!(dir) do
      day = 86_400
      now = System.os_time(:second)

      for {stamp, age_days} <- [
            {"20260101-000000", 90},
            {"20260102-000000", 89},
            {"20261118-000000", 0}
          ] do
        path = Path.join([dir, "db", "kiln-db-#{stamp}.dump"])
        File.write!(path, "dump #{stamp}")
        File.touch!(path, now - age_days * day)
      end
    end

    defp listing(dir) do
      for sub <- ["", "db", "media"], name <- File.ls!(Path.join(dir, sub)), into: %{} do
        path = Path.join([dir, sub, name])
        {Path.join(sub, name), File.stat!(path, time: :posix).mtime}
      end
    end

    test "reports what retention would delete, and deletes nothing", %{dir: dir} do
      old_units!(dir)
      # The first pass imports the cron-made dumps; compare after it.
      {_code, _} = main(["prune"])
      before = listing(dir)

      {0, text} = main(["prune"])

      assert String.starts_with?(
               text,
               "Report only — nothing is deleted. A real prune runs inside every backup (bin/backup run).\n"
             )

      assert text =~ "db/kiln-db-20260101-000000.dump  (expired)"

      {0, decoded} = json(["prune"])
      keys!(decoded, ~w(report_only would_delete kept last_good destinations in_flight))
      assert decoded["report_only"] == true

      stamps = Enum.map(decoded["would_delete"], & &1["stamp"])
      assert "20260101-000000" in stamps
      keys!(hd(decoded["would_delete"]), ~w(stamp kind sub files reason_code))

      assert listing(dir) == before
      refute Enum.any?(Map.keys(listing(dir)), &String.ends_with?(&1, [".good", ".hold"]))

      for run <- Backups.list_runs!(actor: Backups.system()), artifact <- run.artifacts do
        refute get_in(artifact.destinations, ["local", "status"]) == "pruned"
      end
    end

    test "passes retention exactly [dry_run: true]", %{dir: dir} do
      test = self()

      retention = fn given_dir, opts ->
        send(test, {:retention, given_dir, opts})
        {:ok, %{plan: %{delete: [], keep: [], last_good: %{db: nil, media: nil}}}}
      end

      {0, _} = main(["prune"], retention: retention)
      assert_received {:retention, ^dir, [dry_run: true]}

      {0, _} = main(["prune", "--dry-run"], retention: retention)
      assert_received {:retention, ^dir, [dry_run: true]}
    end

    test "a retention that can't plan exits 1" do
      retention = fn _dir, _opts -> {:error, {:read_runs, :boom}} end

      {1, text} = main(["prune"], retention: retention)
      assert text =~ "couldn't plan"

      {1, decoded} = json(["prune"], retention: retention)
      assert %{"error" => %{"code" => "read_runs"}, "would_delete" => nil} = decoded
    end

    @tag :tmp_dir
    test "each enabled destination's pruning state", %{tmp_dir: tmp_dir} do
      put_backups(local_destination_roots: [tmp_dir])
      site = Path.join(tmp_dir, "site")
      inner = Path.join(site, "inner")
      File.mkdir_p!(inner)
      admin = BackupSchedules.platform_admin()

      on = BackupDestinations.destination!(%{name: "On"}, admin)
      off = BackupDestinations.destination!(%{name: "Off", prune: false}, admin)

      blocked =
        Backups.create_backup_destination!(
          %{name: "Outer", kind: "local", settings: %{"path" => site}},
          actor: admin
        )

      # Disabled, so not reported, but it still overlaps the outer one. Seeded:
      # the create validation refuses an overlapping place, and this is the
      # row an older release (or a later edit of the outer one's peers) left.
      Ash.Seed.seed!(KilnCMS.Backups.DestinationConfig, %{
        name: "Inner",
        kind: "local",
        settings: %{"path" => inner},
        enabled: false
      })

      retention = fn _dir, _opts ->
        {:ok, %{plan: %{delete: [], keep: [], last_good: %{db: nil, media: nil}}}}
      end

      {0, decoded} = json(["prune"], retention: retention)
      by_name = Map.new(decoded["destinations"], &{&1["name"], &1})

      assert Map.keys(by_name) |> Enum.sort() == ["Off", "On", "Outer"]
      keys!(by_name["On"], ~w(key name kind state reason_code reason))
      assert %{"state" => "on", "key" => key} = by_name["On"]
      assert key == "dest:" <> on.id
      assert %{"state" => "off"} = by_name["Off"]
      assert by_name["Off"]["key"] == "dest:" <> off.id

      assert %{"state" => "blocked", "reason_code" => "destination_overlap"} = by_name["Outer"]
      assert by_name["Outer"]["key"] == "dest:" <> blocked.id

      {0, text} = main(["prune"], retention: retention)
      assert text =~ "Outer (local): pruning blocked: it overlaps another backup destination"
    end
  end

  describe "rescan" do
    test "passes the importer's summary through, keys it adds included" do
      importer = fn ->
        {:ok, %{imported: 2, pending: 0, skipped: 0, failed: 0, deferred: 0, reevaluated: 1}}
      end

      {0, text} = main(["rescan"], importer: importer)
      assert text =~ "2 imported"
      assert text =~ "1 reevaluated"

      {0, decoded} = json(["rescan"], importer: importer)
      assert %{"scope" => "local", "summary" => %{"imported" => 2, "reevaluated" => 1}} = decoded
    end

    test "a failed import exits 1" do
      importer = fn -> {:ok, %{imported: 0, pending: 0, skipped: 0, failed: 1, deferred: 0}} end
      {1, decoded} = json(["rescan"], importer: importer)
      assert decoded["error"]["code"] == "import_failed"
    end

    test "an importer error exits 1" do
      {1, decoded} = json(["rescan"], importer: fn -> {:error, :eacces} end)
      assert %{"error" => %{"code" => "rescan_failed"}, "summary" => nil} = decoded
    end

    test "the real importer, against an empty directory" do
      {0, decoded} = json(["rescan"])
      assert decoded["summary"]["failed"] == 0
    end
  end
end
