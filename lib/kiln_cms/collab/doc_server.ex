defmodule KilnCMS.Collab.Crdt.DocServer do
  @moduledoc """
  The authoritative Yjs document for one collaborative editing session
  (`KilnCMS.Collab.Crdt`). Holds a `Yex.Doc`, applies binary updates from clients
  (CRDT merge — order-independent, conflict-free), and serves the full state
  to each joiner so late arrivals converge immediately.

  Attached clients (channel processes) are monitored; when the last one
  leaves, the server lingers for an idle grace period — an editor refresh
  reattaches to the same live doc — then stops. The doc is **not persisted**
  (prototype scope): content durability remains the editor's HTML-mirror
  autosave.
  """
  use GenServer, restart: :transient

  # How long an abandoned doc lingers before shutdown (covers reloads).
  @idle_shutdown :timer.minutes(10)

  def start_link(doc_key) do
    GenServer.start_link(__MODULE__, doc_key, name: via(doc_key))
  end

  defp via(doc_key), do: {:via, Registry, {KilnCMS.Collab.Crdt.Registry, doc_key}}

  @doc """
  Attach the calling process (a channel) as a client. Returns
  `{full_state_update, client_count}` — the count includes the caller, so `1`
  means "you're first" (the client uses that to decide whether to seed the
  doc from the stored HTML).
  """
  @spec attach(pid()) :: {binary(), pos_integer()}
  def attach(server), do: GenServer.call(server, :attach)

  @doc "Apply one binary Yjs update from a client."
  @spec apply_update(pid(), binary()) :: :ok | {:error, term()}
  def apply_update(server, update) when is_binary(update),
    do: GenServer.call(server, {:apply_update, update})

  @doc "The whole doc encoded as a single Yjs update."
  @spec state_update(pid()) :: binary()
  def state_update(server), do: GenServer.call(server, :state_update)

  @impl true
  def init(_doc_key) do
    {:ok, %{doc: Yex.Doc.new(), clients: MapSet.new()}, @idle_shutdown}
  end

  @impl true
  def handle_call(:attach, {pid, _tag}, state) do
    Process.monitor(pid)
    clients = MapSet.put(state.clients, pid)
    {:ok, full} = Yex.encode_state_as_update(state.doc)
    {:reply, {full, MapSet.size(clients)}, %{state | clients: clients}, @idle_shutdown}
  end

  def handle_call({:apply_update, update}, _from, state) do
    case Yex.apply_update(state.doc, update) do
      :ok -> {:reply, :ok, state, @idle_shutdown}
      {:error, reason} -> {:reply, {:error, reason}, state, @idle_shutdown}
    end
  end

  def handle_call(:state_update, _from, state) do
    {:ok, full} = Yex.encode_state_as_update(state.doc)
    {:reply, full, state, @idle_shutdown}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | clients: MapSet.delete(state.clients, pid)}, @idle_shutdown}
  end

  # Fires only after @idle_shutdown with no messages at all; stop when nobody
  # is attached (a lone idle client's heartbeats don't reach us, but its
  # channel process is alive — so presence, not traffic, is the signal).
  def handle_info(:timeout, %{clients: clients} = state) do
    if MapSet.size(clients) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, @idle_shutdown}
    end
  end
end
