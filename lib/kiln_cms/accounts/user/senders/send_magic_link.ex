defmodule KilnCMS.Accounts.User.Senders.SendMagicLink do
  @moduledoc """
  Sends a passwordless magic sign-in link to a user.

  `send/3` may receive either a `User` struct (when the email matches an
  existing account) or a bare email string; with registration disabled, only
  existing users ever receive a link.

  Requests are budgeted per address (#478). A magic-link request is not a
  credential-stuffing vector — it is a mailbomb: anyone can name any address,
  and the per-IP limit alone doesn't stop a distributed sender. Enforced here
  rather than on the action because the sender is the outbound boundary every
  entry point passes through, and it is the mail, not the request, that costs
  the recipient something.
  """
  use AshAuthentication.Sender
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Mail

  @impl true
  def send(user_or_email, token, opts) do
    # White-label branding (#48): AshAuthentication threads the request's tenant
    # through `opts`, so a sign-in link from `acme.example.com` says "Acme".
    # `for_org/1` resolves a missing tenant to the operator default.
    site = KilnCMS.Branding.for_org(opts[:tenant]).site_name
    address = recipient(user_or_email)

    if AccountThrottle.allow_mail?(:magic_link, address) do
      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(address)
      |> subject("Your #{site} sign-in link")
      |> html_body(body(token, site))
      |> Mail.enqueue!()
    else
      # Silently, and identically to the address-doesn't-exist path: the request
      # action already answers `:ok` either way so it can't be used to probe for
      # accounts, and a "you're being throttled" answer would undo that.
      :ok
    end
  end

  defp recipient(%{email: email}), do: to_string(email)
  defp recipient(email), do: to_string(email)

  defp body(token, site) do
    url = url(~p"/magic_link/#{token}")

    """
    <p>Click the link below to sign in to #{site}. It expires shortly and can
    only be used once.</p>
    <p><a href="#{url}">Sign in to #{site}</a></p>
    <p>If you didn't request this, you can safely ignore this email.</p>
    """
  end
end
