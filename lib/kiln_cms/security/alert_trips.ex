defmodule KilnCMS.Security.AlertTrips do
  @moduledoc """
  Which alert thresholds this node has already seen crossed (#2639).

  The failed-sign-in tally is sharded (`KilnCMS.Accounts.ThrottleStore.count_sharded/5`),
  so the attempt that crosses the threshold is no longer the one whose count
  *equals* it: several concurrent attempts can each read a total at or past
  it, and every attempt after them does too. Each of those would otherwise be
  recorded unsampled and try to claim the window's alert.

  `first?/2` lets one of them through per node and window. Across nodes the
  claim itself is exact: `KilnCMS.Security.AlertGate` keeps one dispatch row
  per site, kind and window, so a second node's crossing finds it taken.

  A Hammer fixed window, started in the supervision tree, keyed on the trip
  and its window index, with a scale of **twice** the window's length. The
  window index in the trip comes from the database clock; Hammer's own window
  is `div(now, scale)` on this node's. With a scale of one window the two are
  aligned end to end, so any skew between the clocks splits each trip's
  window across two Hammer windows at both ends, and the trip is admitted
  again in the second. With two, a Hammer boundary falls at one end of each
  trip window only (its start for an even index, its end for an odd one), so
  a skew can admit a trip a second time at most there. That second admission is one extra
  unsampled event: the `KilnCMS.Security.AlertGate` claim still refuses it.
  The index in the key keeps each trip its own across the longer scale. The
  table holds a row per site that crossed a threshold in the last two windows.
  """
  use Hammer, backend: :ets

  @doc """
  Whether this is the first time this node sees `trip` (a term naming the
  threshold, the site and the window index) whose window is `window_ms` long.

  `true` when the table is not there (before the supervisor started it): the
  alert gate still keeps the alert to one.
  """
  @spec first?(term(), pos_integer()) :: boolean()
  def first?(trip, window_ms) when is_integer(window_ms) and window_ms > 0 do
    match?({:allow, _count}, hit(trip, 2 * window_ms, 1))
  rescue
    ArgumentError -> true
  end
end
