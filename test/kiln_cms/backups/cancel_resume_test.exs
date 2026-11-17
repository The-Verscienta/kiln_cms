defmodule KilnCMS.Backups.CancelResumeTest do
  @moduledoc """
  Canceling a resume that holds the backup lock but hasn't re-opened its run
  (#2816): `Run :cancel_resume` frees the lock (the queued request starts),
  cancels the resume's start job and notes the run, which keeps its status
  (a stale `running` one is failed). It can lose a race with the start's
  re-open, and then changes nothing; when it wins, the start stops quietly.

  The lock needs a backup that can run here (`:pg_tools`), though no step gets
  past the start. `async: false`: it changes the VM-wide `Application` env.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.Accounts.{OrgMembership, User}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId, Heartbeat, Recorder, StepWorker, WorkState}
  alias KilnCMS.Backups.Run.Changes.CancelResume
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.SystemActor
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  @note "Resume canceled by a platform admin before it started"

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkcr_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    File.mkdir_p!(dir)

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

    %{base: base, dir: dir, admin: user(:admin)}
  end

  ## helpers

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "cancel-resume-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org_admin do
    viewer = user(:viewer)

    Ash.Seed.seed!(OrgMembership, %{
      organization_id: KilnCMS.Accounts.default_org_id(),
      user_id: viewer.id,
      role: :admin
    })

    viewer
  end

  # A former platform admin whose grant has expired: an editor now.
  defp expired_grant do
    %{
      user(:editor)
      | granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    }
  end

  defp request(opts), do: Backups.request(opts, Backups.system())

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp run_of(stamp), do: Backups.get_run_by_stamp!(stamp, actor: Backups.system())

  defp current_job, do: Repo.get!(Oban.Job, lock().step_job_id)

  defp step_jobs(chain) do
    Repo.all(
      from(j in Oban.Job,
        where: j.queue == "backup_steps" and fragment("?->>'chain' = ?", j.args, ^chain),
        order_by: j.id
      )
    )
  end

  defp canceled_events(admin) do
    Security.list_instance_events!(actor: admin, page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :backup_canceled))
  end

  # A failed in-app run of `stamp` under a chain of its own, with the
  # `state.json` a resume builds on. Its files are recorded in another backup
  # directory unless `dir_id:` says which (`DirId.local/1`: this one).
  defp failed_run!(dir, stamp, opts \\ []) do
    run =
      Backups.start_run!(
        %{
          stamp: stamp,
          trigger: "manual",
          chain_id: Ash.UUID.generate(),
          dir_id: Keyword.get_lazy(opts, :dir_id, &Ash.UUID.generate/0)
        },
        actor: Backups.system()
      )

    run = Backups.fail_run!(run, %{error: "tar exited 2"}, actor: Backups.system())
    work = WorkState.path(dir, stamp)
    File.mkdir_p!(work)
    :ok = WorkState.write(work, WorkState.new(stamp))
    run
  end

  defp set_run!(stamp, fields) do
    {1, _} = Repo.update_all(from(r in "backup_runs", where: r.stamp == ^stamp), set: fields)
    run_of(stamp)
  end

  defp ago_ms(ms), do: DateTime.add(DateTime.utc_now(), -ms, :millisecond)

  # The resume is requested while its files are here, then its start lands on
  # this node, whose backup directory is not the run's: it snoozes, waiting for
  # the server with the files (`StepWorker`). The lock holds it at `start`.
  defp waiting_for_files!(%{base: base, dir: dir}, stamp) do
    {:ok, %{status: :started, chain: chain}} = request(resume: stamp)
    File.rename!(WorkState.path(dir, stamp), Path.join(base, "aside-#{stamp}"))
    assert %{snoozed: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
    assert %{chain: ^chain, step: :start, resume: ^stamp} = Backups.in_flight()
    chain
  end

  describe "a resume waiting for the server with its files" do
    test "Cancel frees the lock and starts the queued backup; the run stays failed and says why",
         %{admin: admin} = ctx do
      stamp = "20261101-010101"
      failed = failed_run!(ctx.dir, stamp)
      chain = waiting_for_files!(ctx, stamp)
      {:ok, %{status: :queued}} = request(trigger: "schedule")
      before = run_of(stamp)

      BackupChain.listen(fn ->
        assert {:ok, noted} = Backups.cancel_run_resume(before, actor: admin)
        assert {:error, :canceled} = BackupChain.settled(chain)

        assert noted.status == :failed
        assert noted.chain_id == failed.chain_id
        assert noted.finished_at == failed.finished_at
        assert noted.error == @note <> "\n" <> failed.error
        assert %{level: :warn, step: "resume", message: @note} = List.last(noted.log)
        refute Enum.any?(noted.log, &(&1.message =~ to_string(admin.email)))
      end)

      assert %{status: :failed} = run = run_of(stamp)
      assert Backups.run_resumable?(run)

      # The start job is canceled; the queued request holds the lock now.
      assert Enum.all?(step_jobs(chain), &(&1.state == "cancelled"))

      assert %{chain: promoted, trigger: "schedule", step: :start, resume: nil} =
               Backups.in_flight()

      assert promoted != chain

      # Audited as a Cancel, told apart from a fresh backup's start.
      assert [event] = canceled_events(admin)
      assert event.actor_id == admin.id
      assert {event.target_type, event.target_id} == {"backup_run", failed.id}
      assert event.metadata == %{"stamp" => stamp, "step" => "start", "resume" => true}

      # A console waiting on the resume chain finds no run of it (#2816).
      assert {:error, :no_run} = Backups.await(chain, timeout: 0)
    end

    test "with nothing queued the lock is free", %{admin: admin} = ctx do
      stamp = "20261101-010102"
      failed_run!(ctx.dir, stamp)
      waiting_for_files!(ctx, stamp)

      assert {:ok, _} = Backups.cancel_run_resume(run_of(stamp), actor: admin)
      assert Backups.in_flight() == nil
    end

    test "a canceled run stays canceled, with its Cancel's time, and resumable",
         %{admin: admin} = ctx do
      stamp = "20261101-010103"
      failed_run!(ctx.dir, stamp)
      settled = ago_ms(Heartbeat.settled_after_ms() + 1_000)
      canceled = set_run!(stamp, status: "canceled", finished_at: settled)
      waiting_for_files!(ctx, stamp)

      assert {:ok, noted} = Backups.cancel_run_resume(run_of(stamp), actor: admin)
      assert noted.status == :canceled
      assert noted.finished_at == canceled.finished_at
      assert noted.error == @note <> "\n" <> canceled.error
      assert Backups.run_resumable?(noted)
    end

    test "notes never stack: a second canceled resume keeps one note and the failure",
         %{admin: admin} = ctx do
      stamp = "20261101-010104"
      failed = failed_run!(ctx.dir, stamp)

      waiting_for_files!(ctx, stamp)
      assert {:ok, _} = Backups.cancel_run_resume(run_of(stamp), actor: admin)

      File.rename!(Path.join(ctx.base, "aside-#{stamp}"), WorkState.path(ctx.dir, stamp))
      waiting_for_files!(ctx, stamp)
      assert {:ok, noted} = Backups.cancel_run_resume(run_of(stamp), actor: admin)

      assert noted.error == @note <> "\n" <> failed.error
    end

    # Critic change 1: a stale `running` run is what the resume re-opens; the
    # resume's Cancel fails it, as a refused resume does.
    test "a stale running run is failed, with the note over the interruption",
         %{admin: admin} = ctx do
      stamp = "20261101-010105"
      failed_run!(ctx.dir, stamp)
      quiet = ago_ms(5 * 3_600_000)

      stale =
        set_run!(stamp,
          status: "running",
          finished_at: nil,
          error: nil,
          started_at: quiet,
          updated_at: quiet
        )

      chain = waiting_for_files!(ctx, stamp)

      assert {:ok, noted} = Backups.cancel_run_resume(run_of(stamp), actor: admin)
      assert noted.status == :failed
      assert noted.finished_at != nil
      assert noted.chain_id == stale.chain_id

      assert noted.error ==
               @note <> "\nInterrupted: the job was killed or the node stopped"

      assert Backups.in_flight() == nil
      assert Enum.all?(step_jobs(chain), &(&1.state == "cancelled"))
      assert Backups.run_resumable?(noted)
    end
  end

  describe "refusals" do
    test "anyone but a platform admin is refused, and nothing changes", ctx do
      stamp = "20261101-020101"
      failed_run!(ctx.dir, stamp)
      chain = waiting_for_files!(ctx, stamp)
      run = run_of(stamp)
      jobs = step_jobs(chain)

      for actor <- [
            user(:editor),
            user(:viewer),
            org_admin(),
            expired_grant(),
            nil,
            Backups.system(),
            SystemActor.new(:billing)
          ] do
        assert {:error, %Ash.Error.Forbidden{}} = Backups.cancel_run_resume(run, actor: actor),
               "must refuse #{inspect(actor && Map.get(actor, :role))}"

        refute Backups.can_cancel_run_resume?(actor, run)
      end

      assert Backups.can_cancel_run_resume?(ctx.admin, run)
      assert run_of(stamp) == run
      assert %{chain: ^chain, step: :start} = Backups.in_flight()
      assert step_jobs(chain) == jobs
      assert canceled_events(ctx.admin) == []
    end

    test "a fresh backup's start, a resume past its start, or a free lock: nothing to cancel",
         %{admin: admin} = ctx do
      stamp = "20261101-020102"
      failed_run!(ctx.dir, stamp)
      run = run_of(stamp)

      refused = fn ->
        assert {:error, %Ash.Error.Invalid{} = error} =
                 Backups.cancel_run_resume(run, actor: admin)

        assert Exception.message(error) =~ "has no resume waiting to start"
        assert run_of(stamp) == run
      end

      # A fresh backup at its start: the lock holds no resume.
      {:ok, %{status: :started, chain: fresh}} = request([])
      refused.()
      assert %{chain: ^fresh} = Backups.in_flight()
      row = lock()
      {:ok, _} = Chain.release(%{chain: fresh, epoch: row.epoch, job_id: row.step_job_id})

      # Nothing holds the lock.
      assert Backups.in_flight() == nil
      refused.()

      # A resume of it moved on past its start (the lock row alone says so).
      {:ok, %{status: :started, chain: resume}} = request(resume: stamp)
      row = lock()

      Backups.move_backup_lock!(row, %{step: :dump, part: nil, step_job_id: row.step_job_id},
        actor: Backups.system()
      )

      refused.()
      assert %{chain: ^resume, step: :dump} = Backups.in_flight()
      assert canceled_events(admin) == []
    end

    test "a resume of another stamp is not this run's", %{admin: admin} = ctx do
      failed_run!(ctx.dir, "20261101-020103")
      other = failed_run!(ctx.dir, "20261101-020104")
      waiting_for_files!(ctx, "20261101-020103")

      assert {:error, %Ash.Error.Invalid{}} = Backups.cancel_run_resume(other, actor: admin)
      assert %{resume: "20261101-020103"} = Backups.in_flight()
    end

    test "a succeeded, skipped or imported run has no resume to cancel", %{admin: admin} do
      done =
        %{stamp: "20261101-020105", trigger: "manual"}
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.finish_run!(%{}, actor: Backups.system())

      skipped =
        Backups.skip_run!(%{stamp: "20261101-020106", trigger: "t", error: "no pg_dump"},
          actor: Backups.system()
        )

      imported =
        Backups.import_run!(
          %{stamp: "20261101-020107", trigger: "cron", status: :failed, error: "x"},
          actor: Backups.system()
        )

      for run <- [done, skipped, imported] do
        assert {:error, %Ash.Error.Invalid{}} = Backups.cancel_run_resume(run, actor: admin)
      end
    end
  end

  describe "racing the start's re-open" do
    # The resume's start, run by hand up to the point it has a lease.
    defp started_resume!(ctx, stamp) do
      # The files are here: the start runs on this node.
      {:ok, dir_id} = DirId.local(ctx.dir)
      failed_run!(ctx.dir, stamp, dir_id: dir_id)
      {:ok, %{status: :started, chain: chain}} = request(resume: stamp)
      {chain, current_job()}
    end

    test "a: the start re-opens first; the Cancel changes nothing and the plain Cancel works",
         %{admin: admin} = ctx do
      stamp = "20261101-030101"
      {chain, job} = started_resume!(ctx, stamp)
      loaded = run_of(stamp)

      # The start re-opens the run (what `Recorder.reopen_run/3` does).
      assert {:ok, %{chain_id: ^chain}} = Recorder.reopen_run(loaded, chain, nil)

      # A Cancel that read the run before the re-open.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.cancel_run_resume(loaded, actor: admin)

      # One that reads it after: the resume has started.
      assert {:error, %Ash.Error.Invalid{} = error} =
               Backups.cancel_run_resume(run_of(stamp), actor: admin)

      assert Exception.message(error) =~ CancelResume.started()

      # Rolled back whole: the job, the lock, the run, the audit.
      assert %{state: "available"} = Repo.get!(Oban.Job, job.id)
      assert %{chain: ^chain, step: :start} = Backups.in_flight()
      assert %{status: :running, chain_id: ^chain} = run = run_of(stamp)
      refute Enum.any?(run.log, &(&1.message == @note))
      assert canceled_events(admin) == []

      assert {:ok, %{status: :canceled}} = Backups.cancel_run(run, actor: admin)
      assert Backups.in_flight() == nil
    end

    test "b: the Cancel first; the start's loaded run can't be re-opened and its lease is gone",
         %{admin: admin} = ctx do
      stamp = "20261101-030102"
      {chain, job} = started_resume!(ctx, stamp)
      {:ok, lease} = Chain.begin_step(job)
      loaded = run_of(stamp)

      assert {:ok, _} = Backups.cancel_run_resume(loaded, actor: admin)

      # The start had read the run before the Cancel: its re-open is refused
      # (the `updated_at` pin), and its lease check says why.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.resume_run(loaded, %{chain_id: chain}, actor: Backups.system())

      assert {:error, :superseded} = Chain.while_holding(lease, fn -> :ok end)
      assert %{status: :failed} = run_of(stamp)
      refute run_of(stamp).chain_id == chain
    end

    # Critic change 1/5 and the `chain_id` pin: a run the resume already took
    # over keeps its status here (re-opened, then failed again, under the
    # chain the lock still holds), so only the pin tells it apart.
    test "a run whose chain moved under the same status is refused", %{admin: admin} = ctx do
      stamp = "20261101-030103"
      {chain, _job} = started_resume!(ctx, stamp)
      loaded = run_of(stamp)
      set_run!(stamp, chain_id: Ecto.UUID.dump!(chain))

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.cancel_run_resume(loaded, actor: admin)

      assert %{chain: ^chain} = Backups.in_flight()
      assert %{status: :failed, chain_id: ^chain} = run_of(stamp)
    end

    # #2538's settle wait: the start sleeps inside the step, not holding the
    # lock, until the run's Cancel has settled. A Cancel of the resume meanwhile
    # returns at once; the start wakes up to a lease that is gone and stops
    # without touching the run or the files.
    test "during the settle wait: the Cancel doesn't wait; the start stops quietly",
         %{admin: admin} = ctx do
      stamp = "20261101-030104"
      {:ok, dir_id} = DirId.local(ctx.dir)
      failed_run!(ctx.dir, stamp, dir_id: dir_id)
      window = Heartbeat.settled_after_ms()

      # Settled when requested; two seconds inside the window when it starts.
      set_run!(stamp, status: "canceled", finished_at: ago_ms(window + 1_000))
      {:ok, %{status: :started, chain: chain}} = request(resume: stamp)
      canceled = set_run!(stamp, finished_at: ago_ms(window - 2_000))
      job = current_job()

      state = WorkState.file(WorkState.path(ctx.dir, stamp))
      state_bytes = File.read!(state)
      partial = Path.join([ctx.dir, "db", "kiln-db-#{stamp}.dump.partial"])
      File.mkdir_p!(Path.dirname(partial))
      File.write!(partial, "half")
      File.touch!(partial, System.os_time(:second) - 7200)

      start = Task.async(fn -> StepWorker.perform(job) end)
      wait_until(fn -> lock().executing_job_id == job.id end)

      {micros, result} =
        :timer.tc(fn -> Backups.cancel_run_resume(run_of(stamp), actor: admin) end)

      assert {:ok, %{status: :canceled}} = result
      assert micros < 1_500_000

      assert {:cancel, :superseded} = Task.await(start, 15_000)

      run = run_of(stamp)
      assert %{status: :canceled, chain_id: chain_id} = run
      assert chain_id == canceled.chain_id and chain_id != chain
      assert run.finished_at == canceled.finished_at
      refute run.error =~ "Resume refused"
      refute Enum.any?(run.log, &(&1.message =~ "Resume refused"))
      assert File.read!(state) == state_bytes
      assert File.read!(partial) == "half"
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("the condition never held")

      true ->
        Process.sleep(25)
        wait_until(fun, tries - 1)
    end
  end
end
