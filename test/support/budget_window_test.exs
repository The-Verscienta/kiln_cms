defmodule KilnCMS.Test.BudgetWindowTest do
  # Pure arithmetic over an injected clock; no Hammer table, no DB.
  use ExUnit.Case, async: true

  import KilnCMS.Test.BudgetWindow

  @hour :timer.hours(1)
  @day :timer.hours(24)

  # Hammer's own key for a window length at `now` (`Hammer.ETS.FixWindow`).
  defp window_number(now, window_ms), do: div(now, window_ms)

  setup do
    %{now: System.system_time(:millisecond)}
  end

  test "each nth is a distinct window", %{now: now} do
    keys = for nth <- 0..3, do: window_number(now, fresh_window_ms(nth, now))
    assert keys == [1_000, 999, 998, 997]
  end

  test "a window opens under a second before now and has days left", %{now: now} do
    for nth <- 0..3 do
      len = fresh_window_ms(nth, now)
      opened = window_number(now, len) * len
      assert now - opened < 1_000
      assert opened + len - now > 19 * @day
    end
  end

  test "a later call with the same nth lands in the same window", %{now: now} do
    later = now + @hour

    for nth <- 0..3 do
      # A length taken at `now`, read an hour on; and a fresh length taken then.
      assert window_number(later, fresh_window_ms(nth, now)) == 1_000 - nth
      assert window_number(later, fresh_window_ms(nth, later)) == 1_000 - nth
    end
  end

  test "a minute window does not have that property, which is the point", %{now: now} do
    # The flake this module exists for: 1 ms before a minute boundary, then
    # 1 ms after it.
    edge = div(now, 60_000) * 60_000 + 60_000
    refute window_number(edge - 1, 60_000) == window_number(edge + 1, 60_000)

    len = fresh_window_ms(0, edge - 1)
    assert window_number(edge - 1, len) == window_number(edge + 1, len)
  end

  test "an nth with no window left is refused" do
    assert_raise FunctionClauseError, fn -> fresh_window_ms(1_000) end
    assert_raise FunctionClauseError, fn -> fresh_window_ms(-1) end
  end
end
