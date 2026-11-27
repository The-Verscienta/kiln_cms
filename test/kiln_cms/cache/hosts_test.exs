defmodule KilnCMS.Cache.HostsTest do
  @moduledoc """
  A host lookup that ran before an organization's slug or `custom_domain`
  change committed must not store its answer after that change's bust (#2972).

  The lookup is held by a `KilnCMS.Test.Latch` inside the resolver the test
  passes to `KilnCMS.Cache.Hosts.fetch/2`, the bust is sent while it is held,
  and the lookup is released after the bust has run on both ends (the local
  delete and this node's own `KilnCMS.Cache.ClusterBust` subscriber).

  `async: false`: the host cache is one named Cachex instance per node.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Cache.ClusterBust
  alias KilnCMS.Cache.Hosts
  alias KilnCMS.Test.Latch

  @latch __MODULE__.Lookup

  setup do
    Hosts.clear()
    on_exit(&Hosts.clear/0)
    start_supervised!({Latch, name: @latch, listener: self()})
    %{host: "hosts-test-#{System.unique_integer([:positive])}.example.com"}
  end

  defp held_lookup(answer) do
    fn ->
      Latch.enter(@latch)
      answer
    end
  end

  # Start a lookup of `host` that reads `answer` and is held before it stores.
  defp start_held_fetch(host, answer) do
    task = Task.async(fn -> Hosts.fetch(host, held_lookup(answer)) end)
    assert_receive {:latch_started, @latch, 1}, 2_000
    task
  end

  # The write's bust, the way `BustSiteUrls` sends it, run to completion on
  # this node's subscriber too before the held lookup goes on.
  defp bust!(host) do
    :ok = ClusterBust.broadcast_in(Hosts.cache_name(), [host])
    _ = :sys.get_state(ClusterBust)
  end

  defp release_and_await(task) do
    assert [_lookup] = Latch.release_all(@latch)
    result = Task.await(task, 5_000)
    refute_received {:latch_timeout, _, _}
    result
  end

  test "a resolution read before a bust is served, and not stored", %{host: host} do
    org = %{id: Ash.UUID.generate(), slug: "before"}
    task = start_held_fetch(host, org)

    bust!(host)

    assert release_and_await(task) == org
    assert {:ok, nil} = Cachex.get(Hosts.cache_name(), host)

    # The next request looks the host up again, and that answer is kept.
    fresh = %{id: org.id, slug: "after"}
    assert Hosts.fetch(host, fn -> fresh end) == fresh
    assert {:ok, ^fresh} = Cachex.get(Hosts.cache_name(), host)
  end

  test "a miss read before a bust is not cached as unresolved", %{host: host} do
    task = start_held_fetch(host, nil)

    bust!(host)

    assert release_and_await(task) == nil
    assert {:ok, nil} = Cachex.get(Hosts.cache_name(), host)

    org = %{id: Ash.UUID.generate()}
    assert Hosts.fetch(host, fn -> org end) == org
  end

  test "a lookup no bust touched is stored, a miss as unresolved", %{host: host} do
    org = %{id: Ash.UUID.generate()}
    assert Hosts.fetch(host, fn -> org end) == org
    assert {:ok, ^org} = Cachex.get(Hosts.cache_name(), host)

    missing = "missing-" <> host
    assert Hosts.fetch(missing, fn -> nil end) == nil
    assert {:ok, :unresolved} = Cachex.get(Hosts.cache_name(), missing)
  end

  test "a bust of another host leaves the lookup's answer stored", %{host: host} do
    org = %{id: Ash.UUID.generate()}
    task = start_held_fetch(host, org)

    bust!("other-" <> host)

    assert release_and_await(task) == org
    assert {:ok, ^org} = Cachex.get(Hosts.cache_name(), host)
  end

  describe "when the cache's lock queue cannot be reached" do
    # Without its registered name every transaction on the host cache exits
    # the caller, as it would while the queue restarts.
    setup do
      queue_name = :"#{Hosts.cache_name()}_locksmith"
      queue = Process.whereis(queue_name)
      Process.unregister(queue_name)
      on_exit(fn -> Process.register(queue, queue_name) end)
      :ok
    end

    test "a lookup still answers, uncached", %{host: host} do
      org = %{id: Ash.UUID.generate()}

      assert Hosts.fetch(host, fn -> org end) == org
      assert {:ok, nil} = Cachex.get(Hosts.cache_name(), host)
    end
  end
end
