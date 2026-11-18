defmodule KilnCMS.Test.DirQueueControl do
  @moduledoc """
  The test build's `KilnCMS.Backups.DirQueues` control (#2845, set in
  `config/test.exs`): records what the heartbeat asks of Oban's queues instead
  of starting real ones, which under `testing: :manual` would fetch from the
  sandbox.

  Each test sees only its own queues: the state is keyed by the test process,
  found through `$callers`, so a task the test starts shares it and async
  tests don't mix. A started queue runs at once, unless `refuse_starts/1`
  says starts don't take (Oban's notifier is down).
  """
  @behaviour KilnCMS.Backups.DirQueues.Control

  @doc "The calls this test made, oldest first: `{:start | :pause | :resume, queue}`."
  @spec calls() :: [{atom(), String.t()}]
  def calls, do: get(owner()).calls |> Enum.reverse()

  @doc "The status of `queue` for this test: `:running`, `:paused` or `:stopped`."
  @spec status(String.t()) :: :running | :paused | :stopped
  def status(queue), do: Map.get(get(owner()).queues, queue, :stopped)

  @doc "From now on in this test, a start is recorded but the queue doesn't run."
  @spec refuse_starts(boolean()) :: :ok
  def refuse_starts(refuse?), do: update(owner(), &%{&1 | refuse_starts?: refuse?})

  @doc "Set `queue`'s status for this test, as if Oban had changed it."
  @spec put_status(String.t(), :running | :paused | :stopped) :: :ok
  def put_status(queue, status) do
    update(owner(), fn state ->
      %{state | queues: Map.put(state.queues, queue, status)}
    end)
  end

  @impl true
  def check(queue), do: status(queue)

  @impl true
  def start(queue) do
    update(owner(), fn state ->
      state = record(state, {:start, queue})
      if state.refuse_starts?, do: state, else: put_in(state.queues[queue], :running)
    end)
  end

  @impl true
  def pause(queue) do
    update(owner(), fn state ->
      state = record(state, {:pause, queue})

      if Map.has_key?(state.queues, queue),
        do: put_in(state.queues[queue], :paused),
        else: state
    end)
  end

  @impl true
  def resume(queue) do
    update(owner(), fn state ->
      state = record(state, {:resume, queue})

      if Map.has_key?(state.queues, queue),
        do: put_in(state.queues[queue], :running),
        else: state
    end)
  end

  @impl true
  def running do
    for {queue, status} <- get(owner()).queues, status != :stopped, do: {queue, status}
  end

  defp record(state, call), do: %{state | calls: [call | state.calls]}

  # The test process: the last of `$callers`, or this process.
  defp owner do
    case Process.get(:"$callers") do
      [_ | _] = callers -> List.last(callers)
      _ -> self()
    end
  end

  defp get(owner), do: Agent.get(agent(), &Map.get(&1, owner, empty()))

  defp update(owner, fun) do
    Agent.update(agent(), fn all -> Map.put(all, owner, fun.(Map.get(all, owner, empty()))) end)
  end

  defp empty, do: %{calls: [], queues: %{}, refuse_starts?: false}

  # Started on first use, outside any test's supervision so it outlives the
  # test that started it. A concurrent start loses to the first.
  defp agent do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
