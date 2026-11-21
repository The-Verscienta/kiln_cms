defmodule KilnCMS.Billing.Changes.GuardProviderEvent do
  @moduledoc """
  Re-checks, under the membership's row lock, that a provider event is still
  the one to apply (#2749).

  `KilnCMS.Billing.Subscriptions` decides with `KilnCMS.Billing.EventGuard`
  before it writes, on a row it read earlier. Two events for one membership can
  run at once (the `:billing` queue is concurrent), and the later-created one
  can commit between that read and this write, so the verdict is repeated
  against the committed row.

  Declared after `SettleErasedAccount`, so the lock order is the account's
  `users` row and then this one (`KilnCMS.Accounts.AccountLock`, #2774).

  In a `before_action`: it re-reads the row `FOR UPDATE`. If nothing the
  verdict reads has moved since the changeset's row was read, the earlier
  verdict stands. If something has:

    * the event is now superseded: the changeset's attribute changes are
      cleared and it is marked (`ignored?/1`), exactly as an erased account's
      transition is. The action succeeds with no change, and
      `KilnCMS.Billing.Changes.RecordTransition` records, announces and syncs
      nothing. The returned row carries the reason as metadata
      (`Ash.Resource.get_metadata(row, :event_ignored)`), which
      `KilnCMS.Billing.Subscriptions.apply/1` turns into `{:ignored, reason}`;
    * the event still applies, but the changes were built against a row that has
      since changed. `RecordTransition` captured its from-status and lifecycle
      stamps from that row, and Ash drops a change equal to the row it saw, so
      applying them would audit the wrong transition or lose a write. The
      changeset errors, the worker records the failure and Oban retries against
      the fresh row.
  """
  use Ash.Resource.Change

  alias KilnCMS.Billing.Changes.SettleErasedAccount
  alias KilnCMS.Billing.EventGuard

  @read [:status, :provider_subscription_id, :last_provider_event_at]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&recheck/1)
    |> Ash.Changeset.after_action(fn changeset_now, membership ->
      case changeset_now.context[:event_ignored] do
        nil -> {:ok, membership}
        reason -> {:ok, Ash.Resource.put_metadata(membership, :event_ignored, reason)}
      end
    end)
  end

  @doc "Whether the event was settled as a no-op because it was superseded."
  @spec ignored?(Ash.Changeset.t()) :: boolean()
  def ignored?(changeset), do: not is_nil(changeset.context[:event_ignored])

  defp recheck(changeset) do
    kind = Ash.Changeset.get_argument(changeset, :event_kind)

    if is_nil(kind) or SettleErasedAccount.erased?(changeset) do
      changeset
    else
      fresh = lock!(changeset)
      verdict(changeset, fresh, kind)
    end
  end

  defp lock!(changeset) do
    KilnCMS.Billing.get_membership!(changeset.data.id,
      actor: KilnCMS.Billing.system(),
      authorize_with: :error,
      tenant: changeset.tenant || changeset.data.org_id,
      query: [lock: :for_update]
    )
  end

  defp verdict(changeset, fresh, kind) do
    if Map.take(fresh, @read) == Map.take(changeset.data, @read) do
      changeset
    else
      event = %{
        kind: kind,
        subscription_id: Ash.Changeset.get_argument(changeset, :event_subscription_id),
        created_at: Ash.Changeset.get_argument(changeset, :event_created_at),
        target_status: Ash.Changeset.get_attribute(changeset, :status)
      }

      case EventGuard.check(fresh, event) do
        {:ignore, reason} -> settle(changeset, reason)
        :ok -> Ash.Changeset.add_error(changeset, stale_error())
      end
    end
  end

  defp settle(changeset, reason) do
    changeset.attributes
    |> Map.keys()
    |> Enum.reduce(changeset, &Ash.Changeset.clear_change(&2, &1))
    |> Ash.Changeset.put_context(:event_ignored, reason)
  end

  defp stale_error do
    Ash.Error.Changes.InvalidChanges.exception(
      message: "the membership changed while this provider event was waiting; retry"
    )
  end
end
