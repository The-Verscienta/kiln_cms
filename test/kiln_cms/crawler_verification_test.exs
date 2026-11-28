defmodule KilnCMS.CrawlerVerificationTest do
  @moduledoc """
  `KilnCMS.CrawlerVerification` (#2254) against the DNS stub
  (`KilnCMS.Test.StubCrawlerResolver`).
  """
  # Not async: telemetry handlers see every process's events, the warning
  # latches and the consecutive-failure counter are node-wide, one test sets
  # `:trusted_proxies` and the network-mark tests set `:scanner_blocking` with
  # `Application.put_env/3`.
  use ExUnit.Case, async: false

  import Cachex.Spec, only: [hook: 1]
  import ExUnit.CaptureLog
  import KilnCMS.Test.Eventually

  alias KilnCMS.BotClass
  alias KilnCMS.CrawlerVerification
  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.InFlight
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.Security.Cidr
  alias KilnCMS.Security.CrawlerSightingStore
  alias KilnCMS.Test.PublicAddress
  alias KilnCMS.Test.StubCrawlerResolver, as: Stub
  alias KilnCMSWeb.RateLimit

  doctest KilnCMS.CrawlerVerification.Engines

  @lookup [:kiln_cms, :crawler_verification, :lookup]
  @skipped [:kiln_cms, :crawler_verification, :skipped]
  @sighting_unavailable [:kiln_cms, :crawler_verification, :sighting_unavailable]

  setup do
    # First sightings (#2852) are database rows. Not shared: a process the
    # test spawns gets no connection, which is how the "database unavailable"
    # case is made.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(KilnCMS.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    # No range list another test planted or fetched may answer for an
    # address here before DNS does (#2586).
    KilnCMS.CrawlerVerification.Ranges.clear()

    # Each test charges rate-limit keys of its own, so no test spends the
    # per-network budget another needs (test addresses share a few /16s).
    # An hour-long window keeps a test from straddling a window boundary.
    opts = [
      rate_scope: "cv-test-#{System.unique_integer([:positive])}",
      rate_window_ms: 3_600_000
    ]

    %{opts: opts}
  end

  describe "a genuine crawler" do
    for {engine, host} <- [
          google: "crawl-66-249-1-1.googlebot.com",
          google: "crawl-66-249-1-1.geo.googlebot.com",
          bing: "msnbot-1-1.search.msn.com",
          apple: "17-58-1-1.applebot.apple.com",
          yandex: "spider-1-1.spider.yandex.com",
          yandex: "spider-1-1.yandex.ru",
          yandex: "spider-1-1.yandex.net",
          baidu: "baiduspider-1-1.crawl.baidu.com",
          baidu: "baiduspider-1-1.crawl.baidu.jp",
          seznam: "fulltextrobot-77-75-77-1.seznam.cz",
          mojeek: "crawl-5-102-173-71.mojeek.com"
        ] do
      test "#{engine} via #{host} is verified, asking only for A records", %{opts: opts} do
        engine = unquote(engine)
        ip = v4()
        host = unique_host(unquote(host))
        Stub.put_ptr(ip, [host])
        Stub.put_addresses(host, [ip, {0x2001, 0x4860, 0, 0, 0, 0, 0, 1}])

        assert CrawlerVerification.check(engine, ip, opts) == {:unverified, :pending}
        assert settle(engine, ip, opts) == :verified
        assert Stub.calls(:ptr, ip) == 1
        assert Stub.calls(:addresses, host, :inet) == 1
        assert Stub.calls(:addresses, host, :inet6) == 0

        assert CrawlerVerification.verify(engine, ip, opts) == {:verified, host}
      end
    end

    test "the engine's own domain, uppercase and with a trailing dot, is verified", %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [String.upcase(host) <> "."])
      Stub.put_addresses(host, [ip])

      assert CrawlerVerification.verify(:google, ip, opts) == {:verified, host}

      bare = v4()
      Stub.put_ptr(bare, ["googlebot.com"])
      Stub.put_addresses("googlebot.com", [bare])
      assert CrawlerVerification.verify(:google, bare, opts) == {:verified, "googlebot.com"}
    end

    test "an IPv6 crawler is confirmed by its AAAA records only", %{opts: opts} do
      ip = v6()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [{66, 249, 0, 1}, ip])

      assert settle(:google, ip, opts) == :verified
      assert Stub.calls(:addresses, host, :inet6) == 1
      assert Stub.calls(:addresses, host, :inet) == 0
    end

    test "an IPv4-mapped address is the IPv4 client it carries", %{opts: opts} do
      {a, b, c, d} = ip = v4()
      mapped = {0, 0, 0, 0, 0, 0xFFFF, a * 256 + b, c * 256 + d}
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [ip])

      assert settle(:google, mapped, opts) == :verified
      assert CrawlerVerification.check(:google, ip, opts) == :verified
      assert Stub.calls(:ptr, ip) == 1
      assert Stub.calls(:addresses, host, :inet) == 1
      assert Stub.calls(:addresses, host, :inet6) == 0
    end
  end

  describe "a spoofed claim" do
    test "with no PTR record is a proven failure, with no forward query", %{opts: opts} do
      ip = v4()

      assert CrawlerVerification.verify(:google, ip, opts) == {:rejected, :no_ptr}
      assert settle(:google, ip, opts) == {:unverified, :failed}

      empty = v4()
      Stub.put_ptr(empty, [])
      assert CrawlerVerification.verify(:google, empty, opts) == {:rejected, :no_ptr}
    end

    for name <- [
          "crawl.evilgooglebot.com",
          "googlebot.com.evil.net",
          "crawl.googleusercontent.com",
          "rate-limited-proxy.google.com",
          "crawl\\.googlebot\\.com",
          "crawl.googlebot\\.com"
        ] do
      test "whose PTR is #{name} is the wrong domain, with no forward query", %{opts: opts} do
        ip = v4()
        name = unquote(name)
        Stub.put_ptr(ip, [name])
        Stub.put_addresses(name, [ip])

        assert CrawlerVerification.verify(:google, ip, opts) == {:rejected, :wrong_domain}
        assert settle(:google, ip, opts) == {:unverified, :failed}
        assert Stub.calls(:addresses, name) == 0
      end
    end

    test "whose forward lookup does not contain the address is a forward mismatch",
         %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [{66, 249, 0, 1}])

      assert CrawlerVerification.verify(:google, ip, opts) == {:rejected, :forward_mismatch}
      assert settle(:google, ip, opts) == {:unverified, :failed}

      missing = v4()
      gone = unique_host("crawl.googlebot.com")
      Stub.put_ptr(missing, [gone])

      assert CrawlerVerification.verify(:google, missing, opts) ==
               {:rejected, :forward_mismatch}
    end

    test "a Google address claiming to be bingbot fails without a second lookup",
         %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [ip])

      assert settle(:google, ip, opts) == :verified
      assert CrawlerVerification.check(:bing, ip, opts) == {:unverified, :failed}
      assert CrawlerVerification.check(:apple, ip, opts) == {:unverified, :failed}
      assert Stub.calls(:ptr, ip) == 1

      assert CrawlerVerification.verify(:bing, ip, opts) == {:rejected, :wrong_domain}
    end
  end

  describe "a resolver that cannot answer" do
    for reason <- [:servfail, :timeout, :refused] do
      test "a PTR #{reason} is an error, cached briefly and never a failure", %{opts: opts} do
        ip = v4()
        Stub.put_ptr(ip, {:error, unquote(reason)})

        assert CrawlerVerification.verify(:google, ip, opts) == {:error, unquote(reason)}
        assert settle(:google, ip, opts) == {:unverified, :error}
        assert_error_ttl(ip)
      end
    end

    # #2588: the PTR query was answered, so the silence is the engine's own
    # zone, not the address's; `:forward_error` tells a caller so.
    for reason <- [:servfail, :timeout] do
      test "a forward #{reason} for an engine-domain name is a forward error, not a mismatch",
           %{opts: opts} do
        ip = v4()
        host = unique_host("crawl.googlebot.com")
        Stub.put_ptr(ip, [host])
        Stub.put_addresses(host, {:error, unquote(reason)})

        assert CrawlerVerification.verify(:google, ip, opts) == {:error, unquote(reason)}
        assert settle(:google, ip, opts) == {:unverified, :forward_error}
        assert_error_ttl(ip)

        assert {:ok, {:ptr, %{budgeted: [^host]}}} =
                 Cachex.get(CrawlerVerification.cache_name(), ip)
      end
    end

    # A reverse zone that answers late leaves the forward query less than its
    # full budget; its failure may be the late answer's doing, so it is the
    # address's silence, never the engine's.
    test "a forward error after a PTR answer that left less than a query's budget is an error",
         %{opts: opts} do
      opts = Keyword.merge(opts, deadline_ms: 1_200, query_timeout_ms: 1_000)
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, {:block, self(), [host]})
      Stub.put_addresses(host, {:error, :timeout})

      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
      assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^ip}, 2_000
      # Past the point where a full query budget is left before the deadline.
      Process.sleep(300)
      Stub.release(resolver)

      assert settle(:google, ip, opts) == {:unverified, :error}
      assert Stub.calls(:addresses, host) == 1
      assert {:ok, {:ptr, %{budgeted: []}}} = Cachex.get(CrawlerVerification.cache_name(), ip)
    end

    test "a cached forward error from before budgets were recorded reads as an error",
         %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      old_shape = {:ptr, %{names: [host], confirmed: [], errors: [{host, :timeout}]}}
      Cachex.put(CrawlerVerification.cache_name(), ip, old_shape)

      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :error}
    end

    test "a PTR naming another engine's host whose forward query fails is not a forward error",
         %{opts: opts} do
      ip = v4()
      host = unique_host("msnbot.search.msn.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, {:error, :timeout})

      # Claimed as Googlebot: the name is not Google's, so the claim fails.
      assert settle(:google, ip, opts) == {:unverified, :failed}
      # Claimed as bingbot, the same cached result is Bing's own zone failing.
      assert CrawlerVerification.check(:bing, ip, opts) == {:unverified, :forward_error}
    end

    test "a PTR naming a host under no engine's domain makes no forward query and fails",
         %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.example.net")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, {:error, :timeout})

      assert settle(:google, ip, opts) == {:unverified, :failed}
      assert Stub.calls(:addresses, host) == 0
    end

    test "a lookup past its deadline is killed and cached as a timeout", %{opts: opts} do
      ip = v4()
      opts = Keyword.put(opts, :deadline_ms, 50)
      Stub.put_ptr(ip, {:block, self()})

      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
      assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^ip}, 2_000
      ref = Process.monitor(resolver)
      assert_receive {:DOWN, ^ref, :process, ^resolver, :killed}, 2_000

      assert settle(:google, ip, opts) == {:unverified, :error}
      assert {:ok, {:error, :timeout}} = Cachex.get(CrawlerVerification.cache_name(), ip)
      assert_error_ttl(ip)
      eventually(fn -> :ets.lookup(InFlight.table(), ip) == [] end)

      sync = v4()
      Stub.put_ptr(sync, {:block, self()})
      assert CrawlerVerification.verify(:google, sync, opts) == {:error, :timeout}
    end
  end

  describe "the cache" do
    test "answers repeat claims without another lookup", %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [ip])

      assert settle(:google, ip, opts) == :verified

      for _ <- 1..10, do: assert(CrawlerVerification.check(:google, ip, opts) == :verified)

      assert Stub.calls(:ptr, ip) == 1
      assert Stub.calls(:addresses, host) == 1
    end

    test "looks the address up again once its entry expires", %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [ip])
      opts = Keyword.put(opts, :verified_ttl_ms, 50)

      assert settle(:google, ip, opts) == :verified

      eventually(fn ->
        CrawlerVerification.check(:google, ip, opts)
        Stub.calls(:ptr, ip) >= 2
      end)
    end

    test "keeps a verified name 6 h and a proven failure 1 h", %{opts: opts} do
      verified = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(verified, [host])
      Stub.put_addresses(host, [verified])
      assert settle(:google, verified, opts) == :verified
      assert ttl(CrawlerVerification.verified_cache_name(), verified) > :timer.hours(5)
      assert {:ok, false} = Cachex.exists?(CrawlerVerification.cache_name(), verified)

      rejected = v4()
      assert settle(:google, rejected, opts) == {:unverified, :failed}
      assert ttl(rejected) in :timer.minutes(50)..:timer.hours(1)
    end

    test "put_result/4 and forget/2 plant and drop a result", %{opts: opts} do
      ip = v4()

      CrawlerVerification.put_result(:google, ip, :verified)
      assert CrawlerVerification.check(:google, ip, opts) == :verified
      assert CrawlerVerification.check(:bing, ip, opts) == {:unverified, :failed}

      CrawlerVerification.put_result(:bing, ip, {:rejected, :forward_mismatch})
      assert CrawlerVerification.check(:bing, ip, opts) == {:unverified, :failed}

      CrawlerVerification.put_result(:google, ip, {:error, :servfail})
      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :error}

      CrawlerVerification.forget(ip)
      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
      assert Stub.calls(:ptr, ip) <= 1
    end

    test "forget/2 drops the address from both caches" do
      ip = v4()
      CrawlerVerification.put_result(:google, ip, :verified)
      Cachex.put(CrawlerVerification.cache_name(), ip, :no_ptr)

      CrawlerVerification.forget(ip)

      assert {:ok, false} = Cachex.exists?(CrawlerVerification.verified_cache_name(), ip)
      assert {:ok, false} = Cachex.exists?(CrawlerVerification.cache_name(), ip)
    end

    # #2588: a rotating attacker writes rejections as fast as the lookup caps
    # allow; with one cache, least-recently-written eviction dropped verified
    # crawlers first. `config/test.exs` scales `max_entries` down.
    test "a flood of rejections twice the cache's size never evicts a verified result",
         %{opts: opts} do
      verified = v4()
      CrawlerVerification.put_result(:google, verified, :verified)

      max_entries = Application.fetch_env!(:kiln_cms, CrawlerVerification)[:max_entries]
      flood = for _ <- 1..(max_entries * 2), do: PublicAddress.v4()

      for ip <- flood,
          do: CrawlerVerification.put_result(:google, ip, {:rejected, :wrong_domain})

      # The bound evicted: the oldest rejections are gone.
      eventually(fn -> cache_size(CrawlerVerification.cache_name()) <= max_entries end)
      assert {:ok, false} = Cachex.exists?(CrawlerVerification.cache_name(), hd(flood))

      assert CrawlerVerification.check(:google, verified, opts) == :verified
      assert Stub.calls(:ptr, verified) == 0
    end

    # Cachex orders eviction by write time in milliseconds, so which of
    # entries written in the same millisecond goes first is not fixed: assert
    # the bound, not which entry it dropped.
    test "the verified cache is bounded on its own" do
      max_verified = Application.fetch_env!(:kiln_cms, CrawlerVerification)[:max_verified_entries]

      for _ <- 1..(max_verified * 2),
          do: CrawlerVerification.put_result(:google, PublicAddress.v4(), :verified)

      eventually(fn ->
        cache_size(CrawlerVerification.verified_cache_name()) <= max_verified
      end)
    end
  end

  describe "single flight" do
    test "twenty concurrent claims from one address make one lookup", %{opts: opts} do
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, {:block, self(), [host]})
      Stub.put_addresses(host, [ip])

      results =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn -> CrawlerVerification.check(:google, ip, opts) end)
        end)
        |> Task.await_many()

      assert Enum.uniq(results) == [{:unverified, :pending}]
      assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^ip}, 2_000
      Stub.release(resolver)

      assert settle(:google, ip, opts) == :verified
      assert Stub.calls(:ptr, ip) == 1
    end

    test "a lookup that outlived its claim does not release the claim that replaced it",
         %{opts: opts} do
      ip = v4()
      # The claim lapses almost at once while the lookup runs on.
      opts = Keyword.merge(opts, in_flight_ttl_ms: 1, deadline_ms: 10_000)
      Stub.put_ptr(ip, {:block, self()})

      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
      assert_receive {Stub, :blocked, first, [first_task | _], :ptr, ^ip}, 2_000
      [{^ip, first_ref, _}] = :ets.lookup(InFlight.table(), ip)

      eventually(fn -> not InFlight.in_flight?(ip) end)
      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
      assert_receive {Stub, :blocked, second, [second_task | _], :ptr, ^ip}, 2_000
      [{^ip, second_ref, _}] = :ets.lookup(InFlight.table(), ip)
      assert second_ref != first_ref

      monitor = Process.monitor(first_task)
      Stub.release(first)
      assert_receive {:DOWN, ^monitor, :process, ^first_task, _}, 2_000
      assert [{^ip, ^second_ref, _}] = :ets.lookup(InFlight.table(), ip)

      monitor = Process.monitor(second_task)
      Stub.release(second)
      assert_receive {:DOWN, ^monitor, :process, ^second_task, _}, 2_000
      assert :ets.lookup(InFlight.table(), ip) == []
    end

    test "the sweep deletes lapsed claims and nothing else" do
      lapsed = v4()
      live = v4()
      now = System.monotonic_time(:millisecond)
      :ets.insert(InFlight.table(), {lapsed, make_ref(), now - 1})
      :ets.insert(InFlight.table(), {live, make_ref(), now + 60_000})
      InFlight.bump(:sweep_test)

      assert InFlight.sweep() >= 1
      assert :ets.lookup(InFlight.table(), lapsed) == []
      assert [{^live, _, _}] = :ets.lookup(InFlight.table(), live)

      assert [{{:counter, :sweep_test}, _}] =
               :ets.lookup(InFlight.table(), {:counter, :sweep_test})

      :ets.delete(InFlight.table(), live)
      :ets.delete(InFlight.table(), {:counter, :sweep_test})
    end
  end

  describe "bounded concurrency" do
    test "a lookup past the limit is skipped, not queued, and frees its claim", %{opts: opts} do
      CrawlerVerification.reset_warnings()
      attach(@skipped)
      supervisor = start_supervised!({Task.Supervisor, max_children: 1})
      opts = Keyword.put(opts, :task_supervisor, supervisor)

      busy = v4()
      Stub.put_ptr(busy, {:block, self()})
      assert CrawlerVerification.check(:google, busy, opts) == {:unverified, :pending}
      assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^busy}, 2_000

      turned_away = v4()

      log =
        capture_log(fn ->
          assert CrawlerVerification.check(:google, turned_away, opts) == {:unverified, :skipped}
          assert CrawlerVerification.check(:bing, v4(), opts) == {:unverified, :skipped}
        end)

      assert :ets.lookup(InFlight.table(), turned_away) == []
      assert Stub.calls(:ptr, turned_away) == 0
      assert_receive {:telemetry, @skipped, %{count: 1}, %{engine: :google, reason: :busy}}
      assert_receive {:telemetry, @skipped, %{count: 1}, %{engine: :bing, reason: :busy}}

      assert [_once] = Regex.scan(~r/concurrent-lookup limit/, log)

      Stub.release(resolver)
      assert settle(:google, busy, opts) == {:unverified, :failed}
    end

    # `check/3` runs in the delivery rate limiter: a verifier mid-restart (its
    # in-flight table gone) must answer "unchecked", never raise into a 500.
    test "a verifier that is restarting answers skipped instead of raising", %{opts: opts} do
      supervisor = KilnCMS.CrawlerVerification.Supervisor
      :ok = Supervisor.terminate_child(supervisor, InFlight)
      on_exit(fn -> Supervisor.restart_child(supervisor, InFlight) end)

      assert :ets.whereis(InFlight.table()) == :undefined
      assert CrawlerVerification.check(:google, v4(), opts) == {:unverified, :skipped}

      {:ok, _pid} = Supervisor.restart_child(supervisor, InFlight)
      assert CrawlerVerification.check(:google, v4(), opts) == {:unverified, :pending}
    end
  end

  # #2588: the caps are charged before the start, so a start turned away as
  # busy gives its charges back; otherwise a flood of busy starts would spend
  # a network's budget, and the node's, without a single lookup.
  describe "a start turned away as busy" do
    for {family, prefixes} <- [inet: [{24, 1}, {16, 1}], inet6: [{64, 1}, {48, 1}, {32, 1}]] do
      test "spends no #{family} network budget and no node budget", %{opts: opts} do
        family = unquote(family)
        supervisor = start_supervised!({Task.Supervisor, max_children: 1})

        opts =
          Keyword.merge(opts,
            task_supervisor: supervisor,
            prefix_lookups_per_minute: [{family, unquote(prefixes)}],
            lookups_per_minute: 2
          )

        # The other family, so it spends the node's budget and no network's.
        blocker = address(other_family(family))
        Stub.put_ptr(blocker, {:block, self()})
        assert CrawlerVerification.check(:google, blocker, opts) == {:unverified, :pending}
        assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^blocker}, 2_000

        ip = address(family)
        before = spent(ip, opts)
        assert before["node"] == 1

        capture_log(fn ->
          assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :skipped}
        end)

        assert spent(ip, opts) == before
        assert Stub.calls(:ptr, ip) == 0

        Stub.release(resolver)
        assert settle(:google, blocker, opts) == {:unverified, :failed}
        eventually(fn -> Task.Supervisor.children(supervisor) == [] end)

        # Every one of its networks is at a cap of 1, and the node at 2: the
        # next address in them still gets its lookup.
        assert CrawlerVerification.check(:google, neighbor(ip), opts) == {:unverified, :pending}
      end
    end

    test "a refund that cannot be made still frees the claim, and never raises",
         %{opts: opts} do
      CrawlerVerification.reset_warnings()
      attach(@skipped)
      node_key = "#{opts[:rate_scope]}:node"
      index = RateLimit.window_index(opts[:rate_window_ms])

      # A stand-in for a full task supervisor that, between the charge and the
      # refund, leaves the node cap's counter row in a shape the refund cannot
      # update, so `RateLimit.refund/3` raises.
      supervisor =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, _start_child} ->
              :ets.insert(RateLimit, {{node_key, index}, :not_a_count, 0})
              GenServer.reply(from, {:error, :max_children})
          end
        end)

      on_exit(fn -> :ets.delete(RateLimit, {node_key, index}) end)
      ip = v4()

      log =
        capture_log(fn ->
          assert CrawlerVerification.check(:google, ip, [task_supervisor: supervisor] ++ opts) ==
                   {:unverified, :skipped}
        end)

      assert :ets.lookup(InFlight.table(), ip) == []
      assert_receive {:telemetry, @skipped, %{count: 1}, %{engine: :google, reason: :busy}}
      assert log =~ "could not refund a rate-limit charge"
      refute log =~ inspect(ip)
    end
  end

  describe "rate caps" do
    test "an IPv4 /24 is capped", %{opts: opts} do
      attach(@skipped)
      opts = Keyword.put(opts, :prefix_lookups_per_minute, inet: [{24, 2}, {16, 100}])
      {a, b, c, _} = v4()
      [first, second, third] = for d <- [1, 2, 3], do: fresh({a, b, c, d})

      assert CrawlerVerification.check(:google, first, opts) == {:unverified, :pending}
      assert CrawlerVerification.check(:google, second, opts) == {:unverified, :pending}
      assert CrawlerVerification.check(:google, third, opts) == {:unverified, :skipped}
      assert_receive {:telemetry, @skipped, _, %{engine: :google, reason: :rate_limited}}
      assert :ets.lookup(InFlight.table(), third) == []
      assert Stub.calls(:ptr, third) == 0
    end

    test "an IPv4 /16 is capped across its /24s", %{opts: opts} do
      opts = Keyword.put(opts, :prefix_lookups_per_minute, inet: [{24, 100}, {16, 2}])
      ips = for _ <- 1..3, do: v4_own_24()
      assert length(Enum.uniq_by(ips, fn {_, _, c, _} -> c end)) == 3

      assert Enum.map(ips, &CrawlerVerification.check(:google, &1, opts)) == [
               {:unverified, :pending},
               {:unverified, :pending},
               {:unverified, :skipped}
             ]
    end

    test "rotating /64s inside one /48 hits the /48's cap", %{opts: opts} do
      opts =
        Keyword.put(opts, :prefix_lookups_per_minute, inet6: [{64, 100}, {48, 3}, {32, 100}])

      ips = for _ <- 1..4, do: v6()
      assert length(Enum.uniq_by(ips, fn ip -> elem(ip, 3) end)) == 4

      assert Enum.map(ips, &CrawlerVerification.check(:google, &1, opts)) == [
               {:unverified, :pending},
               {:unverified, :pending},
               {:unverified, :pending},
               {:unverified, :skipped}
             ]
    end

    test "the node has a cap of its own", %{opts: opts} do
      opts = Keyword.put(opts, :lookups_per_minute, 2)

      assert Enum.map([v4(), v6(), v4()], &CrawlerVerification.check(:google, &1, opts)) == [
               {:unverified, :pending},
               {:unverified, :pending},
               {:unverified, :skipped}
             ]
    end
  end

  describe "a lookup is bounded at three queries" do
    test "one PTR query and at most two forward queries", %{opts: opts} do
      ip = v4()
      [a, b, c] = for _ <- 1..3, do: unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, ["unrelated.example.com", a, b, c])
      for host <- [a, b, c], do: Stub.put_addresses(host, [{66, 249, 0, 1}])

      assert CrawlerVerification.verify(:google, ip, opts) == {:rejected, :forward_mismatch}
      assert Stub.calls(:ptr, ip) == 1
      assert Stub.calls(:addresses, "unrelated.example.com") == 0
      assert Stub.calls(:addresses, a) == 1
      assert Stub.calls(:addresses, b) == 1
      assert Stub.calls(:addresses, c) == 0
    end

    test "only the first three names are read, and two are confirmed", %{opts: opts} do
      ip = v4()
      [a, b, c] = for _ <- 1..3, do: unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, ["one.example.com", "two.example.com", a, b, c])
      for host <- [a, b, c], do: Stub.put_addresses(host, [ip])

      assert {:verified, ^a} = CrawlerVerification.verify(:google, ip, opts)
      assert Stub.calls(:addresses, b) == 0

      many = v4()
      [x, y, z] = for _ <- 1..3, do: unique_host("crawl.googlebot.com")
      Stub.put_ptr(many, [x, y, z, unique_host("crawl.googlebot.com")])
      for host <- [x, y, z], do: Stub.put_addresses(host, [{66, 249, 0, 1}])

      assert CrawlerVerification.verify(:google, many, opts) == {:rejected, :forward_mismatch}
      total = 1 + Enum.sum(for host <- [x, y, z], do: Stub.calls(:addresses, host))
      assert total == 3
      assert Stub.calls(:addresses, z) == 0
    end

    test "a name already proven by another is not looked up again", %{opts: opts} do
      ip = v4()
      [a, b] = for _ <- 1..2, do: unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [a, b])
      for host <- [a, b], do: Stub.put_addresses(host, [ip])

      assert {:verified, ^a} = CrawlerVerification.verify(:google, ip, opts)
      assert Stub.calls(:addresses, b) == 0
    end

    test "one address with names from two engines serves both from one lookup", %{opts: opts} do
      ip = v4()
      google = unique_host("crawl.googlebot.com")
      bing = unique_host("msnbot.search.msn.com")
      Stub.put_ptr(ip, [google, bing])
      Stub.put_addresses(google, [ip])
      Stub.put_addresses(bing, [ip])

      assert settle(:google, ip, opts) == :verified
      assert CrawlerVerification.check(:bing, ip, opts) == :verified
      assert Stub.calls(:ptr, ip) == 1
    end
  end

  describe "no lookup is made" do
    test "for an address that is not public unicast", %{opts: opts} do
      for ip <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {192, 168, 1, 1},
            {100, 64, 0, 1},
            {169, 254, 1, 1},
            {0, 0, 0, 0},
            {224, 0, 0, 1},
            {255, 255, 255, 255},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
            nil,
            "66.249.66.1"
          ] do
        assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :not_public},
               inspect(ip)

        assert Stub.calls(:ptr, ip) == 0, inspect(ip)
      end

      assert CrawlerVerification.verify(:google, nil, opts) == {:error, :invalid_address}
    end

    test "for a request through a forwarding header nothing trusts", %{opts: opts} do
      ip = v4()

      assert CrawlerVerification.check(:google, ip, [forwarded_untrusted?: true] ++ opts) ==
               {:unverified, :not_public}

      assert Stub.calls(:ptr, ip) == 0
    end

    test "for a trusted proxy's address", %{opts: opts} do
      {a, b, c, _} = ip = v4()
      previous = Application.get_env(:kiln_cms, :trusted_proxies)
      Application.put_env(:kiln_cms, :trusted_proxies, ["#{a}.#{b}.#{c}.0/24"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :trusted_proxies, previous),
          else: Application.delete_env(:kiln_cms, :trusted_proxies)
      end)

      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :not_public}
      assert Stub.calls(:ptr, ip) == 0
    end

    test "for DuckDuckBot with no fresh list, since it publishes no reverse-DNS domain",
         %{opts: opts} do
      ip = v4()

      assert CrawlerVerification.check(:duckduckgo, ip, opts) == {:unverified, :unverifiable}
      assert CrawlerVerification.check(:altavista, ip, opts) == {:unverified, :unverifiable}
      assert CrawlerVerification.verify(:duckduckgo, ip, opts) == {:error, :unverifiable}
      assert Stub.calls(:ptr, ip) == 0
    end

    test "when verification is off", %{opts: opts} do
      ip = v4()
      CrawlerVerification.put_result(:google, ip, :verified)

      assert CrawlerVerification.enabled?()
      assert CrawlerVerification.check(:google, ip, [enabled: false] ++ opts) == :disabled
      assert CrawlerVerification.check(:duckduckgo, ip, [enabled: false] ++ opts) == :disabled
      assert CrawlerVerification.check(:google, v4(), [enabled: false] ++ opts) == :disabled
    end
  end

  describe "published IP ranges (#2586)" do
    # Clear of every vendor's real list and of `PublicAddress`, whose
    # addresses the DNS cases below use.
    @range_v4 "45.143.200.0/24"
    @range_v6 "2a01:4f8:1::/48"

    setup do
      Ranges.clear()
      on_exit(&Ranges.clear/0)
    end

    test "DuckDuckBot inside a fresh list is verified, with no DNS lookup", %{opts: opts} do
      Ranges.put_fixture(:duckduckgo, [@range_v4, @range_v6])
      ip = fresh({45, 143, 200, 7})
      ip6 = fresh({0x2A01, 0x4F8, 1, 2, 0, 0, 0, 7})

      assert CrawlerVerification.check(:duckduckgo, ip, opts) == :verified
      assert CrawlerVerification.check(:duckduckgo, ip6, opts) == :verified
      assert Stub.calls(:ptr, ip) == 0
      assert Stub.calls(:ptr, ip6) == 0
    end

    # #2852: a list can lag the vendor's newest crawler, so an address outside
    # it is evidence against the claim, never a proof.
    test "DuckDuckBot outside a fresh list is not listed: no lookup, no cache write, no mark",
         %{opts: opts} do
      previous = Application.get_env(:kiln_cms, :scanner_blocking)
      Application.put_env(:kiln_cms, :scanner_blocking, enabled: true)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :scanner_blocking, previous),
          else: Application.delete_env(:kiln_cms, :scanner_blocking)
      end)

      Ranges.put_fixture(:duckduckgo, [@range_v4, @range_v6])
      ip = v4()
      ip6 = fresh({0x2A01, 0x4F8, 9, 2, 0, 0, 0, 7})
      CrawlerVerification.forget_listing(ip)
      CrawlerVerification.forget_listing(ip6)
      CrawlerVerification.forget_network(ip6)

      for address <- [ip, ip6] do
        assert CrawlerVerification.check(:duckduckgo, address, opts) ==
                 {:unverified, :not_listed}

        assert Stub.calls(:ptr, address) == 0
        assert {:ok, nil} = Cachex.get(CrawlerVerification.cache_name(), address)
        assert {:ok, nil} = Cachex.get(CrawlerVerification.verified_cache_name(), address)
        assert CrawlerVerification.first_seen(:duckduckgo, address) == nil
      end

      refute CrawlerVerification.network_flagged?(ip6, opts)
    end

    test "an IPv4-mapped address outside DuckDuckGo's list is the IPv4 client, not listed",
         %{opts: opts} do
      Ranges.put_fixture(:duckduckgo, [@range_v4])
      {a, b, c, d} = v4()
      mapped = {0, 0, 0, 0, 0, 0xFFFF, Bitwise.bsl(a, 8) + b, Bitwise.bsl(c, 8) + d}

      assert CrawlerVerification.check(:duckduckgo, mapped, opts) == {:unverified, :not_listed}
    end

    test "Google, Bing and Apple outside their fresh lists still go to DNS", %{opts: opts} do
      for engine <- [:google, :bing, :apple] do
        Ranges.put_fixture(engine, [@range_v4])
        ip = v4()

        assert CrawlerVerification.check(engine, ip, opts) == {:unverified, :pending}
        assert settle(engine, ip, opts) == {:unverified, :failed}
        assert Stub.calls(:ptr, ip) == 1
      end
    end

    test "DuckDuckBot over IPv6 is unverifiable when its list holds no IPv6 range",
         %{opts: opts} do
      Ranges.put_fixture(:duckduckgo, [@range_v4])
      ip6 = fresh({0x2A01, 0x4F8, 9, 2, 0, 0, 0, 7})

      assert CrawlerVerification.check(:duckduckgo, ip6, opts) == {:unverified, :unverifiable}
    end

    test "a stale list never verifies and never fails anything", %{opts: opts} do
      max_age = Ranges.config()[:max_age_ms]
      Ranges.put_fixture(:duckduckgo, [@range_v4], age_ms: max_age + 1)
      Ranges.put_fixture(:google, [@range_v4], age_ms: max_age + 1)
      ip = fresh({45, 143, 200, 8})

      assert CrawlerVerification.check(:duckduckgo, ip, opts) == {:unverified, :unverifiable}
      assert CrawlerVerification.check(:duckduckgo, v4(), opts) == {:unverified, :unverifiable}

      # Google falls back to DNS, where this address has no PTR record.
      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
      assert settle(:google, ip, opts) == {:unverified, :failed}
      assert Stub.calls(:ptr, ip) == 1
    end

    test "Google inside a fresh list is verified with no lookup and no rate-cap charge",
         %{opts: opts} do
      Ranges.put_fixture(:google, [@range_v4])
      opts = [lookups_per_minute: 1] ++ opts

      for d <- 10..20 do
        ip = fresh({45, 143, 200, d})
        assert CrawlerVerification.check(:google, ip, opts) == :verified
        assert Stub.calls(:ptr, ip) == 0
      end

      # The node's one lookup a minute is still unspent.
      assert CrawlerVerification.check(:google, v4(), opts) == {:unverified, :pending}
      assert CrawlerVerification.check(:google, v4(), opts) == {:unverified, :skipped}
    end

    test "a spoofed Googlebot outside a fresh list goes to DNS, never verified by ranges",
         %{opts: opts} do
      Ranges.put_fixture(:google, [@range_v4])
      ip = v4()

      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
      assert settle(:google, ip, opts) == {:unverified, :failed}
      assert Stub.calls(:ptr, ip) == 1
    end

    test "a real Googlebot the list does not name yet is still verified by DNS",
         %{opts: opts} do
      Ranges.put_fixture(:google, [@range_v4])
      ip = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [ip])

      assert settle(:google, ip, opts) == :verified
    end

    test "an address inside a list is not public through untrusted forwarding or a trusted proxy",
         %{opts: opts} do
      Ranges.put_fixture(:duckduckgo, [@range_v4])
      Ranges.put_fixture(:google, [@range_v4])
      ip = fresh({45, 143, 200, 30})

      for engine <- [:duckduckgo, :google] do
        assert CrawlerVerification.check(engine, ip, [forwarded_untrusted?: true] ++ opts) ==
                 {:unverified, :not_public}
      end

      previous = Application.get_env(:kiln_cms, :trusted_proxies)
      Application.put_env(:kiln_cms, :trusted_proxies, ["45.143.200.30/32"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :trusted_proxies, previous),
          else: Application.delete_env(:kiln_cms, :trusted_proxies)
      end)

      assert CrawlerVerification.check(:duckduckgo, ip, opts) == {:unverified, :not_public}
      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :not_public}
      assert Stub.calls(:ptr, ip) == 0
    end

    test "with ranges off, the lists are not read", %{opts: opts} do
      Ranges.put_fixture(:duckduckgo, [@range_v4])
      Ranges.put_fixture(:google, [@range_v4])
      ip = fresh({45, 143, 200, 40})
      opts = [ranges: [enabled: false]] ++ opts

      assert CrawlerVerification.check(:duckduckgo, ip, opts) == {:unverified, :unverifiable}
      assert CrawlerVerification.check(:duckduckgo, v4(), opts) == {:unverified, :unverifiable}
      assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :pending}
    end

    test "with verification off, nothing is checked", %{opts: opts} do
      Ranges.put_fixture(:duckduckgo, [@range_v4])

      assert CrawlerVerification.check(:duckduckgo, v4(), [enabled: false] ++ opts) == :disabled
    end
  end

  describe "listing_overdue?/3 (#2852)" do
    @range_v4 "45.143.200.0/24"
    @range_v6 "2a01:4f8:1::/48"

    # `now` (monotonic) and `wall` are read together, and the list is
    # installed at `now`: with both seams passed, the list was fetched at
    # exactly `wall` by this node's wall clock.
    setup %{opts: opts} do
      Ranges.clear()
      on_exit(&Ranges.clear/0)
      now = now()
      wall = System.system_time(:millisecond)
      Ranges.put_fixture(:duckduckgo, [@range_v4, @range_v6], now: now)

      %{grace: :timer.hours(24), now: now, wall: wall, at: [now: now, system_now: wall] ++ opts}
    end

    test "the first question records the sighting in the database and answers false",
         %{at: at} do
      ip = listed_out()

      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      assert {first_seen, ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert_in_delta first_seen, System.system_time(:millisecond), :timer.minutes(1)
      assert_in_delta ttl, :timer.hours(48), :timer.minutes(1)
      assert {^first_seen, _refresh_at} = CrawlerVerification.cached_first_seen(:duckduckgo, ip)
    end

    test "only a list fetched a full grace after the first sighting is believed",
         %{at: at, grace: grace, wall: wall} do
      ip = listed_out()

      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace + 1)
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)

      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace)
      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
    end

    # The restart the node-local sighting could not survive: a deploy, a
    # restart or a new node every few hours kept the grace from ever running
    # out.
    test "a restart or another node keeps the grace: the database's sighting decides",
         %{at: at, grace: grace, now: now, wall: wall} do
      ip = listed_out()
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      assert {first_seen, _ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)

      # A day and a minute on, this node restarted: its copy is gone. The
      # list was refetched then, and still does not name the client.
      Cachex.clear(CrawlerVerification.listing_cache_name())
      later = [now: now, system_now: wall + grace + :timer.minutes(1)] ++ at
      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, later)

      # A node that never saw the client counts it from the same moment.
      other = :"cv-listing-#{System.unique_integer([:positive])}"
      start_supervised!({Cachex, name: other})

      assert CrawlerVerification.listing_overdue?(
               :duckduckgo,
               ip,
               [listing_cache: other] ++ later
             )

      assert {^first_seen, _ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
    end

    test "a sighting is never moved by a later question",
         %{at: at, grace: grace, wall: wall} do
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace - 5)

      # Each question reaches the database: this node's copy is dropped first.
      for _ <- 1..3 do
        Cachex.clear(CrawlerVerification.listing_cache_name())
        assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      end

      assert {first_seen, _ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert first_seen == wall - grace - 5
    end

    test "a lapsed sighting the prune has not reached yet starts again",
         %{at: at, grace: grace, wall: wall} do
      ip = listed_out()

      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace - 5,
        listing_ttl_ms: -1_000
      )

      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      assert {first_seen, ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert first_seen > wall - grace
      assert ttl > :timer.hours(47)
    end

    test "a refresh moves the sighting's expiry on", %{at: at, grace: grace, wall: wall} do
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace, listing_ttl_ms: 60_000)
      assert {_at, short} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert short <= 60_000

      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      assert {_at, ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert ttl > :timer.hours(47)
    end

    test "this node's copy answers until it is due a refresh, then the database does",
         %{at: at, grace: grace, now: now, wall: wall} do
      ip = listed_out()
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)

      # The database moves the sighting back a day behind this node's back.
      {a, b, c, d} = ip
      CrawlerSightingStore.put("inet:#{a}.#{b}.#{c}.#{d}", :duckduckgo, wall - grace, 60_000)

      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)

      # `:listing_refresh_ms`, by default.
      refresh = :timer.minutes(5)
      due = [now: now + refresh, system_now: wall + refresh] ++ at
      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, due)
    end

    test "with the database unavailable, this node's copy decides, else not overdue",
         %{at: at, grace: grace, now: now, wall: wall} do
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace)

      # No copy here, and a process the database will not serve.
      capture_log(fn ->
        refute without_database(fn ->
                 CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
               end)
      end)

      assert CrawlerVerification.cached_first_seen(:duckduckgo, ip) == nil

      # `:listing_retry_ms` on, by default, the database answers.
      retry = :timer.seconds(30)
      later = [now: now + retry, system_now: wall + retry] ++ at
      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, later)

      # The copy is due a refresh the database cannot give: it still answers.
      # `:listing_refresh_ms`, by default.
      refresh = :timer.minutes(5)
      due = [now: now + retry + refresh, system_now: wall + retry + refresh] ++ at

      capture_log(fn ->
        assert without_database(fn ->
                 CrawlerVerification.listing_overdue?(:duckduckgo, ip, due)
               end)
      end)
    end

    test "an unanswered question is logged at most once a minute, naming no client, and emitted",
         %{at: at, now: now} do
      CrawlerVerification.reset_warnings()
      on_exit(&CrawlerVerification.reset_warnings/0)
      attach(@sighting_unavailable)
      [first, second, third] = for _ <- 1..3, do: listed_out()

      log =
        capture_log(fn ->
          refute without_database(fn ->
                   CrawlerVerification.listing_overdue?(:duckduckgo, first, at)
                 end)
        end)

      assert log =~ "[error]"
      assert log =~ "Crawler sighting store unavailable"
      # The database error's own message, and nothing naming the client.
      assert log =~ "cannot find ownership process"
      refute_names_client(log, first)

      assert_receive {:telemetry, @sighting_unavailable, %{count: 1},
                      %{engine: :duckduckgo, reason: :ownership} = metadata}

      assert Map.keys(metadata) |> Enum.sort() == [:engine, :reason]

      # Another client a second short of a minute on: emitted, not logged.
      quiet =
        capture_log(fn ->
          refute without_database(fn ->
                   CrawlerVerification.listing_overdue?(
                     :duckduckgo,
                     second,
                     [now: now + 59_999] ++ at
                   )
                 end)
        end)

      refute quiet =~ "Crawler sighting store unavailable"
      assert_receive {:telemetry, @sighting_unavailable, %{count: 1}, %{reason: :ownership}}

      # A minute on, logged again.
      loud =
        capture_log(fn ->
          refute without_database(fn ->
                   CrawlerVerification.listing_overdue?(
                     :duckduckgo,
                     third,
                     [now: now + 60_000] ++ at
                   )
                 end)
        end)

      assert loud =~ "Crawler sighting store unavailable"
      refute_names_client(loud, third)
    end

    # The database is available to this test process again: a question
    # that reached it would move the sighting's short expiry to 48 h, and
    # find the sighting overdue.
    test "with no copy, an unanswered question is not asked again until the retry",
         %{at: at, grace: grace, now: now, wall: wall} do
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace, listing_ttl_ms: 60_000)

      capture_log(fn ->
        refute without_database(fn ->
                 CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
               end)
      end)

      retry = :timer.seconds(30)
      at_ms = fn ms -> [now: now + ms, system_now: wall + ms] ++ at end
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at_ms.(retry - 1))
      assert {_at, ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert ttl <= 60_000

      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at_ms.(retry))
      assert {_at, ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert ttl > :timer.hours(47)
    end

    test "with a copy, an unanswered refresh keeps the copy and waits for the retry",
         %{at: at, grace: grace, now: now, wall: wall} do
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace + 1)
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      assert {first_seen, _refresh_at} = CrawlerVerification.cached_first_seen(:duckduckgo, ip)

      # The database moves the sighting back behind this node's back.
      {a, b, c, d} = ip
      CrawlerSightingStore.put("inet:#{a}.#{b}.#{c}.#{d}", :duckduckgo, wall - grace, 60_000)

      # `:listing_refresh_ms` and `:listing_retry_ms`, by default.
      refresh = :timer.minutes(5)
      retry = :timer.seconds(30)
      at_ms = fn ms -> [now: now + ms, system_now: wall + ms] ++ at end

      capture_log(fn ->
        refute without_database(fn ->
                 CrawlerVerification.listing_overdue?(:duckduckgo, ip, at_ms.(refresh))
               end)
      end)

      assert CrawlerVerification.cached_first_seen(:duckduckgo, ip) ==
               {first_seen, now + refresh + retry}

      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at_ms.(refresh + retry - 1))
      assert {_at, ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert ttl <= 60_000

      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at_ms.(refresh + retry))
    end

    test "inside a transaction nothing is recorded and the claim is not overdue",
         %{at: at, grace: grace, wall: wall} do
      CrawlerVerification.reset_warnings()
      on_exit(&CrawlerVerification.reset_warnings/0)
      attach(@sighting_unavailable)
      ip = listed_out()

      log =
        capture_log(fn ->
          assert {:ok, false} =
                   KilnCMS.Repo.transaction(fn ->
                     CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
                   end)
        end)

      assert CrawlerVerification.first_seen(:duckduckgo, ip) == nil
      # Nothing is wrong with the store: no log, no event, no retry marker.
      refute log =~ "Crawler sighting store unavailable"
      refute_received {:telemetry, @sighting_unavailable, _, _}
      {a, b, c, d} = ip

      assert Cachex.get(
               CrawlerVerification.listing_cache_name(),
               {:duckduckgo, {:inet, a, b, c, d}}
             ) ==
               {:ok, nil}

      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace)

      assert {:ok, false} =
               KilnCMS.Repo.transaction(fn ->
                 CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
               end)
    end

    test "a real DuckDuckBot the list names after its grace is verified, never overdue",
         %{opts: opts, at: at, grace: grace, now: now, wall: wall} do
      Ranges.clear()
      Ranges.put_fixture(:duckduckgo, [@range_v4], now: now - 10)
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace - 100)
      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)

      {a, b, c, _d} = ip
      Ranges.put_fixture(:duckduckgo, [@range_v4, "#{a}.#{b}.#{c}.0/24"], now: now)

      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      assert CrawlerVerification.check(:duckduckgo, ip, opts) == :verified
    end

    test "a stale list is never overdue, and a list that goes stale mid-grace keeps the " <>
           "first sighting",
         %{at: at, grace: grace, now: now, wall: wall} do
      max_age = Ranges.config()[:max_age_ms]
      Ranges.clear()
      Ranges.put_fixture(:duckduckgo, [@range_v4], now: now, age_ms: max_age + 1)
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace - max_age - 10)

      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      assert {first_seen, _ttl} = CrawlerVerification.first_seen(:duckduckgo, ip)
      assert first_seen == wall - grace - max_age - 10

      Ranges.put_fixture(:duckduckgo, [@range_v4], now: now)
      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
    end

    test "IPv6 addresses in one /64 share a sighting; two IPv4 neighbors do not",
         %{at: at, grace: grace, wall: wall} do
      n = rem(System.unique_integer([:positive]), 0xFFFF)
      first = listed_out({0x2A01, 0x4F8, 9, n, 0, 0, 0, 1})
      rotated = listed_out({0x2A01, 0x4F8, 9, n, 0xAB, 0xCD, 0xEF, 0x12})
      CrawlerVerification.put_first_seen(:duckduckgo, first, wall - grace)

      assert CrawlerVerification.listing_overdue?(:duckduckgo, rotated, at)

      ip = listed_out()
      {a, b, c, d} = ip
      neighbor = listed_out({a, b, c, rem(d + 1, 254) + 1})
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace)

      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      refute CrawlerVerification.listing_overdue?(:duckduckgo, neighbor, at)
    end

    test "the table holds a hash of the client, never its address", %{at: at} do
      ip = listed_out()
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      {a, b, c, d} = ip

      %{rows: rows} =
        KilnCMS.Repo.query!("SELECT key_hash, engine FROM crawler_sightings")

      assert [CrawlerSightingStore.key_hash("inet:#{a}.#{b}.#{c}.#{d}"), "duckduckgo"] in rows
      # A plain SHA-256 of an IPv4 key is reversible by hashing every address (#3501).
      refute [:crypto.hash(:sha256, "inet:#{a}.#{b}.#{c}.#{d}"), "duckduckgo"] in rows
      refute Enum.any?(rows, fn [hash, _] -> String.contains?(hash, "#{a}.#{b}.#{c}.#{d}") end)
    end

    test "an address inside the list, or with no list, records nothing", %{at: at} do
      inside = listed_out({45, 143, 200, 77})
      refute CrawlerVerification.listing_overdue?(:duckduckgo, inside, at)
      assert CrawlerVerification.first_seen(:duckduckgo, inside) == nil

      Ranges.clear()
      ip = listed_out()
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)
      refute CrawlerVerification.listing_overdue?(:duckduckgo, nil, at)
      assert CrawlerVerification.first_seen(:duckduckgo, ip) == nil
    end

    test "with verification off nothing is recorded", %{at: at, grace: grace, wall: wall} do
      ip = listed_out()
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, [enabled: false] ++ at)
      assert CrawlerVerification.first_seen(:duckduckgo, ip) == nil

      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace)
      refute CrawlerVerification.listing_overdue?(:duckduckgo, ip, [enabled: false] ++ at)
    end

    test "a cache that is not running answers false and never raises", %{at: at} do
      name = :"cv-listing-#{System.unique_integer([:positive])}"
      {:ok, pid} = Cachex.start_link(name: name)
      Process.unlink(pid)
      GenServer.stop(pid)

      refute CrawlerVerification.listing_overdue?(
               :duckduckgo,
               listed_out(),
               [listing_cache: name] ++ at
             )
    end

    # The cap bounds this node's copies, not the sightings: an evicted copy is
    # read back from the database, so the grace does not start again.
    test "a copy evicted at the cap costs a database read, never the grace",
         %{at: at, grace: grace, wall: wall} do
      name = :"cv-listing-#{System.unique_integer([:positive])}"

      start_supervised!(
        {Cachex,
         name: name, hooks: [hook(module: Cachex.Limit.Evented, args: {3, [reclaim: 0.5]})]}
      )

      at = [listing_cache: name] ++ at
      ip = listed_out()
      CrawlerVerification.put_first_seen(:duckduckgo, ip, wall - grace, listing_cache: name)
      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)

      # Cachex dates writes to the millisecond and evicts the oldest first; a
      # tie with the newer copies would leave which one goes to chance.
      Process.sleep(5)

      for _ <- 1..4,
          do: refute(CrawlerVerification.listing_overdue?(:duckduckgo, listed_out(), at))

      eventually(fn ->
        CrawlerVerification.cached_first_seen(:duckduckgo, ip, listing_cache: name) == nil
      end)

      assert CrawlerVerification.listing_overdue?(:duckduckgo, ip, at)

      assert {first_seen, _refresh_at} =
               CrawlerVerification.cached_first_seen(:duckduckgo, ip, listing_cache: name)

      assert first_seen == wall - grace
    end
  end

  describe "telemetry" do
    test "a finished lookup reports engine, result and reason, and nothing else",
         %{opts: opts} do
      attach(@lookup)

      verified = v4()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(verified, [host])
      Stub.put_addresses(host, [verified])
      assert settle(:google, verified, opts) == :verified

      assert_receive {:telemetry, @lookup, %{duration: duration},
                      %{engine: :google, result: :verified} = metadata},
                     2_000

      assert is_integer(duration)
      assert metadata |> Map.keys() |> Enum.sort() == [:engine, :reason, :result]
      assert metadata.reason == nil

      assert settle(:bing, v4(), opts) == {:unverified, :failed}

      assert_receive {:telemetry, @lookup, _,
                      %{engine: :bing, result: :rejected, reason: :no_ptr} = rejected},
                     2_000

      assert rejected |> Map.keys() |> Enum.sort() == [:engine, :reason, :result]

      failing = v4()
      Stub.put_ptr(failing, {:error, :servfail})
      assert settle(:apple, failing, opts) == {:unverified, :error}

      assert_receive {:telemetry, @lookup, _,
                      %{engine: :apple, result: :error, reason: :servfail}},
                     2_000

      odd = v4()
      Stub.put_ptr(odd, {:error, {:weird, "203.0.113.9"}})
      assert settle(:baidu, odd, opts) == {:unverified, :error}

      assert_receive {:telemetry, @lookup, _, %{engine: :baidu, result: :error, reason: :other}},
                     2_000

      slow = v4()
      Stub.put_ptr(slow, {:block, self()})
      CrawlerVerification.check(:yandex, slow, Keyword.put(opts, :deadline_ms, 50))

      assert_receive {:telemetry, @lookup, _,
                      %{engine: :yandex, result: :timeout, reason: :timeout}},
                     2_000
    end

    test "a skipped lookup reports engine and reason, and nothing else", %{opts: opts} do
      attach(@skipped)
      opts = Keyword.put(opts, :lookups_per_minute, 0)

      assert CrawlerVerification.check(:google, v4(), opts) == {:unverified, :skipped}
      assert_receive {:telemetry, @skipped, %{count: 1}, metadata}
      assert metadata == %{engine: :google, reason: :rate_limited}
    end
  end

  describe "resolver_failing?/1 (#2588)" do
    setup %{opts: opts} do
      CrawlerVerification.reset_health()
      on_exit(&CrawlerVerification.reset_health/0)

      canary = v4()
      %{canary: canary, opts: Keyword.put(opts, :canary_address, canary)}
    end

    test "is false after an answered lookup, with no canary", %{opts: opts, canary: canary} do
      assert settle(:google, v4(), opts) == {:unverified, :failed}

      refute CrawlerVerification.resolver_failing?(opts)
      assert Stub.calls(:ptr, canary) == 0
    end

    test "with no recent answer, starts one canary a window and stays false while it runs",
         %{opts: opts, canary: canary} do
      Stub.put_ptr(canary, {:block, self()})

      for _ <- 1..5, do: refute(CrawlerVerification.resolver_failing?(opts))

      assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^canary}, 2_000
      refute_receive {Stub, :blocked, _resolver, _callers, :ptr, ^canary}, 100
      assert Stub.calls(:ptr, canary) == 1
      assert [{{:probe, :canary}, _window}] = :ets.lookup(InFlight.table(), {:probe, :canary})

      Stub.release(resolver)
      eventually(fn -> InFlight.health(:canary) == :healthy end)
      refute CrawlerVerification.resolver_failing?(opts)
    end

    test "a canary that gets no answer turns it true; one that answers turns it false",
         %{opts: opts, canary: canary} do
      opts = Keyword.put(opts, :health_window_ms, 50)
      Stub.put_ptr(canary, {:error, :timeout})

      eventually(fn -> CrawlerVerification.resolver_failing?(opts) end)

      Stub.put_ptr(canary, [])
      eventually(fn -> not CrawlerVerification.resolver_failing?(opts) end)
    end

    test "the canary runs with every lookup slot busy and no lookup budget, and charges nothing",
         %{opts: opts, canary: canary} do
      supervisor = start_supervised!({Task.Supervisor, max_children: 1})
      busy = v4()
      Stub.put_ptr(busy, {:block, self()})

      opts = Keyword.merge(opts, task_supervisor: supervisor, lookups_per_minute: 1)
      assert CrawlerVerification.check(:google, busy, opts) == {:unverified, :pending}
      assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^busy}, 2_000
      before = spent(canary, opts)

      Stub.put_ptr(canary, {:error, :timeout})
      eventually(fn -> CrawlerVerification.resolver_failing?(opts) end)
      assert Stub.calls(:ptr, canary) == 1
      assert spent(canary, opts) == before

      Stub.release(resolver)
    end

    test "a canary that cannot start leaves the last verdict, healthy by default",
         %{opts: opts, canary: canary} do
      opts = Keyword.put(opts, :canary_supervisor, :"no-such-canary-supervisor")

      refute CrawlerVerification.resolver_failing?(opts)
      assert Stub.calls(:ptr, canary) == 0
    end

    test "with verification off, is false and asks nothing", %{opts: opts, canary: canary} do
      refute CrawlerVerification.resolver_failing?([enabled: false] ++ opts)
      assert Stub.calls(:ptr, canary) == 0
    end

    test "reset_latches/0 lets a canary start in the same window again", %{canary: canary} do
      window = 1

      assert InFlight.claim_probe(:canary, window)
      refute InFlight.claim_probe(:canary, window)
      assert InFlight.claim_probe(:canary, window + 1)
      assert [_one_row] = :ets.lookup(InFlight.table(), {:probe, :canary})

      InFlight.reset_latches()
      assert :ets.lookup(InFlight.table(), {:probe, :canary}) == []
      assert InFlight.claim_probe(:canary, window)
      assert Stub.calls(:ptr, canary) == 0
    end
  end

  describe "the consecutive-failure warning" do
    test "names the switch once after enough lookups in a row get no answer",
         %{opts: opts} do
      CrawlerVerification.reset_warnings()
      opts = Keyword.put(opts, :error_warning_after, 3)

      fail = fn ->
        ip = v4()
        Stub.put_ptr(ip, {:error, :timeout})
        assert settle(:google, ip, opts) == {:unverified, :error}
      end

      answered = fn ->
        assert settle(:google, v4(), opts) == {:unverified, :failed}
      end

      quiet =
        capture_log(fn ->
          fail.()
          fail.()
          answered.()
          fail.()
          fail.()
        end)

      refute quiet =~ "KILN_CRAWLER_VERIFICATION"

      loud = capture_log(fn -> for _ <- 1..4, do: fail.() end)
      assert [_once] = Regex.scan(~r/KILN_CRAWLER_VERIFICATION=false/, loud)
      refute loud =~ "66.249."
    end
  end

  # #2838: a finished lookup's own negative evidence marks the address's IPv6
  # /64, which `KilnCMS.Security.ScannerGuard` reads for the claims nothing
  # has proven either way.
  describe "network marks (#2838)" do
    setup %{opts: opts} do
      # Marks are written only while the 404 guard, their one reader, is on.
      previous = Application.get_env(:kiln_cms, :scanner_blocking)
      Application.put_env(:kiln_cms, :scanner_blocking, enabled: true)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :scanner_blocking, previous),
          else: Application.delete_env(:kiln_cms, :scanner_blocking)
      end)

      # A canary of the test's own, so whether the resolver is failing is
      # decided here and not by whatever an earlier test left behind.
      CrawlerVerification.reset_health()
      on_exit(&CrawlerVerification.reset_health/0)
      canary = v4()

      %{opts: Keyword.put(opts, :canary_address, canary), canary: canary}
    end

    test "a failed IPv6 lookup flags its /64, and only its /64", %{opts: opts} do
      ip = marked_v6()

      assert finish(:google, ip, opts) == {:unverified, :failed}

      assert CrawlerVerification.network_flagged?(ip, opts)
      assert CrawlerVerification.network_flagged?(neighbor(ip), opts)
      refute CrawlerVerification.network_flagged?(next_64(ip), opts)
    end

    test "a PTR query with no answer marks it silent: flagged while the resolver answers, " <>
           "not while it fails",
         %{opts: opts, canary: canary} do
      ip = marked_v6()
      Stub.put_ptr(ip, {:error, :timeout})

      assert finish(:google, ip, opts) == {:unverified, :error}

      # Another lookup got an answer: the resolver works.
      assert settle(:google, v4(), opts) == {:unverified, :failed}
      refute CrawlerVerification.resolver_failing?(opts)
      assert CrawlerVerification.network_flagged?(neighbor(ip), opts)

      failing = failing_resolver(opts, canary)
      refute CrawlerVerification.network_flagged?(neighbor(ip), failing)
    end

    test "a PTR query with no answer while the resolver fails marks nothing, " <>
           "so the outage leaves no mark behind",
         %{opts: opts, canary: canary} do
      failing = failing_resolver(opts, canary)
      ip = marked_v6()
      Stub.put_ptr(ip, {:error, :timeout})

      assert finish(:google, ip, failing) == {:unverified, :error}
      assert network_mark(ip) == nil

      # The resolver recovers: nothing marked during the outage is read now.
      Stub.put_ptr(canary, [])
      eventually(fn -> not CrawlerVerification.resolver_failing?(failing) end)
      refute CrawlerVerification.network_flagged?(neighbor(ip), opts)
    end

    test "a silent mark never replaces a failed one", %{opts: opts, canary: canary} do
      ip = marked_v6()
      CrawlerVerification.put_network_mark(ip, :failed)

      sibling = neighbor(ip)
      Stub.put_ptr(sibling, {:error, :timeout})
      assert finish(:google, sibling, opts) == {:unverified, :error}

      # A `:silent` mark would not be read while the resolver fails.
      failing = failing_resolver(opts, canary)
      assert CrawlerVerification.network_flagged?(ip, failing)
    end

    test "a forward error in the engine's own zone marks nothing", %{opts: opts} do
      ip = marked_v6()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, {:error, :timeout})

      assert finish(:google, ip, opts) == {:unverified, :forward_error}
      refute CrawlerVerification.network_flagged?(ip, opts)
    end

    test "a verified lookup marks nothing, clears a silent mark, and keeps a failed one",
         %{opts: opts} do
      ip = marked_v6()
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [ip])

      assert finish(:google, ip, opts) == :verified
      refute CrawlerVerification.network_flagged?(ip, opts)

      CrawlerVerification.put_network_mark(ip, :silent)
      assert CrawlerVerification.network_flagged?(ip, opts)
      silent_sibling = neighbor(ip)
      Stub.put_ptr(silent_sibling, [host])
      Stub.put_addresses(host, [silent_sibling])

      assert finish(:google, silent_sibling, opts) == :verified
      assert network_mark(ip) == nil
      refute CrawlerVerification.network_flagged?(ip, opts)

      CrawlerVerification.put_network_mark(ip, :failed)
      failed_sibling = neighbor(ip)
      Stub.put_ptr(failed_sibling, [host])
      Stub.put_addresses(host, [failed_sibling])

      assert finish(:google, failed_sibling, opts) == :verified
      assert network_mark(ip) == :failed
      assert CrawlerVerification.network_flagged?(ip, opts)
    end

    test "a verified lookup with the guard off clears nothing", %{opts: opts} do
      Application.put_env(:kiln_cms, :scanner_blocking, enabled: false)
      ip = marked_v6()
      CrawlerVerification.put_network_mark(ip, :silent)
      host = unique_host("crawl.googlebot.com")
      Stub.put_ptr(ip, [host])
      Stub.put_addresses(host, [ip])

      assert finish(:google, ip, opts) == :verified
      assert network_mark(ip) == :silent
    end

    test "a lookup turned away by a network cap marks nothing", %{opts: opts} do
      opts = Keyword.put(opts, :prefix_lookups_per_minute, inet6: [{64, 1}, {48, 100}])
      first = marked_v6()
      Stub.put_ptr(first, {:block, self()})

      assert CrawlerVerification.check(:google, first, opts) == {:unverified, :pending}
      assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^first}, 2_000

      second = neighbor(first)
      assert CrawlerVerification.check(:google, second, opts) == {:unverified, :skipped}
      refute CrawlerVerification.network_flagged?(second, opts)

      Stub.release(resolver)
      assert settle(:google, first, opts) == {:unverified, :failed}
    end

    for refusal <- [:node_cap, :busy] do
      test "a lookup turned away by #{refusal} marks nothing", %{opts: opts} do
        supervisor = start_supervised!({Task.Supervisor, max_children: 1})

        opts =
          case unquote(refusal) do
            :node_cap -> Keyword.put(opts, :lookups_per_minute, 1)
            :busy -> Keyword.put(opts, :task_supervisor, supervisor)
          end

        blocker = v4()
        Stub.put_ptr(blocker, {:block, self()})
        assert CrawlerVerification.check(:google, blocker, opts) == {:unverified, :pending}
        assert_receive {Stub, :blocked, resolver, _callers, :ptr, ^blocker}, 2_000

        ip = marked_v6()

        capture_log(fn ->
          assert CrawlerVerification.check(:google, ip, opts) == {:unverified, :skipped}
        end)

        refute CrawlerVerification.network_flagged?(ip, opts)

        Stub.release(resolver)
        assert settle(:google, blocker, opts) == {:unverified, :failed}
      end
    end

    test "IPv4 is never marked, nor an IPv4-mapped address", %{opts: opts} do
      {a, b, c, d} = ip = v4()

      assert finish(:google, ip, opts) == {:unverified, :failed}
      refute CrawlerVerification.network_flagged?(ip, opts)
      refute CrawlerVerification.network_flagged?(neighbor(ip), opts)

      assert CrawlerVerification.put_network_mark(ip, :failed) == :ok
      refute CrawlerVerification.network_flagged?(ip, opts)

      mapped = {0, 0, 0, 0, 0, 0xFFFF, a * 256 + b, c * 256 + d}
      refute CrawlerVerification.network_flagged?(mapped, opts)
    end

    test "with the 404 guard off, a failed lookup marks nothing", %{opts: opts} do
      Application.delete_env(:kiln_cms, :scanner_blocking)
      ip = marked_v6()

      assert finish(:google, ip, opts) == {:unverified, :failed}
      refute CrawlerVerification.network_flagged?(ip, opts)
    end

    # ADR 0054: the canary runs only while the 404 guard asks. A lookup with
    # no answer must not start one on an install with the guard off, nor for
    # an IPv4 address, which has no mark to write.
    test "a PTR query with no answer starts no canary with the guard off, nor for IPv4",
         %{opts: opts, canary: canary} do
      Application.delete_env(:kiln_cms, :scanner_blocking)
      ip = marked_v6()
      Stub.put_ptr(ip, {:error, :timeout})
      assert finish(:google, ip, opts) == {:unverified, :error}

      Application.put_env(:kiln_cms, :scanner_blocking, enabled: true)
      v4_ip = v4()
      Stub.put_ptr(v4_ip, {:error, :timeout})
      assert finish(:google, v4_ip, opts) == {:unverified, :error}

      refute_receive {Stub, :blocked, _resolver, _callers, :ptr, ^canary}, 100
      assert Stub.calls(:ptr, canary) == 0
    end

    # Cachex orders eviction by write time in milliseconds: assert the bound,
    # not which mark it dropped.
    test "the mark cache is bounded on its own, and forget_network/1 drops one" do
      max = Application.fetch_env!(:kiln_cms, CrawlerVerification)[:max_network_marks]

      for _ <- 1..(max * 2), do: CrawlerVerification.put_network_mark(PublicAddress.v6(), :failed)

      eventually(fn -> cache_size(CrawlerVerification.network_cache_name()) <= max end)

      ip = marked_v6()
      CrawlerVerification.put_network_mark(ip, :silent)
      assert CrawlerVerification.network_flagged?(ip)
      CrawlerVerification.forget_network(neighbor(ip))
      refute CrawlerVerification.network_flagged?(ip)
    end

    test "a mark is kept for :network_mark_ttl_ms, refreshed by each write" do
      ip = marked_v6()
      CrawlerVerification.put_network_mark(ip, :failed, network_mark_ttl_ms: 1_000)
      assert mark_ttl(ip) <= 1_000

      CrawlerVerification.put_network_mark(ip, :silent)
      assert mark_ttl(ip) > :timer.minutes(59)
      assert CrawlerVerification.network_flagged?(ip)
    end

    test "with verification off, a mark is not read" do
      ip = marked_v6()
      CrawlerVerification.put_network_mark(ip, :failed)

      refute CrawlerVerification.network_flagged?(ip, enabled: false)
    end

    test "with the mark cache down, nothing raises and a lookup still finishes",
         %{opts: opts} do
      attach(@lookup)
      supervisor = KilnCMS.CrawlerVerification.Supervisor
      cache = CrawlerVerification.network_cache_name()
      ip = marked_v6()
      CrawlerVerification.put_network_mark(ip, :failed)

      :ok = Supervisor.terminate_child(supervisor, cache)
      on_exit(fn -> Supervisor.restart_child(supervisor, cache) end)

      refute CrawlerVerification.network_flagged?(ip, opts)
      assert CrawlerVerification.put_network_mark(ip, :failed) == :ok
      assert CrawlerVerification.forget_network(ip) == :ok

      sibling = neighbor(ip)
      assert finish(:google, sibling, opts) == {:unverified, :failed}
      assert_receive {:telemetry, @lookup, _, %{engine: :google, result: :rejected}}, 2_000

      {:ok, _pid} = Supervisor.restart_child(supervisor, cache)
    end
  end

  describe "Engines" do
    test "every engine BotClass can name has a row" do
      assert Engines.engines() == BotClass.engines()
    end

    test "only DuckDuckBot is unverifiable" do
      assert for(engine <- Engines.engines(), not Engines.verifiable?(engine), do: engine) ==
               [:duckduckgo]
    end

    test "Google's user-content and product domains are not crawler domains" do
      refute Engines.matches?(:google, "x.googleusercontent.com")
      refute Engines.matches?(:google, "x.google.com")
      assert Engines.matches?(:google, "crawl-1.geo.googlebot.com")
    end

    test "a regional engine's domain must end the name (#2468)" do
      for {engine, suffix} <- [seznam: "seznam.cz", mojeek: "mojeek.com"] do
        assert Engines.matches?(engine, "crawl-1." <> suffix)
        refute Engines.matches?(engine, "crawl-1.evil" <> suffix)
        refute Engines.matches?(engine, "crawl-1." <> suffix <> ".example.net")
        refute Engines.matches?(:google, "crawl-1." <> suffix)
      end
    end

    test "normalize_host/1 reads plain hostnames only" do
      assert Engines.normalize_host("Crawl-1.GoogleBot.COM.") == "crawl-1.googlebot.com"
      assert Engines.normalize_host(~c"crawl-1.googlebot.com") == "crawl-1.googlebot.com"

      for bad <- [
            "",
            ".",
            "crawl\\.googlebot\\.com",
            "crawl..googlebot.com",
            "crawl googlebot.com",
            <<0xFF, ".googlebot.com">>,
            String.duplicate("a", 64) <> ".googlebot.com",
            [0x100],
            nil
          ] do
        assert Engines.normalize_host(bad) == nil, inspect(bad)
      end
    end
  end

  # ---- helpers ---------------------------------------------------------------

  # Addresses no earlier test in this run has used (`KilnCMS.Test.PublicAddress`:
  # a counter that never wraps, unlike `System.unique_integer/1` modulo a /16).
  defp v4, do: fresh(PublicAddress.v4())

  # A public IPv4 address in a /24 of its own, inside one fixed /16.
  defp v4_own_24, do: fresh(PublicAddress.v4_own_24())

  # Inside Google's crawler /48, each in a /64 of its own.
  defp v6, do: fresh(PublicAddress.v6())

  defp fresh(ip) do
    CrawlerVerification.forget(ip)
    Stub.reset(ip)
    ip
  end

  # Fresh, with no first sighting before or after the test (#2852).
  defp listed_out(ip \\ PublicAddress.v4()) do
    CrawlerVerification.forget_listing(ip)
    on_exit(fn -> CrawlerVerification.forget_listing(ip) end)
    fresh(ip)
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Neither the address nor the digest it is stored under is in `log`.
  defp refute_names_client(log, {a, b, c, d} = ip) do
    refute log =~ :inet.ntoa(ip) |> to_string()
    refute log =~ "inet:"

    for hash <- [
          CrawlerSightingStore.key_hash("inet:#{a}.#{b}.#{c}.#{d}"),
          :crypto.hash(:sha256, "inet:#{a}.#{b}.#{c}.#{d}")
        ] do
      refute log =~ Base.encode16(hash, case: :lower)
      refute log =~ Base.encode16(hash)
    end
  end

  # Runs `fun` in a process with no `$callers`, which the sandbox refuses a
  # connection: the database cannot answer it.
  defp without_database(fun) do
    parent = self()
    ref = make_ref()
    spawn(fn -> send(parent, {ref, fun.()}) end)
    assert_receive {^ref, result}, 5_000
    result
  end

  defp unique_host(template) do
    [first | rest] = String.split(template, ".", parts: 2)
    "#{first}-#{System.unique_integer([:positive])}.#{Enum.join(rest)}"
  end

  # Polls `check/3` until a lookup has settled the claim.
  defp settle(engine, ip, opts) do
    eventually(fn ->
      case CrawlerVerification.check(engine, ip, opts) do
        {:unverified, :pending} -> false
        status -> status
      end
    end)
  end

  defp ttl(cache \\ CrawlerVerification.cache_name(), ip) do
    {:ok, ttl} = Cachex.ttl(cache, ip)
    ttl
  end

  defp cache_size(cache) do
    {:ok, size} = Cachex.size(cache)
    size
  end

  # What each of `ip`'s rate caps has counted in this window, by cap key.
  defp spent(ip, opts) do
    family = if tuple_size(ip) == 4, do: :inet, else: :inet6
    text = ip |> :inet.ntoa() |> to_string()

    networks =
      for {bits, _limit} <- Keyword.get(opts[:prefix_lookups_per_minute] || [], family, []) do
        {:ok, cidr} = Cidr.parse("#{text}/#{bits}")
        Cidr.format(cidr)
      end

    Map.new(networks ++ ["node"], fn key ->
      {key, RateLimit.get("#{opts[:rate_scope]}:#{key}", opts[:rate_window_ms])}
    end)
  end

  defp address(:inet), do: v4()
  defp address(:inet6), do: v6()

  defp other_family(:inet), do: :inet6
  defp other_family(:inet6), do: :inet

  # Another address in `ip`'s /24 (IPv4) or /64 (IPv6), never used before.
  defp neighbor({a, b, c, d}), do: fresh({a, b, c, rem(d + 128, 254) + 1})
  defp neighbor({a, b, c, d, e, f, g, h}), do: fresh({a, b, c, d, e, f, g, h + 0x8000})

  # A fresh IPv6 address whose /64 holds no mark, and none after the test.
  defp marked_v6 do
    ip = v6()
    CrawlerVerification.forget_network(ip)
    on_exit(fn -> CrawlerVerification.forget_network(ip) end)
    ip
  end

  # The first address of the /64 after `ip`'s, inside the same /48.
  defp next_64({a, b, c, d, _e, _f, _g, _h}) do
    ip = fresh({a, b, c, rem(d + 1, 0x10000), 0, 0, 0, 1})
    CrawlerVerification.forget_network(ip)
    ip
  end

  # Settles the claim, then waits for its lookup to release its claim, which
  # it does last: after the result, and after any network mark.
  defp finish(engine, ip, opts) do
    status = settle(engine, ip, opts)
    eventually(fn -> :ets.lookup(InFlight.table(), ip) == [] end)
    status
  end

  # `opts` under which the resolver is failing: no recent answer, and a
  # canary whose PTR query gets none. Starts from no health state: a silent
  # lookup may already have claimed the canary for a 1-minute window, and a
  # window number at 50 ms is not later than that one (monotonic time is
  # negative), so no 50 ms canary would ever start.
  defp failing_resolver(opts, canary) do
    CrawlerVerification.reset_health()
    Stub.put_ptr(canary, {:error, :timeout})
    failing = Keyword.put(opts, :health_window_ms, 50)
    eventually(fn -> CrawlerVerification.resolver_failing?(failing) end)
    failing
  end

  # The raw mark on `ip`'s /64, whether or not `network_flagged?/2` reads it.
  defp network_mark({a, b, c, d, _e, _f, _g, _h}) do
    {:ok, kind} = Cachex.get(CrawlerVerification.network_cache_name(), {:inet6, a, b, c, d})
    kind
  end

  defp mark_ttl({a, b, c, d, _e, _f, _g, _h}) do
    {:ok, ttl} = Cachex.ttl(CrawlerVerification.network_cache_name(), {:inet6, a, b, c, d})
    ttl
  end

  defp assert_error_ttl(ip) do
    assert ttl(ip) <= :timer.minutes(5)
  end

  defp attach(event) do
    test = self()
    id = "crawler-verification-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      event,
      fn name, measurements, metadata, _ ->
        send(test, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
