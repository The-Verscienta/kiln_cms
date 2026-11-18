defmodule KilnCMS.Backups.FanoutTest do
  @moduledoc """
  The off-site step sending to every destination, one `offsite` job each
  (#2220, plan step S6): the env destination (`BACKUP_RCLONE_REMOTE`) and
  stored ones (`KilnCMS.Backups.DestinationConfig`), with a destination that
  fails, raises, hangs, refuses a file or disappears mid-backup.

  What an env-only deployment sees is pinned, unchanged, by
  `offsite_parity_test.exs`; this file is everything beyond that.

  Runs real `pg_dump` and `tar` (`:pg_tools`); `rclone` is a stub ahead of
  them on PATH, and stored destinations use the test-only
  `KilnCMS.Test.BackupDestinations.Fake` or a Local destination under a
  temporary root. `async: false`: PATH, `Application` env and telemetry
  handlers are VM-global.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.Test.BackupDestinations, only: [destination!: 3]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Manifest, RunDestination, WorkState}
  alias KilnCMS.Repo
  alias KilnCMS.Test.{BackupChain, BackupSchedules}

  @moduletag :capture_log
  @moduletag :pg_tools

  @secret "fanout-secret-token-987"

  @conn_remote ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket"

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_fan_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(media)

    # Six 300-byte files with a 700-byte cap: three parts of two files each.
    for n <- 1..6, do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    original_dest = Application.get_env(:kiln_cms, KilnCMS.Backups.Destination, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original,
        enabled: true,
        dir: dir,
        media_dir: media,
        keep_days: 14,
        media_part_bytes: 700,
        rclone_remote: nil
      )
    )

    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      Application.put_env(:kiln_cms, KilnCMS.Backups.Destination, original_dest)
      File.rm_rf!(base)
    end)

    %{base: base, dir: dir, media: media, admin: BackupSchedules.platform_admin()}
  end

  # -- helpers ---------------------------------------------------------------

  defp remote!(remote), do: backups_env(:rclone_remote, remote)

  defp backups_env(key, value) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), key, value)
    )
  end

  defp call_timeout!(ms) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups.Destination,
      Keyword.put(
        Application.get_env(:kiln_cms, KilnCMS.Backups.Destination, []),
        :call_timeout,
        ms
      )
    )
  end

  defp dest_env(key, value) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups.Destination,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups.Destination, []), key, value)
    )
  end

  # An rclone that logs its argv to `log`, one line per call, and exits 1
  # while `fail` exists.
  defp fake_rclone!(base) do
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    f = Map.new([:log, :fail], &{&1, Path.join(base, "rclone.#{&1}")})

    File.write!(Path.join(bin, "rclone"), """
    #!/bin/sh
    echo "$*" >> "#{f.log}"
    [ -f "#{f.fail}" ] && { echo "upload refused" >&2; exit 1; }
    exit 0
    """)

    File.chmod!(Path.join(bin, "rclone"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    Map.put(f, :exe, Path.join(bin, "rclone"))
  end

  # A stored Fake destination: `settings` over `"mode" => "ok"`, its secret
  # token `@secret`.
  defp fake!(name, position, settings) do
    destination!(
      %{name: name, position: position, settings: Map.merge(%{"mode" => "ok"}, settings)},
      nil,
      @secret
    )
  end

  defp lines(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp run!, do: hd(Backups.list_runs!(actor: Backups.system()))

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp offsite_jobs, do: BackupChain.step_jobs(step: "offsite")

  defp offsite_job(part), do: Enum.find(offsite_jobs(), &(&1.args["part"] == part))

  # The files the off-site step copies, in order: the dump, the three media
  # parts, then the db and media checksum sidecars.
  defp names(stamp) do
    ["kiln-db-#{stamp}.dump" | Enum.map(1..3, &Artifact.part_name(stamp, &1))] ++
      [Artifact.sidecar_name(:db, stamp), Artifact.sidecar_name(:media, stamp)]
  end

  defp entry(run, key), do: Enum.find(run.destinations, &(&1.key == key))

  defp status(map, key), do: get_in(map, [key, "status"])

  # Run the chain's jobs one at a time until the lock points at `step` (`part`).
  defp step_until(step, part \\ nil) do
    row = lock()

    unless to_string(row.step) == step and row.part == part do
      %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      step_until(step, part)
    end
  end

  defp listen_partial do
    id = {__MODULE__, make_ref()}
    pid = self()

    :telemetry.attach(
      id,
      [:kiln_cms, :backups, :offsite, :partial],
      fn _event, measurements, metadata, _ -> send(pid, {:partial, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Hides `rclone` on a host that has one installed (as the parity test does).
  defp no_rclone_on_path(base) do
    shims = Path.join(base, "norclone")

    kept =
      System.get_env("PATH")
      |> String.split(":")
      |> Enum.with_index()
      |> Enum.map_join(":", fn {dir, i} -> without_rclone(dir, Path.join(shims, "#{i}")) end)

    System.put_env("PATH", kept)
  end

  defp without_rclone(dir, shim) do
    if File.exists?(Path.join(dir, "rclone")) do
      File.mkdir_p!(shim)

      for name <- File.ls!(dir),
          name != "rclone",
          do: File.ln_s!(Path.join(dir, name), Path.join(shim, name))

      shim
    else
      dir
    end
  end

  # -- the acceptance case ---------------------------------------------------

  describe "two destinations, one failing every attempt" do
    test "the run succeeds partly off-site, with mixed status, an alarm line and telemetry", %{
      base: base,
      dir: dir
    } do
      listen_partial()
      remote!("r2:kiln")
      rclone = fake_rclone!(base)
      log = Path.join(base, "b.log")
      b = fake!("Bucket B", 1, %{"put_mode" => "fail", "log" => log})
      bkey = "dest:" <> b.id

      assert :ok = BackupChain.run()
      run = run!()

      assert run.status == :succeeded
      assert run.offsite_status == :partial
      assert length(lines(rclone.log)) == 6

      # Four attempts, each trying every file: nothing was ever sent to skip.
      assert length(lines(log)) == 24
      assert %{attempt: 4, state: "completed"} = offsite_job(2)
      assert %{attempt: 1, state: "completed"} = offsite_job(1)

      assert [
               %RunDestination{key: "rclone:r2:kiln", status: :ok, files_ok: 6, files_total: 6},
               %RunDestination{key: ^bkey, status: :failed, label: "Bucket B", error: error}
             ] = run.destinations

      assert error =~ "FAILED for 6 files"
      assert error =~ "***"
      refute error =~ @secret

      for artifact <- run.artifacts do
        assert status(artifact.destinations, "rclone:r2:kiln") == "ok"
        assert status(artifact.destinations, bkey) == "failed"
        refute inspect(artifact.destinations) =~ @secret
      end

      assert Enum.any?(
               run.log,
               &(&1.level == :error and
                   &1.message =~
                     "Partly off-site: reached 1 of 2 destination(s); " <>
                       "not reached: Bucket B")
             )

      assert_received {:partial, %{reached: 1, total: 2}, %{missed: [^bkey]}}

      manifest = Manifest.read(dir)
      assert manifest.ok
      assert manifest.offsite == "r2:kiln"

      assert manifest.destinations == [
               %{key: "rclone:r2:kiln", label: "r2:kiln", status: "ok"},
               %{key: bkey, label: "Bucket B", status: "failed"}
             ]

      refute Backups.work_state?(run.stamp)
    end

    # `:tmp_dir`: a Local destination's path may hold no symlink, and the
    # system temp directory sits behind one on macOS.
    @tag :tmp_dir
    test "a Local destination that is reached makes the run complete", %{
      base: base,
      tmp_dir: tmp_dir,
      admin: admin
    } do
      remote!("r2:kiln")
      fake_rclone!(base)
      backups_env(:local_destination_roots, [tmp_dir])
      path = Path.join(tmp_dir, "site")
      File.mkdir_p!(path)

      local =
        Backups.create_backup_destination!(
          %{name: "Disk", kind: "local", position: 1, settings: %{"path" => path}},
          actor: admin
        )

      assert :ok = BackupChain.run()
      run = run!()

      assert run.status == :succeeded
      assert run.offsite_status == :complete

      assert Enum.map(run.destinations, &{&1.key, &1.status}) ==
               [{"rclone:r2:kiln", :ok}, {"dest:" <> local.id, :ok}]

      for name <- names(run.stamp) do
        sub = if String.starts_with?(name, "kiln-db-"), do: "db", else: "media"
        assert File.regular?(Path.join([path, sub, name])), "#{name} did not land"
      end

      refute Enum.any?(run.log, &(&1.message =~ "Partly off-site"))
    end
  end

  # -- every destination failing ---------------------------------------------

  describe "every destination failing" do
    test "fails the run with each destination named, and keeps it resumable", %{base: base} do
      remote!("r2:kiln")
      rclone = fake_rclone!(base)
      File.write!(rclone.fail, "")
      b = fake!("Bucket B", 1, %{"put_mode" => "fail"})

      assert {:error, {:offsite, {:destinations, failures}}} = BackupChain.run()
      assert [{"r2:kiln", env_error}, {"Bucket B", b_error}] = failures
      assert env_error =~ "FAILED for 6 files"
      assert b_error =~ "FAILED for 6 files"

      run = run!()
      assert run.status == :failed
      assert run.offsite_status == :failed

      assert run.error =~
               "Off-site copy FAILED to every destination (2): r2:kiln: FAILED for 6 files: " <>
                 "kiln-db-#{run.stamp}.dump (rclone exited 1)"

      assert run.error =~ "; Bucket B: FAILED for 6 files"
      assert run.error =~ "Resume retries the off-site copies."
      refute run.error =~ @secret

      assert Enum.map(run.destinations, &{&1.key, &1.status}) ==
               [{"rclone:r2:kiln", :failed}, {"dest:" <> b.id, :failed}]

      assert %{attempt: 4, state: "cancelled"} = offsite_job(2)
      assert Backups.work_state?(run.stamp)
      assert Backups.run_resumable?(run)
    end

    test "a Resume with the env remote fixed re-copies every file there, and skips what the " <>
           "stored destination already has, except a rebuilt part",
         %{base: base, dir: dir, media: media} do
      remote!("r2:kiln")
      rclone = fake_rclone!(base)
      File.write!(rclone.fail, "")
      log = Path.join(base, "b.log")
      # Takes everything but the checksum sidecars.
      b = fake!("Bucket B", 1, %{"fail_names" => ".sha256", "log" => log})
      bkey = "dest:" <> b.id

      assert {:error, {:offsite, {:destinations, _}}} = BackupChain.run()
      stamp = run!().stamp
      [dump, p1, p2, p3, db_sidecar, media_sidecar] = names(stamp)

      # The first attempt sent four files; the next three only tried the two
      # sidecars again.
      assert lines(log) ==
               names(stamp) ++ List.flatten(List.duplicate([db_sidecar, media_sidecar], 3))

      # Part 2 changes: its media changed, and the file on disk no longer
      # matches its record, so the resume rebuilds it with a new sha256.
      # Parts 1 and 3 still match their records, so they are reused as they are.
      for n <- 1..6,
          do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

      File.write!(Path.join([dir, "media", p2]), "x", [:append])

      File.rm!(rclone.fail)
      File.rm!(rclone.log)
      File.rm!(log)

      assert :ok = BackupChain.resume(stamp)

      # The env destination copies every file again, as it always did.
      assert length(lines(rclone.log)) == 6

      # The stored one gets the rebuilt part and the sidecars, nothing else.
      sent = lines(log)
      assert p2 in sent
      refute dump in sent
      refute p1 in sent
      refute p3 in sent
      assert db_sidecar in sent and media_sidecar in sent

      run = run!()
      assert run.stamp == stamp
      assert run.status == :succeeded
      assert run.offsite_status == :partial
      assert entry(run, "rclone:r2:kiln").status == :ok
      assert %{status: :failed, files_ok: 4, files_total: 6} = entry(run, bkey)

      [_db, media_artifact] = run.artifacts
      assert status(media_artifact.destinations, bkey) == "ok"

      assert Enum.any?(
               run.log,
               &(&1.message == "#{dump} was already copied to Bucket B; not sent again")
             )
    end
  end

  # -- a refused file --------------------------------------------------------

  describe "a file that changes while an earlier destination is being sent to" do
    test "is refused for the next destination, which fails the backup; nothing further is sent",
         %{base: base} do
      [a_log, b_log, c_log] = for n <- ~w(a b c), do: Path.join(base, "#{n}.log")
      # A appends to part 2 once it has been sent the checksum sidecars.
      fake!("A", 1, %{"log" => a_log, "tamper_after" => ".sha256"})
      b = fake!("B", 2, %{"log" => b_log})
      fake!("C", 3, %{"log" => c_log})

      assert {:error, {:offsite, %{refused: [{p2, {:changed, _}}], failed: []}}} =
               BackupChain.run()

      run = run!()
      stamp = run.stamp
      assert p2 == Artifact.part_name(stamp, 2)

      # A got everything (part 2 was unchanged when it was sent there); B was
      # re-checked file by file and refused only part 2; C never ran.
      assert lines(a_log) == names(stamp)
      assert lines(b_log) == names(stamp) -- [p2]
      assert lines(c_log) == []
      assert offsite_job(3) == nil

      assert run.status == :failed
      assert run.error =~ "Off-site copy REFUSED for 1 file: #{p2} (changed on disk"
      # B's own Run entry names the refusal, not an inspected problems map.
      assert %{status: :failed, error: b_error} = entry(run, "dest:" <> b.id)
      assert b_error =~ "REFUSED for 1 file: #{p2}"
      assert %{attempt: 1, state: "cancelled"} = offsite_job(2)

      [db, media] = run.artifacts
      assert db.verified
      refute media.verified
    end
  end

  # -- adapters that misbehave -----------------------------------------------

  describe "a destination whose adapter misbehaves" do
    test "a raise is that destination's failure, not the backup's crash" do
      b = fake!("Raises", 1, %{"put_mode" => "raise"})
      c = fake!("Fine", 2, %{})

      assert :ok = BackupChain.run()
      run = run!()

      assert run.status == :succeeded
      assert run.offsite_status == :partial
      assert %{status: :failed, error: error} = entry(run, "dest:" <> b.id)
      assert error =~ "raised"
      refute error =~ @secret
      assert %{status: :ok} = entry(run, "dest:" <> c.id)
    end

    test "a permanent failure fails the destination on the first attempt; the others still " <>
           "run (#2223)",
         %{base: base} do
      log = Path.join(base, "b.log")
      b = fake!("Gone", 1, %{"put_mode" => "permanent", "log" => log})
      c = fake!("Fine", 2, %{})

      assert :ok = BackupChain.run()
      run = run!()

      # One file tried, once: no retry fixes it.
      assert length(lines(log)) == 1
      assert %{attempt: 1, state: "completed"} = offsite_job(1)

      assert run.offsite_status == :partial
      assert %{status: :failed, error: error} = entry(run, "dest:" <> b.id)
      assert error =~ "the bucket is gone"
      refute error =~ @secret
      assert %{status: :ok} = entry(run, "dest:" <> c.id)
    end

    test "a file the destination already holds is recorded as sent, not a crash (#2223)" do
      b = fake!("Holds it", 1, %{"put_mode" => "present"})

      assert :ok = BackupChain.run()
      run = run!()

      assert run.offsite_status == :complete
      assert %{status: :ok, files_ok: 6, files_total: 6} = entry(run, "dest:" <> b.id)

      for artifact <- run.artifacts do
        assert status(artifact.destinations, "dest:" <> b.id) == "ok"
      end

      assert Enum.count(
               run.log,
               &(&1.message =~ "was already on Holds it with the same checksum")
             ) ==
               6
    end

    test "any other {:ok, _} from a put is that destination's failure, not a crash (#2223)" do
      b = fake!("Odd", 1, %{"put_mode" => "ok_weird"})
      c = fake!("Fine", 2, %{})

      assert :ok = BackupChain.run()
      run = run!()

      assert run.offsite_status == :partial
      assert %{status: :failed, error: error} = entry(run, "dest:" <> b.id)
      assert error =~ "returned an unexpected value"
      assert %{status: :ok} = entry(run, "dest:" <> c.id)
    end

    test "a hanging destination times out, fails, and the others still run", %{base: base} do
      call_timeout!(300)
      log = Path.join(base, "b.log")
      b = fake!("Hangs", 1, %{"put_mode" => "sleep", "sleep_ms" => 30_000, "log" => log})
      c = fake!("Fine", 2, %{})

      {elapsed, result} = :timer.tc(fn -> BackupChain.run() end, :millisecond)
      assert :ok = result

      # One file per attempt: a timeout ends the attempt.
      assert length(lines(log)) == 4
      assert elapsed < 20_000

      run = run!()
      assert run.offsite_status == :partial
      assert %{status: :failed, error: error} = entry(run, "dest:" <> b.id)
      assert error =~ "timed out after 300 ms"
      assert %{status: :ok} = entry(run, "dest:" <> c.id)
    end

    test "with no :call_timeout cap, an upload takes as long as the step allows" do
      # The default bound for calls made outside a step, set far below each
      # put here: the step passes its own deadline instead, so an env-only
      # upload slower than the default (60 min in production) still lands.
      dest_env(:default_call_timeout, 100)
      b = fake!("Slow", 1, %{"put_mode" => "sleep", "sleep_ms" => 400})

      assert :ok = BackupChain.run()

      run = run!()
      assert run.offsite_status == :complete
      assert %{status: :ok, error: nil} = entry(run, "dest:" <> b.id)
      assert [%{attempt: 1}] = offsite_jobs()
    end

    test "a missing rclone fails the env destination at once; the other is still reached", %{
      base: base
    } do
      remote!("r2:kiln")
      no_rclone_on_path(base)
      b = fake!("Bucket B", 1, %{})

      assert :ok = BackupChain.run()
      run = run!()

      assert run.status == :succeeded
      assert run.offsite_status == :partial

      assert %{status: :failed, error: "rclone is not installed in this image"} =
               entry(run, "rclone:r2:kiln")

      assert %{status: :ok} = entry(run, "dest:" <> b.id)
      assert %{attempt: 1} = offsite_job(1)

      assert Enum.any?(
               run.log,
               &(&1.message ==
                   "r2:kiln: rclone is not installed in this image; nothing was sent to it")
             )
    end
  end

  # -- the destinations changing under a backup -------------------------------

  describe "a destination deleted while the backup runs" do
    test "is recorded failed, removed during this backup, and the chain moves on", %{
      admin: admin
    } do
      a = fake!("A", 1, %{})
      b = fake!("B", 2, %{})

      BackupChain.listen(fn ->
        {:ok, %{status: :started, chain: chain}} = Backups.request([], Backups.system())
        step_until("offsite", 2)

        :ok =
          Backups.destroy_backup_destination(Backups.get_backup_destination!(b.id, actor: admin),
            actor: admin
          )

        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      run = run!()
      assert run.offsite_status == :partial
      assert %{status: :ok} = entry(run, "dest:" <> a.id)

      assert %{status: :failed, error: "removed or disabled during this backup", label: "B"} =
               entry(run, "dest:" <> b.id)
    end

    test "a destination disabled since the start counts the same", %{admin: admin} do
      a = fake!("A", 1, %{})
      b = fake!("B", 2, %{})

      BackupChain.listen(fn ->
        {:ok, %{status: :started, chain: chain}} = Backups.request([], Backups.system())
        step_until("offsite", 1)
        Backups.update_backup_destination!(b, %{enabled: false}, actor: admin)
        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      run = run!()
      assert %{status: :ok} = entry(run, "dest:" <> a.id)

      assert %{status: :failed, error: "removed or disabled during this backup"} =
               entry(run, "dest:" <> b.id)
    end
  end

  describe "the destinations table can't be read at the start" do
    test "the start retries, then goes ahead with the env remote; the run is partly off-site", %{
      base: base
    } do
      remote!("r2:kiln")
      rclone = fake_rclone!(base)

      # A row no release could load: every read of the table fails.
      Repo.query!(
        "INSERT INTO backup_destinations (name, kind, settings) VALUES ('Broken', 'fake', '\"x\"')"
      )

      assert :ok = BackupChain.run()
      run = run!()

      assert run.status == :succeeded
      assert run.offsite_status == :partial
      assert length(lines(rclone.log)) == 6

      assert [%{key: "rclone:r2:kiln", status: :ok}, %{key: "unreadable", status: :failed} = u] =
               run.destinations

      assert u.error =~ "couldn't read the backup destinations"

      [start] = BackupChain.step_jobs(step: "start")

      assert start.attempt == 4

      assert Enum.any?(
               run.log,
               &(&1.message ==
                   "Couldn't read the backup destinations; this backup is sent only to " <>
                     "BACKUP_RCLONE_REMOTE")
             )
    end
  end

  describe "a chain an older release queued" do
    test "an offsite job with no part and no destinations settles them and runs as part 1", %{
      base: base,
      dir: dir
    } do
      remote!("r2:kiln")
      fake_rclone!(base)
      b = fake!("Bucket B", 1, %{})

      BackupChain.listen(fn ->
        {:ok, %{status: :started, chain: chain}} = Backups.request([], Backups.system())
        step_until("prune")
        %{stamp: stamp} = lock()

        # The state an older release's start wrote: no destinations, no sends.
        work_dir = WorkState.path(dir, stamp)
        {:ok, state} = WorkState.read(work_dir)
        :ok = WorkState.write(work_dir, Map.drop(state, ["destinations", "sent"]))

        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      assert [%{args: %{"part" => nil}, state: "completed"}, %{args: %{"part" => 2}}] =
               offsite_jobs()

      run = run!()
      assert run.offsite_status == :complete

      assert Enum.map(run.destinations, &{&1.key, &1.status}) ==
               [{"rclone:r2:kiln", :ok}, {"dest:" <> b.id, :ok}]
    end
  end

  describe "secrets" do
    test "appear in no Oban job, state.json, the Lock row, the Run, or the log", %{
      base: base,
      dir: dir
    } do
      remote!(@conn_remote)
      rclone = fake_rclone!(base)
      File.write!(rclone.fail, "")
      fake!("Bucket B", 1, %{"put_mode" => "fail"})

      log =
        capture_log(fn ->
          assert {:error, {:offsite, {:destinations, _}}} = BackupChain.run()
        end)

      run = run!()
      {:ok, state} = File.read(WorkState.file(WorkState.path(dir, run.stamp)))
      jobs = BackupChain.step_jobs()

      haystacks = [
        {"the Oban jobs",
         inspect(Enum.map(jobs, &{&1.args, &1.meta, &1.errors}), limit: :infinity)},
        {"state.json", state},
        {"the Lock row", inspect(lock(), limit: :infinity)},
        {"the Run", inspect(run, limit: :infinity)},
        {"the log", log},
        {"the manifest", File.read!(Manifest.path(dir))}
      ]

      for {where, haystack} <- haystacks, secret <- [@secret, "SUPERSECRETVAL", "AKIAEXAMPLE1"] do
        refute haystack =~ secret, "#{where} holds #{secret}"
      end

      # The connection string itself, credentials and all, is nowhere either.
      for {where, haystack} <- haystacks do
        refute haystack =~ "secret_access_key=SUPER", "#{where} holds the remote"
      end

      # It was really there to leak: the fake names it in every error.
      assert log =~ "***"
    end
  end
end
