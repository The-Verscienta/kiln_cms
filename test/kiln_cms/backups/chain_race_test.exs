defmodule KilnCMS.Backups.ChainRaceTest do
  @moduledoc """
  The backup lock under real concurrency (#2218, D2).

  The sandbox runs every test on one connection inside one transaction, where
  an advisory lock is re-entrant and nothing ever waits, so these run
  **outside** it (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) on two real
  connections whose writes commit. Everything they commit (the lock row, the
  step jobs) is deleted again on exit. `async: false`: committed rows and the
  VM-wide backup directory.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId, Recorder, StepWorker, Worker, WorkState}
  alias KilnCMS.Repo

  @moduletag :pg_tools
  @moduletag :capture_log

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bkx_#{System.unique_integer([:positive])}")
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir)
    )

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(j in "oban_jobs", where: j.queue == "backup_steps"))
        Repo.delete_all(from(l in "backup_locks"))
        Repo.delete_all(from(r in "backup_runs"))
      end)

      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(dir)
    end)

    :ok
  end

  # Both start together; each runs on its own connection.
  defp race(fun_a, fun_b) do
    gate = make_ref()
    parent = self()

    tasks =
      for fun <- [fun_a, fun_b] do
        Task.async(fn ->
          receive do
            ^gate -> unboxed(fun)
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: send(pid, gate)
    _ = parent
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  test "two concurrent requests: exactly one holds the lock and one waits" do
    request = fn -> Backups.request([trigger: "manual"], Backups.system()) end

    results = race(request, request)
    statuses = results |> Enum.map(fn {:ok, %{status: s}} -> s end) |> Enum.sort()
    assert statuses == [:queued, :started]

    unboxed(fn ->
      assert %{chain: chain, waiting: %{folds: 0}} = Backups.in_flight()

      # One start job, the holder's.
      assert [%{args: %{"chain" => ^chain}}] =
               Repo.all(from(j in Oban.Job, where: j.queue == "backup_steps"))
    end)
  end

  test "two steps of different chains never both begin" do
    {:ok, %{status: :started, chain: chain}} =
      unboxed(fn -> Backups.request([trigger: "manual"], Backups.system()) end)

    job =
      unboxed(fn ->
        Repo.one!(from(j in Oban.Job, where: j.queue == "backup_steps"))
      end)

    assert job.args["chain"] == chain
    # A start job of another chain, under the same id (the worst case).
    other = %{job | args: Map.put(job.args, "chain", Ash.UUID.generate())}

    results = race(fn -> Chain.begin_step(job) end, fn -> Chain.begin_step(other) end)

    assert [{:error, :superseded}, {:ok, %{chain: ^chain}}] =
             Enum.sort_by(results, &match?({:ok, _}, &1))
  end

  # A committed in-app run of `stamp` that failed, and (with `state?: true`)
  # the `state.json` a resume builds on.
  defp failed_run!(stamp, opts \\ []) do
    run =
      unboxed(fn ->
        %{stamp: stamp, trigger: "test"}
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.fail_run!(%{error: "boom"}, actor: Backups.system())
      end)

    if Keyword.get(opts, :state?, false) do
      work = Backups.work_dir(stamp)
      File.mkdir_p!(work)
      File.write!(Path.join(work, "state.json"), "{}")
    end

    run
  end

  defp start_jobs do
    unboxed(fn -> Repo.all(from(j in Oban.Job, where: j.queue == "backup_steps")) end)
  end

  describe "#2421: one resume per stamp" do
    # The two UPDATEs serialize on the row lock, so before #2421 the second
    # still landed (its WHERE named only the id) and both chains thought they
    # held the run. Without the fix this passes whenever the second caller
    # happens to read the row after the first commits, so it is not the
    # proof: that is the stale-struct test in `run_test.exs`.
    test "two concurrent re-opens of one failed run: exactly one wins" do
      stamp = "20260803-101500"
      failed_run!(stamp)
      chain_a = Ash.UUID.generate()
      chain_b = Ash.UUID.generate()

      results =
        race(fn -> Recorder.reopen(stamp, chain_a) end, fn -> Recorder.reopen(stamp, chain_b) end)

      assert [{:error, :not_resumable}, {:ok, %Recorder{chain_id: winner}}] =
               Enum.sort_by(results, &match?({:ok, _}, &1))

      assert winner in [chain_a, chain_b]

      assert %{status: :running, chain_id: ^winner} =
               unboxed(fn -> Backups.get_run_by_stamp!(stamp, actor: Backups.system()) end)
    end

    test "two concurrent resume requests: one starts, the other is in flight" do
      stamp = "20260803-101600"
      failed_run!(stamp, state?: true)
      request = fn -> Backups.request([trigger: "manual", resume: stamp], Backups.system()) end

      assert [{:error, :in_flight}, {:ok, %{status: :started, chain: chain}}] =
               request |> race(request) |> Enum.sort_by(&match?({:ok, _}, &1))

      assert [%{args: %{"chain" => ^chain, "resume" => ^stamp}}] = start_jobs()
    end

    test "a console resume racing a resume request: one start job" do
      stamp = "20260803-101700"
      failed_run!(stamp, state?: true)

      # `timeout: 0`: the console returns after one look instead of waiting
      # for a chain no queue here runs.
      console = fn -> Worker.run("console", nil, resume: stamp, timeout: 0) end
      request = fn -> Backups.request([trigger: "manual", resume: stamp], Backups.system()) end

      results = race(console, request)

      assert Enum.count(results, &match?({:error, :in_flight}, &1)) == 1
      assert [%{args: %{"resume" => ^stamp}}] = start_jobs()
    end
  end

  # #2543: the advisory lock alone holds a request back. The `:ensure`
  # upsert's row lock also serializes two lock transactions today, so the
  # race above passes without the advisory lock; this one does not: the
  # holder takes only the advisory key and never touches the lock row.
  test "a transaction holding only the advisory lock holds a request back until it commits" do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              Chain.lock_key()
            ])

            send(parent, {:holding, self()})

            receive do
              :go -> :ok
            end
          end)
        end)
      end)

    assert_receive {:holding, pid}, 10_000

    request =
      Task.async(fn ->
        unboxed(fn -> Backups.request([trigger: "manual"], Backups.system()) end)
      end)

    assert Task.yield(request, 500) == nil

    send(pid, :go)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:ok, %{status: :started}} = Task.await(request, 10_000)
  end

  # #2554: the marker sync takes the same advisory lock, so a request that
  # arrives while it moves the markers waits for it, and a backup can never
  # start (and later sync markers of its own) in the middle of it.
  test "a request that arrives during a marker sync waits until the sync commits" do
    dir = Backups.dir()
    File.mkdir_p!(Path.join(dir, "db"))
    File.write!(Path.join([dir, "db", "kiln-db-20260801-031700.dump"]), "dump")

    File.touch!(
      Path.join([dir, "db", "kiln-db-20260801-031700.dump"]),
      System.os_time(:second) - 3600
    )

    parent = self()

    # Stands in for creating the marker file: says it is inside the lock, and
    # holds it there until the test lets go.
    create = fn path ->
      send(parent, {:in_sync, self()})

      receive do
        :go -> File.write(path, "")
      end
    end

    sync =
      Task.async(fn -> unboxed(fn -> Chain.sync_last_good(dir, create_marker: create) end) end)

    assert_receive {:in_sync, syncer}, 10_000

    request =
      Task.async(fn ->
        unboxed(fn -> Backups.request([trigger: "manual"], Backups.system()) end)
      end)

    # Blocked on the advisory lock the sync holds.
    assert Task.yield(request, 500) == nil

    send(syncer, :go)
    assert {:ok, %{db: "20260801-031700"}} = Task.await(sync, 10_000)
    assert {:ok, %{status: :started}} = Task.await(request, 10_000)
    assert File.exists?(Path.join([dir, "db", "kiln-20260801-031700.good"]))
  end

  describe "#2816: a resume canceled while its start re-opens the run" do
    # A failed run whose files are in this backup directory, so its resume's
    # start runs here.
    defp resumable_here!(stamp, dir_id) do
      unboxed(fn ->
        %{stamp: stamp, trigger: "test", chain_id: Ash.UUID.generate(), dir_id: dir_id}
        |> Backups.start_run!(actor: Backups.system())
        |> Backups.fail_run!(%{error: "boom"}, actor: Backups.system())
      end)

      work = WorkState.path(Backups.dir(), stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))
    end

    # The Cancel against the whole start step, on two real connections, twenty
    # times: either may win, never both, and the loser leaves no trace. Both
    # win some rounds (checked by hand, not asserted: it depends on timing). The
    # invariant is the issue's: the lock is never free while the run is
    # `running` under the chain that was canceled.
    test "exactly one wins, every time" do
      File.mkdir_p!(Backups.dir())
      {:ok, dir_id} = DirId.local(Backups.dir())
      # Not seeded: the audit row names the actor by id only.
      admin = %User{id: Ash.UUID.generate(), email: "race-admin@example.com", role: :admin}

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(
            from(e in "instance_security_events",
              where: e.actor_id == type(^admin.id, :binary_id)
            )
          )
        end)
      end)

      outcomes =
        for n <- 1..20 do
          stamp = "20260804-1000" <> String.pad_leading(Integer.to_string(n), 2, "0")
          resumable_here!(stamp, dir_id)

          {:ok, %{status: :started, chain: chain}} =
            unboxed(fn ->
              Backups.request([trigger: "manual", resume: stamp], Backups.system())
            end)

          {job, run} =
            unboxed(fn ->
              {Repo.get!(Oban.Job, Backups.backup_lock!(actor: Backups.system()).step_job_id),
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())}
            end)

          # Each round lets the start get a little further first, so the
          # Cancel lands before its lock claim, during its checks, around
          # its re-open, and after it.
          [cancel, start] =
            race(
              fn ->
                Process.sleep(div(3 * (n - 1), 2))
                Backups.cancel_run_resume(run, actor: admin)
              end,
              fn -> StepWorker.perform(job) end
            )

          {row, after_run} =
            unboxed(fn ->
              {Backups.backup_lock!(actor: Backups.system()),
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())}
            end)

          reopened? = after_run.status == :running and after_run.chain_id == chain

          refute row.chain_id == nil and reopened?,
                 "round #{n}: the lock is free and the run runs under the canceled chain"

          outcome =
            case cancel do
              {:ok, _} ->
                assert start == {:cancel, :superseded}, "round #{n}: #{inspect(start)}"
                assert after_run.status == :failed and after_run.chain_id == run.chain_id
                refute after_run.error =~ "Resume refused"
                assert row.chain_id == nil
                :canceled

              {:error, %Ash.Error.Invalid{}} ->
                assert start == :ok, "round #{n}: #{inspect(start)}"
                assert reopened?
                assert row.chain_id == chain
                :started
            end

          unboxed(fn ->
            Repo.delete_all(from(j in "oban_jobs", where: j.queue == "backup_steps"))
            Repo.delete_all(from(l in "backup_locks"))
          end)

          outcome
        end

      assert Enum.all?(outcomes, &(&1 in [:canceled, :started]))
    end
  end
end
