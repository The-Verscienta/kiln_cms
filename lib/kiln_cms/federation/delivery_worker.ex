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

  Requests go through `KilnCMS.SafeFetch`, which pins the resolved address and
  restores the real hostname in a `Host` header. The signature is computed
  against that real host — see `KilnCMS.Federation.HttpSignature` — so this
  must not supply a `host` header of its own.
  """
  use Oban.Worker, queue: :federation, max_attempts: 12

  alias KilnCMS.Federation
  alias KilnCMS.Federation.Actor
  alias KilnCMS.Federation.Delivery
  alias KilnCMS.Federation.HttpSignature
  alias KilnCMS.Federation.SiteFederation

  require Logger

  @accepted_statuses 200..299

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    %{"org_id" => org_id, "delivery_id" => delivery_id} = args

    case Ash.get(Delivery, delivery_id, authorize?: false, tenant: org_id) do
      {:ok, delivery} -> attempt(delivery, org_id, attempt, attempt >= max_attempts)
      # The ledger row was pruned out from under the job. Nothing to deliver and
      # nothing to record — succeeding is the honest outcome.
      _other -> :ok
    end
  end

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

      :skip ->
        # Federation was switched off, or the key is unreadable. Settle rather
        # than retry: nothing about waiting makes an absent signing key appear.
        settle(delivery, org_id, :failed, attempt, nil, "federation is not enabled for this site")
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
      authorize?: false,
      tenant: org_id
    )
  rescue
    error ->
      Logger.warning("Federation delivery #{delivery.id} could not be settled: #{inspect(error)}")
      :ok
  end

  defp record_success(%{follower_id: nil}, _org_id), do: :ok

  defp record_success(delivery, org_id) do
    with {:ok, follower} <- follower(delivery, org_id) do
      Federation.record_follower_success(follower, authorize?: false, tenant: org_id)
    end

    :ok
  end

  defp record_failure(%{follower_id: nil}, _org_id), do: :ok

  defp record_failure(delivery, org_id) do
    with {:ok, follower} <- follower(delivery, org_id),
         {:ok, updated} <-
           Federation.record_follower_failure(follower, authorize?: false, tenant: org_id) do
      drop_if_dead(updated, org_id)
    end

    :ok
  end

  # Deleted rather than flagged: there is no admin on the other side to notice,
  # and a deleted follower can simply follow again if the instance comes back.
  defp drop_if_dead(follower, org_id) do
    if follower.consecutive_failures >= Federation.drop_follower_after() do
      Logger.info(
        "Dropping federation follower #{follower.actor_uri} after " <>
          "#{follower.consecutive_failures} consecutive failures"
      )

      Federation.destroy_follower(follower, authorize?: false, tenant: org_id)
    end

    :ok
  end

  defp site_settings(org_id) do
    case Federation.list_site_federation(authorize?: false, tenant: org_id) do
      {:ok, [%{enabled: true, origin: origin} = settings]} when is_binary(origin) ->
        if SiteFederation.private_key_pem(settings), do: {:ok, settings}, else: :skip

      _other ->
        :skip
    end
  end

  # The follower a delivery was addressed to, or `:error` when its row is gone
  # (a dropped dead instance). Read through the domain's list interface rather
  # than `Ash.get/3` so this stays on the code-interface contract AGENTS.md
  # sets; the list is bounded by the per-site follower ceiling.
  defp follower(%{follower_id: id}, org_id) do
    case Federation.list_followers(authorize?: false, tenant: org_id) do
      {:ok, followers} ->
        case Enum.find(followers, &(&1.id == id)) do
          nil -> :error
          follower -> {:ok, follower}
        end

      _other ->
        :error
    end
  end

  defp truncate(nil), do: nil
  defp truncate(error), do: String.slice(to_string(error), 0, 500)
end
