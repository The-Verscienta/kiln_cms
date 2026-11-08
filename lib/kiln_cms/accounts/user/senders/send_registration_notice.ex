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
  """
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Mail

  @spec deliver(String.t()) :: :ok
  def deliver(address) do
    if AccountThrottle.allow_mail?(:registration_notice, address) do
      site = KilnCMS.Branding.for_org(nil).site_name

      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(address)
      |> subject("Someone tried to create a #{site} account with your address")
      |> html_body(body(site))
      |> Mail.enqueue!()
    else
      :ok
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
