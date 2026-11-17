defmodule KilnCMS.Webhooks.HealthNotice do
  @moduledoc """
  Telling a site's admins that one of its webhooks is not getting through.

  A webhook endpoint that exhausts its retries on `KilnCMS.Webhooks.auto_disable_after/0`
  deliveries in a row is switched off (see `KilnCMS.Webhooks`). Before this
  module that happened in silence: the delivery ledger and the Disabled badge
  on `/editor/webhooks` said so, and nobody reads either until they already
  suspect something — typically when new content has stopped appearing on a
  site that is rebuilt by a webhook.

  `surface/2` compares the endpoint before and after
  `KilnCMS.CMS.WebhookEndpoint`'s `:record_delivery_failure` and raises:

  | when | event |
  |------|-------|
  | the first exhausted delivery in a row (`consecutive_failures` 0 → 1, still active) | `:webhook_failing` |
  | the failure that auto-disabled it (active → inactive) | `:webhook_disabled` |

  Nothing for the failures in between: the first notice already said the
  endpoint is failing, and the next thing worth hearing is that it was
  switched off.

  ## What an admin gets

  An in-app notice (the bell, `/editor/inbox`) linking to `/editor/webhooks`,
  and an email to the same effect
  (`KilnCMS.Accounts.User.Senders.SendWebhookFailure`). Both events collapse
  per endpoint (`KilnCMS.Notifications.record_in_app_result/1`): while a
  notice about an endpoint is unread, another of the same event is not
  written, and the email goes only with a new row. Opening the webhooks page
  marks them read (`KilnCMSWeb.WebhookLive`).

  `User.notify_on_webhook_failure` mutes the email only; the bell row is
  always written.

  ## What it says

  The endpoint by its masked URL (`KilnCMS.Webhooks.display_url/1`, ADR 0028
  — an incoming-webhook URL is the credential), never the delivery's error:
  a receiver's error text can echo the URL back. The webhooks page shows the
  error to the admins who may see it.

  Retractions are not counted here: they never count towards auto-disable,
  and one that is lost is announced by `KilnCMS.Webhooks.RetractionLost`.

  Best effort, like every notifier: the delivery has already failed, and a
  notice that cannot be written is logged rather than raised into the worker.
  """
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User.Senders.SendWebhookFailure
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Registrations

  @content_type "webhook_endpoint"

  @typedoc "What `surface/2` raised."
  @type event :: :webhook_failing | :webhook_disabled

  @doc "The notification events this module writes."
  @spec events() :: [event()]
  def events, do: [:webhook_failing, :webhook_disabled]

  @doc """
  The event a failure that took `before` to `after_failure` raises, or `nil`.
  Pure; see the moduledoc's table.
  """
  @spec event_for(map(), map()) :: event() | nil
  def event_for(%{active: true}, %{active: false}), do: :webhook_disabled

  def event_for(%{active: true} = before, %{active: true, consecutive_failures: 1}) do
    if (before.consecutive_failures || 0) == 0, do: :webhook_failing
  end

  def event_for(_before, _after_failure), do: nil

  @doc """
  Announce the failure that took the endpoint from `before` to
  `after_failure`, if it is news (`event_for/2`). Returns `:ok`; never raises.
  """
  @spec surface(map(), map()) :: :ok
  def surface(before, after_failure) do
    case event_for(before, after_failure) do
      nil -> :ok
      event -> announce(event, after_failure)
    end
  end

  defp announce(event, endpoint) do
    url = KilnCMS.Webhooks.display_url(endpoint.url)

    Logger.warning(
      "Webhook endpoint #{endpoint.id} (#{url}) #{log_phrase(event)} after " <>
        "#{endpoint.consecutive_failures} failed deliveries in a row"
    )

    case Accounts.get_organization(endpoint.org_id,
           actor: Accounts.system(),
           authorize_with: :error
         ) do
      {:ok, org} ->
        endpoint.org_id
        |> recipients()
        |> Enum.each(&notify(&1, event, endpoint, org, url))

      {:error, error} ->
        Logger.error(
          "Webhook health notice for endpoint #{endpoint.id}: could not read the site: " <>
            Exception.message(error)
        )
    end

    :ok
  rescue
    error ->
      Logger.error(
        "Webhook health notice for endpoint #{endpoint.id} not recorded: " <>
          Exception.message(error)
      )

      :ok
  end

  defp log_phrase(:webhook_failing), do: "is failing"
  defp log_phrase(:webhook_disabled), do: "was switched off"

  @doc """
  Who hears about `org_id`'s webhooks: the same admins as the registration
  notice (`KilnCMS.Notifications.Registrations.recipients/1`) — a standing
  platform admin, or an active admin membership on the site, not erased. A
  temporary platform admin is left out, so everyone told is also offered the
  settings switch that mutes the email (`administers_any_site?/1`).
  """
  @spec recipients(Ash.UUID.t()) :: [Accounts.User.t()]
  def recipients(org_id), do: Registrations.recipients(org_id)

  defp notify(admin, event, endpoint, org, url) do
    outcome =
      Notifications.record_in_app_result(%{
        user_id: admin.id,
        org_id: endpoint.org_id,
        event: event,
        content_type: @content_type,
        content_id: endpoint.id,
        block_id: nil,
        title: url,
        excerpt: excerpt(event, endpoint),
        actor_id: nil,
        actor_name: nil
      })

    if outcome == :recorded and admin.notify_on_webhook_failure and admin.email do
      SendWebhookFailure.deliver(admin, org, event, url, endpoint.consecutive_failures)
    end

    :ok
  rescue
    error ->
      Logger.error(
        "Webhook health notice for admin #{admin.id} not sent: #{Exception.message(error)}"
      )

      :ok
  end

  defp excerpt(:webhook_failing, _endpoint),
    do: "A delivery failed after every retry. Content changes may not be reaching this receiver."

  defp excerpt(:webhook_disabled, endpoint),
    do:
      "Switched off after #{endpoint.consecutive_failures} failed deliveries in a row. " <>
        "Nothing is sent to it until an admin turns it back on."
end
