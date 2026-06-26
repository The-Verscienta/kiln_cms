defmodule KilnCMS.Collab.Locks do
  @moduledoc """
  Soft, in-memory block locks for collaborative editing (Kiln v2 — decision D5/F).

  A block can be held by at most one editor at a time; conflicting writes are
  rejected with a friendly error rather than clobbering. This is the
  server-authoritative coarse-grained collaboration the v1 scope calls for (the
  `docs/collaborative-editing-spike.md` single-editor + Presence model); CRDT/OT
  remains post-v1. Keyed by `{document_key, block_id}`.

  A held lock is released automatically when the acquiring process dies
  (`Process.monitor`) or after an idle TTL (a periodic sweep), so a crashed or
  vanished editor can't strand a block or grow the lock map without bound.
  """
  use GenServer

  @type holder :: term()

  # Idle lifetime of a lock and how often the sweep runs.
  @ttl_ms :timer.minutes(30)
  @sweep_ms :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Acquire a block lock. Idempotent for the same holder."
  @spec acquire(term(), term(), holder()) :: :ok | {:error, {:locked, holder()}}
  def acquire(document_key, block_id, holder),
    do: GenServer.call(__MODULE__, {:acquire, {document_key, block_id}, holder})

  @doc "Release a block lock (only the holder may release)."
  @spec release(term(), term(), holder()) :: :ok
  def release(document_key, block_id, holder),
    do: GenServer.call(__MODULE__, {:release, {document_key, block_id}, holder})

  @doc "Who holds a block lock, if anyone."
  @spec holder(term(), term()) :: {:ok, holder()} | :free
  def holder(document_key, block_id),
    do: GenServer.call(__MODULE__, {:holder, {document_key, block_id}})

  @impl true
  def init(_state) do
    schedule_sweep()
    # state: %{key => %{holder: term, pid: pid, ref: reference, at: monotonic_ms}}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:acquire, key, holder}, {pid, _tag}, state) do
    case Map.get(state, key) do
      nil ->
        {:reply, :ok, put_lock(state, key, holder, pid)}

      %{holder: ^holder} = entry ->
        # Same holder re-acquiring: refresh the TTL and re-point the monitor if
        # the call now comes from a different process.
        {:reply, :ok, Map.put(state, key, refresh(entry, pid))}

      %{holder: other} ->
        {:reply, {:error, {:locked, other}}, state}
    end
  end

  def handle_call({:release, key, holder}, _from, state) do
    case Map.get(state, key) do
      %{holder: ^holder, ref: ref} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, Map.delete(state, key)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:holder, key}, _from, state) do
    case Map.get(state, key) do
      %{holder: holder} -> {:reply, {:ok, holder}, state}
      nil -> {:reply, :free, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop_by_ref(state, ref)}
  end

  def handle_info(:sweep, state) do
    schedule_sweep()
    {:noreply, sweep(state)}
  end

  defp put_lock(state, key, holder, pid) do
    ref = Process.monitor(pid)
    Map.put(state, key, %{holder: holder, pid: pid, ref: ref, at: now()})
  end

  defp refresh(%{pid: old_pid, ref: old_ref} = entry, pid) do
    ref =
      if pid == old_pid do
        old_ref
      else
        Process.demonitor(old_ref, [:flush])
        Process.monitor(pid)
      end

    %{entry | pid: pid, ref: ref, at: now()}
  end

  defp drop_by_ref(state, ref) do
    state
    |> Enum.reject(fn {_key, %{ref: r}} -> r == ref end)
    |> Map.new()
  end

  defp sweep(state) do
    cutoff = now() - @ttl_ms

    {expired, kept} =
      Enum.split_with(state, fn {_key, %{at: at}} -> at < cutoff end)

    Enum.each(expired, fn {_key, %{ref: ref}} -> Process.demonitor(ref, [:flush]) end)
    Map.new(kept)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp now, do: System.monotonic_time(:millisecond)
end
