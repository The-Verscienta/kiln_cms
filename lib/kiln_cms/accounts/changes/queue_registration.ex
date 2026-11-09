defmodule KilnCMS.Accounts.Changes.QueueRegistration do
  @moduledoc """
  On a site that requires approval (#2251), `:register_with_password` records a
  `:pending` `KilnCMS.Accounts.OrgMembership` for the new account on the site it
  registered on, in the same transaction as the account.

  The site is the registration's tenant — the host org, as `RegisterForm` and
  the password strategy pass it — and the default org when there is none.

  ## Two hooks

    * `before_transaction`: reads the site's setting
      (`KilnCMS.Accounts.RegistrationPolicy`) once, when the action runs —
      not in the change body, which `AshPhoenix.Form.validate/2` runs per
      keystroke — and before the transaction opens, so no connection is held
      for it. An unreadable setting refuses the registration
      (`RegistrationRefused`, `:settings_unavailable`) and nothing is created:
      **fail closed**, because "no approval needed" is the direction that lets
      an unreviewed account in.
    * `after_action`: when approval is required, creates the pending row
      through `OrgMembership.:queue_registration` as
      `KilnCMS.SystemActor.new(:registrations)` — the one actor that action
      admits. A failure there rolls the account back with it.

  ## Which site the row goes on

    * the registering site requires approval: the row is on that site;
    * it does not, it is another site than the default org, and the **default
      org** requires approval: the row is on the default org. Otherwise the
      new account would be membership-less, which is a `:viewer` on the default
      org — let in there unreviewed through another site's host. Queued there,
      it is affiliated and holds nothing anywhere until a default-org admin
      approves it (it already held nothing on the registering site);
    * neither does: nothing is written, and the account is exactly what it was
      before #2251 — membership-less, a viewer on the default org only.

  Both settings are read before the transaction. The default org's is read
  only when it can matter, and an unreadable one refuses as above.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.RegistrationRefused
  alias KilnCMS.Accounts.RegistrationPolicy
  alias KilnCMS.Security.Recorder

  @verdict_key :registration_approval_required

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_transaction(&read_setting/1)
    |> Ash.Changeset.after_action(&queue/2)
  end

  defp read_setting(%{valid?: false} = changeset), do: changeset

  defp read_setting(changeset) do
    case queue_on(Accounts.org_id(changeset.tenant)) do
      {:ok, org_id} ->
        Ash.Changeset.set_context(changeset, %{@verdict_key => org_id})

      {:error, :unavailable} ->
        Ash.Changeset.add_error(
          changeset,
          RegistrationRefused.exception(field: :email, reason: :settings_unavailable)
        )
    end
  end

  # The org to queue the registration on, or nil — see "Which site the row
  # goes on".
  defp queue_on(site_id) do
    default_id = Accounts.default_org_id()

    case RegistrationPolicy.approval_required(site_id) do
      {:ok, true} -> {:ok, site_id}
      {:ok, false} when site_id == default_id -> {:ok, nil}
      {:ok, false} -> default_queue(default_id)
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp default_queue(default_id) do
    case RegistrationPolicy.approval_required(default_id) do
      {:ok, true} -> {:ok, default_id}
      {:ok, false} -> {:ok, nil}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp queue(changeset, user) do
    case changeset.context[@verdict_key] do
      org_id when is_binary(org_id) -> queue_membership(changeset, org_id, user)
      _none -> {:ok, user}
    end
  end

  defp queue_membership(changeset, org_id, user) do
    case Accounts.queue_registration(
           %{organization_id: org_id, user_id: user.id, new_account?: true, method: :password},
           actor: KilnCMS.SystemActor.new(:registrations),
           context: Map.take(changeset.context, [Recorder.context_key()])
         ) do
      {:ok, _membership} -> {:ok, user}
      {:error, error} -> {:error, error}
    end
  end
end
