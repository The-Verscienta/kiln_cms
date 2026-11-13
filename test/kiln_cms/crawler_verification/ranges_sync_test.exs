defmodule KilnCMS.CrawlerVerification.RangesSyncTest do
  @moduledoc """
  Sharing the published crawler range lists across nodes (#2586): what a
  node installs from a peer, what it answers a sync request with, and when it
  queues a fetch of its own. Driven through the callbacks and pure helpers,
  so no second node is needed.
  """
  # Not async: the lists are VM-global, and one test changes the `Ranges`
  # config with `Application.put_env/3`.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.CrawlerVerification.RangesSync
  alias KilnCMS.CrawlerVerification.RangesWorker

  @v4 "45.143.200.0/24"
  @inside_v4 {45, 143, 200, 7}

  setup do
    Ranges.clear()
    on_exit(&Ranges.clear/0)
    :ok
  end

  describe "a list from a peer" do
    test "is installed, dated from this node's clock less its age" do
      now = System.monotonic_time(:millisecond)

      assert RangesSync.install({:crawler_ranges, 1, :duckduckgo, [@v4], 60_000}, now: now) ==
               :installed

      assert Ranges.lookup(:duckduckgo, @inside_v4, now: now) == :in
      assert Ranges.status().duckduckgo.age_ms >= 60_000

      max_age = Ranges.config()[:max_age_ms]
      assert Ranges.lookup(:duckduckgo, @inside_v4, now: now + max_age - 60_000 + 1) == :unknown
    end

    test "arriving through PubSub is installed by the running process" do
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        Ranges.topic(),
        {:crawler_ranges, 1, :bing, [@v4], 0}
      )

      KilnCMS.Test.Eventually.eventually(fn -> Ranges.lookup(:bing, @inside_v4) == :in end)
    end

    test "older than the one installed is ignored" do
      now = System.monotonic_time(:millisecond)
      Ranges.put_fixture(:duckduckgo, [@v4], age_ms: 1_000, now: now)

      assert RangesSync.install(
               {:crawler_ranges, 1, :duckduckgo, ["45.143.202.0/24"], 5_000},
               now: now
             ) == :ignored

      assert Ranges.lookup(:duckduckgo, @inside_v4) == :in
    end

    test "is ignored when malformed, of another version, unsafe, stale or for an engine with no source" do
      max_age = Ranges.config()[:max_age_ms]

      for payload <- [
            {:crawler_ranges, 2, :duckduckgo, [@v4], 0},
            {:crawler_ranges, 0, :duckduckgo, [@v4], 0},
            {:crawler_ranges, 1, :duckduckgo, ["0.0.0.0/0"], 0},
            {:crawler_ranges, 1, :duckduckgo, [@v4, "10.0.0.0/24"], 0},
            {:crawler_ranges, 1, :duckduckgo, [], 0},
            {:crawler_ranges, 1, :duckduckgo, [@v4], -1},
            {:crawler_ranges, 1, :duckduckgo, [@v4], max_age + 1},
            {:crawler_ranges, 1, :duckduckgo, [@v4], "0"},
            {:crawler_ranges, 1, :duckduckgo, @v4, 0},
            {:crawler_ranges, 1, "duckduckgo", [@v4], 0},
            {:crawler_ranges, 1, :yandex, [@v4], 0},
            {:crawler_ranges, 1, :altavista, [@v4], 0},
            {:crawler_ranges, 1, :duckduckgo, [@v4]},
            {:crawler_ranges, :duckduckgo, [@v4], 0, 0, 0},
            :crawler_ranges,
            nil
          ] do
        assert RangesSync.install(payload) == :ignored, inspect(payload)
        assert Ranges.lookup(:duckduckgo, @inside_v4) == :unknown, inspect(payload)
      end
    end

    test "is ignored with ranges off" do
      assert RangesSync.install({:crawler_ranges, 1, :duckduckgo, [@v4], 0}, enabled: false) ==
               :ignored
    end
  end

  describe "a sync request" do
    test "is answered with every fresh list, directly to the requester" do
      Ranges.put_fixture(:duckduckgo, [@v4])
      Ranges.put_fixture(:google, [@v4], age_ms: Ranges.config()[:max_age_ms] + 1)

      assert [{:peer@host, {:crawler_ranges, 1, :duckduckgo, [@v4], _age}}] =
               RangesSync.replies_for(:peer@host)
    end

    test "from this node, or with ranges off, gets no answer" do
      Ranges.put_fixture(:duckduckgo, [@v4])

      assert RangesSync.replies_for(node()) == []
      assert RangesSync.replies_for(:peer@host, enabled: false) == []
    end

    test "is sent when another node connects" do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Ranges.topic())
      me = node()

      assert {:noreply, _state} = RangesSync.handle_info({:nodeup, :peer@host}, state())
      assert_receive {:crawler_ranges_sync, ^me}
    end
  end

  describe "a node with no fresh list" do
    test "queues one fetch at bootstrap" do
      assert {:noreply, _state} = RangesSync.handle_info(:bootstrap, state())
      assert [_one] = all_enqueued(worker: RangesWorker)
    end

    test "queues none at bootstrap when every list is fresh" do
      for engine <- Engines.range_engines(), do: Ranges.put_fixture(engine, [@v4])

      assert {:noreply, _state} = RangesSync.handle_info(:bootstrap, state())
      refute_enqueued(worker: RangesWorker)
    end

    test "queues none at bootstrap with ranges off" do
      assert {:noreply, _state} = RangesSync.handle_info(:bootstrap, state(enabled: false))
      refute_enqueued(worker: RangesWorker)
    end

    test "asks again, queues again and warns once at each check while a list is stale" do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Ranges.topic())

      for engine <- Engines.range_engines() -- [:duckduckgo],
          do: Ranges.put_fixture(engine, [@v4])

      me = node()

      {first, log} = with_log(fn -> RangesSync.tick(state(bootstrap?: true)) end)

      assert log =~ "duckduckgo"
      assert log =~ "KILN_CRAWLER_RANGES=false"
      refute log =~ "google"
      assert_receive {:crawler_ranges_sync, ^me}
      assert [_one] = all_enqueued(worker: RangesWorker)

      {_second, log} = with_log(fn -> RangesSync.tick(first) end)
      refute log =~ "duckduckgo"
      assert_receive {:crawler_ranges_sync, ^me}
    end

    test "queues nothing at a check with bootstrap off, and nothing at all once fresh" do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Ranges.topic())

      capture_log(fn -> RangesSync.tick(state(bootstrap?: false)) end)
      refute_enqueued(worker: RangesWorker)

      for engine <- Engines.range_engines(), do: Ranges.put_fixture(engine, [@v4])
      flush_sync()

      RangesSync.tick(state(bootstrap?: true))
      refute_enqueued(worker: RangesWorker)
      refute_receive {:crawler_ranges_sync, _}, 50
    end
  end

  defp state(opts \\ []), do: %{warned: MapSet.new(), opts: opts}

  defp flush_sync do
    receive do
      {:crawler_ranges_sync, _} -> flush_sync()
    after
      0 -> :ok
    end
  end
end
