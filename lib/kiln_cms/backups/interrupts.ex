defmodule KilnCMS.Backups.Interrupts do
  @moduledoc """
  The file work that follows a backup `KilnCMS.Backups.Chain` interrupted from
  outside its step, after the lock's commit, in a task apart from the caller
  (#3078).

  A reclaim with no attempts left, a reap and the stranded-step sweep each
  release the lock in a transaction of their own, and fail the run right
  after, in the caller (no `BACKUP_DIR` I/O). What is left reads and writes
  `BACKUP_DIR`: the failure manifest, a re-send's work directory, and the
  whole record of an interrupted finish, whose verdict needs its files. On a
  hung mount that blocks, and it used to block the heartbeat with it, so the
  node stopped beating (and was then taken over) because of another node's
  step. Now the caller hands it here with `run/3`, a cast, and goes on: the
  heartbeat's tick, and a backup request that sweeps first, never wait on it.
  The failure manifest and a work directory's removal are fenced by the lock
  as the release left it (`Chain.released_fenced/3`), so a record that runs
  late never writes over a newer backup's manifest or removes its files.

  ## One at a time

  The work runs in a task under `KilnCMS.Backups.InterruptTasks`, one at a
  time, in the order it came. A process blocked in a file operation on a hung
  mount can't be killed, so a task per interrupt would pile up there; this
  way a hung directory holds one task, and the work queued behind it runs
  once it answers. At most 20 wait. One that doesn't fit is dropped with a
  line in the log naming the backup and what is left undone: for a finish,
  an error, as its run then reads `Running` until the stale-run check
  (`Backups.reconcile_stale_runs/1`, about 2 h 15 min after its last
  update) fails it, and only then can it be resumed. A task that has run
  for 60 s logs one warning, and a line when it ends; while one has, this
  node's heartbeat skips the lock sweep (`stalled?/0`). Another node's
  heartbeat, and a backup request on any node, still sweep; on a shared
  mount hung for every node, only requests do until it answers.

  A task that crashes is logged, and the next one starts. If this process
  restarts while a task runs, it finds that task under the supervisor and
  starts none until it has ended, so two never run at once. The queue lives
  in this process: a restart, or a node that stops, loses what is still in
  it.

  `config :kiln_cms, KilnCMS.Backups, interrupts: :inline` (the test build)
  runs the work in the caller instead.
  """
  use GenServer

  require Logger

  @max_queued 20
  @slow_ms 60_000
  @tasks KilnCMS.Backups.InterruptTasks

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` after the work handed over before it, in a task of its own;
  `label` names the backup in the log (a stamp, or what stands for one).
  Returns at once. In the test build's `:inline` mode `fun` runs here.

  `opts`: `dropped: {level, sentence}`, what the log says is left undone
  when the queue is full and `fun` is dropped (a warning by default).
  """
  @spec run(String.t(), (-> term()), keyword()) :: :ok
  def run(label, fun, opts \\ []) when is_binary(label) and is_function(fun, 0) do
    if inline?() do
      _ = fun.()
      :ok
    else
      # The caller's `$callers`, so the task shares a test's sandbox.
      callers = [self() | Process.get(:"$callers", [])]
      dropped = Keyword.get(opts, :dropped, {:warning, "What it left undone is not done."})

      GenServer.cast(
        __MODULE__,
        {:run, %{label: label, fun: fun, callers: callers, dropped: dropped}}
      )
    end
  end

  @doc """
  Whether a task has run for longer than 60 s (a hung `BACKUP_DIR`, most
  likely): `KilnCMS.Backups.Heartbeat` then skips the lock sweep, so a
  healthy node takes the next interrupt rather than this one queueing it.
  False when this process doesn't answer within a second, and always in
  `:inline` mode.
  """
  @spec stalled?() :: boolean()
  def stalled? do
    not inline?() and GenServer.call(__MODULE__, :stalled?, 1_000)
  catch
    :exit, _reason -> false
  end

  @doc false
  # Tests: `:ok` once nothing runs or waits, `:timeout` after `timeout` ms.
  @spec await_idle(timeout()) :: :ok | :timeout
  def await_idle(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :await_idle, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
  end

  @impl GenServer
  def init(_opts) do
    # Tasks a crashed predecessor left running: none starts until they end.
    orphans =
      for pid <- running_tasks(), into: %{} do
        {Process.monitor(pid), now_ms()}
      end

    if orphans != %{} do
      Logger.warning(
        "Backup interrupt records: #{map_size(orphans)} task(s) of an earlier run of this " <>
          "process are still running; the next record waits for them"
      )
    end

    {:ok, %{running: nil, orphans: orphans, queue: :queue.new(), queued: 0, idle_waiters: []}}
  end

  @impl GenServer
  def handle_cast({:run, item}, %{running: nil, orphans: orphans} = state)
      when map_size(orphans) == 0 do
    {:noreply, start(state, item)}
  end

  def handle_cast({:run, item}, %{queued: queued} = state) when queued >= @max_queued do
    {level, sentence} = item.dropped

    Logger.log(
      level,
      "Backup #{item.label}: dropped from the interrupt records, #{queued} are waiting " <>
        "behind one that has run for #{div(busy_ms(state), 1000)} s (a hung BACKUP_DIR?). " <>
        sentence
    )

    {:noreply, state}
  end

  def handle_cast({:run, item}, state) do
    {:noreply, %{state | queue: :queue.in(item, state.queue), queued: state.queued + 1}}
  end

  @impl GenServer
  def handle_call(:stalled?, _from, state),
    do: {:reply, busy?(state) and busy_ms(state) >= slow_ms(), state}

  def handle_call(:await_idle, _from, %{running: nil, orphans: orphans} = state)
      when map_size(orphans) == 0,
      do: {:reply, :ok, state}

  def handle_call(:await_idle, from, state),
    do: {:noreply, %{state | idle_waiters: [from | state.idle_waiters]}}

  @impl GenServer
  def handle_info({ref, _result}, %{running: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, :normal)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref}} = state) do
    {:noreply, finished(state, reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{orphans: orphans} = state)
      when is_map_key(orphans, ref) do
    {:noreply, next(%{state | orphans: Map.delete(orphans, ref)})}
  end

  def handle_info({:slow, ref}, %{running: %{ref: ref} = running} = state) do
    Logger.warning(
      "Backup #{running.label}: the interrupt record has taken more than " <>
        "#{div(slow_ms(), 1000)} s (a hung BACKUP_DIR?). Records of other interrupted " <>
        "backups wait behind it, and this node's heartbeat skips the lock sweep."
    )

    {:noreply, %{state | running: %{running | slow?: true}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start(state, item) do
    task =
      Task.Supervisor.async_nolink(@tasks, fn ->
        Process.put(:"$callers", item.callers)
        before_interrupt(item.label)
        item.fun.()
      end)

    Process.send_after(self(), {:slow, task.ref}, slow_ms())
    %{state | running: %{ref: task.ref, label: item.label, since: now_ms(), slow?: false}}
  rescue
    # The task supervisor isn't running (only while the application stops).
    error ->
      Logger.error(
        "Backup #{item.label}: couldn't start the interrupt record: " <> Exception.message(error)
      )

      next(%{state | running: nil})
  catch
    :exit, reason ->
      Logger.error(
        "Backup #{item.label}: couldn't start the interrupt record: " <> inspect(reason)
      )

      next(%{state | running: nil})
  end

  defp finished(%{running: running} = state, reason) do
    took = div(now_ms() - running.since, 1000)

    cond do
      reason not in [:normal, :noproc] ->
        Logger.error(
          "Backup #{running.label}: the interrupt record crashed: " <> inspect(reason, limit: 5)
        )

      running.slow? ->
        Logger.info("Backup #{running.label}: the interrupt record finished after #{took} s")

      true ->
        :ok
    end

    next(%{state | running: nil})
  end

  defp next(%{orphans: orphans} = state) when map_size(orphans) > 0, do: state

  defp next(state) do
    case :queue.out(state.queue) do
      {{:value, item}, queue} -> start(%{state | queue: queue, queued: state.queued - 1}, item)
      {:empty, _queue} -> reply_idle(state)
    end
  end

  defp reply_idle(state) do
    Enum.each(state.idle_waiters, &GenServer.reply(&1, :ok))
    %{state | idle_waiters: []}
  end

  # How long the oldest task still running has run: the current one, or one
  # a crashed predecessor left (counted from this process's start).
  defp busy_ms(state) do
    since = [state.running && state.running.since | Map.values(state.orphans)]

    case Enum.reject(since, &is_nil/1) do
      [] -> 0
      times -> now_ms() - Enum.min(times)
    end
  end

  defp busy?(state), do: state.running != nil or map_size(state.orphans) > 0

  defp running_tasks do
    Task.Supervisor.children(@tasks)
  catch
    :exit, _reason -> []
  end

  # `config :kiln_cms, KilnCMS.Backups, interrupts: :inline`, and, tests
  # only, `interrupt_slow_ms:` and `before_interrupt:` (a one-argument
  # function of the label, run in the task first).
  defp inline?, do: Keyword.get(backups_env(), :interrupts) == :inline

  defp slow_ms, do: Keyword.get(backups_env(), :interrupt_slow_ms, @slow_ms)

  defp before_interrupt(label) do
    case Keyword.get(backups_env(), :before_interrupt) do
      hook when is_function(hook, 1) -> hook.(label)
      _ -> :ok
    end
  end

  defp backups_env, do: Application.get_env(:kiln_cms, KilnCMS.Backups, [])

  defp now_ms, do: System.monotonic_time(:millisecond)
end
