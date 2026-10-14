defmodule KilnCMS.Test.BudgetWindow do
  @moduledoc """
  Window lengths for tests that charge a `KilnCMS.LLM.Budget` (Hammer) bucket
  and then assert on it — a counter read back, or a refusal on the next call.

  Hammer's fixed window keys a bucket on `{key, div(now, window_ms)}`: windows
  are clock-aligned, and the length itself is not in the key. A
  `:timer.minutes(1)` window therefore rolls over mid-test whenever the wall
  clock crosses a minute, and a charge made before the boundary is gone after
  it — the counter reads back 0, the refusal becomes an `:ok`. A wider window
  only makes that rarer, and a single huge one breaks the "next window"
  trick: every large length has quotient 0, so `@w` and `@w + 1` share a
  bucket.

  `fresh_window_ms/1` fixes the quotient instead of the length.
  """

  # Every `fresh_window_ms/1` window is window number `@window_index - nth`.
  @window_index 1_000

  @doc """
  A window length (~20 days) whose current window opened under a second ago,
  so no window boundary can fall inside a test.

  The length is `div(now, @window_index - nth)`, which puts `now` at the very
  start of window number `@window_index - nth`: each `nth` is a distinct,
  empty window — a "next window" without sleeping — and every call with the
  same `nth` lands in the same one, however much time passed between them.

  The `now` argument exists for this module's own test.
  """
  @spec fresh_window_ms(non_neg_integer(), integer()) :: pos_integer()
  def fresh_window_ms(nth \\ 0, now \\ System.system_time(:millisecond))
      when nth in 0..(@window_index - 1)//1,
      do: div(now, @window_index - nth)
end
