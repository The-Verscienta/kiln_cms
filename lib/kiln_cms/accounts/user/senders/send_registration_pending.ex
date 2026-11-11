defmodule KilnCMS.Accounts.User.Senders.SendRegistrationPending do
  @moduledoc """
  Tells a site admin that someone is waiting for their approval (#2251).

  Sent by `KilnCMS.Notifications.Registrations` with the in-app notice, and
  only when that wrote a new row: one mail per admin per unread notice, not
  one per applicant. Muted by the admin's `notify_on_registration`.

  About the site's queue, not the applicant: the mail names the site and links
  to `/editor/registrations` on the site's own host, and carries no address or
  name — those are for the queue, which checks who is asking.

  Best effort: a mail that cannot be queued is logged and the notice stands.
  """
  require Logger

  import Swoosh.Email

  alias KilnCMS.Mail
  alias KilnCMS.Notifications.Link
  alias KilnCMSWeb.Plugs.ConsoleHost

  @spec deliver(KilnCMS.Accounts.User.t(), KilnCMS.Accounts.Organization.t()) :: :ok
  def deliver(admin, org) do
    site = KilnCMS.Branding.for_org(org).site_name

    link =
      Link.editor_url(%{
        event: :registration_pending,
        content_type: "registration_queue",
        content_id: org.id,
        org: org
      })

    settings = ConsoleHost.org_url("/editor/settings#settings-email-notifications", org)

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(admin.email))
    |> subject("Registrations are waiting for approval on #{site}")
    |> html_body(body(escape(site), link, settings))
    |> Mail.enqueue!(org_id: org.id)
  rescue
    # Boundary: the confirmation that caused this has committed; a mail fault
    # must not reach it. The module only: the message can carry the address.
    error ->
      Logger.warning("Could not queue a registration notice: #{inspect(error.__struct__)}")
      :ok
  end

  defp body(site, link, settings) do
    """
    <p>Someone who signed up on #{site} has confirmed their email address and
    is waiting for an administrator's approval.</p>
    <p><a href="#{link}">Review registrations</a></p>
    <p>You get this because you administer #{site}. You can
    <a href="#{settings}">turn these emails off</a> under Your settings, Email
    notifications.</p>
    """
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
