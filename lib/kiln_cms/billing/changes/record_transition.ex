defmodule KilnCMS.Billing.Changes.RecordTransition do
  @moduledoc """
  On any membership status change: stamp the lifecycle timestamps, recompute the
  user's entitlements, and append a `KilnCMS.Billing.MembershipEvent` recording the
  status change *and* the audience delta.

  All three happen in the action's `after_action`, i.e. **inside the same
  transaction** as the status write. If the recompute fails, the status change
  rolls back with it and Oban retries — an entitlement is not best-effort, so this
  deliberately does *not* copy the never-raise `rescue` used by
  `KilnCMS.Governance.Chain.anchor/2` for tamper-evidence anchors.

  Doing the recompute here rather than at each call site means every path that
  changes a membership — webhook, comp, reconcile — cannot forget it.
  """
  use Ash.Resource.Change

  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements

  @impl true
  def change(changeset, _opts, context) do
    from_status = changeset.data.status

    changeset
    |> stamp_timestamps()
    |> Ash.Changeset.after_action(fn _changeset, membership ->
      with {:ok, delta} <- Entitlements.recompute(membership.user_id),
           {:ok, _event} <- append_event(changeset, membership, from_status, delta, context) do
        {:ok, membership}
      end
    end)
  end

  # `activated_at` marks the first time a membership ever became entitling (so a
  # lapse-and-return keeps the original date); `canceled_at` is stamped on the way
  # into a terminal state.
  defp stamp_timestamps(changeset) do
    to_status = Ash.Changeset.get_attribute(changeset, :status)
    now = DateTime.utc_now()

    changeset
    |> maybe_stamp(
      :activated_at,
      to_status == :active and is_nil(changeset.data.activated_at),
      now
    )
    |> maybe_stamp(
      :canceled_at,
      to_status == :canceled and is_nil(changeset.data.canceled_at),
      now
    )
  end

  defp maybe_stamp(changeset, _field, false, _value), do: changeset

  defp maybe_stamp(changeset, field, true, value),
    do: Ash.Changeset.force_change_attribute(changeset, field, value)

  defp append_event(changeset, membership, from_status, delta, context) do
    Billing.append_membership_event(
      %{
        membership_id: membership.id,
        user_id: membership.user_id,
        tier_id: membership.tier_id,
        kind: kind(from_status, membership.status, delta),
        from_status: from_status,
        to_status: membership.status,
        audiences_added: delta.added,
        audiences_removed: delta.removed,
        provider_event_id: Ash.Changeset.get_argument(changeset, :provider_event_id),
        # Non-nil only when a human caused it — i.e. an admin comp. Webhook-driven
        # transitions run actorless, and their provenance is the event id above.
        actor_id: context.actor && context.actor.id,
        note: membership.note
      },
      authorize?: false,
      tenant: membership.org_id
    )
  end

  # A renewal is an `:active -> :active` transition that moved the period end; it
  # is worth its own kind so the trail distinguishes "kept paying" from
  # "re-subscribed after cancelling".
  defp kind(:active, :active, _delta), do: :renewed
  defp kind(_from, :active, _delta), do: :activated
  defp kind(_from, :past_due, _delta), do: :past_due
  defp kind(:comped, :canceled, _delta), do: :uncomped
  defp kind(_from, :canceled, _delta), do: :canceled
  defp kind(_from, :comped, _delta), do: :comped
  defp kind(_from, :incomplete, _delta), do: :started
  defp kind(_from, _to, _delta), do: :reconciled
end
