defmodule KilnCMS.Backups.Fence do
  @moduledoc """
  The backup self-fence's watchdog (#2848): a process apart from
  `KilnCMS.Backups.Heartbeat` that kills this node's backup steps once the
  heartbeat's last successful beat is `KilnCMS.Backups.Heartbeat.fence_after_ms/0`
  old.

  The heartbeat's own tick also fences, but the tick did file I/O on
  `BACKUP_DIR` (the backup-directory id, and the sweep's interrupted-run
  cleanup; both now run in tasks of their own, #2848 and #3078), and its
  database calls can still hang on a half-open connection. A fence inside a
  blocked tick would never run. This process does no file or
  database I/O: it reads `KilnCMS.Backups.StepRegistry` and kills processes,
  every few seconds. The heartbeat tells it of each successful beat
  (`beat/1`); until the first one, the time this process started stands in.

  Started next to the heartbeat in `KilnCMS.Application`, only when the
  heartbeat is (`config :kiln_cms, KilnCMS.Backups, heartbeat?: true`).
  """
  use GenServer

  alias KilnCMS.Backups.Heartbeat

  require Logger

  @check_ms 5_000

  @doc """
  Options: `:name` (default this module), `:fence_after_ms` (default
  `Heartbeat.fence_after_ms/0`) and `:check_ms` (default 5 s). Tests shorten
  the last two; a deployment does not set them.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Record a successful beat at `at` (`System.monotonic_time(:millisecond)`).
  A cast: the heartbeat never waits on this process, and a beat sent while
  none runs (the test build) goes nowhere.
  """
  @spec beat(GenServer.server(), integer()) :: :ok
  def beat(server \\ __MODULE__, at), do: GenServer.cast(server, {:beat, at})

  @impl GenServer
  def init(opts) do
    state = %{
      last_beat: now_ms(),
      fence_after_ms: Keyword.get(opts, :fence_after_ms, Heartbeat.fence_after_ms()),
      check_ms: Keyword.get(opts, :check_ms, @check_ms)
    }

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:beat, at}, state),
    do: {:noreply, %{state | last_beat: max(at, state.last_beat)}}

  @impl GenServer
  def handle_info(:check, state) do
    since = now_ms() - state.last_beat
    if since >= state.fence_after_ms, do: kill_steps(since)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Kill every process registered in `KilnCMS.Backups.StepRegistry`, logging
  why: `since_ms` is how long ago this node last beat. Each step's
  `KilnCMS.ExternalCommand` run then kills its `pg_dump`, `tar` or
  `rclone`, whose port closes with the step. Returns how many were killed. Registry reads only, no I/O.
  """
  @spec kill_steps(non_neg_integer()) :: non_neg_integer()
  def kill_steps(since_ms) do
    case step_pids() do
      [] ->
        0

      pids ->
        Logger.error(
          "Backup heartbeat: no successful beat for #{div(since_ms, 1000)} s; " <>
            "stopping #{length(pids)} backup step(s) on this node before another node " <>
            "takes them over"
        )

        Enum.each(pids, &Process.exit(&1, :kill))
        length(pids)
    end
  end

  defp step_pids do
    KilnCMS.Backups.StepRegistry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  defp schedule(state), do: Process.send_after(self(), :check, state.check_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
