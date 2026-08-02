defmodule KilnCMS.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email.

  Requests are budgeted per address (#478). A reset request is not a
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
  def send(user, token, opts) do
    # White-label branding (#48). Note the read-based reset path
    # (`RequestPasswordResetPreparation`) does NOT thread a tenant, so this can
    # legitimately be nil — `for_org/1` then resolves the operator default.
    site = KilnCMS.Branding.for_org(opts[:tenant]).site_name
    address = to_string(user.email)

    if AccountThrottle.allow_mail?(:password_reset, address) do
      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(address)
      |> subject("Reset your #{site} password")
      |> html_body(body(token: token))
      |> Mail.enqueue!()
    else
      # Silently, and identically to the address-doesn't-exist path: the request
      # action already answers `:ok` either way so it can't be used to probe for
      # accounts, and a "you're being throttled" answer would undo that.
      :ok
    end
  end

  defp body(params) do
    url = url(~p"/password-reset/#{params[:token]}")

    """
    <p>Click this link to reset your password:</p>
    <p><a href="#{url}">#{url}</a></p>
    """
  end
end
