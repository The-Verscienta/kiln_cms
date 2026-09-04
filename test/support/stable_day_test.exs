defmodule KilnCMS.Test.StableDayTest do
  # The helpers are pure process-local state + an injected clock; no DB.
  use ExUnit.Case, async: true

  alias KilnCMS.Test.StableDay

  # A clock that returns `days` in order, then repeats the last one forever.
  # `Agent.get_and_update`'s fun runs in the agent's process, but the clock
  # closure itself is called from the test process — nothing here captures
  # `self()` inside the agent fun.
  defp clock_returning(days) do
    {:ok, agent} = Agent.start_link(fn -> days end)

    fn ->
      Agent.get_and_update(agent, fn
        [d] -> {d, [d]}
        [d | rest] -> {d, rest}
      end)
    end
  end

  describe "today/0" do
    test "is memoized: later calls return the first read, not a fresh one" do
      # Reach through the memo deliberately: planting a day no real clock
      # returns is the only way to prove later calls read the memo.
      Process.put({StableDay, :today}, ~D[2000-01-01])
      assert StableDay.today() == ~D[2000-01-01]
    end

    test "first call in a process reads the real clock" do
      before = Date.utc_today()
      day = StableDay.today()
      # Bracketed, not `==`: this test must not itself flake at midnight.
      assert day in [before, Date.utc_today()]
    end
  end

  describe "stable_day/2" do
    test "runs the body once when the day holds, passing it that day" do
      clock = clock_returning([~D[2026-01-15]])

      result =
        StableDay.stable_day(
          fn day ->
            send(self(), {:ran, day})
            {:done, day}
          end,
          clock
        )

      assert result == {:done, ~D[2026-01-15]}
      assert_received {:ran, ~D[2026-01-15]}
      refute_received {:ran, _}
    end

    test "re-runs exactly once, on the new day, when midnight passes under the body" do
      clock = clock_returning([~D[2026-01-15], ~D[2026-01-16]])

      result = StableDay.stable_day(fn day -> send(self(), {:ran, day}) && day end, clock)

      assert result == ~D[2026-01-16]
      assert_received {:ran, ~D[2026-01-15]}
      assert_received {:ran, ~D[2026-01-16]}
      refute_received {:ran, _}
    end

    test "an assertion failure with the day rolled is the flake itself: retried once" do
      # The realistic shape: the app wrote the new day mid-body, so the first
      # attempt's assertion raises before stable_day's own clock check runs.
      clock = clock_returning([~D[2026-01-15], ~D[2026-01-16]])

      result =
        StableDay.stable_day(
          fn day ->
            send(self(), {:ran, day})
            assert day == ~D[2026-01-16], "first attempt fails like a mid-body roll"
            :survived
          end,
          clock
        )

      assert result == :survived
      assert_received {:ran, ~D[2026-01-15]}
      assert_received {:ran, ~D[2026-01-16]}
      refute_received {:ran, _}
    end

    test "an assertion failure with the day unchanged is a real failure: reraised" do
      clock = clock_returning([~D[2026-01-15]])

      assert_raise ExUnit.AssertionError, ~r/genuinely broken/, fn ->
        StableDay.stable_day(
          fn day ->
            send(self(), {:ran, day})
            flunk("genuinely broken")
          end,
          clock
        )
      end

      assert_received {:ran, ~D[2026-01-15]}
      refute_received {:ran, _}
    end

    test "non-assertion errors are never absorbed, rolled day or not" do
      clock = clock_returning([~D[2026-01-15], ~D[2026-01-16]])

      assert_raise RuntimeError, "boom", fn ->
        StableDay.stable_day(fn _day -> raise "boom" end, clock)
      end
    end

    test "each attempt re-primes today/0 to its own day" do
      clock = clock_returning([~D[2026-01-15], ~D[2026-01-16]])

      StableDay.stable_day(fn _day -> send(self(), {:memo, StableDay.today()}) end, clock)

      # The retry's body must not see the stale pre-roll memo (or a body
      # calling `today/0` would fail the retry the same way it failed live).
      assert_received {:memo, ~D[2026-01-15]}
      assert_received {:memo, ~D[2026-01-16]}
    end
  end
end
