defmodule KilnCMS.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email
  """

  use AshAuthentication.Sender
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Mail

  @impl true
  def send(user, token, opts) do
    # White-label branding (#48). Note the read-based reset path
    # (`RequestPasswordResetPreparation`) does NOT thread a tenant, so this can
    # legitimately be nil — `for_org/1` then resolves the operator default.
    site = KilnCMS.Branding.for_org(opts[:tenant]).site_name

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(user.email))
    |> subject("Reset your #{site} password")
    |> html_body(body(token: token))
    |> Mail.enqueue!()
  end

  defp body(params) do
    url = url(~p"/password-reset/#{params[:token]}")

    """
    <p>Click this link to reset your password:</p>
    <p><a href="#{url}">#{url}</a></p>
    """
  end
end
