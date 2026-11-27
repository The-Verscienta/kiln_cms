defmodule KilnCMS.Accounts.User.Senders.SendBreachedPasswordReset do
  @moduledoc """
  The mail an administrator gets when their sign-in is refused because the
  password appears in a known breach (#2407): a reset link, why it was sent,
  and what to do if the sign-in was not theirs.

  Not the ordinary reset mail. That one says "you asked for this", and here
  nobody asked: someone signed in with the account's current password, which
  is in a breach corpus, so it may not have been the owner. The body says so.

  The token is an ordinary reset token (`KilnCMS.Accounts.PasswordResetMail`
  mints it and charges the address's reset-mail budget), so the link works
  and expires like any other reset link. The body names nothing from the
  request (no IP, no host, no time): whoever triggered it holds the password,
  and request data echoed into the mail would make it a phishing channel.
  English, like the other account mail.

  `tenant` is the site the mail is branded for, which the caller picks
  (#3436): a site whose policy refused the sign-in, so the mail names one the
  recipient administers rather than whichever host they signed in on.
  """
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Accounts
  alias KilnCMS.Mail

  @doc "Queue the mail for `user`, with the reset `token`, in `tenant`'s branding."
  @spec deliver(Accounts.User.t(), String.t(), term()) :: :ok
  def deliver(user, token, tenant) do
    site = KilnCMS.Branding.for_org(tenant).site_name

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(user.email))
    |> subject("Choose a new password for your #{site} account")
    |> html_body(body(escape(site), url(~p"/password-reset/#{token}")))
    |> Mail.enqueue!(user_id: user.id)

    :ok
  end

  defp body(site, link) do
    """
    <p>Someone signed in to your #{site} account with your current password.
    That password appears in a known data breach, so administrators can't sign
    in with it any more.</p>
    <p>Choose a new one with this link:</p>
    <p><a href="#{link}">#{link}</a></p>
    <p>If that sign-in wasn't you, change your password now: someone else
    knows it.</p>
    """
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
