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
      assert_receive {:bust_keys, [key]}
      assert key == Cache.code_injection_key(org)

      # Branding travels the same way, deliberately: the two keys hold the same
      # shape of thing and there is no reason for one to reach every node and
      # the other not to.
      Cache.bust_branding(org)
      assert_receive {:bust_keys, [branding]}
      assert branding == Cache.branding_key(org)
    end

    test "puts a new head-generation token locally and broadcasts it (#1079)", %{org: org} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      assert Cache.head_generation(org) == "0"

      Cache.bump_head_generation(org)
      token = Cache.head_generation(org)
      refute token == "0"

      assert_receive {:put_keys, [{key, ^token}]}
      assert key == Cache.head_generation_key(org)
    end

    # Keys, not a name for the thing being invalidated. A node running older
    # code cannot misinterpret a key it does not recognise — it deletes nothing.
    test "the payload is the keys themselves", %{org: org} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())

      Cache.bust_branding(org)

      assert_receive {:bust_keys, keys}
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

      assert_receive {:bust_prefix, prefix}
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
      Cachex.del(Cache.cache_name(), key)

      send(ClusterBust, {:put_keys, [{key, "gen-from-peer"}]})
      _ = :sys.get_state(ClusterBust)

      assert Cache.head_generation(org) == "gen-from-peer"
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
end
