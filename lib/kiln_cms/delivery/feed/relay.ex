defmodule KilnCMS.Delivery.Feed.Relay do
  @moduledoc """
  Takes the change feed's local fan-out off the publisher (#2083).

  `Phoenix.PubSub.broadcast/3` delivers to every subscriber on the calling
  node before it returns, so a publish whose site had 10,000 feed subscribers
  paid for 10,000 sends inside the editor's request. `dispatch/4` splits the
  broadcast in two:

    * **remote nodes**, from the caller as before: one
      `Phoenix.PubSub.direct_broadcast/4` per node in `Node.list/0`, each a
      single send whose fan-out runs in that node's PubSub server. The PG2
      adapter picks its shard by the sender's pid, so the event leaves through
      the same shard as the caller's earlier `KilnCMS.Cache.ClusterBust`
      broadcast and a remote node still sees the bust before the event.
    * **this node**, handed to a relay: one cast, after which the relay runs
      `Phoenix.PubSub.local_broadcast/3`. The publisher's cost no longer
      grows with the number of subscribers.

  Relays run under a `PartitionSupervisor` (`KilnCMS.Delivery.Feed.Relays` in
  `KilnCMS.Application`, one partition per scheduler) keyed by org id, so one
  site's events always pass through the same relay, in the order they reach
  it. Sites are spread over the partitions by hash, so a burst on one site
  queues only behind (and ahead of) the sites that share its partition.

  When no relay can be found (the supervisor is not running, or the
  partition's child is restarting), the local half is broadcast inline as
  before.
  """
  use GenServer

  require Logger

  @pubsub KilnCMS.PubSub
  @relays KilnCMS.Delivery.Feed.Relays

  @doc "The `PartitionSupervisor` the application starts the relays under."
  def supervisor, do: @relays

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Broadcast `message` on `topic` to every node: remote nodes from the caller,
  this node through `org_id`'s relay under `relays` (inline when there is
  none). Returns `:ok`; a relay's own failure is logged there, not raised here.
  """
  @spec dispatch(atom(), String.t(), String.t(), term()) :: :ok
  def dispatch(relays \\ @relays, org_id, topic, message) do
    for node <- Node.list() do
      Phoenix.PubSub.direct_broadcast(node, @pubsub, topic, message)
    end

    case whereis(relays, org_id) do
      nil -> Phoenix.PubSub.local_broadcast(@pubsub, topic, message)
      pid -> GenServer.cast(pid, {:broadcast, topic, message})
    end

    :ok
  end

  @doc """
  Wait until `org_id`'s relay under `relays` has broadcast every event it
  received before this call. `:ok` at once when there is no relay.
  """
  @spec sync(atom(), String.t()) :: :ok
  def sync(relays \\ @relays, org_id) do
    case whereis(relays, org_id) do
      nil -> :ok
      pid -> GenServer.call(pid, :sync)
    end
  end

  @doc "The pid of `org_id`'s relay under `relays`, or `nil` when it is not running."
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(relays \\ @relays, org_id) do
    # A missing PartitionSupervisor *exits* (`:noproc`), and a cast to a `:via`
    # name that does not resolve is silently dropped: resolve the pid first so
    # both fall back to the inline broadcast.
    case GenServer.whereis({:via, PartitionSupervisor, {relays, org_id}}) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _not_running -> nil
    end
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_cast({:broadcast, topic, message}, state) do
    Phoenix.PubSub.local_broadcast(@pubsub, topic, message)
    {:noreply, state}
  rescue
    # One malformed event must not crash-loop the relay every other event of
    # its partition passes through.
    error ->
      Logger.error(
        "Feed relay could not broadcast on #{inspect(topic)}: " <> Exception.message(error)
      )

      {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
end
