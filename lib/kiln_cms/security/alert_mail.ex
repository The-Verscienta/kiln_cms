defmodule KilnCMS.Security.AlertMail do
  @moduledoc """
  The words of a security alert (#2245): the email, and the one-line
  `headline/1` the bell row carries as its excerpt.

  Built from the alert's payload (the same map its webhooks carry,
  `KilnCMS.Security.Changes.DeliverAlert`), so the three channels cannot say
  different things. What that map leaves out, this leaves out: no email
  address, no user agent, no endpoint URL, and the client address only as the
  site's settings allow (`KilnCMS.Security.Alerts.display_ip/2`).

  Sent through the **instance** relay (`KilnCMS.Mail.enqueue!/2` without an
  `org_id`): a site's own relay is a setting a site admin can change, and an
  alert about that site must not depend on it — a changed relay is itself an
  alert (`mail_relay_changed`).

  English, like the other account mail (`SendRegistrationPending`): an alert
  goes to admins of possibly several sites, from a worker with no request
  locale.
  """
  import Swoosh.Email

  alias KilnCMS.Mail

  @kind_labels %{
    "new_admin" => "A new administrator",
    "role_elevation" => "A role was raised",
    "failed_sign_ins" => "Failed sign-ins reached the alert threshold",
    "lockout" => "An account was locked out",
    "two_factor_disabled" => "Two-step verification was turned off",
    "sso_config_changed" => "Single sign-on settings changed",
    "platform_role_changed" => "A platform administrator lost the role",
    "new_api_key" => "An API key was created",
    "api_key_abuse" => "A rotated API key was used again"
  }

  @change_labels %{
    "kind_disabled" => "Some security alerts were turned off",
    "admin_notifications_off" => "Security alert notifications and emails were turned off",
    "webhook_changed" => "A webhook that receives security alerts was changed",
    "webhook_removed" => "A webhook that receives security alerts was deleted",
    "webhook_secret_rotated" =>
      "A webhook that receives security alerts got a new signing secret",
    "webhook_auto_disabled" =>
      "A webhook that receives security alerts was switched off after failed deliveries",
    "admin_removed" => "An administrator was removed",
    "admin_demoted" => "An administrator was demoted",
    "admin_grant_revoked" => "A temporary administrator role was ended early",
    "mail_relay_changed" => "The site's mail relay was changed"
  }

  @doc """
  One line saying what happened: the bell's excerpt, and the email's first
  paragraph.
  """
  @spec headline(map()) :: String.t()
  def headline(%{phase: "notice", change: change}),
    do: Map.get(@change_labels, change, "Security alerts were made quieter")

  def headline(%{phase: "summary", kind: kind, count: count}),
    do: "#{label(kind)}: #{count} in this alert window"

  def headline(%{kind: kind} = data) do
    case get_in(data, [:event, :ip]) do
      nil -> label(kind)
      ip -> "#{label(kind)} (from #{ip})"
    end
  end

  defp label(kind), do: Map.get(@kind_labels, kind, "Security alert")

  @doc "The email's subject."
  @spec subject(map()) :: String.t()
  def subject(%{phase: "notice", site_name: site}), do: "Security alerts on #{site} were changed"
  def subject(%{phase: "summary", site_name: site}), do: "Security alert summary for #{site}"
  def subject(%{site_name: site, kind: kind}), do: "Security alert on #{site}: #{label(kind)}"

  @doc """
  Queue the alert's email to `recipient` on the instance relay. Raises when
  it cannot be queued: the delivery runs in a transaction that is then
  retried, rather than stamped as sent.

  `mutable?` says whether the recipient could turn the email off (a site
  alert; not a platform alert or a notice), which the footer says.
  """
  @spec deliver!(map(), map(), boolean()) :: term()
  def deliver!(recipient, data, mutable?) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(recipient.email))
    |> subject(subject(data))
    |> html_body(body(data, mutable?))
    |> Mail.enqueue!()
  end

  defp link_text(%{phase: "notice"}), do: "Open the security alerts settings"
  defp link_text(_data), do: "Open the security log"

  defp body(data, mutable?) do
    """
    <p>#{escape(headline(data))}</p>
    #{details(data)}
    <p><a href="#{escape(data.console_url)}">#{link_text(data)}</a></p>
    <p>#{footer(data, mutable?)}</p>
    """
  end

  defp details(%{phase: "notice"} = data) do
    kinds = Enum.map_join(List.wrap(data[:kinds]), ", ", &label/1)

    if kinds == "",
      do: "<p>Fewer people may hear about security events on this site from now on.</p>",
      else: "<p>Turned off: #{escape(kinds)}.</p>"
  end

  defp details(%{phase: "summary"} = data) do
    "<p>#{data.count} in the window from #{escape(data.window.started_at)} " <>
      "to #{escape(data.window.ends_at)} (UTC). The first was alerted on its own.</p>"
  end

  defp details(data) do
    "<p>At #{escape(data.occurred_at)} (UTC).</p>"
  end

  defp footer(%{channel: "platform"}, _mutable?),
    do: "You get this because you are a platform administrator. Platform alerts cannot be muted."

  defp footer(%{phase: "notice", site_name: site}, _mutable?),
    do: "You get this because you administer #{escape(site)}. Notices like this cannot be muted."

  defp footer(%{site_name: site}, true),
    do:
      "You get this because you administer #{escape(site)}. You can turn these emails off " <>
        "under Your settings, Email notifications."

  defp footer(%{site_name: site}, _mutable?),
    do: "You get this because you administer #{escape(site)}."

  defp escape(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
