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
  subscriber on every node that deletes (or puts) the named keys locally. The
  writing node *also* applies the change synchronously before broadcasting —
  see below.

  Three shapes: `broadcast/1` names keys to delete, `broadcast_put/1` names
  key/value pairs to write (#1079), and `broadcast_prefix/1` names a rule for
  finding keys to delete. The prefix shape exists because a prefix scan's
  matching keys differ per node, so there is nothing for the writer to
  enumerate (#1078).

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

  @doc """
  Write `entries` on this node now, and ask every other node to do the same.

  The sibling of `broadcast/1` for a value that must *move*, not merely vanish
  (#1079). Delivery ETags fold a per-org head-generation token; a delete-only
  bust would leave every node on the default `"0"` after a miss, which is the
  same ETag the page carried *before* the settings write. Putting the new token
  cluster-wide is what makes a conditional GET stop returning 304.

  Same guarantees as `broadcast/1`: best effort, at-most-once, TTL is the
  backstop. Receivers stay dumb — they put whatever pairs arrive.
  """
  @spec broadcast_put([{String.t(), term()}]) :: :ok
  def broadcast_put(entries) when is_list(entries) do
    Enum.each(entries, fn {key, value} ->
      Cachex.put(KilnCMS.Cache.cache_name(), key, value)
    end)

    Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, {:put_keys, entries})

    :ok
  end

  @doc """
  Drop every key starting with `prefix` on this node, and ask every other node
  to do the same (#1078).

  The sibling of `broadcast/1` for a bust whose *keys* the sender cannot name.
  `KilnCMS.Cache.bust_all_feeds/1` drops one org's cached feed documents by
  prefix, and which keys match differs per node — a node that never served
  `/blog/category/news/feed.xml` has no key for it — so a key list broadcast
  from the writer would leave every other node's feeds untouched. That was the
  gap: turning full content off dropped the syndication *policy* on every node
  (`bust_feed_policy/1`, above) while the cached bodies rendered under the old
  policy survived everywhere but the writer.

  Receivers stay as dumb as they are for `broadcast/1`. This carries a string
  and a rule — "forget what starts with this" — not a name for the thing being
  invalidated, so a node running older code drops a message it does not
  recognise rather than guessing at one.

  Same guarantees as `broadcast/1`: best effort, at-most-once, TTL is the
  backstop.
  """
  @spec broadcast_prefix(String.t()) :: :ok
  def broadcast_prefix(prefix) when is_binary(prefix) do
    KilnCMS.Cache.drop_prefix(prefix)

    Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, {:bust_prefix, prefix})

    :ok
  end

  @doc """
  Drop every key in `KilnCMS.Cache` on this node, and ask every other node to
  do the same (#1138).

  The sibling of `broadcast/1` for a full clear: a key list cannot express
  "everything", and `bust_published/0` stays node-local on purpose — its
  callers include a path that fires on every media download (#1137). The
  operator-facing purge (`flush_delivery/0`) is the one that must reach the
  whole cluster after a template deploy.

  Also clears `KilnCMS.Firing.Cache` on every node: both instances feed
  delivery, so emptying one and not the other leaves the site half-stale.

  The sender clears synchronously first (read-your-writes), then broadcasts
  with its node name so the local subscriber skips a redundant walk. Same
  best-effort / at-most-once / TTL-as-backstop posture as `broadcast/1`.
  """
  @spec broadcast_clear() :: :ok
  def broadcast_clear do
    clear_delivery_caches()
    notify_clear()
  end

  @doc false
  def notify_clear do
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, {:bust_all, Node.self()})
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

  def handle_info({:put_keys, entries}, state) when is_list(entries) do
    Enum.each(entries, fn {key, value} ->
      Cachex.put(KilnCMS.Cache.cache_name(), key, value)
    end)

    {:noreply, state}
  end

  # Synchronous, and worth one line about why: this walks the keyspace, which is
  # more work than the key-list clause above and blocks the next bust behind it
  # — including a code-injection one, which is the one that matters most. It is
  # the same walk the writing node already does inline, and its callers are
  # settings and content-type writes, so the pile-up needs an operator saving in
  # a loop. A `Task` here would trade that for an unsupervised process in the
  # module whose whole job is being dependable.
  def handle_info({:bust_prefix, prefix}, state) when is_binary(prefix) do
    KilnCMS.Cache.drop_prefix(prefix)
    {:noreply, state}
  end

  # Sender already cleared synchronously in `broadcast_clear/0`. Skipping the
  # origin keeps a full-cache walk off the critical path twice on one node.
  def handle_info({:bust_all, origin}, state) do
    if origin != Node.self(), do: clear_delivery_caches()
    {:noreply, state}
  end

  # A message this node's code does not understand is dropped, not crashed on:
  # during a rolling deploy the cluster runs two versions, and a subscriber that
  # dies on an unfamiliar payload would stop honouring the busts it *does*
  # understand for as long as it takes to restart.
  def handle_info(_other, state), do: {:noreply, state}

  defp clear_delivery_caches do
    Cachex.clear(KilnCMS.Cache.cache_name())
    KilnCMS.Firing.Cache.clear()
    :ok
  end
end
