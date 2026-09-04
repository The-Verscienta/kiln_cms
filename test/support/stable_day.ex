defmodule KilnCMS.Test.StableDay do
  @moduledoc """
  Clock-edge helpers for tests whose assertions compare two reads of "today"
  (#1358). CI runs at all hours; a test that reads `Date.utc_today/0` twice
  across the action under test disagrees with itself when a run straddles
  UTC midnight — a fails-once, never-reproduces flake.

  Two tools, for the two shapes of the problem:

    * `today/0` — when every date in the test is computed **test-side**
      (seeded buckets, window bounds passed as arguments). One clock read
      per test process, memoized: all later calls return the same day, so
      the test cannot disagree with itself. It says nothing about dates the
      application computes.

    * `stable_day/1` — when the **application** reads the clock too (a
      `:record` action bucketing on its own today, a due date computed
      server-side, a `[yyyy]` slug token). No mock: capture the day, run the
      body, and if the real day still equals the captured one afterwards,
      every read inside — the test's and the app's — saw the same day.
      Otherwise re-run the body exactly once on the new day; midnight cannot
      pass twice in one test.

  A `stable_day/1` body must be safe to run twice: create its fixtures
  inside the function (unique ids/slugs) and scope its assertions to them,
  so a retry never trips over the first attempt's leftovers. Inside the
  body, derive every date from the `day` the function is given — a bare
  `Date.utc_today()` in there re-introduces the second read (`today/0` is
  safe: each attempt re-primes it).
  """

  @key {__MODULE__, :today}

  @doc """
  Today's date, read from the clock once per test process.
  """
  @spec today() :: Date.t()
  def today do
    Process.get(@key) || tap(Date.utc_today(), &Process.put(@key, &1))
  end

  @doc """
  Run `fun` with today's date; re-run it exactly once iff UTC midnight
  passed while it ran. Returns the surviving attempt's result.

  The roll usually surfaces as a *failed assertion* in the first attempt
  (the app wrote the new day, the body compared against the captured one),
  so an `ExUnit.AssertionError` is caught and, **only if the day actually
  rolled**, retried; with the day unchanged it reraises untouched — a real
  failure is never absorbed, and nothing but assertion errors is caught.

  The `clock` argument exists for this module's own test.
  """
  @spec stable_day((Date.t() -> result), (-> Date.t())) :: result when result: var
  def stable_day(fun, clock \\ &Date.utc_today/0) do
    day = clock.()
    Process.put(@key, day)

    try do
      result = fun.(day)
      if clock.() == day, do: result, else: rerun(fun, clock)
    rescue
      error in [ExUnit.AssertionError] ->
        if clock.() == day, do: reraise(error, __STACKTRACE__), else: rerun(fun, clock)
    end
  end

  defp rerun(fun, clock) do
    day = clock.()
    Process.put(@key, day)
    fun.(day)
  end
end
