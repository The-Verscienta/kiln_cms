defmodule KilnCMS.CrawlerVerificationTest do
  @moduledoc """
  `KilnCMS.CrawlerVerification` (#2254) against the DNS stub
  (`KilnCMS.Test.StubCrawlerResolver`).
  """
  # Not async: telemetry handlers see every process's events, the warning
  # latches and the consecutive-failure counter are node-wide, and one test
  # sets `:trusted_proxies` with `Application.put_env/3`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import KilnCMS.Test.Eventually

  alias KilnCMS.BotClass
  alias KilnCMS.CrawlerVerification
  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.InFlight
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.Security.Cidr
  alias KilnCMS.Test.PublicAddress
  alias KilnCMS.Test.StubCrawlerResolver, as: Stub
  alias KilnCMSWeb.RateLimit

  doctest KilnCMS.CrawlerVerification.Engines

  @lookup [:kiln_cms, :crawler_verification, :lookup]
  @skipped [:kiln_cms, :crawler_verification, :skipped]

  setup do
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
          baidu: "baiduspider-1-1.crawl.baidu.jp"
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

    test "DuckDuckBot outside a fresh list is a proven failure", %{opts: opts} do
      Ranges.put_fixture(:duckduckgo, [@range_v4])
      ip = v4()

      assert CrawlerVerification.check(:duckduckgo, ip, opts) == {:unverified, :failed}
      assert Stub.calls(:ptr, ip) == 0
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
