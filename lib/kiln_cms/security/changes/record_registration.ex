defmodule KilnCMS.Security.Changes.RecordRegistration do
  @moduledoc """
  The audit events (#2241) of registration approval (#2251), on
  `OrgMembership`'s registration actions. Built on
  `KilnCMS.Security.Changes.Record`, in the transaction, so the event commits or
  rolls back with the row:

    * `:queue_registration` — `:registration_queued` (`method`: how the account
      was registered, `password` or `site_sso`, from the action's argument);
    * `:approve_registration` — `:registration_approved` (`role`: the tier the
      membership now grants, `via`: `queue`, the console's decision);
    * `:approve_registration_by_invitation` — `:registration_approved` too
      (#2514), `via`: `invitation` when an invitation was accepted, `added` when
      a platform admin added the address directly;
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

  defp type(_record, %{action: %{name: name}})
       when name in [:approve_registration, :approve_registration_by_invitation],
       do: :registration_approved

  defp type(_record, %{action: %{name: :reject_registration}}), do: :registration_rejected
  defp type(_record, _changeset), do: nil

  defp metadata(_record, %{action: %{name: :queue_registration}} = changeset),
    do: %{"method" => to_string(Ash.Changeset.get_argument(changeset, :method))}

  defp metadata(record, %{action: %{name: :approve_registration}}),
    do: %{"role" => record.role, "via" => "queue"}

  defp metadata(record, %{action: %{name: :approve_registration_by_invitation}} = changeset),
    do: %{"role" => record.role, "via" => to_string(Ash.Changeset.get_argument(changeset, :via))}

  defp metadata(_record, %{action: %{name: :reject_registration}}), do: %{"outcome" => "kept"}
  defp metadata(_record, _changeset), do: %{}
end
