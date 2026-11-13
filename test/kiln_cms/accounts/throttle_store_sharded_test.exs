defmodule KilnCMS.Accounts.ThrottleStoreShardedTest do
  @moduledoc """
  `ThrottleStore.count_sharded/5` and `window_sum/3` (#2639): a tally spread
  over several rows per key, whose total is the sum of every shard and of the
  unsharded key a node of the previous release writes. Concurrency is
  `ThrottleStoreShardedRaceTest`, below; the latency numbers are
  `ThrottleStoreShardedBenchmarkTest`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Repo
  alias KilnCMS.Test.BudgetWindow

  @shards 8

  defp bucket, do: "test:sharded:#{System.unique_integer([:positive])}"

  defp rows(bucket) do
    %{rows: rows} =
      Repo.query!(
        "SELECT key_hash, count FROM throttle_counters WHERE bucket = $1 ORDER BY key_hash",
        [bucket]
      )

    rows
  end

  test "the key set is the unsharded key, then one key per shard" do
    assert ThrottleStore.sharded_keys("site", 3) == ["site", "site:0", "site:1", "site:2"]
  end

  test "each charge lands on one shard, and returns the total over all of them" do
    b = bucket()
    window = BudgetWindow.fresh_window_ms()

    results =
      for shard <- [0, 3, 3, 7, 0],
          do: ThrottleStore.count_sharded(b, "site", window, @shards, shard: shard)

    assert Enum.map(results, &elem(&1, 0)) == [1, 2, 3, 4, 5]
    assert [idx] = results |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assert Enum.all?(results, &(elem(&1, 2) == :shared))

    hashes = Map.new(rows(b), fn [hash, count] -> {hash, count} end)
    assert map_size(hashes) == 3
    assert hashes[ThrottleStore.key_hash("site:0")] == 2
    assert hashes[ThrottleStore.key_hash("site:3")] == 2
    assert hashes[ThrottleStore.key_hash("site:7")] == 1
    refute Map.has_key?(hashes, ThrottleStore.key_hash("site"))

    assert ThrottleStore.window_sum(b, ThrottleStore.sharded_keys("site", @shards), idx) == 5
  end

  test "an unpinned shard is random, so a run of charges spreads over several rows" do
    b = bucket()
    window = BudgetWindow.fresh_window_ms()

    for _ <- 1..40, do: ThrottleStore.count_sharded(b, "site", window, @shards)

    # 40 draws from 8 shards all landing on one has odds of 8^-39.
    assert length(rows(b)) > 1
    assert ThrottleStore.spent(b, "site") == 0

    assert rows(b) |> Enum.map(&List.last/1) |> Enum.sum() == 40
  end

  test "the total counts the unsharded key a previous release's node wrote mid-window" do
    b = bucket()
    window = BudgetWindow.fresh_window_ms()

    # An old node counts on `count/3`, the unsharded key.
    for _ <- 1..3, do: ThrottleStore.count(b, "site", window)

    assert {4, idx, :shared} = ThrottleStore.count_sharded(b, "site", window, @shards, shard: 5)
    assert {5, ^idx, :shared} = ThrottleStore.count_sharded(b, "site", window, @shards, shard: 1)

    assert ThrottleStore.window_sum(b, ThrottleStore.sharded_keys("site", @shards), idx) == 5
    # Another key's rows and another window are not in it.
    ThrottleStore.count_sharded(b, "other", window, @shards, shard: 5)
    assert ThrottleStore.window_sum(b, ThrottleStore.sharded_keys("site", @shards), idx) == 5

    assert ThrottleStore.window_sum(b, ThrottleStore.sharded_keys("site", @shards), idx - 1) ==
             nil
  end

  test "window_sum is nil, never zero, when nothing was counted" do
    assert ThrottleStore.window_sum(bucket(), ThrottleStore.sharded_keys("site", @shards), 7) ==
             nil
  end

  test "a sharded charge inside a transaction raises, as count/3 does" do
    b = bucket()

    assert_raise ArgumentError, ~r/inside a transaction/, fn ->
      Repo.transaction(fn ->
        ThrottleStore.count_sharded(b, "site", BudgetWindow.fresh_window_ms(), @shards)
      end)
    end

    assert rows(b) == []
  end
end

defmodule KilnCMS.Accounts.ThrottleStoreShardedFallbackTest do
  @moduledoc """
  `count_sharded/5` with no database (#2639): it counts on this node, on the
  unsharded key, so the node's total is one number that climbs. Sync and not a
  `DataCase`, for the reasons `ThrottleStoreFallbackTest` gives.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Test.BudgetWindow

  setup do
    Sandbox.mode(KilnCMS.Repo, :manual)
    :ok
  end

  test "an unreachable store counts on the node, whatever shard each charge drew" do
    b = "test:sharded:fallback:#{System.unique_integer([:positive])}"
    window = BudgetWindow.fresh_window_ms()

    capture_log(fn ->
      results =
        for shard <- 0..11,
            do: ThrottleStore.count_sharded(b, "site", window, 8, shard: rem(shard, 8))

      assert Enum.map(results, &elem(&1, 0)) == Enum.to_list(1..12)
      assert [idx] = results |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      assert idx == div(System.system_time(:millisecond), window)
      assert Enum.all?(results, &(elem(&1, 2) == :local))

      # The same fallback count `count/3` keeps: one node-local total.
      assert {13, ^idx} = ThrottleStore.count(b, "site", window)
    end)
  end

  test "a sum that fails after the charge returns the shard's own count, not a restart" do
    b = "test:sharded:sum:#{System.unique_integer([:positive])}"
    window = BudgetWindow.fresh_window_ms()
    :ok = Sandbox.checkout(KilnCMS.Repo)

    for shard <- [2, 2, 4], do: ThrottleStore.count_sharded(b, "site", window, 8, shard: shard)

    # The connection goes away between the upsert and the sum: the third
    # charge on shard 2 is in the table, the total cannot be read.
    log =
      capture_log(fn ->
        assert {3, _idx, :shared} =
                 ThrottleStore.count_sharded(b, "site", window, 8,
                   shard: 2,
                   after_count: fn -> Sandbox.checkin(KilnCMS.Repo) end
                 )
      end)

    assert log =~ "using the one shard's count"
    # Nothing was counted on the node-local fallback, which restarts at 1.
    refute log =~ "on this node only"
  end
end

defmodule KilnCMS.Accounts.ThrottleStoreShardedRaceTest do
  @moduledoc """
  `count_sharded/5` under concurrency (#2639), on real connections
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`): in the sandbox every caller
  shares one connection and nothing waits on a row lock. Each test's rows are
  deleted on exit.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Repo
  alias KilnCMS.Test.BudgetWindow

  @moduletag :capture_log

  @shards 8

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    bucket = "race:sharded:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Repo.query!("DELETE FROM throttle_counters WHERE bucket = $1", [bucket]) end)
    end)

    %{bucket: bucket, window: BudgetWindow.fresh_window_ms()}
  end

  # The argument the threshold rests on: each call reads the total after its
  # own increment committed, so whichever reads last sees all n. A single
  # statement that upserted and summed (one CTE) would fail this: its
  # snapshot predates its own commit, so concurrent callers can each read a
  # total missing the others' increments, and none reaches n.
  test "n concurrent charges: at least one of them sees a total of n", ctx do
    n = 24

    totals =
      1..n
      |> Enum.map(fn i ->
        Task.async(fn ->
          unboxed(fn ->
            ThrottleStore.count_sharded(ctx.bucket, "site", ctx.window, @shards,
              shard: rem(i, @shards)
            )
          end)
        end)
      end)
      |> Task.await_many(10_000)
      |> Enum.map(&elem(&1, 0))

    assert Enum.max(totals) == n
    assert Enum.all?(totals, &(&1 in 1..n))
  end

  test "a charge on one shard does not wait on a lock held on another", ctx do
    test = self()

    # Shard 0's row exists, and another connection holds it locked.
    unboxed(fn ->
      ThrottleStore.count_sharded(ctx.bucket, "site", ctx.window, @shards, shard: 0)
    end)

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              "SELECT count FROM throttle_counters WHERE bucket = $1 AND key_hash = $2 FOR UPDATE",
              [ctx.bucket, ThrottleStore.key_hash("site:0")]
            )

            send(test, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked, 2_000

    {us, result} =
      :timer.tc(fn ->
        unboxed(fn ->
          ThrottleStore.count_sharded(ctx.bucket, "site", ctx.window, @shards, shard: 3)
        end)
      end)

    # The sum reads shard 0's committed row without waiting on its lock.
    assert {2, _idx, :shared} = result
    assert us < 500_000

    # Shard 0 itself is still blocked behind the holder.
    blocked =
      Task.async(fn ->
        unboxed(fn ->
          ThrottleStore.count_sharded(ctx.bucket, "site", ctx.window, @shards, shard: 0)
        end)
      end)

    assert Task.yield(blocked, 300) == nil

    send(holder.pid, :release)
    Task.await(holder)
    assert {3, _idx, :shared} = Task.await(blocked)
  end
end
