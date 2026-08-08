defmodule KilnCMS.Analytics.Changes.BustFunnelTargets do
  @moduledoc """
  Drops the site's cached funnel targets after any funnel or funnel-step write
  (#1010).

  A `:funnel_completion` experiment converts on its funnel's **final step**, and
  the reason that goal names a funnel rather than a document is precisely that
  editing the funnel is supposed to move the goal. Without this, it would move
  it only once the cache TTL expired — so an editor who re-ordered a funnel
  would watch conversions land on the old last step for five more minutes, with
  nothing saying why.

  `after_transaction`, and for the same reason
  `KilnCMS.Experiments.Changes.BustExperimentCache` gives: busting before the
  commit lands opens a window where a concurrent request repopulates the cache
  from the pre-commit state, which the TTL would then hold.

  A funnel-step **destroy** matters as much as a create — deleting the last step
  moves the target back to the one before it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} ->
          bust(record, changeset)
          result

        other ->
          other
      end
    end)
  end

  # A destroyed `FunnelStep` still carries its own `org_id`; a destroyed row
  # reached through a funnel cascade does not go through this change at all
  # (the FK deletes it), which is why `Funnel`'s own destroy busts too.
  defp bust(record, changeset) do
    org_id = Map.get(record, :org_id) || changeset.tenant
    if org_id, do: KilnCMS.Cache.bust_funnel_targets(org_id)
    :ok
  end
end
