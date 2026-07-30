defmodule KilnCMSWeb.BillingWebhookController do
  @moduledoc """
  Inbound payment-provider webhooks (#337 Phase 2).

  Authorized by the provider's HMAC signature over the **raw** request body — not
  by a session — so the route is CSRF-free and every action runs
  `authorize?: false` behind that verification. The raw bytes are preserved by
  `KilnCMSWeb.Plugs.RawBodyReader`; re-encoding the parsed JSON would not reproduce
  them.

  ## Verify → record → enqueue → ack

  Processing is **not** inline. The provider times out at around 20 seconds and
  treats a timeout as a failure, while handling an event does one or two outbound
  API calls plus a multi-row transaction — an inline bet against an external API on
  a path whose failure mode is "the provider disables our endpoint". Recording
  before enqueuing also means the durable dedupe record exists before any work
  starts.

  ## This controller must never read the ambient tenant

  `KilnCMSWeb.Plugs.SetTenant` resolves the tenant from `conn.host` and falls back
  to the default org for an unknown host; a webhook arrives at whatever host the
  provider was configured with. Organization resolution happens from the event, in
  `KilnCMS.Billing.Webhooks`.

  ## Status codes

  | Condition | Code | Why |
  |---|---|---|
  | billing not configured | 404 | don't confirm the route exists on an unconfigured instance |
  | missing raw body | 400 | reader misconfiguration; must be loud |
  | missing/invalid signature | 400 | the provider's convention. Not 401/403, which invite retry loops and read as a WAF block |
  | malformed payload, or no id/type | 400 | genuine malformation, post-verification |
  | duplicate event id | 200 | we already have it; anything else makes the provider retry work we've done |
  | unhandled event type | 200 | success from the provider's view; no row written |
  | recorded and enqueued | 200 | |
  | record/enqueue failure | 500 | we have *not* durably accepted it, so the provider must retry. The only 5xx |
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Billing
  alias KilnCMS.Billing.Subscriptions
  alias KilnCMS.Billing.WebhookEvent

  @signature_header "stripe-signature"

  def stripe(conn, _params) do
    if Billing.configured?() do
      handle(conn)
    else
      send_resp(conn, :not_found, "")
    end
  end

  defp handle(conn) do
    with {:ok, raw_body} <- raw_body(conn),
         {:ok, secret} <- webhook_secret(),
         {:ok, event} <- verify(raw_body, signature(conn), secret),
         {:ok, id, type} <- identify(event) do
      record(conn, event, id, type)
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  # A verified event we don't act on is acked without writing a row, so a
  # misconfigured endpoint sending every event type can't fill the table.
  defp record(conn, event, id, type) do
    if Subscriptions.handled?(type) do
      insert_and_enqueue(conn, event, id, type)
    else
      send_resp(conn, :ok, "")
    end
  end

  defp insert_and_enqueue(conn, event, id, type) do
    case Billing.receive_webhook_event(
           %{provider: :stripe, provider_event_id: id, type: type, payload: event},
           authorize?: false
         ) do
      {:ok, record} ->
        enqueue(conn, record)

      {:error, %{errors: errors}} ->
        # A duplicate is matched STRUCTURALLY on the dedupe identity, never on
        # error text. Ack it: we already hold this event.
        if WebhookEvent.duplicate?(errors) do
          send_resp(conn, :ok, "")
        else
          Logger.error("billing webhook: could not record event #{id}")
          send_resp(conn, :internal_server_error, "")
        end

      {:error, _reason} ->
        Logger.error("billing webhook: could not record event #{id}")
        send_resp(conn, :internal_server_error, "")
    end
  end

  defp enqueue(conn, record) do
    case %{"webhook_event_id" => record.id}
         |> KilnCMS.Billing.WebhookWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        send_resp(conn, :ok, "")

      {:error, _reason} ->
        # The row exists but nothing will process it, so ask for a retry: the
        # dedupe read path will find the existing row and re-enqueue.
        Logger.error("billing webhook: could not enqueue event #{record.provider_event_id}")
        send_resp(conn, :internal_server_error, "")
    end
  end

  defp reject(conn, reason) do
    # Logged without the body or the signature header — neither belongs in logs.
    Logger.warning("billing webhook rejected: #{inspect(reason)}")
    send_resp(conn, :bad_request, "")
  end

  defp raw_body(conn) do
    case conn.private[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _other -> {:error, :missing_raw_body}
    end
  end

  defp webhook_secret do
    case Billing.credentials() do
      {:ok, %{webhook_secret: secret}} -> {:ok, secret}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signature(conn) do
    case get_req_header(conn, @signature_header) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp verify(raw_body, signature, secret) do
    case Billing.provider().verify_webhook(raw_body, signature, secret, []) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp identify(%{"id" => id, "type" => type}) when is_binary(id) and is_binary(type),
    do: {:ok, id, type}

  defp identify(_event), do: {:error, :missing_event_id_or_type}
end
