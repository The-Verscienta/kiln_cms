defmodule KilnCMS.Billing.Validations.RegistrationApproved do
  @moduledoc """
  Refuses `Membership.:start` for an account that has not been let into the
  site it is paying on (#2251):

    * its registration there awaits approval or was rejected — `Scoping`
      grants nothing through a row that is not `:active`, so checkout would take
      the money and deliver nothing;
    * the site requires approval (`KilnCMS.CMS.SiteRegistration`) and the
      account has not been let in there: no `:active` membership, and no tier
      there by any other route (`Scoping.effective_tier/2` is `:none`).
      Otherwise paying would be a way in: `KilnCMS.Billing.Entitlements` gives a
      paying reader a viewer membership on a site where it has none. The
      setting is read failing **closed** — unreadable refuses, as a
      registration would.

  "Let in" covers the membership-less account that predates approval: on the
  default site it is a viewer already (the legacy branch of `Scoping`), so
  switching approval on there does not stop an existing reader paying. A
  pending or rejected row resolves to `:none`, so it is never "let in".

  On a site that does not require approval, an account with no row there may
  pay as before; the entitlement recompute then makes it a viewer member.

  Refused here, on the action, rather than in the checkout controller, so no
  other caller can start one either. The row is read `authorize?: false`: the
  validation must see it as stored, and the read only ever refuses.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.RegistrationRefused
  alias KilnCMS.Accounts.RegistrationPolicy
  alias KilnCMS.Accounts.Scoping

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :user_id) do
      user_id when is_binary(user_id) ->
        org_id = Accounts.org_id(changeset.tenant)
        decide(registration_status(user_id, org_id), user_id, org_id)

      _none ->
        :ok
    end
  end

  defp decide(:active, _user_id, _org_id), do: :ok

  defp decide(status, _user_id, _org_id) when status in [:pending, :rejected],
    do: refuse(:not_approved)

  defp decide(nil, user_id, org_id) do
    case RegistrationPolicy.approval_required(org_id) do
      {:ok, false} -> :ok
      {:ok, true} -> if let_in?(user_id, org_id), do: :ok, else: refuse(:not_approved)
      {:error, :unavailable} -> refuse(:settings_unavailable)
    end
  end

  defp let_in?(user_id, org_id) do
    # authorize?: false — the account as stored, only to ask its tier here
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %{} = user} -> Scoping.effective_tier(user, org_id) != :none
      _none -> false
    end
  end

  defp refuse(reason),
    do: {:error, RegistrationRefused.exception(field: :user_id, reason: reason)}

  defp registration_status(user_id, org_id) do
    # authorize?: false — the account's own row as stored; this only ever refuses
    case Accounts.get_org_membership(user_id, org_id, authorize?: false, not_found_error?: false) do
      {:ok, %{status: status}} -> status
      _none -> nil
    end
  end
end
