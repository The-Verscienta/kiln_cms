defmodule KilnCMS.Search.Budget do
  @moduledoc false
  # The clock behind `KilnCMS.Search.query_budget/0` (#2166): deadlines, a
  # serving call bounded by one, and `global/2`'s first round run against one.
  #
  # Deadlines are monotonic milliseconds, or `:infinity` for none.

  @type deadline() :: integer() | :infinity

  # `{key, fn sweep -> result end}`: `sweep` is `%{deadline: _, emit: _}`,
  # and a section calls `emit.(leg, result)` for each part it finishes.
  @type section() :: {term(), (map() -> term())}
  @type outcome() :: {:done, term()} | {:cut, %{term() => term()}}

  @spec deadline(non_neg_integer() | :infinity) :: deadline()
  def deadline(:infinity), do: :infinity
  def deadline(ms) when is_integer(ms) and ms >= 0, do: System.monotonic_time(:millisecond) + ms

  @spec half(non_neg_integer() | :infinity) :: non_neg_integer() | :infinity
  def half(:infinity), do: :infinity
  def half(ms), do: div(ms, 2)

  @spec past?(deadline()) :: boolean()
  def past?(:infinity), do: false
  def past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  `fun` for as long as `deadline` allows, on a pool of at most `limit` calls
  in flight node-wide (named by `slots`): `{:ok, result}`, `:timeout`, or
  `:busy` when the pool is full and `fun` never started.

  For work that killing the caller does not stop — a call into an
  `Nx.Serving` stays in its queue, and the serving runs it, whether or not
  anyone still waits. So a call that misses its deadline is abandoned, not
  killed: it keeps its slot until it really finishes, and the slots count
  what the serving has in hand. Without them, every search the budget cut
  left its batch behind, and under load the backlog took the CPU that the
  next searches needed (#2166). A late answer goes to a process alias that
  is gone by then, so nothing reaches the caller's mailbox after it stopped
  waiting.
  """
  @spec within_slots(term(), pos_integer(), integer(), (-> result)) ::
          {:ok, result} | :timeout | :busy
        when result: term()
  def within_slots(slots, limit, deadline, fun) when is_integer(deadline) do
    counter = slots(slots)

    if :atomics.add_get(counter, 1, 1) > limit do
      :atomics.sub(counter, 1, 1)
      :busy
    else
      reply_to = Process.alias([:reply])
      ref = make_ref()

      started =
        Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn ->
          result =
            try do
              {:ok, fun.()}
            rescue
              error -> {:raised, error, __STACKTRACE__}
            after
              :atomics.sub(counter, 1, 1)
            end

          send(reply_to, {ref, result})
        end)

      case started do
        {:ok, _pid} ->
          await_slot(reply_to, ref, deadline)

        # The task supervisor is at `max_children`: as full as a pool can be.
        {:error, _max_children} ->
          :atomics.sub(counter, 1, 1)
          Process.unalias(reply_to)
          :busy
      end
    end
  end

  defp await_slot(reply_to, ref, deadline) do
    receive do
      {^ref, {:ok, result}} -> {:ok, result}
      {^ref, {:raised, error, stacktrace}} -> reraise(error, stacktrace)
    after
      remaining(deadline) ->
        Process.unalias(reply_to)
        # An answer sent between the timeout and the unalias.
        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  @doc false
  # How many `within_slots/4` calls on `slots` are in flight. For tests.
  @spec in_flight(term()) :: non_neg_integer()
  def in_flight(slots), do: slots |> slots() |> :atomics.get(1)

  # One counter per pool, created on first use and kept for the life of the
  # node. Two callers racing to create it can each make one; the loser's
  # calls are counted on a counter nobody else reads, once.
  defp slots(name) do
    key = {__MODULE__, :slots, name}

    case :persistent_term.get(key, nil) do
      nil ->
        counter = :atomics.new(1, signed: true)
        :persistent_term.put(key, counter)
        counter

      counter ->
        counter
    end
  end

  @doc """
  Run `sections` before `deadline`: `%{key => outcome}`, where a section that
  finished is `{:done, result}` and one the deadline stopped is `{:cut,
  sent}` — `sent` being `%{leg => result}` for what it had passed to `emit`.
  That is how a cut content section keeps the legs it finished. A section
  not started by the deadline is `{:cut, %{}}`.

  At `concurrency: 1` the sections run in the caller's process and the
  deadline is only checked: between sections here, between legs in the
  section (`emit` is `nil` there, since nothing can stop it midway). Above 1
  it is enforced: up to `concurrency` tasks run at once, nothing new starts
  once the deadline has passed, and the tasks still running then get
  `:grace` more milliseconds (default 0) to return on their own. A section
  that returns inside the grace is `{:done, result}`; one still running
  after it is killed and cut. With no deadline, a sweep that makes no
  progress for `:stall_timeout` milliseconds raises. A section that raises
  fails the call with its own error.

  Why a grace (#2614): killing a task that holds a database connection
  mid-query costs that connection. Postgrex cancels the query on the server
  (a `CancelRequest`, so nothing keeps running there), but DBConnection
  drops the connection and opens a new one — and in the SQL sandbox the
  connection it drops is the test's own. A section checks the deadline
  between its legs, so most return within one query of it. The grace only
  saves the connection of a query that finishes inside it: a query still
  running after it is killed as before, and a task that was waiting for a
  connection at the deadline may get one during the grace and run its
  query. A server-side `statement_timeout` would bound each query instead,
  but only inside a transaction or with a session `SET`/`RESET` per
  checkout — round trips on every search to spare a reconnect on the rare
  one the budget cuts.

  When the deadline passes with sections still running, it emits
  `[:kiln_cms, :search, :budget, :cut]` with `%{returned: n, killed: k}`:
  how many of them returned after the deadline (inside the grace, or while
  being stopped) and how many were killed.
  """
  @spec run([section()], deadline(), keyword()) :: %{term() => outcome()}
  def run(sections, deadline, opts) do
    case Keyword.fetch!(opts, :concurrency) do
      1 ->
        Map.new(sections, fn {key, run} -> {key, run_in_caller(run, deadline)} end)

      concurrency ->
        %{
          pending: sections,
          running: %{},
          outcomes: %{},
          sent: %{},
          tag: make_ref(),
          deadline: deadline,
          grace: Keyword.get(opts, :grace, 0),
          grace_until: nil,
          returned: 0,
          max: concurrency,
          stall: Keyword.fetch!(opts, :stall_timeout)
        }
        |> start()
        |> await()
    end
  end

  defp run_in_caller(run, deadline) do
    if past?(deadline),
      do: {:cut, %{}},
      else: {:done, run.(%{deadline: deadline, emit: nil})}
  end

  defp start(%{pending: [{key, run} | rest], running: running, max: max} = state)
       when map_size(running) < max do
    if past?(state.deadline) do
      state
    else
      %{tag: tag, deadline: deadline} = state
      parent = self()
      emit = fn leg, result -> send(parent, {tag, :leg, key, leg, result}) end

      task =
        Task.async(fn ->
          try do
            {key, run.(%{deadline: deadline, emit: emit})}
          rescue
            error -> {key, {:section_failed, error, __STACKTRACE__}}
          end
        end)

      start(%{state | pending: rest, running: Map.put(running, task.ref, {key, task})})
    end
  end

  defp start(state), do: state

  # Nothing in flight with sections left over means the deadline passed
  # before they could start.
  defp await(%{running: running} = state) when map_size(running) == 0 do
    if state.grace_until, do: cut_event(state.returned, 0)

    Enum.reduce(state.pending, state.outcomes, fn {key, _run}, acc ->
      Map.put(acc, key, {:cut, %{}})
    end)
  end

  defp await(%{tag: tag, running: running} = state) do
    receive do
      {^tag, :leg, key, leg, result} ->
        state |> record_sent(key, leg, result) |> await()

      {ref, reply} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        state = %{state | running: Map.delete(running, ref), returned: returned(state)}
        {key, result} = unwrap(reply, state.running)

        %{state | outcomes: Map.put(state.outcomes, key, {:done, result})}
        |> start()
        |> await()

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {key, _task} = running[ref]
        shutdown(Map.delete(running, ref))
        raise "search section #{inspect(key)} exited: #{inspect(reason)}"
    after
      wait(state) ->
        if state.deadline == :infinity do
          shutdown(running)
          keys = running |> Map.values() |> Enum.map(&elem(&1, 0))
          raise "search section(s) #{inspect(keys)} made no progress in #{state.stall} ms"
        end

        if state.grace_until == nil and state.grace > 0,
          do: await(%{state | grace_until: state.deadline + state.grace}),
          else: cut(state)
    end
  end

  defp wait(%{deadline: :infinity, stall: stall}), do: stall
  defp wait(%{grace_until: nil, deadline: deadline}), do: remaining(deadline)
  defp wait(%{grace_until: grace_until}), do: remaining(grace_until)

  # A section that answers once the grace has begun returned after the
  # deadline.
  defp returned(%{grace_until: nil, returned: returned}), do: returned
  defp returned(%{returned: returned}), do: returned + 1

  defp record_sent(state, key, leg, result) do
    Map.update!(state, :sent, fn sent ->
      Map.update(sent, key, %{leg => result}, &Map.put(&1, leg, result))
    end)
  end

  # A section that raised fails the call with its own error — after stopping
  # the others, which would otherwise outlive a caller that rescues it
  # (`KilnCMS.Search.unless_unavailable/1`).
  defp unwrap({_key, {:section_failed, error, stacktrace}}, running) do
    shutdown(running)
    reraise(error, stacktrace)
  end

  defp unwrap(reply, _running), do: reply

  # The deadline (and the grace after it) passed. A task that answered while
  # being stopped is done; the rest keep what they sent, and the sections
  # never started have none.
  defp cut(%{running: running} = state) do
    replies =
      Enum.map(running, fn {_ref, {key, task}} -> {key, Task.shutdown(task, :brutal_kill)} end)

    finished =
      for {key, {:ok, reply}} <- replies, do: {key, {:done, reply |> unwrap(%{}) |> elem(1)}}

    cut_event(state.returned + length(finished), length(replies) - length(finished))

    %{sent: sent} = drain(state)
    stopped = Enum.map(Map.values(running), &elem(&1, 0)) ++ Enum.map(state.pending, &elem(&1, 0))

    stopped
    |> Map.new(&{&1, {:cut, Map.get(sent, &1, %{})}})
    |> Map.merge(Map.new(finished))
    |> Map.merge(state.outcomes)
  end

  # What a task sent before it was killed is already in the mailbox: a local
  # send is delivered before the sender can be stopped.
  defp drain(%{tag: tag} = state) do
    receive do
      {^tag, :leg, key, leg, result} -> state |> record_sent(key, leg, result) |> drain()
    after
      0 -> state
    end
  end

  defp cut_event(returned, killed),
    do:
      :telemetry.execute(
        [:kiln_cms, :search, :budget, :cut],
        %{returned: returned, killed: killed},
        %{}
      )

  defp shutdown(running),
    do: Enum.each(running, fn {_ref, {_key, task}} -> Task.shutdown(task, :brutal_kill) end)
end
