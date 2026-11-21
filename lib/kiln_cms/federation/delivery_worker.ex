defmodule KilnCMS.Federation.DeliveryWorker do
  @moduledoc """
  POSTs one signed activity to one remote inbox (#491).

  The same reliability shape `KilnCMS.Webhooks.DeliveryWorker` has — a ledger
  row per delivery, attempts recorded, exhaustion counted against the recipient
  — with the fediverse's differences baked in:

    * **more attempts.** A webhook receiver that is down is usually a bug
      someone is fixing; a fediverse instance that is down is often just
      restarting, or rate-limiting, or having a bad afternoon. Mastodon retries
      for days, and giving up in five minutes would drop deliveries that would
      have landed.
    * **the recipient is dropped, not disabled.** A webhook endpoint belongs to
      the site's own admin, who can re-enable it. A follower belongs to a
      stranger on another server; there is no one here to notice a disabled
      row, so past `KilnCMS.Federation.drop_follower_after/0` it is deleted and
      the remote server is free to follow again.

  ## One POST, every follower behind it

  A delivery is per inbox, not per follower (#2753), so its outcome is
  recorded against everyone that inbox stands for: with `follower_id` set,
  exactly that follower; with it `nil`, every follower whose deliveries go to
  the row's `inbox_uri` when the delivery settles (`Follower`'s `:at_inbox`).
  A success resets all of them and an exhausted failure charges each one, in a
  single atomic `UPDATE`, and drops those it takes to the ceiling.

  Requests go through `KilnCMS.SafeFetch`, which pins the resolved address and
  restores the real hostname in a `Host` header. The signature is computed
  against that real host — see `KilnCMS.Federation.HttpSignature` — so this
  must not supply a `host` header of its own.
  """
  use Oban.Worker, queue: :federation, max_attempts: 12

  alias KilnCMS.Federation
  alias KilnCMS.Federation.Actor
  alias KilnCMS.Federation.Delivery
  alias KilnCMS.Federation.Follower
  alias KilnCMS.Federation.HttpSignature
  alias KilnCMS.Federation.SiteFederation

  require Ash.Query
  require Logger

  @accepted_statuses 200..299

  @key_unreadable "this site's signing key is unreadable — was SECRET_KEY_BASE rotated " <>
                    "without re-encrypting? See docs/secrets-rotation.md"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    %{"org_id" => org_id, "delivery_id" => delivery_id} = args

    case Ash.get(Delivery, delivery_id,
           actor: Federation.system(),
           tenant: org_id,
           authorize_with: :error
         ) do
      {:ok, delivery} ->
        attempt(delivery, org_id, attempt, attempt >= max_attempts)

      {:error, error} ->
        # The ledger row was pruned out from under the job: nothing to deliver
        # and nothing to record, so succeeding is the honest outcome. Any OTHER
        # failed read (a timeout, a refused read) is not that — retry it rather
        # than drop the activity and leave the row `:pending` forever.
        if not_found?(error), do: :ok, else: {:error, error}
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.all?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(_error), do: false

  # Mastodon-ish backoff: quick early retries for a restart, then hours. Capped
  # so a dead instance does not hold a job for a week.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(30 * round(:math.pow(2, attempt)), 6 * 60 * 60)
  end

  defp attempt(delivery, org_id, attempt, last_attempt?) do
    case site_settings(org_id) do
      {:ok, settings} ->
        deliver(delivery, settings, org_id, attempt, last_attempt?)

      # Settle rather than retry, either way: nothing about waiting switches
      # federation back on or makes an unreadable key readable.
      :off ->
        settle(delivery, org_id, :failed, attempt, nil, "federation is not enabled for this site")
        :ok

      # Told apart from `:off` (#1487): the site is on and means to deliver, but
      # the vault cannot open its key — almost always `SECRET_KEY_BASE` rotated
      # without `PREVIOUS_SECRET_KEY_BASE` or the re-encryption task. Saying
      # "not enabled" here sent operators to the wrong switch.
      :key_unreadable ->
        Logger.warning(
          "Federation delivery #{delivery.id} not sent: this site's signing key is unreadable"
        )

        settle(delivery, org_id, :failed, attempt, nil, @key_unreadable)
        :ok
    end
  end

  defp deliver(delivery, settings, org_id, attempt, last_attempt?) do
    identity = Actor.identity(settings)
    body = Jason.encode!(delivery.activity)

    with {:ok, headers} <-
           HttpSignature.sign(delivery.inbox_uri, identity.key_id, body,
             private_key_pem: SiteFederation.private_key_pem(settings)
           ),
         {:ok, %{status: status}} when status in @accepted_statuses <-
           post(delivery.inbox_uri, body, headers) do
      settle(delivery, org_id, :delivered, attempt, status, nil)
      record_success(delivery, org_id)
      :ok
    else
      {:ok, %{status: status}} ->
        fail(delivery, org_id, attempt, status, "inbox answered #{status}", last_attempt?)

      {:error, reason} ->
        fail(delivery, org_id, attempt, nil, to_string(reason), last_attempt?)
    end
  end

  defp post(inbox_uri, body, headers) do
    KilnCMS.SafeFetch.post(inbox_uri, body,
      headers: headers,
      receive_timeout: 15_000,
      # An inbox that redirects is not an inbox. Following one would re-POST a
      # signed activity to a host the signature never covered.
      max_redirects: 0,
      req_options: Federation.req_options()
    )
  end

  # A retryable failure stays `:pending` so the ledger does not claim a verdict
  # the job has not reached; only the last attempt settles.
  defp fail(delivery, org_id, attempt, status, error, false = _last_attempt?) do
    settle(delivery, org_id, :pending, attempt, status, error)
    {:error, error}
  end

  defp fail(delivery, org_id, attempt, status, error, true = _last_attempt?) do
    settle(delivery, org_id, :failed, attempt, status, error)
    record_failure(delivery, org_id)
    # `:ok`, not an error: the attempt is exhausted and recorded. Returning an
    # error here would only mark the job discarded for the same fact.
    :ok
  end

  defp settle(delivery, org_id, state, attempt, status, error) do
    Ash.update!(
      delivery,
      %{state: state, attempts: attempt, last_status: status, last_error: truncate(error)},
      action: :settle,
      actor: Federation.system(),
      tenant: org_id
    )
  rescue
    error ->
      Logger.warning("Federation delivery #{delivery.id} could not be settled: #{inspect(error)}")
      :ok
  end

  defp record_success(delivery, org_id) do
    case delivery
         |> covered_followers(org_id)
         |> Federation.record_follower_success(
           actor: Federation.system(),
           tenant: org_id,
           bulk_options: [strategy: :atomic]
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      # Not crediting them leaves their failure count standing, and the
      # ceiling may later drop them: say so rather than lose it.
      %Ash.BulkResult{errors: errors} ->
        Logger.warning(
          "Federation delivery #{delivery.id} could not credit its followers: #{inspect(errors)}"
        )
    end

    # The site's own "last federated" line (#967) — system-side, its own
    # action so no settings form can backdate it.
    with {:ok, settings} <- Federation.active_settings(org_id) do
      Federation.record_site_delivery(settings, actor: Federation.system(), tenant: org_id)
    end

    :ok
  end

  defp record_failure(delivery, org_id) do
    case delivery
         |> covered_followers(org_id)
         |> Federation.record_follower_failure(
           actor: Federation.system(),
           tenant: org_id,
           bulk_options: [strategy: :atomic, return_records?: true]
         ) do
      %Ash.BulkResult{status: :success, records: followers} ->
        Enum.each(followers, &drop_if_dead(&1, org_id))

      %Ash.BulkResult{errors: errors} ->
        Logger.warning(
          "Federation delivery #{delivery.id} could not charge its followers: #{inspect(errors)}"
        )
    end

    :ok
  end

  # Whose bookkeeping a delivery's outcome lands on (#2753), as a query the
  # atomic updates above run against:
  #
  #   * `follower_id` set — exactly that follower. An inbox only one follower
  #     used when the row was written, and every `Accept`. A follower dropped
  #     since matches nothing, which is the right amount of bookkeeping.
  #   * `follower_id` nil — everyone whose deliveries go to `inbox_uri` when
  #     the delivery settles: the shared inbox the one POST reached. A follower
  #     who arrived at that inbox after the row was written is counted too; it
  #     is the same endpoint, and its outcome is theirs as much as anyone's.
  defp covered_followers(%{follower_id: nil, inbox_uri: inbox_uri}, org_id) do
    Ash.Query.for_read(Follower, :at_inbox, %{inbox_uri: inbox_uri},
      actor: Federation.system(),
      tenant: org_id
    )
  end

  defp covered_followers(%{follower_id: follower_id}, org_id) do
    Follower
    |> Ash.Query.for_read(:read, %{}, actor: Federation.system(), tenant: org_id)
    |> Ash.Query.filter(id == ^follower_id)
  end

  # Deleted rather than flagged: there is no admin on the other side to notice,
  # and a deleted follower can simply follow again if the instance comes back.
  defp drop_if_dead(follower, org_id) do
    if follower.consecutive_failures >= Federation.drop_follower_after() do
      Logger.info(
        "Dropping federation follower #{follower.actor_uri} after " <>
          "#{follower.consecutive_failures} consecutive failures"
      )

      Federation.destroy_follower(follower, actor: Federation.system(), tenant: org_id)
    end

    :ok
  end

  # One query for the three callers (#967) — `Federation.active_settings/2`;
  # this one signs, so it needs the private key.
  defp site_settings(org_id), do: Federation.active_settings(org_id, require_key?: true)

  defp truncate(nil), do: nil
  defp truncate(error), do: String.slice(to_string(error), 0, 500)
end
