defmodule KilnCMS.Backups.MarkerSyncAbandoned do
  @moduledoc """
  The last-good marker sync's abandoned I/O tasks (#3079): the ones
  `KilnCMS.Backups.MarkerSyncWorker` stopped waiting on and left running,
  because a process blocked in a file operation on a hung mount can't be
  killed.

  The worker asks `count/0` before it starts a task, and starts none while
  two abandoned ones are still alive, so a mount that stays hung can't pile
  them up. Tasks that are merely running (a sync waiting its turn for the
  backup lock, say) are not counted.

  Each abandoned task is monitored. When one ends, a line is logged at info
  with how long it took, so a slow but healthy directory shows up as one
  rather than only as the earlier warning.
  """
  use GenServer

  require Logger

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Tracks `pid`, a task the worker stopped waiting on: the `phase` it was in
  (`:dir_id` or `:sync`) and the backup directory `dir`.
  """
  @spec abandon(pid(), atom(), Path.t()) :: :ok
  def abandon(pid, phase, dir), do: GenServer.call(__MODULE__, {:abandon, pid, phase, dir})

  @doc "How many abandoned tasks are still alive."
  @spec count() :: non_neg_integer()
  def count, do: GenServer.call(__MODULE__, :count)

  @impl GenServer
  def init(:ok), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:abandon, pid, phase, dir}, _from, tasks) do
    ref = Process.monitor(pid)
    task = %{pid: pid, phase: phase, dir: dir, since: System.monotonic_time(:millisecond)}
    {:reply, :ok, Map.put(tasks, ref, task)}
  end

  # A task whose `:DOWN` is still in flight is not counted.
  def handle_call(:count, _from, tasks) do
    {:reply, Enum.count(tasks, fn {_ref, task} -> Process.alive?(task.pid) end), tasks}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, tasks) do
    case Map.pop(tasks, ref) do
      {nil, tasks} ->
        {:noreply, tasks}

      {task, tasks} ->
        log_ended(task, reason)
        {:noreply, tasks}
    end
  end

  def handle_info(_message, tasks), do: {:noreply, tasks}

  # `:noproc`: it ended between the worker giving up and the monitor.
  defp log_ended(task, reason) do
    took = div(System.monotonic_time(:millisecond) - task.since, 1000)
    what = describe(task.phase)

    if reason in [:normal, :noproc] do
      Logger.info(
        "Backup last-good marker sync: the #{what} of #{task.dir} finished after #{took} s " <>
          "more, after the job had given up on it"
      )
    else
      Logger.info(
        "Backup last-good marker sync: the #{what} of #{task.dir} ended after #{took} s " <>
          "more (#{inspect(reason)}), after the job had given up on it"
      )
    end
  end

  defp describe(:dir_id), do: "id read"
  defp describe(:sync), do: "marker sync"
  defp describe(other), do: to_string(other)
end
