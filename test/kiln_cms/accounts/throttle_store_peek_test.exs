defmodule KilnCMS.Accounts.ThrottleStorePeekTest do
  @moduledoc """
  `ThrottleStore.peek/3` (#2249): reads the current window and charges
  nothing — the human-verification gate decides on it before the budget that
  admits is spent.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.ThrottleStore

  @window :timer.hours(24 * 365 * 100)

  defp bucket, do: "test:peek:#{System.unique_integer([:positive])}"

  test "reads what hit/5 charged in the current window" do
    b = bucket()
    assert ThrottleStore.peek(b, "k", @window) == 0

    ThrottleStore.hit(b, "k", @window, 100)
    ThrottleStore.hit(b, "k", @window, 100, 2)

    assert ThrottleStore.peek(b, "k", @window) == 3
    assert ThrottleStore.peek(b, "other", @window) == 0
    assert ThrottleStore.peek(bucket(), "k", @window) == 0
  end

  test "charges nothing, however often it is asked" do
    b = bucket()
    ThrottleStore.hit(b, "k", @window, 100)

    for _ <- 1..10, do: ThrottleStore.peek(b, "k", @window)

    assert ThrottleStore.spent(b, "k") == 1
    assert {:allow, 2} = ThrottleStore.hit(b, "k", @window, 100)
  end

  test "reads the current window only, not every window still in the table" do
    b = bucket()

    # A window of one millisecond: each charge below lands in its own window.
    ThrottleStore.hit(b, "k", 1, 100)
    Process.sleep(5)
    ThrottleStore.hit(b, "k", 1, 100)
    Process.sleep(5)

    assert ThrottleStore.spent(b, "k") == 2
    assert ThrottleStore.peek(b, "k", 1) == 0
  end

  describe "refund/3" do
    test "hands back one unit of the current window, never below zero" do
      b = bucket()
      for _ <- 1..3, do: ThrottleStore.hit(b, "k", @window, 100)

      assert ThrottleStore.refund(b, "k", @window) == :ok
      assert ThrottleStore.peek(b, "k", @window) == 2

      for _ <- 1..5, do: ThrottleStore.refund(b, "k", @window)
      assert ThrottleStore.peek(b, "k", @window) == 0

      # Nothing charged yet: nothing to hand back, and nothing created.
      ThrottleStore.refund(bucket(), "k", @window)
      assert ThrottleStore.spent(b, "other") == 0
    end

    test "leaves a closed window alone" do
      b = bucket()
      ThrottleStore.hit(b, "k", 1, 100)
      Process.sleep(5)

      ThrottleStore.refund(b, "k", 1)
      assert ThrottleStore.spent(b, "k") == 1
    end
  end

  test "is allowed inside a transaction, where hit/5 is not" do
    b = bucket()

    assert {:ok, 0} = KilnCMS.Repo.transaction(fn -> ThrottleStore.peek(b, "k", @window) end)
  end
end

defmodule KilnCMS.Accounts.ThrottleStorePeekFallbackTest do
  @moduledoc """
  With the store unreachable, `peek/3` reads the node-local fallback that
  `hit/5` is counting against meanwhile — and never raises. Not a `DataCase`
  for the reason `ThrottleStoreFallbackTest` gives; sync because the fallback
  table is node-wide.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts.ThrottleStore

  @window :timer.hours(24 * 365 * 100)

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)
    :ok
  end

  test "reads the node's own count while the database cannot answer" do
    b = "test:peek-fallback:#{System.unique_integer([:positive])}"

    assert ThrottleStore.peek(b, "k", @window) == 0

    for _ <- 1..3, do: ThrottleStore.hit(b, "k", @window, 100)

    assert ThrottleStore.peek(b, "k", @window) == 3
  end
end
