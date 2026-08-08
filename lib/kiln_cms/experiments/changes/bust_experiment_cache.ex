defmodule KilnCMS.Experiments.Changes.BustExperimentCache do
  @moduledoc """
  Drops the site's cached running-experiment set after any experiment or variant
  write (#499).

  Delivery reads that set on every page request, so without this an experiment
  an editor just started stays invisible until the TTL expires — and, worse, one
  they just concluded keeps serving variants.

  `after_transaction` rather than `after_action`: busting before the commit
  lands would open a window where a concurrent request repopulates the cache
  from the pre-commit state, which is the failure the TTL would then hold for
  five minutes.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} ->
          KilnCMS.Cache.bust_experiments(record.org_id)
          result

        other ->
          other
      end
    end)
  end
end
