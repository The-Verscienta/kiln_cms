defmodule KilnCMS.Security.Changes.RecordRegistration do
  @moduledoc """
  The audit events (#2241) of registration approval (#2251), on
  `OrgMembership`'s three registration actions. Built on
  `KilnCMS.Security.Changes.Record`, in the transaction, so the event commits or
  rolls back with the row:

    * `:queue_registration` — `:registration_queued` (`method`: how the account
      was registered, `password`);
    * `:approve_registration` — `:registration_approved` (`role`: the tier the
      membership now grants, `via`: `queue`, the console's decision);
    * `:reject_registration` — `:registration_rejected` (`outcome`: `kept`, the
      account and its row stay).

  None of them is a `role_granted`: a queued row grants nothing, and approving
  one is recorded as what it is. The target is the applicant, and the event
  lands in the log of the org the membership names, whichever host the deciding
  admin is on. A queued registration has no acting person (the actor is the
  system); a decision records the admin who made it.
  """
  use Ash.Resource.Change

  alias KilnCMS.Security.Changes.Record

  @impl true
  def change(changeset, _opts, context) do
    Record.change(
      changeset,
      [
        type: &type/2,
        tenant: fn record, _changeset -> record.organization_id end,
        target: fn record, _changeset -> {"user", record.user_id} end,
        metadata: &metadata/2
      ],
      context
    )
  end

  defp type(_record, %{action: %{name: :queue_registration}}), do: :registration_queued
  defp type(_record, %{action: %{name: :approve_registration}}), do: :registration_approved
  defp type(_record, %{action: %{name: :reject_registration}}), do: :registration_rejected
  defp type(_record, _changeset), do: nil

  defp metadata(_record, %{action: %{name: :queue_registration}}), do: %{"method" => "password"}

  defp metadata(record, %{action: %{name: :approve_registration}}),
    do: %{"role" => record.role, "via" => "queue"}

  defp metadata(_record, %{action: %{name: :reject_registration}}), do: %{"outcome" => "kept"}
  defp metadata(_record, _changeset), do: %{}
end
