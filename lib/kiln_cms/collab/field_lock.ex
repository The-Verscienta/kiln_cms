defmodule KilnCMS.Collab.FieldLock do
  @moduledoc """
  The content editor's advisory field locks: one process per open record owns
  who may write each of its fields. Every lock operation goes through it, so
  message ordering gives first-come-first-served for free — no database
  locking, no id tie-break, no retries.

  Modelled on texttile's `Texttile.Articles.Lock`, widened from "the body" to
  "a field": the block editor locks the title, the slug, the SEO fields, every
  DSL block field and every rich-text body independently, so the process
  carries a map of locks rather than one holder.

  Releasing has three paths, and all three live here:

    1. explicit — the input blurs (`release/3`) or the editor is left on
       purpose (`release_all/2`);
    2. process death, with a grace period (`grace_ms`, 45 s) so a reload or a
       short network drop does not cost the lock: the same person coming back
       inside the grace gets it straight back;
    3. an idle timeout (`idle_ms`, 15 min) so a tab left open hands the field
       over without anybody having to take it.

  A held field can be taken over. The takeover asks the holder to flush first:
  the holder's LiveView gets `{:lock_flush, topic, field}`, pushes what still
  sits in its client-side debounce, persists it, and calls `flushed/2`; only
  then does the lock transfer. A holder that does not answer within `flush_ms`
  (3 s) is not waited for. A holder whose process is already gone has nothing
  left to flush, so that transfer is immediate.

  The process lives only as long as its locks: once every field is free and
  nobody waits for a flush, it stops, so the supervisor carries a process per
  record with a focused field, not per record ever opened.

  ## Messages

  To the LiveViews involved (direct `send/2`):

    * `{:lock_flush, topic, field}` — to the holder: flush, then `flushed/2`
    * `{:lock_taken, topic, field, by}` — to the displaced holder; `by` is
      `%{user_id, name}`
    * `{:lock_granted, topic, field}` — to whoever just got the field

  On the record's PubSub topic (the same `editing:<kind>:<id>` topic
  `KilnCMSWeb.Presence` uses, so every open editor already subscribes):

    * `{:field_locks, topic, locks}` — the full lock map after every change,
      `%{field => holder}` with `holder` a `%{user_id, name, pid, acquired_at,
      last_keystroke_at}` map.

  ## Keying and tenancy

  Keyed by the editing topic string, which carries kind and record id — the
  same key space Presence tracks editors under, so a session cannot lock a
  field of a record it is not on. Node-local, like `KilnCMS.Collab.Locks` and
  the CRDT `DocServer` registry: the editor LiveViews that hold locks are
  local pids, and the announce goes through PubSub either way.
  """

  use GenServer, restart: :temporary

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  # How long a dead holder keeps a field (a reload, a dropped socket).
  @grace_ms 45_000
  # How long a silent holder keeps a field.
  @idle_ms :timer.minutes(15)
  # How long a takeover waits for the holder's flush.
  @flush_ms 3_000
  # A holder whose last keystroke is this recent is "typing right now".
  @typing_window_s 30

  @typedoc "What other sessions see of a lock."
  @type holder :: %{
          user_id: term(),
          name: String.t(),
          pid: pid(),
          acquired_at: DateTime.t(),
          last_keystroke_at: DateTime.t()
        }

  @typedoc "Who is asking: their user id and display name."
  @type user :: %{id: term(), name: String.t()}

  ## Supervision — `KilnCMS.Application` starts the registry and the
  ## DynamicSupervisor these names refer to.

  @doc "The Registry the per-record processes register under, keyed by topic."
  def registry, do: @registry

  def start_link(opts) do
    topic = Keyword.fetch!(opts, :topic)
    GenServer.start_link(__MODULE__, opts, name: via(topic))
  end

  defp via(topic), do: {:via, Registry, {@registry, topic}}

  @doc "The lock process of a topic, started if it is not running."
  def ensure(topic) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, topic: topic}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc """
  Every field of every record is free again: each lock process is stopped,
  whoever held it. The locks live beside the database, not in it, so nothing
  rolls them back — a test starts from no open editors with this.
  """
  def forget_all do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    :ok
  end

  ## API

  @doc """
  Focusing a field: a free one is yours, a held one answers with the holder —
  and that holds for your own second tab as well. Whoever was in the field
  first goes on writing; everybody who arrives after them takes it over by
  hand or not at all.

  The one exception is the same user coming back to a tab that is gone: a
  reload or a short drop inside the grace hands the field straight back, which
  is what the grace is for. Re-focusing a field you already hold is a no-op
  that counts as activity.
  """
  @spec acquire(String.t(), String.t(), user(), pid()) :: :ok | {:held, holder()}
  def acquire(topic, field, user, pid) do
    call(topic, {:acquire, field, user, pid})
  end

  @doc "The input blurred. A record without a process is free already, so none is started."
  @spec release(String.t(), String.t(), pid()) :: :ok
  def release(topic, field, pid) do
    case Registry.lookup(@registry, topic) do
      [{lock, _}] -> call_or(lock, {:release, field, pid}, fn -> :ok end)
      [] -> :ok
    end
  end

  @doc "The editor was left on purpose: every field this session holds is free."
  @spec release_all(String.t(), pid()) :: :ok
  def release_all(topic, pid) do
    case Registry.lookup(@registry, topic) do
      [{lock, _}] -> call_or(lock, {:release_all, pid}, fn -> :ok end)
      [] -> :ok
    end
  end

  @doc """
  A keystroke from `pid`: feeds the idle rule and the takeover dialog's
  activity line for every field it holds. A cast, so the per-keystroke cost is
  one message; a record without a process has nothing to refresh.
  """
  @spec ping(String.t(), pid()) :: :ok
  def ping(topic, pid) do
    case Registry.lookup(@registry, topic) do
      [{lock, _}] -> GenServer.cast(lock, {:ping, pid})
      [] -> :ok
    end
  end

  @doc """
  Take a field over. `:ok` when it was free (or the holder is gone and had
  nothing to flush); `:pending` while the holder flushes, after which the
  requester gets `{:lock_granted, topic, field}`.
  """
  @spec takeover(String.t(), String.t(), user(), pid()) :: :ok | :pending
  def takeover(topic, field, user, pid) do
    call(topic, {:takeover, field, user, pid})
  end

  @doc "The holder finished flushing `field`; the transfer may go ahead."
  @spec flushed(String.t(), String.t()) :: :ok
  def flushed(topic, field) do
    case Registry.lookup(@registry, topic) do
      [{lock, _}] -> GenServer.cast(lock, {:flushed, field})
      [] -> :ok
    end
  end

  @doc "The current lock map, `%{field => holder}` — empty when no process runs."
  @spec locks(String.t()) :: %{optional(String.t()) => holder()}
  def locks(topic) do
    case Registry.lookup(@registry, topic) do
      [{lock, _}] -> call_or(lock, :locks, fn -> %{} end)
      [] -> %{}
    end
  end

  @doc "The holder of `field`, or `nil`."
  @spec holder(String.t(), String.t()) :: holder() | nil
  def holder(topic, field), do: topic |> locks() |> Map.get(field)

  @doc """
  Whether a holder is typing right now (last keystroke within the last
  #{@typing_window_s} seconds) — the takeover dialog's first line.
  """
  @spec typing?(holder(), DateTime.t()) :: boolean()
  def typing?(holder, now \\ DateTime.utc_now()) do
    DateTime.diff(now, holder.last_keystroke_at, :second) <= @typing_window_s
  end

  # A lock process ends itself once its record is free, and a caller can
  # reach it a breath too late: the registry still names the pid, or the pid
  # is alive but already on its way out. Either way the call exits, with
  # :noproc or with :normal. That is no failure of the caller, so the door is
  # knocked at again on a fresh process. A second miss is a real fault and is
  # left to crash.
  defp call(topic, msg) do
    call_or(ensure(topic), msg, fn -> GenServer.call(ensure(topic), msg) end)
  end

  defp call_or(pid, msg, on_gone) do
    GenServer.call(pid, msg)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal] -> on_gone.()
  end

  ## GenServer

  @impl true
  def init(opts) do
    config = Application.get_env(:kiln_cms, __MODULE__, [])

    {:ok,
     %{
       topic: Keyword.fetch!(opts, :topic),
       grace_ms: setting(opts, config, :grace_ms, @grace_ms),
       idle_ms: setting(opts, config, :idle_ms, @idle_ms),
       flush_ms: setting(opts, config, :flush_ms, @flush_ms),
       pubsub: Keyword.get(opts, :pubsub, true),
       # field => holder (private shape: adds gen + timers)
       locks: %{},
       # field => %{user, pid, timer}
       pending: %{},
       # pid => monitor ref; one monitor per holder process
       monitors: %{}
     }}
  end

  defp setting(opts, config, key, default),
    do: Keyword.get(opts, key, Keyword.get(config, key, default))

  @impl true
  def handle_call({:acquire, field, user, pid}, _from, state) do
    case Map.get(state.locks, field) do
      nil ->
        {:reply, :ok, give(state, field, user, pid)}

      # The same tab focusing the field again: activity, nothing more.
      %{pid: ^pid} ->
        {:reply, :ok, touch(state, field)}

      # The same person coming back to a tab that is not there any more: a
      # reload, a short drop, a window closed inside the grace.
      %{user_id: user_id} = holder ->
        if user_id == user.id and gone?(holder) do
          {:reply, :ok, state |> drop(field) |> give(field, user, pid)}
        else
          {:reply, {:held, public(holder)}, state}
        end
    end
  end

  def handle_call(:locks, _from, state) do
    {:reply, public_locks(state), state}
  end

  def handle_call({:release, field, pid}, _from, state) do
    state =
      case Map.get(state.locks, field) do
        %{pid: ^pid} -> state |> drop(field) |> announce()
        _ -> state
      end

    stop_reply(state)
  end

  def handle_call({:release_all, pid}, _from, state) do
    mine = for {field, %{pid: ^pid}} <- state.locks, do: field

    state =
      if mine == [] do
        state
      else
        mine |> Enum.reduce(state, &drop(&2, &1)) |> announce()
      end

    stop_reply(state)
  end

  def handle_call({:takeover, field, user, pid}, _from, state) do
    cond do
      not Map.has_key?(state.locks, field) ->
        {:reply, :ok, give(state, field, user, pid)}

      state.locks[field].pid == pid ->
        {:reply, :ok, touch(state, field)}

      # A tab that is gone has nothing left to flush, whoever's it was.
      gone?(state.locks[field]) ->
        {:reply, :ok, state |> drop(field) |> give(field, user, pid)}

      # A flush is already in flight for this field: the newest asker is the
      # one it hands over to.
      Map.has_key?(state.pending, field) ->
        pending = Map.update!(state.pending, field, &%{&1 | user: user, pid: pid})
        {:reply, :pending, %{state | pending: pending}}

      true ->
        holder = state.locks[field]
        send(holder.pid, {:lock_flush, state.topic, field})
        timer = Process.send_after(self(), {:flush_timeout, field, holder.gen}, state.flush_ms)
        pending = Map.put(state.pending, field, %{user: user, pid: pid, timer: timer})
        {:reply, :pending, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_cast({:flushed, field}, state), do: {:noreply, transfer(state, field)}

  def handle_cast({:ping, pid}, state) do
    fields = for {field, %{pid: ^pid}} <- state.locks, do: field
    {:noreply, Enum.reduce(fields, state, &touch(&2, &1))}
  end

  @impl true
  # The holder did not answer in time: whoever waits on this field gets it.
  def handle_info({:flush_timeout, field, _gen}, state),
    do: {:noreply, transfer(state, field)}

  def handle_info({:grace_over, field, gen}, state), do: expire(state, field, gen)
  def handle_info({:idle_over, field, gen}, state), do: expire(state, field, gen)

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}

    locks =
      Map.new(state.locks, fn
        {field, %{pid: ^pid, grace_timer: nil} = holder} ->
          timer = Process.send_after(self(), {:grace_over, field, holder.gen}, state.grace_ms)
          {field, %{holder | grace_timer: timer}}

        other ->
          other
      end)

    {:noreply, %{state | locks: locks}}
  end

  ## The moves

  # A holder whose tab is gone: its process is dead (grace running), or dead
  # and not yet noticed.
  defp gone?(holder), do: holder.grace_timer != nil or not Process.alive?(holder.pid)

  defp give(state, field, user, pid) do
    now = DateTime.utc_now()

    holder = %{
      user_id: user.id,
      name: user.name,
      pid: pid,
      gen: make_ref(),
      acquired_at: now,
      last_keystroke_at: now,
      grace_timer: nil,
      idle_timer: nil
    }

    state
    |> monitor(pid)
    |> put_in([:locks, field], holder)
    |> reset_idle(field)
    |> announce()
  end

  # Activity on a held field: the keystroke timestamp and the idle clock.
  defp touch(state, field) do
    state
    |> update_in([:locks, field], &%{&1 | last_keystroke_at: DateTime.utc_now()})
    |> reset_idle(field)
  end

  # The transfer itself, after the flush answered or timed out. Without a
  # pending requester (a stray timeout, a flush nobody asked for) there is
  # nothing to do.
  defp transfer(state, field) do
    case Map.pop(state.pending, field) do
      {nil, _} ->
        state

      {%{user: user, pid: pid, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        state = %{state | pending: pending}
        notify_displaced(state.locks[field], state.topic, field, user, pid)
        send(pid, {:lock_granted, state.topic, field})
        state |> drop(field) |> give(field, user, pid)
    end
  end

  # The displaced holder learns who took the field — unless the field was
  # free by then (released mid-flush), or the taker is the holder's own pid.
  defp notify_displaced(nil, _topic, _field, _user, _pid), do: :ok
  defp notify_displaced(%{pid: pid}, _topic, _field, _user, pid), do: :ok

  defp notify_displaced(holder, topic, field, user, _pid),
    do: send(holder.pid, {:lock_taken, topic, field, Map.take(user, [:id, :name])})

  defp expire(state, field, gen) do
    case state.locks[field] do
      %{gen: ^gen} -> state |> drop(field) |> announce() |> stop_noreply()
      _ -> {:noreply, state}
    end
  end

  defp drop(state, field) do
    case Map.pop(state.locks, field) do
      {nil, _} ->
        state

      {holder, locks} ->
        cancel(holder.grace_timer)
        cancel(holder.idle_timer)
        %{state | locks: locks} |> demonitor_if_unused(holder.pid)
    end
  end

  defp reset_idle(state, field) do
    update_in(state, [:locks, field], fn holder ->
      cancel(holder.idle_timer)
      timer = Process.send_after(self(), {:idle_over, field, holder.gen}, state.idle_ms)
      %{holder | idle_timer: timer}
    end)
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp monitor(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
    end
  end

  defp demonitor_if_unused(state, pid) do
    still_holds? = Enum.any?(state.locks, fn {_field, holder} -> holder.pid == pid end)

    case Map.fetch(state.monitors, pid) do
      {:ok, ref} when not still_holds? ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, pid)}

      _ ->
        state
    end
  end

  # A record with no locks that waits for nobody has nothing left to watch. A
  # takeover still in flight keeps the process alive until it is resolved: its
  # requester waits for a message this process alone can send.
  defp stop_noreply(%{locks: locks, pending: pending} = state)
       when map_size(locks) == 0 and map_size(pending) == 0,
       do: {:stop, :normal, state}

  defp stop_noreply(state), do: {:noreply, state}

  defp stop_reply(%{locks: locks, pending: pending} = state)
       when map_size(locks) == 0 and map_size(pending) == 0,
       do: {:stop, :normal, :ok, state}

  defp stop_reply(state), do: {:reply, :ok, state}

  defp announce(state) do
    if state.pubsub do
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        state.topic,
        {:field_locks, state.topic, public_locks(state)}
      )
    end

    state
  end

  defp public_locks(state), do: Map.new(state.locks, fn {field, h} -> {field, public(h)} end)

  defp public(holder),
    do: Map.take(holder, [:user_id, :name, :pid, :acquired_at, :last_keystroke_at])
end
