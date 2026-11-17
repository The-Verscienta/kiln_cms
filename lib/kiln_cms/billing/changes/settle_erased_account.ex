defmodule KilnCMS.Billing.Changes.SettleErasedAccount do
  @moduledoc """
  Takes the account's `users` row `FOR KEY SHARE` before a membership
  transition writes anything (`KilnCMS.Accounts.AccountLock`'s lock order),
  and turns the transition into a successful no-op when the account was
  erased (#2774).

  Erasure cancels every paid membership locally and drops its provider ids
  (`Membership.:anonymize`). The provider does not know: a renewal webhook
  for the subscription still arrives every period, resolves the row by its
  metadata, and used to set it `:active` again with the provider ids back,
  append an `activated` event and enqueue a `membership.activated` webhook.

  For an erased account this clears every attribute change, so the row keeps
  what the erasure left (`:canceled`, no provider ids), and marks the
  changeset (`erased_account?: true` in its context), so
  `KilnCMS.Billing.Changes.RecordTransition` records no event, sends no
  webhook and syncs nothing. The action still succeeds, so the provider
  webhook settles instead of retrying.

  Declared first on `:apply_provider_state` and `:uncomp`. In a
  `before_action`, so the decision is made under the lock, inside the
  action's transaction: an erasure committing while this waited is seen.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountLock

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, :user_id) do
        nil -> changeset
        user_id -> lock(changeset, user_id)
      end
    end)
  end

  @doc "Whether `changeset` was settled as a no-op for an erased account."
  @spec erased?(Ash.Changeset.t()) :: boolean()
  def erased?(changeset), do: changeset.context[:erased_account?] == true

  defp lock(changeset, user_id) do
    case AccountLock.share(user_id) do
      {:error, :erased} ->
        changeset.attributes
        |> Map.keys()
        |> Enum.reduce(changeset, &Ash.Changeset.clear_change(&2, &1))
        |> Ash.Changeset.put_context(:erased_account?, true)

      # A missing account leaves the transition to the action, as before.
      _locked_or_missing ->
        changeset
    end
  end
end
