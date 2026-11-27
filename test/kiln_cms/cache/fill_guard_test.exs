defmodule KilnCMS.Cache.FillGuardTest do
  @moduledoc """
  `KilnCMS.Cache.FillGuard` (#2972): a fill that began before a bust (or a
  clear) is served but never stored, a fill that began after it is stored, and
  every call is total when the cache's lock queue cannot be reached.

  Each test runs against a Cachex instance of its own, and the marks it leaves
  in the generation store are keyed by that instance's name, so nothing here
  touches state another test reads.
  """
  use ExUnit.Case, async: true

  import Cachex.Spec, only: [hook: 1]

  alias KilnCMS.Cache.FillGuard

  setup do
    cache = :"fill_guard_test_#{System.unique_integer([:positive])}"
    start_supervised!({Cachex, name: cache, transactions: true})
    %{cache: cache}
  end

  # The bust's own mark, read back, so a test can begin a fill at exactly the
  # bust's time.
  defp mark_of(cache, key) do
    {:ok, at} = Cachex.get(KilnCMS.Cache.generation_cache_name(), {:fill_mark, cache, key})
    at
  end

  defp listen_for_discards(cache),
    do: listen(cache, [:kiln_cms, :cache, :fill_discarded], :discarded)

  defp listen_for_unmarked(cache),
    do: listen(cache, [:kiln_cms, :cache, :bust_unmarked], :unmarked)

  # Other async tests emit the same events for their own caches. The filter
  # is in the body, not the head: a handler that raises on their events is
  # detached by `:telemetry`, and this test would miss its own.
  defp listen(cache, event, tag) do
    handler = "fill-guard-test-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, measurements, metadata, _config ->
          if metadata[:cache] == cache, do: send(test, {tag, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "put/5" do
    test "stores a fill no bust has touched, with the given options", %{cache: cache} do
      began = FillGuard.begin()

      assert :stored = FillGuard.put(cache, "k", :v, [expire: :timer.minutes(1)], began)
      assert {:ok, :v} = Cachex.get(cache, "k")
      assert {:ok, ttl} = Cachex.ttl(cache, "k")
      assert is_integer(ttl) and ttl > 0 and ttl <= :timer.minutes(1)
    end

    test "discards a fill that began before a bust of its key", %{cache: cache} do
      listen_for_discards(cache)
      began = FillGuard.begin()
      :ok = FillGuard.bust(cache, ["k"])

      assert :discarded = FillGuard.put(cache, "k", :old, [], began)
      assert {:ok, nil} = Cachex.get(cache, "k")
      assert_received {:discarded, %{count: 1}, %{reason: :busted}}
    end

    test "discards a fill that began at the very time of the bust", %{cache: cache} do
      :ok = FillGuard.bust(cache, ["k"])
      at = mark_of(cache, "k")

      assert :discarded = FillGuard.put(cache, "k", :old, [], at)
      assert :stored = FillGuard.put(cache, "k", :new, [], at + 1)
      assert {:ok, :new} = Cachex.get(cache, "k")
    end

    test "stores a fill that began after the bust", %{cache: cache} do
      :ok = FillGuard.bust(cache, ["k"])
      began = FillGuard.begin()

      assert :stored = FillGuard.put(cache, "k", :new, [], began)
      assert {:ok, :new} = Cachex.get(cache, "k")
    end

    test "a bust of another key leaves the fill alone", %{cache: cache} do
      began = FillGuard.begin()
      :ok = FillGuard.bust(cache, ["other"])

      assert :stored = FillGuard.put(cache, "k", :v, [], began)
    end

    test "a bust of the same key in another cache leaves the fill alone", %{cache: cache} do
      other = :"#{cache}_other"

      start_supervised!(
        Supervisor.child_spec({Cachex, name: other, transactions: true}, id: other)
      )

      began = FillGuard.begin()
      :ok = FillGuard.bust(other, ["k"])

      assert :stored = FillGuard.put(cache, "k", :v, [], began)
    end

    test "discards a fill that began before a clear", %{cache: cache} do
      listen_for_discards(cache)
      began = FillGuard.begin()
      :ok = FillGuard.clear(cache)

      assert :discarded = FillGuard.put(cache, "k", :old, [], began)
      assert {:ok, nil} = Cachex.get(cache, "k")
      assert_received {:discarded, _, %{reason: :busted}}

      assert :stored = FillGuard.put(cache, "k", :new, [], FillGuard.begin())
    end

    test "discards a fill that began longer ago than the window", %{cache: cache} do
      listen_for_discards(cache)
      window = System.convert_time_unit(FillGuard.window(), :millisecond, :native)
      began = FillGuard.begin() - window - 1

      assert :discarded = FillGuard.put(cache, "k", :old, [], began)
      assert {:ok, nil} = Cachex.get(cache, "k")
      assert_received {:discarded, _, %{reason: :too_old}}
    end

    test "goes through Cachex.put/4, so the cache's hooks see it" do
      capped = :"fill_guard_capped_#{System.unique_integer([:positive])}"
      limiter = :"#{capped}_limit"

      start_supervised!(
        Supervisor.child_spec(
          {Cachex,
           name: capped,
           transactions: true,
           hooks: [hook(module: Cachex.Limit.Evented, args: {3, [reclaim: 0.5]}, name: limiter)]},
          id: capped
        )
      )

      for n <- 1..10, do: :stored = FillGuard.put(capped, n, n, [], FillGuard.begin())

      # The limiter prunes on each put notification, in its own process: once
      # it has handled every message sent before this call, the cap holds.
      _ = :sys.get_state(limiter)
      assert {:ok, size} = Cachex.size(capped)
      assert size <= 3
    end

    test "a cache that is not running stores nothing and raises nothing" do
      assert :not_stored =
               FillGuard.put(:fill_guard_no_such_cache, "k", :v, [], FillGuard.begin())
    end
  end

  describe "when the cache's lock queue cannot be reached" do
    # The queue is called by its registered name, so without the name every
    # transaction exits the caller, as it would while the queue restarts.
    setup %{cache: cache} do
      queue_name = :"#{cache}_locksmith"
      queue = Process.whereis(queue_name)
      Process.unregister(queue_name)
      on_exit(fn -> if Process.alive?(queue), do: Process.register(queue, queue_name) end)
      :ok
    end

    test "a fill stores nothing and exits nothing", %{cache: cache} do
      assert :not_stored = FillGuard.put(cache, "k", :v, [], FillGuard.begin())
      assert {:ok, nil} = Cachex.get(cache, "k")
    end

    @tag :capture_log
    test "a bust still deletes, and reports that it left no mark", %{cache: cache} do
      listen_for_unmarked(cache)
      {:ok, true} = Cachex.put(cache, "k", :old)

      assert :ok = FillGuard.bust(cache, ["k"])
      assert {:ok, nil} = Cachex.get(cache, "k")
      assert_received {:unmarked, %{count: 1}, %{reason: :queue_unavailable}}
    end

    @tag :capture_log
    test "a clear still clears, and reports that it left no mark", %{cache: cache} do
      listen_for_unmarked(cache)
      {:ok, true} = Cachex.put(cache, "k", :old)

      assert :ok = FillGuard.clear(cache)
      assert {:ok, nil} = Cachex.get(cache, "k")
      assert_received {:unmarked, _, %{reason: :queue_unavailable}}
    end
  end

  # A mark store that is not running stands in for the generation store
  # being down or restarting: its puts and gets return `{:error, :no_cache}`.
  describe "when the mark store cannot be reached" do
    @down :fill_guard_test_no_mark_store

    @tag :capture_log
    test "a bust still deletes, and reports that it left no mark", %{cache: cache} do
      listen_for_unmarked(cache)
      {:ok, true} = Cachex.put(cache, "k", :old)

      assert :ok = FillGuard.bust(cache, ["k"], @down)
      assert {:ok, nil} = Cachex.get(cache, "k")
      assert_received {:unmarked, %{count: 1}, %{reason: :mark_failed}}
    end

    @tag :capture_log
    test "a clear still clears, and reports that it left no mark", %{cache: cache} do
      listen_for_unmarked(cache)
      {:ok, true} = Cachex.put(cache, "k", :old)

      assert :ok = FillGuard.clear(cache, @down)
      assert {:ok, nil} = Cachex.get(cache, "k")
      assert_received {:unmarked, _, %{reason: :mark_failed}}
    end

    test "a fill stores nothing: no mark can prove it fresh", %{cache: cache} do
      assert :not_stored = FillGuard.put(cache, "k", :v, [], FillGuard.begin(), @down)
      assert {:ok, nil} = Cachex.get(cache, "k")
    end
  end

  test "a bust that wrote its marks reports nothing", %{cache: cache} do
    listen_for_unmarked(cache)

    assert :ok = FillGuard.bust(cache, ["k"])
    assert :ok = FillGuard.clear(cache)
    refute_received {:unmarked, _, _}
  end

  describe "bust/2" do
    test "deletes every key it names, and only those", %{cache: cache} do
      for k <- ~w(a b c), do: {:ok, true} = Cachex.put(cache, k, k)

      assert :ok = FillGuard.bust(cache, ["a", "b"])
      assert {:ok, nil} = Cachex.get(cache, "a")
      assert {:ok, nil} = Cachex.get(cache, "b")
      assert {:ok, "c"} = Cachex.get(cache, "c")
    end

    test "its marks expire, after twice the window", %{cache: cache} do
      :ok = FillGuard.bust(cache, ["k"])

      assert {:ok, ttl} =
               Cachex.ttl(KilnCMS.Cache.generation_cache_name(), {:fill_mark, cache, "k"})

      assert ttl > FillGuard.window() and ttl <= 2 * FillGuard.window()
    end
  end
end
