defmodule KilnCMS.Backups.ResendTest do
  @moduledoc """
  Re-sending a partly off-site backup to the destinations it missed (#2949):
  a step chain under the backup lock that copies the run's files as they are
  in `BACKUP_DIR`, re-hashed before each copy, and never changes the run's
  status or writes a failure manifest.

  Runs real `pg_dump` (`:pg_tools`), database-only, against stored
  destinations that use the test-only `KilnCMS.Test.BackupDestinations.Fake`.
  `async: false`: `Application` env and telemetry handlers are VM-global.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.Test.BackupDestinations, only: [destination!: 3]

  alias KilnCMS.Backups

  alias KilnCMS.Backups.{
    Artifact,
    Chain,
    Heartbeat,
    Manifest,
    Recorder,
    Resend,
    RunDestination,
    Steps,
    WorkState
  }

  alias KilnCMS.Backups.Run.Changes.{Cancel, CancelResend}
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Test.{BackupChain, BackupSchedules}

  @moduletag :capture_log
  @moduletag :pg_tools

  @secret "resend-secret-token-246"

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_resend_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original,
        enabled: true,
        dir: dir,
        media_dir: nil,
        keep_days: 14,
        rclone_remote: nil
      )
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{base: base, dir: dir, admin: BackupSchedules.platform_admin()}
  end

  # -- helpers ---------------------------------------------------------------

  defp backups_env(key, value) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), key, value)
    )
  end

  defp fake!(name, position, settings) do
    destination!(
      %{name: name, position: position, settings: Map.merge(%{"mode" => "ok"}, settings)},
      nil,
      @secret
    )
  end

  defp settings!(dest, settings, admin) do
    Backups.update_backup_destination!(
      dest,
      %{settings: Map.merge(%{"mode" => "ok"}, settings)},
      actor: admin
    )
  end

  defp run!, do: hd(Backups.list_runs!(actor: Backups.system()))
  defp run_of(stamp), do: Backups.get_run_by_stamp!(stamp, actor: Backups.system())
  defp entry(run, key), do: Enum.find(run.destinations, &(&1.key == key))
  defp key(dest), do: "dest:" <> dest.id

  defp lines(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # A backup that reached Bucket A and not Bucket B, whose puts are logged
  # to `<base>/b.log`.
  defp partial!(ctx, extra \\ []) do
    a = fake!("Bucket A", 0, %{})
    b_log = Path.join(ctx.base, "b.log")
    b = fake!("Bucket B", 1, %{"put_mode" => "fail", "log" => b_log})

    extra =
      for {name, position} <- Enum.with_index(extra, 2),
          do: fake!(name, position, %{"put_mode" => "fail"})

    assert :ok = BackupChain.run()
    run = run!()
    assert %{status: :succeeded, offsite_status: :partial} = run
    File.rm(b_log)
    %{run: run, a: a, b: b, b_log: b_log, extra: extra}
  end

  # Request a re-send as the system actor and drain its chain: `{settled,
  # started}`, or the request's own result.
  defp resend!(stamp) do
    BackupChain.listen(fn ->
      case Backups.resend_offsite(stamp, Backups.system()) do
        {:ok, %{status: :started, chain: chain} = started} ->
          BackupChain.drain()
          {BackupChain.settled(chain), started}

        other ->
          other
      end
    end)
  end

  defp listen(events) do
    id = {__MODULE__, make_ref()}
    pid = self()

    :telemetry.attach_many(
      id,
      events,
      fn event, measurements, metadata, _ ->
        send(pid, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp work_dir(dir, stamp), do: Path.join([dir, ".work", stamp])

  defp canceled_events(admin) do
    Security.list_instance_events!(actor: admin, page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :backup_canceled))
  end

  # -- the acceptance case ---------------------------------------------------

  describe "a partly off-site backup" do
    test "becomes complete; only the missed destination is sent to, nothing else changes",
         ctx do
      %{run: run, a: a, b: b, b_log: b_log} = partial!(ctx)
      settings!(b, %{"log" => b_log}, ctx.admin)
      manifest = File.read!(Manifest.path(ctx.dir))
      a_entry = entry(run, key(a))

      listen([
        [:kiln_cms, :backups, :resend, :requested],
        [:kiln_cms, :backups, :resend, :destination],
        [:kiln_cms, :backups, :resend, :stop]
      ])

      assert {:ok, %{targets: ["Bucket B"], skipped: []}} = resend!(run.stamp)

      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert run.offsite_status == :complete
      assert run.finished_at != nil
      assert entry(run, key(a)) == a_entry

      assert %RunDestination{status: :ok, files_ok: 2, files_total: 2, error: nil} =
               entry(run, key(b))

      for artifact <- run.artifacts do
        assert artifact.verified
        assert get_in(artifact.destinations, [key(b), "status"]) == "ok"
      end

      assert lines(b_log) == [
               "kiln-db-#{run.stamp}.dump",
               Artifact.sidecar_name(:db, run.stamp)
             ]

      assert Enum.any?(run.log, &(&1.message =~ "Re-sending to 1 destination(s): Bucket B"))

      assert Enum.any?(
               run.log,
               &(&1.message =~ "reached 2 of 2 destination(s); off-site now complete")
             )

      assert File.read!(Manifest.path(ctx.dir)) == manifest
      refute File.exists?(work_dir(ctx.dir, run.stamp))
      assert Backups.in_flight() == nil

      stamp = run.stamp

      assert_received {:event, [:kiln_cms, :backups, :resend, :requested], %{targets: 1},
                       %{stamp: ^stamp}}

      bkey = key(b)

      assert_received {:event, [:kiln_cms, :backups, :resend, :destination], %{files_ok: 2},
                       %{destination: ^bkey, status: :ok}}

      assert_received {:event, [:kiln_cms, :backups, :resend, :stop], %{reached: 2, total: 2},
                       %{outcome: :done, offsite_status: :complete}}
    end

    test "the chain settles :ok and names its targets", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      assert {:ok, %{status: :started, targets: ["Bucket B"], skipped: []}} =
               BackupChain.listen(fn ->
                 result = Backups.resend_offsite(run.stamp, Backups.system())
                 BackupChain.drain()
                 result
               end)

      assert run_of(run.stamp).offsite_status == :complete
    end

    test "a destination removed or disabled since is skipped, its entry left failed", ctx do
      %{run: run, b: b, extra: [c]} = partial!(ctx, ["Bucket C"])
      settings!(b, %{}, ctx.admin)
      Backups.update_backup_destination!(c, %{enabled: false}, actor: ctx.admin)
      c_entry = entry(run, key(c))

      assert {:ok, %{skipped: ["Bucket C"]}} =
               BackupChain.listen(fn ->
                 result = Backups.resend_offsite(run.stamp, Backups.system())
                 BackupChain.drain()
                 result
               end)

      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert entry(run, key(b)).status == :ok
      assert entry(run, key(c)) == c_entry
      assert run.offsite_status == :partial

      assert Enum.any?(
               run.log,
               &(&1.message =~ "Skipped Bucket C: removed or disabled since this backup")
             )
    end

    test "a destination removed between two of its parts is skipped there", ctx do
      %{run: run, b: b, extra: [c]} = partial!(ctx, ["Bucket C"])
      settings!(b, %{}, ctx.admin)
      c = settings!(c, %{}, ctx.admin)
      c_entry = entry(run, key(c))

      result =
        BackupChain.listen(fn ->
          {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
          # Part 1 (Bucket B) runs; Bucket C is disabled before part 2.
          %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
          assert %{step: :resend, part: 2} = Backups.in_flight()
          Backups.update_backup_destination!(c, %{enabled: false}, actor: ctx.admin)
          BackupChain.drain()
          BackupChain.settled(chain)
        end)

      assert result == :ok
      run = run_of(run.stamp)
      assert entry(run, key(b)).status == :ok
      assert entry(run, key(c)) == c_entry
      assert Enum.any?(run.log, &(&1.message =~ "Skipped Bucket C"))
      assert Backups.in_flight() == nil
    end

    test "every destination it missed disabled after the request: refused at part 1", ctx do
      %{run: run, b: b} = partial!(ctx)
      b = settings!(b, %{}, ctx.admin)
      before = run_of(run.stamp)

      result =
        BackupChain.listen(fn ->
          {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
          Backups.update_backup_destination!(b, %{enabled: false}, actor: ctx.admin)
          BackupChain.drain()
          BackupChain.settled(chain)
        end)

      assert result == {:error, :nothing_to_send}
      assert run_of(run.stamp) == before
      refute File.exists?(work_dir(ctx.dir, run.stamp))
      assert Backups.in_flight() == nil
    end

    test "every destination it missed gone: nothing to send", ctx do
      %{run: run, b: b} = partial!(ctx)
      Backups.destroy_backup_destination!(b, actor: ctx.admin)

      assert {:error, :nothing_to_send} = Backups.resend_offsite(run.stamp, Backups.system())
      assert Backups.in_flight() == nil
    end

    test "a destination that still fails is recorded failed; the run stays succeeded", ctx do
      %{run: run, b: b} = partial!(ctx)

      assert {:ok, _started} = resend!(run.stamp)

      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert run.offsite_status == :partial
      assert %{status: :failed} = entry(run, key(b))
      refute File.exists?(work_dir(ctx.dir, run.stamp))
      assert Manifest.read(ctx.dir).ok
    end
  end

  describe "a file refused before its copy (O4)" do
    test "a file changed on disk: stopped, unverified on the run and in the manifest, left in place",
         ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)
      dump = Path.join([ctx.dir, "db", "kiln-db-#{run.stamp}.dump"])
      File.write!(dump, "x", [:append])

      assert {{:error, :refused}, _started} = resend!(run.stamp)

      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert run.error == nil
      assert %{status: :failed, error: error} = entry(run, key(b))
      assert error =~ "REFUSED for 1 file"
      assert [%{kind: :db, verified: false}] = run.artifacts

      # The file stays where it is; nothing was kept aside.
      assert File.exists?(dump)
      assert Path.wildcard(dump <> ".refused-*") == []

      # The manifest is this run's, so its entry says unverified too.
      assert %Manifest{stamp: stamp, ok: true, artifacts: artifacts} = Manifest.read(ctx.dir)
      assert stamp == run.stamp
      assert Enum.find(artifacts, &(&1.path =~ ".dump")).verified == false

      assert Enum.any?(run.log, &(&1.message =~ "Re-send stopped: 1 file changed on disk"))
      refute File.exists?(work_dir(ctx.dir, run.stamp))
      assert Backups.in_flight() == nil
    end

    test "changed after the first destination took it: the second refuses it", ctx do
      %{run: run, b: b, extra: [c]} = partial!(ctx, ["Bucket C"])
      name = "kiln-db-#{run.stamp}.dump"
      settings!(b, %{"append_after" => name}, ctx.admin)
      settings!(c, %{}, ctx.admin)

      assert {{:error, :refused}, %{targets: ["Bucket B", "Bucket C"]}} = resend!(run.stamp)

      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert entry(run, key(b)).status == :ok
      assert %{status: :failed, error: "REFUSED" <> _} = entry(run, key(c))
      assert [%{verified: false}] = run.artifacts
      assert run.offsite_status == :partial
    end

    test "a file deleted after the first destination took it reads as missing, not refused",
         ctx do
      %{run: run, b: b, extra: [c]} = partial!(ctx, ["Bucket C"])
      name = "kiln-db-#{run.stamp}.dump"
      settings!(b, %{"remove_after" => name}, ctx.admin)
      settings!(c, %{}, ctx.admin)

      assert {{:error, :local_files_missing}, _started} = resend!(run.stamp)

      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert entry(run, key(b)).status == :ok
      assert %{status: :failed, error: error} = entry(run, key(c))
      assert error =~ "no longer in BACKUP_DIR"
      # Gone is not changed: the backup verified, and still says so.
      assert [%{verified: true}] = run.artifacts
      assert Enum.find(Manifest.read(ctx.dir).artifacts, &(&1.path =~ ".dump")).verified
    end

    test "files deleted before it starts: part 1 refuses as local files missing", ctx do
      %{run: run, b: b, b_log: b_log} = partial!(ctx)
      settings!(b, %{"log" => b_log}, ctx.admin)

      result =
        BackupChain.listen(fn ->
          {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
          File.rm!(Path.join([ctx.dir, "db", "kiln-db-#{run.stamp}.dump"]))
          BackupChain.drain()
          BackupChain.settled(chain)
        end)

      assert result == {:error, :local_files_missing}
      assert lines(b_log) == []

      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert [%{verified: true}] = run.artifacts

      assert Enum.any?(
               run.log,
               &(&1.message =~
                   "Re-send refused: kiln-db-#{run.stamp}.dump is no longer in BACKUP_DIR")
             )

      refute File.exists?(work_dir(ctx.dir, run.stamp))
      assert Backups.in_flight() == nil
    end
  end

  describe "refusals before it starts" do
    test "pruned local files", ctx do
      %{run: run} = partial!(ctx)
      Recorder.mark_pruned(["kiln-db-#{run.stamp}.dump"])

      assert {:error, :pruned} = Backups.resend_offsite(run.stamp, Backups.system())
    end

    test "a complete, failed or imported run is not partly off-site" do
      fake!("Bucket A", 0, %{})
      assert :ok = BackupChain.run()
      complete = run!()
      assert complete.offsite_status == :complete

      assert {:error, :not_partial} = Backups.resend_offsite(complete.stamp, Backups.system())

      failed =
        %{stamp: "20260101-010101", trigger: "manual"}
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.fail_run!(%{error: "x"}, actor: Backups.system())

      assert {:error, :not_partial} = Backups.resend_offsite(failed.stamp, Backups.system())
      assert {:error, :no_such_run} = Backups.resend_offsite("20260101-010102", Backups.system())
      assert {:error, :invalid_stamp} = Backups.resend_offsite("../etc", Backups.system())
    end

    test "BACKUP_ENABLED=false refuses it (O11)", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)
      backups_env(:enabled, false)

      assert {:error, :disabled} = Backups.resend_offsite(run.stamp, Backups.system())
      assert Backups.in_flight() == nil
    end

    test "while a backup holds the lock it is refused, not queued (O2)", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      assert {:ok, %{status: :started}} = Backups.request([], Backups.system())
      assert {:error, :busy} = Backups.resend_offsite(run.stamp, Backups.system())
      assert %{step: :start, waiting: nil} = Backups.in_flight()
    end

    test "a second request for the same run: already being re-sent (O1)", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      assert {:ok, %{status: :started}} = Backups.resend_offsite(run.stamp, Backups.system())
      assert {:error, :in_flight} = Backups.resend_offsite(run.stamp, Backups.system())

      # Pinned to the run's backup directory, as every step after a start.
      dir_id = run.dir_id
      stamp = run.stamp

      assert [%{args: %{"dir" => ^dir_id, "stamp" => ^stamp, "part" => 1}}] =
               BackupChain.step_jobs(step: "resend")
    end

    test "a backup asked for while a re-send runs queues behind it and then runs", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      BackupChain.listen(fn ->
        assert {:ok, %{status: :started}} = Backups.resend_offsite(run.stamp, Backups.system())
        assert {:ok, %{status: :queued}} = Backups.request([], Backups.system())
        BackupChain.drain()
      end)

      assert run_of(run.stamp).offsite_status == :complete
      assert length(Backups.list_runs!(actor: Backups.system())) == 2
      assert Backups.in_flight() == nil
    end
  end

  describe "Cancel" do
    test "stops it, releases the lock, clears the chain and is audited; a new one waits", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      assert {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
      [job] = BackupChain.step_jobs(chain: chain)
      loaded = run_of(run.stamp)

      assert {:ok, canceled} = Backups.cancel_run_resend(loaded, actor: ctx.admin)
      assert canceled.status == :succeeded
      assert canceled.chain_id == nil
      assert Backups.in_flight() == nil
      assert %{state: "cancelled"} = Repo.get!(Oban.Job, job.id)

      note = List.last(canceled.log)
      assert note.message == Resend.canceled_note()
      refute note.message =~ ctx.admin.email |> to_string()

      assert [%{metadata: %{"stamp" => stamp, "resend" => true, "step" => "resend part 1"}}] =
               canceled_events(ctx.admin)

      assert stamp == run.stamp

      # A step that outlived the Cancel can't write the run.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.record_run_resend(%{canceled | chain_id: chain}, %{log: []},
                 actor: Backups.system()
               )

      # A re-send of it waits out the settle window (#2538's, from the note).
      assert {:error, {:canceled_recently, seconds}} =
               Backups.resend_offsite(run.stamp, Backups.system())

      assert seconds > 0 and seconds <= div(Heartbeat.settled_after_ms(), 1000) + 1
    end

    test "the run's plain Cancel is refused while a re-send runs", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      assert {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())

      assert {:error, %Ash.Error.Invalid{} = error} =
               Backups.cancel_run(run_of(run.stamp), actor: ctx.admin)

      assert Exception.message(error) =~ Cancel.resending()
      assert %{chain: ^chain, step: :resend} = Backups.in_flight()
      assert [%{state: "available"}] = BackupChain.step_jobs(chain: chain)
    end

    test "a late Cancel, once the re-send is finishing, is refused", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      assert {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
      lock = Backups.backup_lock!(actor: Backups.system())
      Backups.mark_backup_lock_finishing!(lock, actor: Backups.system())

      assert {:error, %Ash.Error.Invalid{} = error} =
               Backups.cancel_run_resend(run_of(run.stamp), actor: ctx.admin)

      assert Exception.message(error) =~ CancelResend.finishing()
      assert %{chain: ^chain} = Backups.in_flight()
      assert canceled_events(ctx.admin) == []
    end

    test "with no re-send running there is nothing to cancel", ctx do
      %{run: run} = partial!(ctx)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Backups.cancel_run_resend(run, actor: ctx.admin)

      assert Exception.message(error) =~ CancelResend.not_resending()
    end

    # Critic change 1: the setup reads the run, checks its lease, then begins
    # from that read at once. Replayed by hand at the point a Cancel can land.
    test "a Cancel between the setup's read and its begin: the begin matches nothing", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)

      assert {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
      [job] = BackupChain.step_jobs(chain: chain)
      assert {:ok, lease} = Chain.begin_step(job)

      # The setup's read, and its lease check.
      loaded = run_of(run.stamp)
      assert :ok = Chain.check_lease(lease)

      # The Cancel commits now.
      assert {:ok, _} = Backups.cancel_run_resend(loaded, actor: ctx.admin)

      # The begin, from the struct the setup read: refused, nothing written.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.begin_run_resend(loaded, %{chain_id: chain}, actor: Backups.system())

      assert run_of(run.stamp).chain_id == nil
      assert {:error, :superseded} = Chain.check_lease(lease)
    end
  end

  describe "never a failure manifest" do
    test "the re-send's state.json names its chain under resend_chain, never chain", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{"put_mode" => "fail"}, ctx.admin)

      assert {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
      %{success: _} = BackupChain.drain(with_recursion: false, with_scheduled: false)

      # Part 1 failed its first attempt and wrote its state for the retry.
      assert {:ok, state} = WorkState.read(work_dir(ctx.dir, run.stamp))
      assert state["kind"] == "resend"
      assert state["resend_chain"] == chain
      refute Map.has_key?(state, "chain")
      assert WorkState.chain(state) == nil
    end

    test "interrupted from outside (an older node's path too): no manifest, run unchanged",
         ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{"put_mode" => "fail"}, ctx.admin)
      manifest = File.read!(Manifest.path(ctx.dir))

      assert {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
      %{success: _} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      lock = Backups.backup_lock!(actor: Backups.system())

      # What an older release's interrupt does with the state it finds.
      assert :ok = Steps.interrupt(run.stamp, chain, lock.dir_id, "Interrupted: node gone")
      assert File.read!(Manifest.path(ctx.dir)) == manifest
      assert run_of(run.stamp).status == :succeeded

      # This release's: the job is reaped, the re-send stopped.
      [job] = BackupChain.step_jobs(chain: chain)
      :ok = Oban.cancel_job(job.id)
      assert {:ok, {:orphaned, _}} = Chain.reap()

      assert File.read!(Manifest.path(ctx.dir)) == manifest
      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert run.offsite_status == :partial
      assert Enum.any?(run.log, &(&1.message =~ "Re-send stopped: Interrupted"))
      refute File.exists?(work_dir(ctx.dir, run.stamp))
      assert Backups.in_flight() == nil
    end

    test "a step that crashes on its last attempt stops the re-send; no manifest", ctx do
      %{run: run, b: b} = partial!(ctx)
      settings!(b, %{}, ctx.admin)
      manifest = File.read!(Manifest.path(ctx.dir))

      assert {:ok, %{chain: chain}} = Backups.resend_offsite(run.stamp, Backups.system())
      [job] = BackupChain.step_jobs(chain: chain)
      assert {:ok, lease} = Chain.begin_step(job)

      assert {:cancel, {:crashed, "boom"}} =
               Steps.crashed(lease, %{job | attempt: 4, max_attempts: 4}, {:crashed, "boom"})

      assert File.read!(Manifest.path(ctx.dir)) == manifest
      run = run_of(run.stamp)
      assert run.status == :succeeded
      assert run.error == nil
      assert Backups.in_flight() == nil
      refute File.exists?(work_dir(ctx.dir, run.stamp))
    end
  end

  describe "the unreadable entry (O3)" do
    test "is replaced by the enabled stored destinations the run has no entry for" do
      fake!("Bucket A", 0, %{})
      assert :ok = BackupChain.run()
      ran = run!()

      # As a run whose stored destinations couldn't be read records it.
      unreadable = %{
        key: RunDestination.unreadable_key(),
        label: "Stored destinations",
        status: :failed,
        error: "couldn't read the backup destinations"
      }

      run =
        Backups.record_run_resend!(
          ran,
          %{destinations: [unreadable], offsite_status: :failed},
          actor: Backups.system()
        )

      assert Backups.run_offsite_state(run) == :failed

      assert {:ok, _started} = resend!(run.stamp)

      run = run_of(run.stamp)
      refute entry(run, RunDestination.unreadable_key())
      assert [%{label: "Bucket A", status: :ok}] = run.destinations
      assert run.offsite_status == :complete
    end
  end
end
