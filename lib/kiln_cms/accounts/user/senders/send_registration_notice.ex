defmodule KilnCMS.Accounts.User.Senders.SendRegistrationNotice do
  @moduledoc """
  Tells the owner of an address that someone tried to register it (#2255).

  What a visitor who names an address with an account is told is exactly what a
  visitor with a new address is told ("check your email"), so the owner is the
  one place the difference may land: this notice, in their inbox, instead of the
  confirmation mail a new address gets. It carries no link that does anything —
  only the sign-in and reset pages — so a stranger who triggers it learns
  nothing and gains nothing.

  Budgeted per address, like the reset and magic-link mail, for the same reason:
  anyone can name any address, and it is the mail that costs the recipient.
  Dropped silently when the budget is spent; the requester is told the same
  thing either way.

  Account mail (#3035): the account holding the address is read again here,
  after the registration's transaction, and the notice is queued for it
  (`user_id:`), so it is not sent once that account is erased. No account
  holds the address any more (erased between the refusal and this): nothing is
  sent. The refusal's own read cannot hand the account over, because
  `after_transaction` sees the changeset from before its `before_action`; the
  second read costs about a millisecond, after the hash, on the path that
  already queues a job.
  """
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User
  alias KilnCMS.Mail

  @spec deliver(String.t()) :: :ok
  def deliver(address) do
    with %User{} = owner <- owner(address),
         true <- AccountThrottle.allow_mail?(:registration_notice, address) do
      site = KilnCMS.Branding.for_org(nil).site_name

      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(address)
      |> subject("Someone tried to create a #{site} account with your address")
      |> html_body(body(site))
      |> Mail.enqueue!(user_id: owner.id)
    else
      _no_account_or_no_budget -> :ok
    end
  end

  defp owner(address) do
    # authorize?: false — pre-auth registration lookup, no actor exists (the
    # same read `Changes.RefuseExistingAddress` refused the registration on).
    case Accounts.get_user_by_email(address, authorize?: false, not_found_error?: false) do
      {:ok, %User{anonymized_at: nil} = user} -> user
      _none -> nil
    end
  end

  defp body(site) do
    """
    <p>Someone tried to create a #{site} account with this email address, but it
    already has one. Nothing has changed.</p>
    <p>If it was you, <a href="#{url(~p"/sign-in")}">sign in</a>, or
    <a href="#{url(~p"/reset")}">reset your password</a> if you have forgotten it.</p>
    <p>If it wasn't you, you can safely ignore this email.</p>
    """
  end
end
