defmodule KilnCMS.CacheTest do
  @moduledoc false
  # async: false — exercises the shared, app-wide content cache.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Cache

  setup do
    Cache.bust_published()
    %{org: KilnCMS.Accounts.default_org_id()}
  end

  defp slug, do: "cache-#{System.unique_integer([:positive])}"

  # Record every `[:kiln_cms, :cache, :content]` result for the duration of one
  # test. Events are sent from the process that did the fetch, so a task's
  # event always reaches this mailbox before that task's own reply does —
  # draining after `Task.await_many/2` sees all of them.
  defp listen_for_cache_results do
    test_pid = self()
    handler_id = "test-cache-content-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kiln_cms, :cache, :content],
      fn _name, _measurements, %{result: result}, _config ->
        send(test_pid, {:cache_result, result})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp cache_results(acc \\ %{}) do
    receive do
      {:cache_result, result} -> cache_results(Map.update(acc, result, 1, &(&1 + 1)))
    after
      0 -> acc
    end
  end

  # Block until every pid is parked inside a call into Cachex — which, for a
  # `fetch`, is the Courier reply it waits on while another caller's fallback
  # runs. This is the only observable proof that a caller reached the Courier
  # BEFORE the single compute committed (Cachex publishes no waiter count), and
  # it is what lets the dedup test release the latch only once every task is
  # provably contending. A task that never gets there fails here by name
  # instead of silently taking a plain cache hit later.
  defp await_courier_waiters(pids, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    pending = Enum.reject(pids, &in_cachex_call?/1)

    cond do
      pending == [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "#{length(pending)} task(s) never parked in the Cachex Courier: #{inspect(pending)}"
        )

      true ->
        Process.sleep(5)
        await_courier_waiters(pending, deadline)
    end
  end

  defp in_cachex_call?(pid) do
    with {:current_function, {:gen, :do_call, 4}} <- Process.info(pid, :current_function),
         {:current_stacktrace, stack} <- Process.info(pid, :current_stacktrace) do
      Enum.any?(stack, fn {module, _f, _a, _loc} ->
        module |> inspect() |> String.starts_with?("Cachex.")
      end)
    else
      _ -> false
    end
  end

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
  # stampede the DB (Cachex.fetch's Courier deduplicates fallbacks) — and each
  # deduplicated caller must be COUNTED as deduplicated rather than as a hit
  # (#1377), or the hit-rate graph reads healthiest during a stampede.
  #
  # The overlap is a latch, not a sleep (#1351, via KilnCMS.Test.Latch): the
  # one compute HOLDS until the test releases it, so the previous 50ms sleep —
  # the whole window in which all eight tasks had to collide — is gone. What
  # the hold guarantees: no task can finish before the release (checked below),
  # and a second compute starting at any point before it is a deterministic
  # failure.
  #
  # What the hold alone could NOT guarantee — and what the telemetry claim
  # needs — is that all eight actually contended: a task descheduled between
  # its `:fetching` send and its fetch could arrive after the release and take
  # a plain cache hit. `await_courier_waiters/1` closes that from the other
  # side, holding the release until every task is parked in the Courier, so the
  # counts below are exact rather than scheduler-dependent.
  test "concurrent misses for one key compute once and count as coalesced, not hits", %{org: org} do
    s = slug()
    test_pid = self()
    counter = :counters.new(1, [:atomics])
    {:ok, _} = KilnCMS.Test.Latch.start_link(name: __MODULE__.ComputeLatch, listener: self())
    listen_for_cache_results()

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

    # Every task — the one whose dispatch is running the fallback included — is
    # now blocked on the Courier's reply, so none can still arrive afterwards
    # and take an uncontended hit.
    await_courier_waiters(Enum.map(tasks, & &1.pid))

    # Exactly one held compute, woken by the test: a match failure here shows
    # every compute that started — the broken-dedup world, by name.
    assert [_worker] = KilnCMS.Test.Latch.release_all(__MODULE__.ComputeLatch)

    results = Task.await_many(tasks, 5_000)

    assert Enum.all?(results, &(&1 == :computed))
    assert :counters.get(counter, 1) == 1
    # Released by the test, not by the latch's bounded fallback — a timeout
    # here means the latch silently degraded back into a sleep.
    refute_received {:latch_timeout, _, _}

    # One caller ran the fallback, seven were served by it. Cachex answers both
    # the second case and a genuine hit with `{:ok, value}`, so reading the
    # reply tag alone reports this burst as 1 miss and 7 hits — an 87.5% hit
    # rate for the moment the cache did the least work of its life.
    assert cache_results() == %{miss: 1, coalesced: 7}
  end

  test "a plain cache hit is still counted as a hit", %{org: org} do
    s = slug()
    listen_for_cache_results()

    assert :v = Cache.fetch_published(org, "page", s, "en", fn -> :v end)
    assert :v = Cache.fetch_published(org, "page", s, "en", fn -> :ignored end)

    assert cache_results() == %{miss: 1, hit: 1}
  end

  # The other half of #1376's amplifier, and the common half: a fallback that
  # raises. On the delivery path that is just a 404 — a bang code interface on a
  # slug that does not exist — and the old catch-all recovered the real
  # exception by re-running the fallback in the caller, so a burst of requests
  # for one missing URL ran it once per caller.
  test "a raising fallback runs once for a burst and re-raises in every caller", %{org: org} do
    s = slug()
    test_pid = self()
    counter = :counters.new(1, [:atomics])
    {:ok, _} = KilnCMS.Test.Latch.start_link(name: __MODULE__.RaiseLatch, listener: self())

    held_raise = fn ->
      :counters.add(counter, 1, 1)
      KilnCMS.Test.Latch.enter(__MODULE__.RaiseLatch)
      raise "no such page"
    end

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(test_pid, :fetching)

          try do
            Cache.fetch_published(org, "page", s, "en", held_raise)
          rescue
            e -> {:rescued, e}
          end
        end)
      end

    for _ <- 1..8, do: assert_receive(:fetching, 2_000)
    assert_receive {:latch_started, __MODULE__.RaiseLatch, 1}, 2_000
    await_courier_waiters(Enum.map(tasks, & &1.pid))
    assert [_worker] = KilnCMS.Test.Latch.release_all(__MODULE__.RaiseLatch)

    # Every caller rescues by TYPE — the controller's 404 depends on that, and a
    # `Cachex.Error` carrying the message as text would 500 instead.
    assert Task.await_many(tasks, 5_000) ==
             List.duplicate(
               {:rescued, %RuntimeError{message: "no such page"}},
               8
             )

    # One run for all eight, where the old catch-all made eight.
    assert :counters.get(counter, 1) == 1
    refute_received {:latch_timeout, _, _}

    # Nothing was cached, so the page appears the moment it is published.
    assert :now_here = Cache.fetch_published(org, "page", s, "en", fn -> :now_here end)
  end

  test "the generic fetch re-raises the caller's own exception too" do
    key = "cache-generic-#{System.unique_integer([:positive])}"

    assert_raise RuntimeError, "sitemap blew up", fn ->
      Cache.fetch(key, 1_000, fn -> raise "sitemap blew up" end)
    end
  end

  # #1376: `Cachex.fetch` answers `{:error, reason}` when the Courier's worker
  # dies, so on a Courier failure EVERY blocked caller falls out of the dedup
  # at once. The degrade is deliberate — the caller computes, so the page still
  # renders — but it must be logged and counted, because N callers recomputing
  # together is the stampede this module exists to prevent.
  test "a Courier failure degrades to a logged, counted, per-caller recompute", %{org: org} do
    s = slug()
    counter = :counters.new(1, [:atomics])
    listen_for_cache_results()

    # An untrappable kill of the Courier's worker on the first run — the one
    # failure `fetcher/2` cannot catch and turn into a value, so the fetch
    # resolves as `{:error, :killed}` exactly as a crashed courier does.
    crash_once = fn ->
      if :counters.get(counter, 1) == 0 do
        :counters.add(counter, 1, 1)
        Process.exit(self(), :kill)
      end

      :counters.add(counter, 1, 1)
      :recovered
    end

    log =
      capture_log(fn ->
        assert :recovered = Cache.fetch_published(org, "page", s, "en", crash_once)
      end)

    # Once in the dead worker, once in the caller — and no more: a retry back
    # through Cachex would run an already-failing fallback a third time.
    assert :counters.get(counter, 1) == 2
    assert log =~ "cache fetch failed"
    assert log =~ "published:record:"
    assert log =~ ":killed"
    # Not `:miss` — a miss is the cache working. This arm has to be separable
    # on the dashboard from the ordinary uncached read it otherwise resembles.
    assert cache_results() == %{error: 1}
  end

  # The same arm on the generic helper (#1376 again): it has no telemetry of
  # its own, but it is the costlier site — it guards the sitemap rebuild — so
  # the silent per-caller recompute is the one that must not stay silent.
  test "the generic fetch degrades through the same logged path" do
    key = "cache-generic-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [:atomics])

    crash_once = fn ->
      if :counters.get(counter, 1) == 0 do
        :counters.add(counter, 1, 1)
        Process.exit(self(), :kill)
      end

      :counters.add(counter, 1, 1)
      :rebuilt
    end

    log = capture_log(fn -> assert :rebuilt = Cache.fetch(key, 1_000, crash_once) end)

    assert :counters.get(counter, 1) == 2
    assert log =~ "cache fetch failed"
    assert log =~ key
    assert log =~ ":killed"
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
