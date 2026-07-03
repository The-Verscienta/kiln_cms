defmodule KilnCMS.Accounts.User.Senders.SendMagicLink do
  @moduledoc """
  Sends a passwordless magic sign-in link to a user.

  `send/3` may receive either a `User` struct (when the email matches an
  existing account) or a bare email string; with registration disabled, only
  existing users ever receive a link.
  """
  use AshAuthentication.Sender
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Mail

  @impl true
  def send(user_or_email, token, _opts) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(recipient(user_or_email))
    |> subject("Your KilnCMS sign-in link")
    |> html_body(body(token))
    |> Mail.enqueue!()
  end

  defp recipient(%{email: email}), do: to_string(email)
  defp recipient(email), do: to_string(email)

  defp body(token) do
    url = url(~p"/magic_link/#{token}")

    """
    <p>Click the link below to sign in to KilnCMS. It expires shortly and can
    only be used once.</p>
    <p><a href="#{url}">Sign in to KilnCMS</a></p>
    <p>If you didn't request this, you can safely ignore this email.</p>
    """
  end
end
