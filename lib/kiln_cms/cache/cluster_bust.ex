defmodule KilnCMS.Cache.ClusterBust do
  @moduledoc """
  Makes a cache invalidation reach every node, not just the one that served the
  write (#739).

  `KilnCMS.Cache` is deliberately in-process (D2, `docs/resilient-delivery.md`):
  no Redis, no shared store. That is the right trade for content, where a stale
  entry is an out-of-date page and the safety-net TTL is the backstop. It is the
  wrong trade for two keys:

    * **code injection** (#490) — the cached struct carries the operator's
      `head_html` *and* the CSP sources that let it execute. The documented
      incident response for a bad snippet is "delete the row", and on a
      multi-node deployment every other node went on serving the script, under
      its widened policy, for up to five minutes.
    * **branding** — the cited precedent for that design, and the reason this
      covers both rather than diverging one key from the other. A stale logo is
      not an executing third-party script, but there is no reason for the two to
      behave differently and a good reason for a future per-org resolved-struct
      cache to inherit one mechanism.

  ## How

  A `Phoenix.PubSub` broadcast on `#{inspect(__MODULE__)}`'s topic, and a
  subscriber on every node that deletes the named keys locally. The writing node
  *also* deletes synchronously before broadcasting — see below.

  This is not a distributed cache and does not pretend to be. It is a best-effort
  "forget this key" signal: PubSub delivery is at-most-once, a node that is
  partitioned or booting misses it, and the TTL remains the guarantee. What it
  buys is that the *normal* case — an operator deleting a bad snippet on a
  healthy cluster — takes effect in milliseconds instead of minutes.

  ## Why the caller deletes locally too

  A broadcast is asynchronous even to the sending node's own subscriber, so a
  request that saves settings and immediately re-reads them could still see the
  old value. Deleting locally first makes the write's own node
  read-your-writes consistent, and the redundant delete the broadcast then
  triggers there is idempotent.

  ## Single-node deployments

  Cost nothing. `Phoenix.PubSub`'s default adapter broadcasts to local
  subscribers directly; with no other nodes connected there is no network
  traffic, and the one extra `Cachex.del` of an already-deleted key is a no-op.
  """
  use GenServer

  @topic "kiln:cache_bust"

  @doc false
  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Delete `keys` on this node now, and ask every other node to do the same.

  Takes the keys rather than a name for the thing being invalidated, so the
  sender decides what a bust means and receivers stay dumb — a node running
  older code cannot misinterpret a key it does not recognise, it just deletes
  nothing.
  """
  @spec broadcast([String.t()]) :: :ok
  def broadcast(keys) when is_list(keys) do
    Enum.each(keys, &Cachex.del(KilnCMS.Cache.cache_name(), &1))

    Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, {:bust_keys, keys})

    :ok
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:bust_keys, keys}, state) when is_list(keys) do
    Enum.each(keys, &Cachex.del(KilnCMS.Cache.cache_name(), &1))
    {:noreply, state}
  end

  # A message this node's code does not understand is dropped, not crashed on:
  # during a rolling deploy the cluster runs two versions, and a subscriber that
  # dies on an unfamiliar payload would stop honouring the busts it *does*
  # understand for as long as it takes to restart.
  def handle_info(_other, state), do: {:noreply, state}
end
