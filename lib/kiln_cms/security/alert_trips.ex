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
  and its window index, with the window's own length as its scale: the entry
  lives until the window it is about closes. The table holds one row per site
  that crossed a threshold in the current window.
  """
  use Hammer, backend: :ets

  @doc """
  Whether this is the first time this node sees `trip` (a term naming the
  threshold, the site and the window index), within a window of `scale` ms.

  `true` when the table is not there (before the supervisor started it): the
  alert gate still keeps the alert to one.
  """
  @spec first?(term(), pos_integer()) :: boolean()
  def first?(trip, scale) when is_integer(scale) and scale > 0 do
    match?({:allow, _count}, hit(trip, scale, 1))
  rescue
    ArgumentError -> true
  end
end
