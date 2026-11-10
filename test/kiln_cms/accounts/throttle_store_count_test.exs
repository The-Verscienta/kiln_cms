defmodule KilnCMS.Accounts.ThrottleStoreCountTest do
  @moduledoc """
  `ThrottleStore.count/3` and `window_count/3` (#2245): a tally on the shared
  counter table that never refuses, tells the caller which window it counted
  in, and outlives its window by an hour so a summary can read the total after
  the window closed.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Repo
  alias KilnCMS.Test.BudgetWindow

  defp bucket, do: "test:count:#{System.unique_integer([:positive])}"

  test "counts up in one window, by the database clock, and never refuses" do
    b = bucket()
    window = BudgetWindow.fresh_window_ms()

    results = for _ <- 1..12, do: ThrottleStore.count(b, "site", window)

    assert Enum.map(results, &elem(&1, 0)) == Enum.to_list(1..12)
    assert [index] = results |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    %{rows: [[db_index]]} =
      Repo.query!(
        "SELECT floor(extract(epoch FROM clock_timestamp()) * 1000 / $1::bigint)::bigint",
        [window]
      )

    assert index == db_index
  end

  test "each key and each window has its own count" do
    b = bucket()

    assert {1, idx} = ThrottleStore.count(b, "a", BudgetWindow.fresh_window_ms(0))
    assert {1, _} = ThrottleStore.count(b, "b", BudgetWindow.fresh_window_ms(0))
    assert {2, ^idx} = ThrottleStore.count(b, "a", BudgetWindow.fresh_window_ms(0))
    assert {1, other} = ThrottleStore.count(b, "a", BudgetWindow.fresh_window_ms(1))
    assert other != idx
  end

  test "window_count reads a window's total, and nil for one never counted" do
    b = bucket()
    window = BudgetWindow.fresh_window_ms()

    for _ <- 1..3, do: ThrottleStore.count(b, "site", window)
    {4, idx} = ThrottleStore.count(b, "site", window)

    assert ThrottleStore.window_count(b, "site", idx) == 4
    assert ThrottleStore.window_count(b, "site", idx - 1) == nil
    assert ThrottleStore.window_count(b, "other", idx) == nil
  end

  test "a tally outlives its window by an hour, so the prune keeps a closed window" do
    b = bucket()

    # A 1 ms window has closed by the time the prune runs.
    {1, idx} = ThrottleStore.count(b, "site", 1)
    Process.sleep(5)

    %{rows: [[seconds_left]]} =
      Repo.query!(
        "SELECT extract(epoch FROM expires_at - (clock_timestamp() AT TIME ZONE 'UTC'))::float8 FROM throttle_counters WHERE bucket = $1",
        [b]
      )

    assert seconds_left > 3_500 and seconds_left <= 3_600

    ThrottleStore.prune()
    assert ThrottleStore.window_count(b, "site", idx) == 1
  end

  test "a tally inside a transaction raises, as a charge does" do
    b = bucket()

    assert_raise ArgumentError, ~r/inside a transaction/, fn ->
      Repo.transaction(fn -> ThrottleStore.count(b, "site", BudgetWindow.fresh_window_ms()) end)
    end

    assert ThrottleStore.spent(b, "site") == 0
  end

  test "a window_count inside a transaction is fine: it is a read" do
    b = bucket()
    {1, idx} = ThrottleStore.count(b, "site", BudgetWindow.fresh_window_ms())

    assert {:ok, 1} = Repo.transaction(fn -> ThrottleStore.window_count(b, "site", idx) end)
  end
end

defmodule KilnCMS.Accounts.ThrottleStoreCountFallbackTest do
  @moduledoc """
  `count/3` with no database (#2245): it still counts, on this node, with the
  window index from this node's clock. Sync and not a `DataCase`, for the
  reasons `ThrottleStoreFallbackTest` gives.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Test.BudgetWindow

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)
    :ok
  end

  test "an unreachable store counts on the node and computes the window itself" do
    b = "test:count:fallback:#{System.unique_integer([:positive])}"
    window = BudgetWindow.fresh_window_ms()

    capture_log(fn ->
      assert {1, idx} = ThrottleStore.count(b, "site", window)
      assert {2, ^idx} = ThrottleStore.count(b, "site", window)
      assert idx == div(System.system_time(:millisecond), window)

      # Nothing it can read back without the database.
      assert ThrottleStore.window_count(b, "site", idx) == nil
    end)
  end
end
