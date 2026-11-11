defmodule KilnCMS.Accounts.User.Senders.SendSignInUnlock do
  @moduledoc """
  The mail a sign-in unlock request sends (#2250): the link that lifts the
  pause, what it does and does not do, and what to do if the owner did not ask.

  Sent on behalf of the site the request was made on, in its branding, with
  links on that site's host (`KilnCMSWeb.Plugs.ConsoleHost.org_url/2`): the
  link is refused on any other site, so it must open where it works. English,
  like the other account mail.

  The body names nothing from the request (no IP, no attempt count): anyone
  can ask for this mail to be sent to a paused account, and request data echoed
  into it would make it a phishing channel. The per-address budget is charged
  by the caller (`KilnCMS.Accounts.SignInUnlock`), only once the account is
  known to be paused, so this does not charge it again.
  """
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SignInUnlock
  alias KilnCMS.Mail
  alias KilnCMSWeb.Plugs.ConsoleHost

  import Swoosh.Email

  @doc "Queue the mail for `user`, with `token`, on `org`'s behalf."
  @spec deliver(Accounts.User.t(), String.t(), Accounts.Organization.t()) :: :ok
  def deliver(user, token, org) do
    site = KilnCMS.Branding.for_org(org).site_name

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(user.email))
    |> subject("Lift the sign-in pause on your #{site} account")
    |> html_body(
      body(
        escape(site),
        ConsoleHost.org_url("/auth/unlock/#{token}", org),
        ConsoleHost.org_url("/reset", org)
      )
    )
    |> Mail.enqueue!()
  end

  defp body(site, link, reset) do
    minutes = div(SignInUnlock.ttl_seconds(), 60)

    """
    <p>Someone asked to lift the sign-in pause on your #{site} account. Sign-in is
    paused after too many attempts that did not complete.</p>
    <p><a href="#{link}">Lift the pause</a></p>
    <p>Or open this link: #{link}</p>
    <p>The link works once, within #{minutes} minutes. It does not sign you in: you
    still sign in as usual afterwards.</p>
    <p>If you didn't ask for this, you can ignore this email. If you don't recognise
    the attempts that paused your account, consider
    <a href="#{reset}">resetting your password</a>.</p>
    """
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
