defmodule KilnCMS.Backups.Interrupts do
  @moduledoc """
  Records the backups that `KilnCMS.Backups.Chain` interrupted from outside
  their step, after the lock's commit, in a task apart from the caller
  (#3078).

  A reclaim with no attempts left, a reap and the stranded-step sweep each
  release the lock in a transaction of their own. What follows reads and
  writes `BACKUP_DIR`: failing the run and writing its failure manifest,
  completing a finish that had in fact finished, a re-send's tail. On a hung
  mount that blocks, and it used to block the heartbeat with it, so the node
  stopped beating (and was then taken over) because of another node's step.
  Now the caller hands the work here with `run/2`, a cast, and goes on: the
  heartbeat's tick, and a backup request that sweeps first, never wait on it.

  ## One at a time

  The work runs in a task under `KilnCMS.Backups.InterruptTasks`, one at a
  time, in the order it came. A process blocked in a file operation on a hung
  mount can't be killed, so a task per interrupt would pile up there; this
  way a hung directory holds one task, and the records queued behind it run
  once it answers. At most 20 wait. One that doesn't fit is dropped with an
  error in the log naming the backup: its run then stays `Running` and quiet,
  which **Resume** treats as interrupted. A task that has run for 60 s logs
  one warning, and a line when it ends.

  A task that crashes is logged, and the next one starts. The queue lives in
  this process: a node that stops loses what is still in it, as it lost the
  record of a reclaim it was making before #3078.

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
  """
  @spec run(String.t(), (-> term())) :: :ok
  def run(label, fun) when is_binary(label) and is_function(fun, 0) do
    if inline?() do
      _ = fun.()
      :ok
    else
      # The caller's `$callers`, so the task shares a test's sandbox.
      callers = [self() | Process.get(:"$callers", [])]
      GenServer.cast(__MODULE__, {:run, label, fun, callers})
    end
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
    {:ok, %{running: nil, queue: :queue.new(), queued: 0, idle_waiters: []}}
  end

  @impl GenServer
  def handle_cast({:run, label, fun, callers}, %{running: nil} = state) do
    {:noreply, start(state, {label, fun, callers})}
  end

  def handle_cast({:run, label, _fun, _callers}, %{queued: queued} = state)
      when queued >= @max_queued do
    Logger.error(
      "Backup #{label}: not recorded as interrupted. #{queued} earlier records are waiting " <>
        "behind one that has run for #{div(now_ms() - state.running.since, 1000)} s " <>
        "(a hung BACKUP_DIR?). Its run stays Running; Resume it once the directory answers."
    )

    {:noreply, state}
  end

  def handle_cast({:run, label, fun, callers}, state) do
    {:noreply,
     %{state | queue: :queue.in({label, fun, callers}, state.queue), queued: state.queued + 1}}
  end

  @impl GenServer
  def handle_call(:await_idle, _from, %{running: nil} = state), do: {:reply, :ok, state}

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

  def handle_info({:slow, ref}, %{running: %{ref: ref} = running} = state) do
    Logger.warning(
      "Backup #{running.label}: recording it as interrupted has taken more than " <>
        "#{div(@slow_ms, 1000)} s (a hung BACKUP_DIR?). Records of other interrupted " <>
        "backups wait behind it; the heartbeat and the lock sweep go on."
    )

    {:noreply, %{state | running: %{running | slow?: true}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start(state, {label, fun, callers}) do
    task =
      Task.Supervisor.async_nolink(@tasks, fn ->
        Process.put(:"$callers", callers)
        before_interrupt(label)
        fun.()
      end)

    Process.send_after(self(), {:slow, task.ref}, @slow_ms)
    %{state | running: %{ref: task.ref, label: label, since: now_ms(), slow?: false}}
  rescue
    # The task supervisor isn't running (only while the application stops).
    error ->
      Logger.error(
        "Backup #{label}: couldn't start recording it as interrupted: " <>
          Exception.message(error)
      )

      next(%{state | running: nil})
  catch
    :exit, reason ->
      Logger.error(
        "Backup #{label}: couldn't start recording it as interrupted: " <> inspect(reason)
      )

      next(%{state | running: nil})
  end

  defp finished(%{running: running} = state, reason) do
    took = div(now_ms() - running.since, 1000)

    cond do
      reason not in [:normal, :noproc] ->
        Logger.error(
          "Backup #{running.label}: recording it as interrupted crashed: " <>
            inspect(reason, limit: 5)
        )

      running.slow? ->
        Logger.info("Backup #{running.label}: recorded as interrupted after #{took} s")

      true ->
        :ok
    end

    next(%{state | running: nil})
  end

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

  # `config :kiln_cms, KilnCMS.Backups, interrupts: :inline` and
  # `before_interrupt:` (a one-argument function of the label, run in the
  # task first; tests only).
  defp inline?, do: Keyword.get(backups_env(), :interrupts) == :inline

  defp before_interrupt(label) do
    case Keyword.get(backups_env(), :before_interrupt) do
      hook when is_function(hook, 1) -> hook.(label)
      _ -> :ok
    end
  end

  defp backups_env, do: Application.get_env(:kiln_cms, KilnCMS.Backups, [])

  defp now_ms, do: System.monotonic_time(:millisecond)
end
