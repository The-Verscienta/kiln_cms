defmodule KilnCMS.Accounts.Changes.SendInvitation do
  @moduledoc """
  Mails an invitation (#2135) on `:invite` and `:resend`, and refuses by name
  when it would not arrive.

  Two refusals the admin is told about, both before anything is written:

    * the address is on a suppression list (`KilnCMS.Mail.suppressed?/2`, the
      instance-wide list and the site's own): `enqueue!/2` would drop the mail
      silently, and "Invitation sent." would be untrue;
    * the address's invitation budget is spent
      (`KilnCMS.Accounts.AccountThrottle`, purpose `:invitation`). An admin can
      name any address, and it is the mail that costs the recipient, so it is
      bounded like the reset and magic-link mail. Reported by name, as
      `KilnCMS.Accounts.AdminPasswordReset` reports a spent reset budget.

  Both from `before_transaction`: the budget lives in Postgres and
  `KilnCMS.Accounts.ThrottleStore.hit/5` refuses to run inside a transaction,
  where a rolled-back write would refund the charge.

  The mail itself is enqueued from `after_action`, inside the write's
  transaction, so a row without its mail (or a mail for a row that rolled back)
  cannot happen.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Changes.GenerateInvitationToken
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.User.Senders.SendInvitation

  @site_key :invitation_site_name

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_transaction(&refuse_undeliverable/1)
    |> Ash.Changeset.after_action(fn changeset, invitation ->
      token = Map.fetch!(changeset.context, GenerateInvitationToken.context_key())
      site = Map.fetch!(changeset.context, @site_key)
      :ok = SendInvitation.deliver(invitation, token, context.actor, site)
      {:ok, invitation}
    end)
  end

  defp refuse_undeliverable(%{valid?: false} = changeset), do: changeset

  defp refuse_undeliverable(changeset) do
    address = changeset |> Ash.Changeset.get_attribute(:email) |> to_string()
    org_id = Ash.Changeset.get_attribute(changeset, :organization_id)

    cond do
      KilnCMS.Mail.suppressed?(address, org_id: org_id) ->
        refuse(changeset, :suppressed)

      not AccountThrottle.allow_mail?(:invitation, address) ->
        refuse(changeset, :mail_budget)

      true ->
        # The site name, read here rather than in the transaction: a branding
        # cache miss resolves on a Cachex courier process, which must not wait
        # on a connection this write holds.
        Ash.Changeset.set_context(changeset, %{
          @site_key => KilnCMS.Branding.for_org(org_id).site_name
        })
    end
  end

  defp refuse(changeset, reason),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvitationRefused.exception(field: :email, reason: reason)
      )
end
