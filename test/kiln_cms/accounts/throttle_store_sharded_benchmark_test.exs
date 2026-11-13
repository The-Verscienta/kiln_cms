defmodule KilnCMS.Accounts.ThrottleStoreShardedBenchmarkTest do
  @moduledoc """
  How long one failed sign-in's tally charge takes while 16 or 32 others
  charge the same site at once (#2639). Prints p50 and p99 per shape for the
  PR to record, for the single row `count/3` keeps per site and for the eight
  shards `count_sharded/5` spreads it over. Asserts only that every charge was
  counted.

  Excluded by default (`:benchmark`, `test/test_helper.exs`):

      mix test --only benchmark test/kiln_cms/accounts/throttle_store_sharded_benchmark_test.exs

  Real connections (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`): inside the
  sandbox every writer shares one connection and nothing ever waits on a row
  lock, which is the thing being measured.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Repo
  alias KilnCMS.Test.BudgetWindow

  @moduletag :benchmark
  @moduletag timeout: :timer.minutes(5)

  @charges_per_writer 200
  @shards 8

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    bucket = "bench:fsi:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Repo.query!("DELETE FROM throttle_counters WHERE bucket = $1", [bucket]) end)
    end)

    %{bucket: bucket}
  end

  # Each writer charges `@charges_per_writer` times in a loop; every call is
  # timed on its own.
  defp run(writers, charge) do
    1..writers
    |> Enum.map(fn _ -> Task.async(fn -> writer(charge) end) end)
    |> Task.await_many(:timer.minutes(4))
    |> List.flatten()
    |> Enum.sort()
  end

  defp writer(charge), do: unboxed(fn -> Enum.map(1..@charges_per_writer, &time(charge, &1)) end)

  defp time(charge, _nth) do
    {us, _result} = :timer.tc(charge)
    us
  end

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))

  defp report(label, writers, sorted) do
    ms = &Float.round(&1 / 1000, 2)

    IO.puts(
      "#2639 #{label}, #{writers} writers x #{@charges_per_writer}: " <>
        "p50 #{ms.(percentile(sorted, 0.5))} ms, p99 #{ms.(percentile(sorted, 0.99))} ms"
    )
  end

  for writers <- [16, 32] do
    @writers writers

    test "one row per site, #{writers} concurrent writers", %{bucket: bucket} do
      window = BudgetWindow.fresh_window_ms()
      key = Ecto.UUID.generate()

      sorted = run(@writers, fn -> ThrottleStore.count(bucket, key, window) end)
      report("single row (count/3)", @writers, sorted)

      assert length(sorted) == @writers * @charges_per_writer
      assert unboxed(fn -> ThrottleStore.spent(bucket, key) end) == length(sorted)
    end

    test "eight shards per site, #{writers} concurrent writers", %{bucket: bucket} do
      window = BudgetWindow.fresh_window_ms()
      key = Ecto.UUID.generate()

      sorted =
        run(@writers, fn -> ThrottleStore.count_sharded(bucket, key, window, @shards) end)

      report("8 shards (count_sharded/5)", @writers, sorted)

      assert length(sorted) == @writers * @charges_per_writer

      assert unboxed(fn ->
               {_count, idx, _source} = ThrottleStore.count_sharded(bucket, key, window, @shards)
               ThrottleStore.window_sum(bucket, ThrottleStore.sharded_keys(key, @shards), idx)
             end) == length(sorted) + 1
    end
  end
end
