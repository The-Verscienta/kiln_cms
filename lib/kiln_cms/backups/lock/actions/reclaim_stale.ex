defmodule KilnCMS.Backups.Lock.Actions.ReclaimStale do
  @moduledoc """
  `KilnCMS.Backups.Lock`'s `:reclaim_stale` action (#2218): free the lock from
  a holder whose node stopped beating (and requeue its step), then from one
  whose step job ended without moving the chain on, then deal with a step
  left in a backup directory's queue no node runs (#2845). See
  `KilnCMS.Backups.Chain.reclaim_stale/0`, `KilnCMS.Backups.Chain.reap/0` and
  `KilnCMS.Backups.Chain.sweep_stranded/0`.

  Returns `%{reclaimed: outcome, reaped: outcome, stranded: outcome}`, each
  `:none` or the outcome and what it acted on.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Backups.Chain

  @impl true
  def run(_input, _opts, _context) do
    with {:ok, reclaimed} <- Chain.reclaim_stale(),
         {:ok, reaped} <- Chain.reap(),
         {:ok, stranded} <- Chain.sweep_stranded() do
      {:ok,
       %{reclaimed: outcome(reclaimed), reaped: outcome(reaped), stranded: outcome(stranded)}}
    end
  end

  defp outcome(:none), do: :none
  defp outcome({outcome, info}), do: Map.put(info, :outcome, outcome)
end
