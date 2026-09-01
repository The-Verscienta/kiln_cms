defmodule KilnCMS.CacheTest do
  @moduledoc false
  # async: false — exercises the shared, app-wide content cache.
  use ExUnit.Case, async: false

  alias KilnCMS.Cache

  setup do
    Cache.bust_published()
    %{org: KilnCMS.Accounts.default_org_id()}
  end

  defp slug, do: "cache-#{System.unique_integer([:positive])}"

  test "caches a computed value and serves it on the next fetch", %{org: org} do
    s = slug()

    assert :first = Cache.fetch_published(org, "page", s, "en", fn -> :first end)
    # The fallback would return :second, but the cached :first wins.
    assert :first = Cache.fetch_published(org, "page", s, "en", fn -> :second end)
  end

  test "does not cache a nil (not-found) result", %{org: org} do
    s = slug()

    assert nil == Cache.fetch_published(org, "page", s, "en", fn -> nil end)
    # Still recomputed, so newly published content shows up immediately.
    assert :now_here = Cache.fetch_published(org, "page", s, "en", fn -> :now_here end)
  end

  test "bust_published clears cached entries", %{org: org} do
    s = slug()

    assert :v1 = Cache.fetch_published(org, "page", s, "en", fn -> :v1 end)
    Cache.bust_published()
    assert :v2 = Cache.fetch_published(org, "page", s, "en", fn -> :v2 end)
  end

  # Audit P-M4: concurrent misses for the same key must compute once, not
  # stampede the DB (Cachex.fetch's Courier deduplicates fallbacks).
  #
  # The overlap is a latch, not a sleep (#1351, via KilnCMS.Test.Latch): the
  # one compute HOLDS until the test releases it, so the previous 50ms sleep —
  # the whole window in which all eight tasks had to collide — is gone. What
  # the hold guarantees, stated honestly: no task can finish before the
  # release (checked below), and a second compute starting at any point
  # before it is a deterministic failure. What it cannot guarantee: a task
  # descheduled between its `:fetching` send and its fetch may arrive after
  # the release and take a plain cache hit — Cachex exposes no waiter count
  # to close that, so full eight-way contention stays scheduler-dependent
  # even though the dedup property itself no longer is.
  test "concurrent misses for one key run the fallback only once", %{org: org} do
    s = slug()
    test_pid = self()
    counter = :counters.new(1, [:atomics])
    {:ok, _} = KilnCMS.Test.Latch.start_link(name: __MODULE__.ComputeLatch, listener: self())

    held_compute = fn ->
      :counters.add(counter, 1, 1)
      KilnCMS.Test.Latch.enter(__MODULE__.ComputeLatch)
      :computed
    end

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(test_pid, :fetching)
          Cache.fetch_published(org, "page", s, "en", held_compute)
        end)
      end

    # All eight tasks are running (each sends exactly once, just before its
    # fetch), and the single compute is in flight...
    for _ <- 1..8, do: assert_receive(:fetching, 2_000)
    assert_receive {:latch_started, __MODULE__.ComputeLatch, 1}, 2_000
    # ...and none has completed while the compute is held — a completion here
    # would be a task that never contended for the key at all.
    for %Task{ref: ref} <- tasks, do: refute_received({^ref, _})

    # Exactly one held compute, woken by the test: a match failure here shows
    # every compute that started — the broken-dedup world, by name.
    assert [_worker] = KilnCMS.Test.Latch.release_all(__MODULE__.ComputeLatch)

    results = Task.await_many(tasks, 5_000)

    assert Enum.all?(results, &(&1 == :computed))
    assert :counters.get(counter, 1) == 1
    # Released by the test, not by the latch's bounded fallback — a timeout
    # here means the latch silently degraded back into a sleep.
    refute_received {:latch_timeout, _, _}
  end

  test "keys are namespaced by type and locale", %{org: org} do
    s = slug()

    assert :page = Cache.fetch_published(org, "page", s, "en", fn -> :page end)
    assert :post = Cache.fetch_published(org, "post", s, "en", fn -> :post end)
    # Same type+slug, different locale → a separate entry.
    assert :fr = Cache.fetch_published(org, "page", s, "fr", fn -> :fr end)
  end

  test "bust/2 drops every locale variant of one record, leaving others intact", %{org: org} do
    s = slug()
    other = slug()

    # Cache the same slug under two locales, plus an unrelated slug.
    assert :en = Cache.fetch_published(org, "page", s, "en", fn -> :en end)
    assert :fr = Cache.fetch_published(org, "page", s, "fr", fn -> :fr end)
    assert :keep = Cache.fetch_published(org, "page", other, "en", fn -> :keep end)

    Cache.bust(org, "page", s)

    # Both locale variants of the busted record are recomputed…
    assert :en2 = Cache.fetch_published(org, "page", s, "en", fn -> :en2 end)
    assert :fr2 = Cache.fetch_published(org, "page", s, "fr", fn -> :fr2 end)
    # …while the unrelated record is still served from cache.
    assert :keep = Cache.fetch_published(org, "page", other, "en", fn -> :ignored end)
  end

  # Regression: the HTML controller caches an enriched payload map while
  # headless delivery caches the bare record for the same {type, slug, locale}.
  # They once shared one key, so whichever endpoint resolved a slug first
  # poisoned the other with a shape it couldn't render (a 500).
  test "record and payload shapes cache independently for the same coordinates", %{org: org} do
    s = slug()

    assert :record = Cache.fetch_published(org, "page", s, "en", fn -> :record end)
    assert :payload = Cache.fetch_published_payload(org, "page", s, "en", fn -> :payload end)

    # Each shape keeps serving its own cached value, never the other's.
    assert :record = Cache.fetch_published(org, "page", s, "en", fn -> :ignored end)
    assert :payload = Cache.fetch_published_payload(org, "page", s, "en", fn -> :ignored end)
  end

  test "bust/3 drops both cached shapes of a record", %{org: org} do
    s = slug()

    assert :record = Cache.fetch_published(org, "page", s, "en", fn -> :record end)
    assert :payload = Cache.fetch_published_payload(org, "page", s, "en", fn -> :payload end)

    Cache.bust(org, "page", s)

    assert :record2 = Cache.fetch_published(org, "page", s, "en", fn -> :record2 end)
    assert :payload2 = Cache.fetch_published_payload(org, "page", s, "en", fn -> :payload2 end)
  end

  test "bust/2 is scoped by type", %{org: org} do
    s = slug()

    assert :page = Cache.fetch_published(org, "page", s, "en", fn -> :page end)
    assert :post = Cache.fetch_published(org, "post", s, "en", fn -> :post end)

    Cache.bust(org, "page", s)

    assert :page2 = Cache.fetch_published(org, "page", s, "en", fn -> :page2 end)
    # Same slug, different type → untouched.
    assert :post = Cache.fetch_published(org, "post", s, "en", fn -> :ignored end)
  end
end
