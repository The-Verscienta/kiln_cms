defmodule KilnCMS.Security.Posture.Checks.SecurityAlerts do
  @moduledoc """
  `core.security_alerts_reach_someone` (#2640): whether the site's security
  alerts (`KilnCMS.Security.Alerts`, #2245) reach anyone — by bell, by email,
  or by a webhook subscribed to them.

  It reads what delivery reads (`KilnCMS.Security.Changes.DeliverAlert`): the
  site's alert settings, its recipients (`Alerts.site_recipients/1`: the
  member admins, or the platform admins when the site has none, OC-1 on
  #2245), who of them has not muted the email, and the active webhook
  endpoints subscribed to an alert kind the site has on.

    * **warn** when alerts are turned off for the whole deployment
      (`config :kiln_cms, KilnCMS.Security.Alerts, enabled: false`), when the
      site turned every kind off, or when no bell, email or webhook would carry
      one: bell and email off (or no admins at all, not even platform admins)
      and no subscribed endpoint.
    * **pass**, saying how, when they go only by webhook, only to the platform
      admins (the site has no admins of its own), or only by bell (every
      recipient muted the email: the bell still rings).
    * **unknown** when the settings or the endpoints cannot be read: an
      unreadable row is not the site's choice, and a refused endpoint read is
      not "no endpoints".

  The facts are counts and flags only. Who the recipients are is never in
  them, and a platform admin's identity never reaches a site's report.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.Posture
  alias KilnCMS.Webhooks

  @impl Kiln.Security.Check
  def id, do: "core.security_alerts_reach_someone"

  @impl Kiln.Security.Check
  def title, do: gettext("Security alerts reach someone")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "Security alerts tell someone about lockouts, new administrators, removed second factors and sign-in changes. An alert that reaches nobody tells nobody."
      )

  @impl Kiln.Security.Check
  def scope, do: :site

  @impl Kiln.Security.Check
  def timeout, do: 3000

  @impl Kiln.Security.Check
  def run(%{org_id: org_id}) do
    opts = [docs_url: Posture.docs_url("security-alerts")]

    if Alerts.enabled?() do
      with {:ok, settings} <- Alerts.read_settings(org_id),
           kinds = Enum.filter(Alerts.site_kinds(), &Alerts.enabled?(settings, &1)),
           {:ok, endpoints} <- subscribed_endpoints(org_id, kinds) do
        report(org_id, settings, kinds, endpoints, opts)
      else
        :error ->
          unknown(gettext("The site's security alert settings could not be read."), opts)

        {:error, :endpoints} ->
          unknown(gettext("The site's webhook endpoints could not be read."), opts)
      end
    else
      warn(
        gettext("Security alerts are turned off for this whole deployment."),
        Keyword.put(opts, :facts, %{deployment_enabled: false})
      )
    end
  end

  defp report(org_id, settings, kinds, endpoints, opts) do
    facts = facts(org_id, settings, kinds, endpoints)
    opts = Keyword.put(opts, :facts, facts)

    case verdict(facts) do
      {status, summary, nil} -> result(status, summary, opts)
      {status, summary, fix} -> result(status, summary, Keyword.put(opts, :fix_path, fix))
    end
  end

  # Counts and flags only: who the recipients are never leaves this function.
  defp facts(org_id, settings, kinds, endpoints) do
    member_admins = length(Scoping.site_member_admins(org_id))
    recipients = if settings.notify_admins, do: Alerts.site_recipients(org_id), else: []

    %{
      deployment_enabled: true,
      enabled_kinds: length(kinds),
      notify_admins: settings.notify_admins,
      member_admins: member_admins,
      fallback: member_admins == 0 and recipients != [],
      bell_recipients: length(recipients),
      email_recipients:
        Enum.count(recipients, &(&1.notify_on_security_alert and &1.email != nil)),
      subscribed_endpoints: endpoints
    }
  end

  # The table in the moduledoc, top to bottom: `{status, summary, fix_path}`.
  defp verdict(%{enabled_kinds: 0}),
    do:
      {:warn, gettext("Every security alert is turned off on this site."),
       "/editor/security-alerts"}

  defp verdict(%{bell_recipients: 0, subscribed_endpoints: 0} = facts),
    do:
      {:warn, gettext("Security alerts on this site reach nobody."),
       if(facts.notify_admins, do: "/editor/team", else: "/editor/security-alerts")}

  defp verdict(%{bell_recipients: 0}),
    do:
      {:pass, gettext("Security alerts on this site go out only by webhook."),
       "/editor/security-alerts"}

  defp verdict(%{fallback: true}),
    do:
      {:pass,
       gettext(
         "Security alerts on this site go to the platform admins: this site has no admins of its own."
       ), "/editor/team"}

  defp verdict(%{email_recipients: 0}),
    do:
      {:pass,
       gettext(
         "Security alerts on this site reach its administrators by bell only: each of them muted the email."
       ), "/editor/settings"}

  defp verdict(_facts),
    do: {:pass, gettext("Security alerts on this site reach its administrators."), nil}

  defp result(:warn, summary, opts), do: warn(summary, opts)
  defp result(:pass, summary, opts), do: pass(summary, opts)

  # How many active endpoints of the site would carry an alert of a kind it
  # has on. Read as the webhook pipeline's own actor, as delivery reads them,
  # with `authorize_with: :error`: a refused read is an error, not "none".
  defp subscribed_endpoints(_org_id, []), do: {:ok, 0}

  defp subscribed_endpoints(org_id, kinds) do
    events = MapSet.new(kinds, &"security.#{&1}")

    case CMS.list_webhook_endpoints(
           actor: Webhooks.system(),
           authorize_with: :error,
           tenant: org_id,
           query: Ash.Query.filter(CMS.WebhookEndpoint, active == true)
         ) do
      {:ok, endpoints} ->
        {:ok,
         Enum.count(endpoints, fn endpoint ->
           Enum.any?(endpoint.events || [], fn event ->
             MapSet.member?(events, event) and
               CMS.WebhookEndpoint.receives?(endpoint, event, false)
           end)
         end)}

      {:error, _reason} ->
        {:error, :endpoints}
    end
  end
end
