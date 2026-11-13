defmodule KilnCMS.Security.Changes.DeliverAlert do
  @moduledoc """
  Delivers one `KilnCMS.Security.AlertDispatch` (#2245): its alert
  (`phase: :alert`) or its closed window's summary (`phase: :summary`). The
  body of the AshOban triggers' `:deliver_alert` and `:deliver_summary`.

  ## Three steps

    1. **Before the transaction**, everything is read: the site, its alert
       settings, the event the alert names, the window's count (a summary),
       who hears, and which webhook endpoints are subscribed. Each read is
       made with `authorize_with: :error`, so a lost grant raises — the job
       fails and is retried — rather than reading as "nobody to tell".
    2. **In the transaction**, on the row as locked
       (`Ash.Resource.Change.Builtins.get_and_lock_for_update/0`): if its
       stamp is already set, another run delivered it and nothing happens.
       Otherwise one bell row per recipient
       (`KilnCMS.Notifications.record_notification!/2`, actor-less
       like every notification), one email per mail recipient
       (`KilnCMS.Security.AlertMail`, instance relay), one ledger row and job
       per endpoint (`KilnCMS.Webhooks.enqueue_security!/4`), and the stamp.
       Nothing is rescued: any failure rolls all of it back, and the trigger
       tries again.
    3. **After the transaction**, the bell recipients hear
       `:notifications_changed`.

  ## Who hears

    * **site** alert — nothing at all when the site turned the kind off (the
      row is only stamped). Otherwise the site's webhooks subscribed to
      `security.<kind>`, and, unless the site turned `notify_admins` off, a
      bell row for each of its member admins, or for each platform admin when
      it has none (`KilnCMS.Security.Alerts.site_recipients/1`), and an email
      to those who have not muted `notify_on_security_alert`.
    * **platform** alert — a bell row (in the default org) and an email for
      every platform admin. No mute applies, and no webhook goes (platform
      kinds are not webhook events). The one setting is the platform's own:
      a kind a platform admin turned off (`api_key_rate_limited`,
      `KilnCMS.Security.PlatformAlertSettings`) sends nothing, and the row is
      only stamped. A platform setting that cannot be read is treated as on.
    * **notice** — a bell row and an email for each of the site-alert
      recipients (`KilnCMS.Security.Alerts.site_recipients/1`: its member
      admins, else the platform admins), muted or not, and the site's webhooks
      subscribed to `security.alerts_silenced`.

  ## Summaries

  A summary says how many of the kind the window held, and is sent only when
  that is more than the alert already said: more than one, or for
  `failed_sign_ins` more than the count that crossed the threshold. The
  count is the failed-sign-in tally's closed window, summed over its shards
  (`KilnCMS.Security.Alerts.failed_sign_in_total/2`), or the window's events
  re-classified (`KilnCMS.Security.Alerts.classify/2`) — a site alert's in
  its own org, a platform alert's across every org. A tally that is gone is
  logged and the summary skipped; it is never read as zero.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMS.Security
  alias KilnCMS.Security.AlertMail
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.AlertText
  alias KilnCMS.Webhooks
  alias KilnCMSWeb.Plugs.ConsoleHost

  @plan_key :security_alert_delivery

  @impl true
  def change(changeset, opts, _context) do
    phase = Keyword.fetch!(opts, :phase)

    changeset
    |> Ash.Changeset.before_transaction(&plan(&1, phase))
    |> Ash.Changeset.before_action(&deliver(&1, phase))
    |> Ash.Changeset.after_transaction(&announce/2)
  end

  # -- 1. Reads -------------------------------------------------------------

  defp plan(changeset, phase) do
    dispatch = changeset.data
    plan = build_plan(dispatch, phase)
    Ash.Changeset.set_context(changeset, %{@plan_key => plan})
  end

  @doc false
  # What a delivery of `dispatch` would send, read but not written. Public for
  # the tests' sake only.
  @spec build_plan(struct(), :alert | :summary) :: map()
  def build_plan(dispatch, phase) do
    org = organization!(dispatch.org_id)
    channel = dispatch.channel
    kind = if channel == :notice, do: :alerts_silenced, else: Alerts.kind(dispatch.kind)
    settings = if channel == :site, do: Alerts.settings_for(org.id)

    cond do
      kind == nil ->
        Logger.warning("Security alert #{dispatch.id} names an unknown kind; not sent.")
        empty_plan()

      turned_off?(channel, kind, settings) ->
        empty_plan()

      true ->
        case payload(dispatch, phase, kind, org, settings) do
          nil -> empty_plan()
          data -> audience(dispatch, kind, org, settings, data)
        end
    end
  end

  # A site kind the site turned off, or a platform kind a platform admin did:
  # stamped, nothing sent. A notice is never turned off.
  defp turned_off?(:site, kind, settings), do: not Alerts.enabled?(settings, kind)
  defp turned_off?(:platform, kind, _settings), do: not Alerts.platform_enabled?(kind)
  defp turned_off?(:notice, _kind, _settings), do: false

  defp empty_plan, do: %{data: nil, bell: [], mail: [], endpoints: [], event_name: nil}

  defp audience(dispatch, kind, org, settings, data) do
    {bell, mail} =
      case dispatch.channel do
        :platform ->
          admins = Alerts.platform_recipients()
          {admins, admins}

        :notice ->
          admins = Alerts.site_recipients(org)
          {admins, admins}

        :site ->
          if settings.notify_admins do
            admins = Alerts.site_recipients(org)
            {admins, Enum.filter(admins, & &1.notify_on_security_alert)}
          else
            {[], []}
          end
      end

    event_name = "security.#{kind}"

    endpoints =
      if dispatch.channel == :platform, do: [], else: endpoints!(org.id, event_name)

    %{
      data: data,
      bell: bell,
      mail: Enum.filter(mail, &(&1.email != nil)),
      mutable?: dispatch.channel == :site,
      endpoints: endpoints,
      event_name: event_name
    }
  end

  defp organization!(org_id) do
    Accounts.get_organization!(org_id, actor: Accounts.system(), authorize_with: :error)
  end

  # Active endpoints of the site subscribed to the event. As the webhook
  # pipeline's own actor, which may read endpoints and nothing more.
  defp endpoints!(org_id, event_name) do
    CMS.list_webhook_endpoints!(
      actor: Webhooks.system(),
      authorize_with: :error,
      tenant: org_id,
      query:
        Ash.Query.filter(
          CMS.WebhookEndpoint,
          ^event_name in events and active == true
        )
    )
    |> Enum.filter(&CMS.WebhookEndpoint.receives?(&1, event_name, false))
    |> Enum.sort_by(& &1.id)
  end

  # -- The payload (webhooks, bell and mail alike) ---------------------------

  defp payload(%{channel: :notice} = dispatch, _phase, _kind, org, _settings) do
    notice = dispatch.notice || %{}

    base(dispatch, org, "notice")
    |> Map.merge(%{
      kind: "alerts_silenced",
      occurred_at: iso(dispatch.inserted_at),
      change: notice["change"],
      kinds: notice["kinds"] || [],
      endpoint_id: notice["endpoint_id"],
      actor_id: notice["actor_id"]
    })
  end

  defp payload(dispatch, :alert, kind, org, settings) do
    event = event!(dispatch)

    base(dispatch, org, "alert")
    |> Map.merge(%{
      kind: Atom.to_string(kind),
      occurred_at: iso((event && event.inserted_at) || dispatch.inserted_at),
      window: window(dispatch),
      count: dispatch.threshold_count || 1
    })
    |> then(fn data ->
      if event,
        do: Map.put(data, :event, event_data(event, dispatch.channel, settings)),
        else: data
    end)
  end

  defp payload(dispatch, :summary, kind, org, _settings) do
    case summary_count(dispatch, kind) do
      nil ->
        nil

      count ->
        if count > (dispatch.threshold_count || 1) do
          base(dispatch, org, "summary")
          |> Map.merge(%{
            kind: Atom.to_string(kind),
            occurred_at: iso(dispatch.window_ends_at),
            window: window(dispatch),
            count: count
          })
        end
    end
  end

  defp base(dispatch, org, phase) do
    %{
      phase: phase,
      channel: Atom.to_string(dispatch.channel),
      site_id: org.id,
      site_name: KilnCMS.Branding.for_org(org).site_name,
      console_url: ConsoleHost.org_url(console_path(phase), org)
    }
  end

  # A notice is about the alert settings or a webhook, not an event in the log.
  defp console_path("notice"), do: "/editor/security-alerts"
  defp console_path(_phase), do: "/editor/security-log"

  defp window(dispatch),
    do: %{started_at: iso(dispatch.window_started_at), ends_at: iso(dispatch.window_ends_at)}

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # A platform alert always masks: no site chose to show the address. The
  # metadata is masked the same way (a block rule names an address).
  defp event_data(event, channel, settings) do
    settings = if channel == :site, do: settings

    %{
      id: event.id,
      type: to_string(event.type),
      actor_id: event.actor_id,
      target_type: event.target_type,
      target_id: event.target_id,
      ip: Alerts.display_ip(event.ip, settings),
      metadata: Alerts.display_metadata(event.type, event.metadata, settings)
    }
  end

  # The event the alert names, in the dispatch's org first (a site alert's
  # event is always there; a platform alert's usually is), then in every
  # other org. Gone (retention) is `nil`; refused raises.
  defp event!(%{first_event_id: nil}), do: nil

  defp event!(dispatch) do
    Enum.find_value(event_orgs(dispatch), fn org_id ->
      Security.get_event_for_alert!(dispatch.first_event_id,
        tenant: org_id,
        actor: Security.alerts_system(),
        authorize_with: :error,
        not_found_error?: false
      )
    end)
  end

  defp event_orgs(%{channel: :site, org_id: org_id}), do: [org_id]

  defp event_orgs(%{org_id: org_id}) do
    others =
      Accounts.list_organizations!(actor: Accounts.system(), authorize_with: :error)
      |> Enum.map(& &1.id)
      |> Enum.reject(&(&1 == org_id))
      |> Enum.sort()

    [org_id | others]
  end

  defp summary_count(dispatch, :failed_sign_ins) do
    case Alerts.failed_sign_in_total(dispatch.org_id, dispatch.window_index) do
      nil ->
        Logger.warning(
          "Security alert summary #{dispatch.id}: the failed sign-in tally for its window " <>
            "is gone; no summary sent."
        )

        nil

      count ->
        count
    end
  end

  defp summary_count(dispatch, kind) do
    types = Alerts.event_types(kind)
    target = {kind, dispatch.channel}

    dispatch
    |> event_orgs()
    |> Enum.map(fn org_id ->
      Security.alert_window_events!(
        types,
        dispatch.window_started_at,
        dispatch.window_ends_at,
        tenant: org_id,
        actor: Security.alerts_system(),
        authorize_with: :error
      )
      |> Enum.count(&(target in Alerts.classify(&1)))
    end)
    |> Enum.sum()
  end

  # -- 2. Writes, in the transaction ----------------------------------------

  defp deliver(changeset, phase) do
    stamp = if phase == :alert, do: :alert_sent_at, else: :summary_sent_at

    if Map.get(changeset.data, stamp) do
      # Delivered by another run while this one was reading.
      changeset
    else
      changeset.context
      |> Map.fetch!(@plan_key)
      |> send!(changeset.data)

      Ash.Changeset.force_change_attribute(changeset, stamp, DateTime.utc_now())
    end
  end

  defp send!(%{data: nil}, _dispatch), do: :ok

  defp send!(plan, dispatch) do
    notification = if dispatch.channel == :notice, do: :security_notice, else: :security_alert
    # The English line stays in `excerpt`, which is all a release before
    # `details` reads (a rollback shows it as before); `details` lets the
    # inbox say it in the reader's language (#2642).
    headline = AlertMail.headline(plan.data)
    details = AlertText.details(plan.data)

    Enum.each(plan.bell, fn user ->
      Notifications.record_notification!(
        %{
          user_id: user.id,
          event: notification,
          content_type: content_type(dispatch),
          content_id: dispatch.id,
          title: plan.data.site_name,
          excerpt: headline,
          details: details
        },
        tenant: dispatch.org_id
      )
    end)

    Enum.each(plan.mail, &AlertMail.deliver!(&1, plan.data, plan.mutable?))

    Enum.each(
      plan.endpoints,
      &Webhooks.enqueue_security!(&1, plan.event_name, plan.data, dispatch.org_id)
    )
  end

  # A platform alert's rows are told apart by their anchor, so the count of
  # unread platform alerts shown outside the default console
  # (`KilnCMS.Notifications.unread_platform_alert_count/1`) is one exact
  # filter. Rows written before this (`"security_alert_dispatch"`) stay where
  # they are, in the default console's bell.
  defp content_type(%{channel: :platform}), do: Notifications.platform_alert_content_type()
  defp content_type(_dispatch), do: "security_alert_dispatch"

  # -- 3. After the commit --------------------------------------------------

  defp announce(changeset, {:ok, _dispatch} = result) do
    changeset.context
    |> Map.get(@plan_key, %{bell: []})
    |> Map.get(:bell, [])
    |> Enum.each(fn user ->
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        Notifications.topic(user.id),
        :notifications_changed
      )
    end)

    result
  end

  defp announce(_changeset, result), do: result
end
