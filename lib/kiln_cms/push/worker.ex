defmodule KilnCMS.Push.Worker do
  @moduledoc """
  Delivers one Web Push notification to one subscription (#628).

  Enqueued by `KilnCMS.Push.notify/2`, one job per subscription, mirroring how
  `KilnCMS.Notifications` enqueues one mail job per recipient: the editor's
  request never blocks on a third-party HTTP call, and one dead device does not
  hold up the others.

  ## Which failures are terminal

  A push service's status codes divide cleanly, and getting the division wrong
  is expensive in both directions — retrying a dead subscription burns a job
  slot every notification forever, and discarding a rate-limited one loses a
  notification a reviewer was waiting for.

    * `404` / `410` — the subscription is gone (permission revoked, site data
      cleared, browser uninstalled). Terminal: the row is deleted.
    * `403` — the VAPID signature is not the one this subscription was created
      with, i.e. the deployment rotated its keys. Also terminal, and also a
      pruned row: it will never start matching again.
    * `413` — the payload was too large. Terminal, and a bug on our side rather
      than the device's, so it is logged loudly and the row is left alone.
    * `429` and `5xx` — the push service is busy or broken. Retried on Oban's
      backoff.
    * A transport error — retried.

  ## The job carries an id, not a subscription

  Oban args are JSON in a database row that may sit in the queue for minutes. A
  subscription's `endpoint` and `auth` are bearer secrets (see
  `KilnCMS.Accounts.PushSubscription`), and serializing them into `oban_jobs`
  would put them somewhere no one thinks of as a credential store — visible in
  the Oban dashboard, in a database dump, and in any error report that includes
  the job. The row is loaded at perform time instead; a subscription deleted in
  between simply has nothing to deliver to.
  """
  use Oban.Worker, queue: :mail, max_attempts: 5

  require Logger

  alias KilnCMS.Accounts.PushSubscription
  alias KilnCMS.Push
  alias KilnCMS.Push.Encryption
  alias KilnCMS.Push.Vapid
  alias KilnCMS.SafeFetch

  # RFC 8030 §5.2. Four hours: long enough that a phone which was off overnight
  # still gets a morning review request, short enough that a week-old one is not
  # delivered as though it were news.
  @ttl_seconds 4 * 60 * 60

  # A push service accepts a body up to its own limit; this is well inside every
  # one of them and inside `Encryption`'s single record.
  @gone_statuses [404, 410]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id, "payload" => payload}}) do
    case Ash.get(PushSubscription, id, authorize?: false, not_found_error?: false) do
      {:ok, nil} -> :ok
      {:ok, subscription} -> deliver(subscription, payload)
      # A read failure is infrastructure, not a dead device — let Oban retry.
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver(subscription, payload) do
    with {:ok, keys} <- decode_keys(subscription),
         {:ok, body} <- Encryption.encrypt(Jason.encode!(payload), keys),
         {:ok, authorization} <- Vapid.authorization(subscription.endpoint) do
      subscription
      |> post(body, authorization)
      |> handle(subscription)
    else
      {:error, reason} ->
        # An unencryptable subscription is malformed storage, not a transient
        # fault: retrying cannot fix a 12-byte auth secret. Prune it, so the
        # reviewer's next opt-in writes a good row instead of colliding with a
        # bad one on the endpoint identity.
        Logger.warning("Dropping unsendable push subscription: #{inspect(reason)}")
        Push.prune(subscription, reason)
    end
  end

  defp post(subscription, body, authorization) do
    SafeFetch.post(subscription.endpoint, body,
      headers: [
        {"authorization", authorization},
        {"content-encoding", "aes128gcm"},
        {"content-type", "application/octet-stream"},
        {"ttl", Integer.to_string(@ttl_seconds)},
        # "Wake the device now." The alternative, `normal`, lets a push service
        # hold the message until the device next wakes on its own — which for a
        # review request is the difference between a notification and a log
        # entry. It is also what browsers require for a payload-bearing push.
        {"urgency", "high"}
      ],
      # A push service answers 201 with an empty body; anything large is a
      # misconfigured URL, and this is the SSRF-hardened client either way.
      max_bytes: 8 * 1024,
      # The seam a test stubs, same as every other outbound caller here.
      req_options: req_options()
    )
  end

  defp req_options,
    do: :kiln_cms |> Application.get_env(KilnCMS.Push, []) |> Keyword.get(:req_options, [])

  defp handle({:ok, %{status: status}}, subscription) when status in 200..299,
    do: touch_delivered(subscription)

  defp handle({:ok, %{status: status}}, subscription) when status in @gone_statuses,
    do: Push.prune(subscription, {:gone, status})

  defp handle({:ok, %{status: 403}}, subscription) do
    Logger.warning(
      "Push service rejected our VAPID signature (403). The deployment's key pair no " <>
        "longer matches this subscription — pruning it; the reviewer must re-enable " <>
        "notifications in /editor/settings."
    )

    Push.prune(subscription, {:vapid_rejected, 403})
  end

  defp handle({:ok, %{status: 413}}, _subscription) do
    # Ours to fix, not the device's. Discarding rather than retrying: the same
    # payload will be the same size on attempt five.
    Logger.error("Push payload rejected as too large (413) — this is a bug in the sender.")
    {:cancel, :payload_too_large}
  end

  # Rate limiting. Retried, not cancelled: the push service is telling us to
  # come back, and discarding here loses a notification somebody is waiting for.
  # It has to precede the general 4xx clause, which would otherwise swallow it.
  defp handle({:ok, %{status: 429}}, _subscription), do: {:error, {:rate_limited, 429}}

  defp handle({:ok, %{status: status}}, _subscription) when status in 400..499 do
    # Every other 4xx is a request we built wrong; retrying it five times just
    # multiplies the same mistake.
    Logger.error("Push service refused the request with #{status}.")
    {:cancel, {:rejected, status}}
  end

  defp handle({:ok, %{status: status}}, _subscription),
    do: {:error, {:push_service_error, status}}

  defp handle({:error, reason}, _subscription), do: {:error, reason}

  # The browser stores both keys base64url-encoded; the crypto wants raw bytes.
  # A row that will not decode is malformed storage — `Encryption` would refuse
  # it on length anyway, and saying so here keeps the reason specific.
  defp decode_keys(%{p256dh: p256dh, auth: auth}) do
    with {:ok, key} <- Base.url_decode64(p256dh, padding: false),
         {:ok, secret} <- Base.url_decode64(auth, padding: false) do
      {:ok, %{p256dh: key, auth: secret}}
    else
      :error -> {:error, :undecodable_keys}
    end
  end

  # Best-effort bookkeeping: "this device was reachable at least once" is what
  # makes a never-deliverable subscription visible in the settings list, and it
  # must not turn a delivered notification into a failed job.
  defp touch_delivered(subscription) do
    Ash.update(subscription, %{}, action: :touch_delivered, authorize?: false)
    :ok
  rescue
    _error -> :ok
  end
end
