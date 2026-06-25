defmodule KilnCMS.Collab.Locks do
  @moduledoc """
  Soft, in-memory block locks for collaborative editing (Kiln v2 — decision D5/F).

  A block can be held by at most one editor at a time; conflicting writes are
  rejected with a friendly error rather than clobbering. This is the
  server-authoritative coarse-grained collaboration the v1 scope calls for (the
  `docs/collaborative-editing-spike.md` single-editor + Presence model); CRDT/OT
  remains post-v1. Keyed by `{document_key, block_id}`.
  """
  use GenServer

  @type holder :: term()

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
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:acquire, key, holder}, _from, state) do
    case Map.get(state, key) do
      nil -> {:reply, :ok, Map.put(state, key, holder)}
      ^holder -> {:reply, :ok, state}
      other -> {:reply, {:error, {:locked, other}}, state}
    end
  end

  def handle_call({:release, key, holder}, _from, state) do
    case Map.get(state, key) do
      ^holder -> {:reply, :ok, Map.delete(state, key)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:holder, key}, _from, state) do
    case Map.get(state, key) do
      nil -> {:reply, :free, state}
      holder -> {:reply, {:ok, holder}, state}
    end
  end
end
