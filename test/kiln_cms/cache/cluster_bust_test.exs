defmodule KilnCMS.Cache.ClusterBustTest do
  @moduledoc """
  Cache invalidations that reach every node (#739).

  `KilnCMS.Cache` is in-process by design, so `Cachex.del/2` only ever emptied
  the node that served the write. For the code-injection key that was a real
  exposure: the documented incident response for a bad snippet is "delete the
  row", and every *other* node went on serving that script — under the widened
  CSP the same cached struct carries — for up to the five-minute TTL.

  There is no second BEAM node here, and spinning one up would be testing
  `Phoenix.PubSub` rather than this module. What is tested instead is the two
  halves that make a second node work, separately: the writer **broadcasts**,
  and the subscriber **deletes on receipt**. A node that does both does the
  right thing when it is the one that did not serve the write.
  """
  # async: false — the shared, app-wide content cache and a named GenServer.
  use ExUnit.Case, async: false

  alias KilnCMS.Cache
  alias KilnCMS.Cache.ClusterBust

  setup do
    Cache.bust_published()
    %{org: Ash.UUID.generate()}
  end

  defp cached?(key) do
    case Cachex.get(Cache.cache_name(), key) do
      {:ok, nil} -> false
      {:ok, _value} -> true
      _error -> false
    end
  end

  defp seed(key), do: Cachex.put(Cache.cache_name(), key, :stale)

  defp bump_both(org) do
    Cache.bump_head_generation(org)
    Cache.bump_menus_generation(org)
    {Cache.head_generation(org), Cache.menus_generation(org)}
  end

  defp tokens(org), do: {Cache.head_generation(org), Cache.menus_generation(org)}

  defp await_queued(pid, count, tries \\ 200) do
    {:message_queue_len, len} = Process.info(pid, :message_queue_len)

    cond do
      len >= count ->
        :ok

      tries == 0 ->
        flunk("nothing reached #{inspect(pid)}'s mailbox")

      true ->
        Process.sleep(5)
        await_queued(pid, count, tries - 1)
    end
  end

  describe "the writing node" do
    # Read-your-writes: a broadcast is asynchronous even to this node's own
    # subscriber, so a request that saves settings and immediately re-reads them
    # would still see the old value if the local delete were left to PubSub.
    test "deletes locally before it broadcasts, synchronously", %{org: org} do
      seed(Cache.code_injection_key(org))

      Cache.bust_code_injection(org)

      refute cached?(Cache.code_injection_key(org))
    end

    test "tells the other nodes which keys to forget", %{org: org} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      Cache.bust_code_injection(org)
      assert_receive {:bust_keys, [key]}, 2_000
      assert key == Cache.code_injection_key(org)

      # Branding travels the same way, deliberately: the two keys hold the same
      # shape of thing and there is no reason for one to reach every node and
      # the other not to.
      Cache.bust_branding(org)
      assert_receive {:bust_keys, [branding]}, 2_000
      assert branding == Cache.branding_key(org)
    end

    test "puts a new head-generation token locally and broadcasts it (#1079)", %{org: org} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      before = Cache.head_generation(org)

      Cache.bump_head_generation(org)
      token = Cache.head_generation(org)
      refute token == before

      assert_receive {:put_keys, [{key, ^token}]}, 2_000
      assert key == Cache.head_generation_key(org)
      assert {:ok, ^token} = Cachex.get(Cache.generation_cache_name(), key)
      assert {:ok, nil} = Cachex.get(Cache.cache_name(), key)
    end

    test "puts a new menus-generation token the same way (#1318)", %{org: org} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      Cache.bump_menus_generation(org)
      token = Cache.menus_generation(org)

      assert_receive {:put_keys, [{key, ^token}]}, 2_000
      assert key == Cache.menus_generation_key(org)
      assert {:ok, ^token} = Cachex.get(Cache.generation_cache_name(), key)
      assert {:ok, nil} = Cachex.get(Cache.cache_name(), key)
    end

    # Keys, not a name for the thing being invalidated. A node running older
    # code cannot misinterpret a key it does not recognise — it deletes nothing.
    test "the payload is the keys themselves", %{org: org} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      Cache.bust_branding(org)

      assert_receive {:bust_keys, keys}, 2_000
      assert Enum.all?(keys, &is_binary/1)
    end
  end

  # The JOINT, which the two halves below do not cover between them: nothing
  # else asserts that the subscriber is actually ON the topic. Deleting the
  # `Phoenix.PubSub.subscribe/2` call from `init/1` left every other test in this
  # file green while making the whole feature inert — every node deaf, every bust
  # landing nowhere.
  #
  # Broadcast directly rather than through `Cache.bust_*`: that function's own
  # synchronous local delete would empty the key regardless, and mask exactly the
  # failure this is for.
  test "the subscriber is on the topic, so a broadcast alone empties the key", %{org: org} do
    key = Cache.code_injection_key(org)
    seed(key)

    Phoenix.PubSub.broadcast(KilnCMS.PubSub, ClusterBust.topic(), {:bust_keys, [key]})
    _ = :sys.get_state(ClusterBust)

    refute cached?(key)
  end

  # A feed bust names no keys: which ones exist differs per node, and the writer
  # cannot enumerate what it never served. So it travels as a rule instead
  # (#1078) — and until it did, turning full content off dropped the syndication
  # policy everywhere and the cached feed BODIES only on the writing node.
  describe "a prefix bust" do
    test "empties the writing node's matching keys and no others", %{org: org} do
      mine = Cache.feed_key(org, "post", :atom)
      site_wide = Cache.feed_key(org, nil, :json)
      another_org = Cache.feed_key(Ash.UUID.generate(), "post", :atom)
      unrelated = Cache.branding_key(org)

      Enum.each([mine, site_wide, another_org, unrelated], &seed/1)

      Cache.bust_all_feeds(org)

      refute cached?(mine)
      refute cached?(site_wide)
      assert cached?(another_org)
      assert cached?(unrelated)
    end

    test "tells the other nodes the rule, not a key list", %{org: org} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      Cache.bust_all_feeds(org)

      assert_receive {:bust_prefix, prefix}, 2_000
      assert String.starts_with?(Cache.feed_key(org, "post", :atom), prefix)
      refute String.starts_with?(Cache.feed_key(Ash.UUID.generate(), "post", :atom), prefix)
    end

    # The half that matters on the node that did not serve the write: it holds
    # feed keys the writer has never heard of, and runs the scan itself.
    test "is applied by a receiving node against its own keyspace", %{org: org} do
      # A scoped feed only this "node" ever built.
      scoped = Cache.feed_key(org, "post", :atom) <> ":category/news"
      seed(scoped)
      assert cached?(scoped)

      send(ClusterBust, {:bust_prefix, "feed:#{org}:"})
      _ = :sys.get_state(ClusterBust)

      refute cached?(scoped)
    end

    test "leaves another org's feeds alone on a receiving node", %{org: org} do
      other_org = Ash.UUID.generate()
      theirs = Cache.feed_key(other_org, "post", :atom)
      seed(theirs)

      send(ClusterBust, {:bust_prefix, "feed:#{org}:"})
      _ = :sys.get_state(ClusterBust)

      assert cached?(theirs)
    end
  end

  describe "a receiving node" do
    # The half that matters on the node that did NOT serve the write: the same
    # message the broadcast above carries, delivered to the real subscriber.
    test "deletes the keys it is told about", %{org: org} do
      key = Cache.code_injection_key(org)
      seed(key)
      assert cached?(key)

      send(ClusterBust, {:bust_keys, [key]})
      # The subscriber is a GenServer; a call flushes the mailbox ahead of it.
      _ = :sys.get_state(ClusterBust)

      refute cached?(key)
    end

    test "puts the values it is told about (#1079)", %{org: org} do
      key = Cache.head_generation_key(org)
      Cachex.del(Cache.generation_cache_name(), key)

      send(ClusterBust, {:put_keys, [{key, "gen-from-peer"}]})

      _ = :sys.get_state(ClusterBust)

      assert Cache.head_generation(org) == "gen-from-peer"
    end

    # #2502: bumps and allowlist saves travel as `{:put_keys, …}` from every
    # node, including one still on the release before the generation store
    # during a rolling deploy. The receiver must route them to where it reads
    # them, not into the delivery cache.
    test "routes a peer's {:put_keys, ...} for a generation key to the generation store",
         %{org: org} do
      head = Cache.head_generation_key(org)
      menus = Cache.menus_generation_key(org)
      last_known = Cache.admin_allowlist_last_known_key(org)
      Enum.each([head, menus, last_known], &Cachex.del(Cache.generation_cache_name(), &1))

      send(
        ClusterBust,
        {:put_keys,
         [{head, "head-from-old-peer"}, {menus, "menus-from-old-peer"}, {last_known, {nil, :off}}]}
      )

      _ = :sys.get_state(ClusterBust)

      assert Cache.head_generation(org) == "head-from-old-peer"
      assert Cache.menus_generation(org) == "menus-from-old-peer"
      assert Cache.peek(last_known) == {nil, :off}

      for key <- [head, menus, last_known] do
        assert {:ok, nil} = Cachex.get(Cache.cache_name(), key)
      end
    end

    test "still puts any other key from {:put_keys, ...} into the delivery cache", %{org: org} do
      key = Cache.branding_key(org)
      send(ClusterBust, {:put_keys, [{key, :from_peer}]})
      _ = :sys.get_state(ClusterBust)

      assert {:ok, :from_peer} = Cachex.get(Cache.cache_name(), key)
    end

    test "leaves keys it was not told about alone", %{org: org} do
      other = Cache.branding_key(org)
      seed(other)

      send(ClusterBust, {:bust_keys, [Cache.code_injection_key(org)]})
      _ = :sys.get_state(ClusterBust)

      assert cached?(other)
    end

    # During a rolling deploy the cluster runs two versions. A subscriber that
    # died on an unfamiliar payload would stop honouring the busts it *does*
    # understand until it restarted — which is the failure this whole module
    # exists to prevent, arrived at from the other side.
    test "survives a message it does not understand", %{org: org} do
      pid = Process.whereis(ClusterBust)

      send(ClusterBust, {:bust_something_from_the_future, %{org: org}})
      send(ClusterBust, :not_even_a_tuple)
      _ = :sys.get_state(ClusterBust)

      assert Process.whereis(ClusterBust) == pid

      # Still working.
      key = Cache.branding_key(org)
      seed(key)
      send(ClusterBust, {:bust_keys, [key]})
      _ = :sys.get_state(ClusterBust)
      refute cached?(key)
    end
  end

  # Full clear for the operator purge (#1138). A key list cannot express
  # "everything", and `bust_published/0` stays node-local on purpose.
  describe "a full clear" do
    test "empties both delivery caches on the writing node and tells the others", %{org: org} do
      key = Cache.branding_key(org)
      seed(key)
      doc_id = Ash.UUID.generate()
      :ok = KilnCMS.Firing.Cache.put(org, :post, doc_id, :html, %{body: "stale"})

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      assert :ok = ClusterBust.broadcast_clear()

      assert_receive {:bust_all, origin}, 2_000
      assert origin == Node.self()
      refute cached?(key)
      assert KilnCMS.Firing.Cache.get(org, :post, doc_id, :html) == :miss
    end

    test "is applied by a receiving node against both caches", %{org: org} do
      key = Cache.branding_key(org)
      seed(key)
      doc_id = Ash.UUID.generate()
      :ok = KilnCMS.Firing.Cache.put(org, :post, doc_id, :html, %{body: "stale"})

      # Another node's name — this node must clear, not skip.
      send(ClusterBust, {:bust_all, :other@host})
      _ = :sys.get_state(ClusterBust)

      refute cached?(key)
      assert KilnCMS.Firing.Cache.get(org, :post, doc_id, :html) == :miss
    end

    test "the origin skips a redundant walk after it already cleared" do
      key = Cache.branding_key(Ash.UUID.generate())
      seed(key)

      # Origin is self: the handler must not clear. A buggy double-walk would
      # empty a key seeded only for this assertion.
      send(ClusterBust, {:bust_all, Node.self()})
      _ = :sys.get_state(ClusterBust)

      assert cached?(key)
    end

    test "flush_delivery/0 clears this node and broadcasts for the rest", %{org: org} do
      key = Cache.branding_key(org)
      seed(key)
      doc_id = Ash.UUID.generate()
      :ok = KilnCMS.Firing.Cache.put(org, :post, doc_id, :html, %{})

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      assert %{published: published, artifacts: artifacts} = Cache.flush_delivery()
      assert published >= 1
      assert artifacts >= 1

      assert_receive {:bust_all, origin}, 2_000
      assert origin == Node.self()
      refute cached?(key)
      assert KilnCMS.Firing.Cache.get(org, :post, doc_id, :html) == :miss
    end
  end

  # #2502: the tokens a delivery ETag and the menu keys fold in live apart
  # from the delivery cache, so nothing that empties that cache moves them.
  # Before, every clear (and the size cap's eviction) sent a site back to
  # `"0"`, and a browser holding an ETag from before its last settings bump
  # got a 304 for the old `<head>`.
  describe "the generation store" do
    test "an unbumped site reads a token of its own, the same on every read", %{org: org} do
      first = Cache.head_generation(org)

      refute first == "0"
      assert Cache.head_generation(org) == first
      refute Cache.head_generation(Ash.UUID.generate()) == first
    end

    test "concurrent first reads on a node agree on one token" do
      org = Ash.UUID.generate()

      tokens =
        1..50
        |> Enum.map(fn _ -> Task.async(fn -> Cache.menus_generation(org) end) end)
        |> Task.await_many()

      assert [_one] = Enum.uniq(tokens)
    end

    # A bump's put and a first read's mint on one key must serialize. A plain
    # `Cachex.put/3` checks for a lock and then writes from its own process, so
    # it could land between the mint's read and its commit and be overwritten,
    # leaving this node off the cluster's token until the next bump. That gap
    # is too narrow to hit on purpose, so this pins what closes it: the put
    # goes through the cache's lock queue, the process the mint runs in.
    # Suspending that process (a Cachex internal, named `<cache>_locksmith`)
    # holds both in order: the mint first, the put behind it.
    test "a put queues behind a first read's mint, and its value is the one kept", %{org: org} do
      key = Cache.head_generation_key(org)
      queue = Process.whereis(:"#{Cache.generation_cache_name()}_locksmith")
      assert is_pid(queue)

      :sys.suspend(queue)
      on_exit(fn -> if Process.alive?(queue), do: :sys.resume(queue) end)

      minting = Task.async(fn -> Cache.head_generation(org) end)
      await_queued(queue, 1)

      putting = Task.async(fn -> ClusterBust.broadcast_put([{key, "bumped"}]) end)

      # Waiting in the queue, not written straight into the store.
      assert Task.yield(putting, 100) == nil
      assert {:ok, nil} = Cachex.get(Cache.generation_cache_name(), key)

      :sys.resume(queue)

      minted = Task.await(minting)
      assert Task.await(putting) == :ok
      refute minted == "bumped"

      _ = :sys.get_state(ClusterBust)
      assert Cache.head_generation(org) == "bumped"
    end

    test "survives bust_published/0", %{org: org} do
      bumped = bump_both(org)
      Cache.bust_published()
      assert tokens(org) == bumped
    end

    test "survives a full clear on the writing node", %{org: org} do
      bumped = bump_both(org)
      ClusterBust.broadcast_clear()
      assert tokens(org) == bumped
    end

    test "survives a full clear on a receiving node", %{org: org} do
      bumped = bump_both(org)
      send(ClusterBust, {:bust_all, :other@host})
      _ = :sys.get_state(ClusterBust)
      assert tokens(org) == bumped
    end

    test "survives flush_delivery/0, which still clears and broadcasts", %{org: org} do
      bumped = bump_both(org)
      key = Cache.branding_key(org)
      seed(key)
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      assert %{published: published} = Cache.flush_delivery()
      assert published >= 1
      assert_receive {:bust_all, _origin}, 2_000
      refute cached?(key)

      assert tokens(org) == bumped
    end

    # The size cap's eviction drops least-recently-written entries, and a token
    # written once at a settings save is exactly that. What eviction removes
    # from the delivery cache is stood in for by emptying it outright.
    test "survives eviction from the delivery cache", %{org: org} do
      bumped = bump_both(org)

      Cachex.del(Cache.cache_name(), Cache.head_generation_key(org))
      Cachex.del(Cache.cache_name(), Cache.menus_generation_key(org))
      Cachex.clear(Cache.cache_name())

      assert tokens(org) == bumped
    end
  end
end
