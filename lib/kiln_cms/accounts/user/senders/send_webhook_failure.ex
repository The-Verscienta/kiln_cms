defmodule KilnCMS.Accounts.User.Senders.SendWebhookFailure do
  @moduledoc """
  Tells a site admin that one of the site's webhooks is failing, or was
  switched off after failing (`KilnCMS.Webhooks.HealthNotice`).

  Sent with the in-app notice, and only when that wrote a new row: one mail
  per admin per unread notice, not one per failed delivery. Muted by the
  admin's `notify_on_webhook_failure`.

  Names the endpoint by its masked URL only (ADR 0028) and links to
  `/editor/webhooks` on the site's own host, where the error and the
  deliveries are.

  Best effort: a mail that cannot be queued is logged and the notice stands.
  """
  require Logger

  import Swoosh.Email

  alias KilnCMS.Mail
  alias KilnCMSWeb.Plugs.ConsoleHost

  @spec deliver(
          KilnCMS.Accounts.User.t(),
          KilnCMS.Accounts.Organization.t(),
          :webhook_failing | :webhook_disabled,
          String.t(),
          non_neg_integer()
        ) :: :ok
  def deliver(admin, org, event, url, failures) do
    site = KilnCMS.Branding.for_org(org).site_name
    link = ConsoleHost.org_url("/editor/webhooks", org)
    settings = ConsoleHost.org_url("/editor/settings#settings-email-notifications", org)

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(admin.email))
    |> subject(subject_line(event, site))
    |> html_body(body(event, escape(site), escape(url), failures, link, settings))
    |> Mail.enqueue!(org_id: org.id)

    :ok
  rescue
    # Boundary: the failed delivery that caused this is settled; a mail fault
    # must not reach the worker. The module only: the message can carry the
    # address.
    error ->
      Logger.warning("Could not queue a webhook failure notice: #{inspect(error.__struct__)}")
      :ok
  end

  defp subject_line(:webhook_failing, site), do: "A webhook is failing on #{site}"
  defp subject_line(:webhook_disabled, site), do: "A webhook was switched off on #{site}"

  defp body(:webhook_failing, site, url, _failures, link, settings) do
    """
    <p>A webhook on #{site} could not deliver an event to <code>#{url}</code>,
    even after retrying. Content changes may not be reaching that receiver, so
    a site it rebuilds or a cache it clears may be out of date.</p>
    <p>If the next deliveries fail as well, the webhook is switched off.</p>
    <p><a href="#{link}">Open webhooks</a> to see the error and send a test ping.</p>
    #{footer(site, settings)}
    """
  end

  defp body(:webhook_disabled, site, url, failures, link, settings) do
    """
    <p>A webhook on #{site} that sends to <code>#{url}</code> was switched off
    after #{failures} failed deliveries in a row. Nothing is sent to it until
    an administrator turns it back on, so content changes are not reaching
    that receiver.</p>
    <p><a href="#{link}">Open webhooks</a> to see the error, fix the receiver,
    and turn the webhook back on. You can then redeliver the events it
    missed.</p>
    #{footer(site, settings)}
    """
  end

  defp footer(site, settings) do
    """
    <p>You get this because you administer #{site}. You can
    <a href="#{settings}">turn these emails off</a> under Your settings, Email
    notifications.</p>
    """
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
