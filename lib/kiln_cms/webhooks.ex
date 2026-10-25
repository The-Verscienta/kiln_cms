defmodule KilnCMS.Webhooks do
  @moduledoc """
  Outbound webhook dispatch, with a **delivery ledger**.

  When content is published, `dispatch/2` records one `WebhookDelivery` row
  and enqueues one `DeliveryWorker` Oban job per active, subscribed endpoint.
  Deliveries are signed with HMAC-SHA256 using the endpoint's secret, so
  receivers can verify authenticity.

  ## Signatures

  Every delivery carries one signature,
  `x-kilncms-webhook-signature: t=<unix seconds>,v1=<hex>` — the HMAC of
  `"<t>.<raw body>"`. Binding the time into the MAC is what lets a receiver
  refuse a captured request replayed later: reject anything whose `t` is more
  than `signature_tolerance/0` seconds from its own clock. The body also
  carries `delivery_id` (echoed in `x-kilncms-delivery-id`), stable across a
  delivery's retries, so a receiver can drop a duplicate inside the window too.
  `verify/4` is the reference implementation.

  The original body-only `x-kilncms-signature` (the HMAC of the body alone,
  proving origin but not freshness) was deprecated in 0.10.0 and is no longer
  sent since 0.12.0 (#1616).

  Each attempt is signed when it is sent, so a retry carries a fresh `t`.

  Reliability model (surfaced at `/editor/webhooks`):

    * every attempt updates the delivery row (attempt count, last HTTP
      status, last error); Oban retries with exponential backoff up to the
      worker's `max_attempts`;
    * a delivery that exhausts its retries is marked `:failed` and counts
      against the endpoint's `consecutive_failures` — after
      `auto_disable_after/0` in a row the endpoint is **auto-disabled**
      (a success while the endpoint is active, or an admin edit, resets the
      count; a ping or retraction that gets through to an inactive endpoint
      does not);
    * a **retraction** (`retraction?/1`: `<type>.unpublished`, `.archived`,
      `.deleted` of a document that was published) is the exception (#1926) —
      see "Retractions" below;
    * `redeliver/1` replays any delivery as a fresh ledger row;
    * `ping/1` sends a test `"ping"` event so admins can verify a receiver
      before (or after) going live — it delivers even to inactive endpoints.

  ## Retractions (#1926)

  Auto-disable exists so a dead receiver stops burning the queue on every
  publish. Applied to a retraction it does the opposite of what anyone wants:
  a consumer that has been failing `updated` deliveries for an hour is
  disabled, and the `unpublished` that follows is never sent, so the consumer
  keeps serving a document the site has withdrawn. For clinical content that is
  the one delivery that must not be dropped. So a retraction:

    * goes to every subscribed endpoint that is active **or auto-disabled**
      (one an admin switched off stays off: that is a decision, not a fault —
      `KilnCMS.CMS.WebhookEndpoint.receives?/3` is the rule);
    * is retried on its own, longer schedule (`retraction_max_attempts/0`
      attempts, `retraction_backoff/1` apart — about a day) — except to an
      endpoint auto-disabled for longer than `retraction_stale_after_days/0`,
      which gets one attempt, so a long-dead receiver cannot tie up the queue
      for a day per retraction;
    * never counts against `consecutive_failures`, and never re-enables an
      auto-disabled endpoint by succeeding;
    * when it does exhaust, is surfaced rather than left as a ledger row:
      `KilnCMS.Webhooks.RetractionLost` tells the site's admins in the console
      and the delivery shows on the document's governance trail
      (`lost_retractions/3`). The console notice is skipped for a stale
      endpoint (see above): its losses were announced while it was fresh, and
      a bulk archive must not send a notice per document. A failed retraction
      row is kept past the ledger's retention window (its body is not) and
      through its endpoint's deletion, so the trail does not lose it.
  """
  alias KilnCMS.CMS
  alias KilnCMS.Webhooks.DeliveryWorker

  require Ash.Query
  require Logger

  @timestamped_signature_header "x-kilncms-webhook-signature"
  @delivery_id_header "x-kilncms-delivery-id"
  @event_header "x-kilncms-event"
  @signature_tolerance 300

  @doc "The timestamped signature header (`t=…,v1=…`)."
  def timestamped_signature_header, do: @timestamped_signature_header
  def delivery_id_header, do: @delivery_id_header
  def event_header, do: @event_header

  @doc """
  How far, in seconds, a receiver should let a signature's `t` stray from its
  own clock before refusing it: five minutes, the window the docs publish and
  `verify/4` defaults to.
  """
  @spec signature_tolerance() :: pos_integer()
  def signature_tolerance, do: @signature_tolerance

  @doc """
  The `x-kilncms-webhook-signature` value for `body` sent at `timestamp` (unix
  seconds): `"t=<timestamp>,v1=<hex HMAC-SHA256 of \"<timestamp>.<body>\">"`.
  """
  @spec timestamped_signature(String.t(), integer(), iodata()) :: String.t()
  def timestamped_signature(secret, timestamp, body) when is_integer(timestamp) do
    "t=#{timestamp},v1=#{hmac_hex(secret, [Integer.to_string(timestamp), ".", body])}"
  end

  @doc """
  Verify an `x-kilncms-webhook-signature` header against the raw `body` — what
  a receiver does, and what the client libraries mirror.

  `:ok`, or `{:error, reason}` for a header that does not parse
  (`:malformed`), a `t` outside the tolerance (`:expired`), or no `v1` that
  matches (`:mismatch`). Several `v1` entries are accepted, any one matching,
  so a receiver keeps working while a secret is rolled.

  Options: `:tolerance` (seconds, default `signature_tolerance/0`) and `:now`
  (unix seconds, default the system clock).
  """
  @spec verify(String.t(), iodata(), String.t() | nil, keyword()) ::
          :ok | {:error, :malformed | :expired | :mismatch}
  def verify(secret, body, header, opts \\ [])

  def verify(secret, body, header, opts) when is_binary(header) do
    tolerance = Keyword.get(opts, :tolerance, @signature_tolerance)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, timestamp, candidates} <- parse_signature(header),
         :ok <- fresh(timestamp, now, tolerance) do
      expected = hmac_hex(secret, [Integer.to_string(timestamp), ".", body])

      if Enum.any?(candidates, &Plug.Crypto.secure_compare(&1, expected)),
        do: :ok,
        else: {:error, :mismatch}
    end
  end

  def verify(_secret, _body, _header, _opts), do: {:error, :malformed}

  defp parse_signature(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.split("=", parts: 2)))

    timestamps = for [k, v] <- pairs, k == "t", do: v
    candidates = for [k, v] <- pairs, k == "v1", v != "", do: String.downcase(v)

    with [raw] <- timestamps,
         {timestamp, ""} <- Integer.parse(raw),
         [_ | _] <- candidates do
      {:ok, timestamp, candidates}
    else
      _ -> {:error, :malformed}
    end
  end

  defp fresh(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance, do: :ok, else: {:error, :expired}
  end

  defp hmac_hex(secret, data),
    do: :hmac |> :crypto.mac(:sha256, secret, data) |> Base.encode16(case: :lower)

  @doc "Exhausted deliveries in a row before an endpoint is auto-disabled."
  @spec auto_disable_after() :: pos_integer()
  def auto_disable_after,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :auto_disable_after, 10)

  # About a day: eight doubling steps from 30 seconds up to the hourly cap
  # (~1h), then hourly. Long enough to outlast a receiver's bad deploy or a
  # night-time outage; short enough that an admin hears about it the same day.
  @retraction_max_attempts 30
  @retraction_backoff_base 30
  @retraction_backoff_cap 3600

  @doc """
  Whether `event` is a retraction verb: a `<type>.unpublished`, `.archived` or
  `.deleted` content event (`KilnCMS.CMS.WebhookEndpoint.retraction_verbs/0`).
  A delivery of one is a retraction when the document was published before
  the action (`dispatch/4`'s `:withdraws`). Domain events with a literal type
  segment (`task.assigned`, `release.failed`, …) never end in one of these,
  and a taxonomy event that does (`tag.deleted`, #1965) withdraws no document,
  so it is not one either (`KilnCMS.CMS.WebhookEndpoint.content_event_parts/1`).
  """
  @spec retraction?(String.t()) :: boolean()
  def retraction?(event) when is_binary(event) do
    case CMS.WebhookEndpoint.content_event_parts(event) do
      {_type, verb} -> verb in CMS.WebhookEndpoint.retraction_verbs()
      nil -> false
    end
  end

  def retraction?(_event), do: false

  @doc """
  Days an endpoint may sit auto-disabled before a retraction to it gets one
  attempt instead of `retraction_max_attempts/0`, and no console notice when
  that fails (default 7). Its losses are still recorded on the governance
  trail.
  """
  @spec retraction_stale_after_days() :: pos_integer()
  def retraction_stale_after_days,
    do:
      Keyword.get(
        Application.get_env(:kiln_cms, __MODULE__, []),
        :retraction_stale_after_days,
        7
      )

  @doc """
  Whether `endpoint` has been auto-disabled for longer than
  `retraction_stale_after_days/0`.
  """
  @spec stale_endpoint?(struct()) :: boolean()
  def stale_endpoint?(%{active: false, auto_disabled_at: %DateTime{} = at}) do
    DateTime.diff(DateTime.utc_now(), at, :day) >= retraction_stale_after_days()
  end

  def stale_endpoint?(_endpoint), do: false

  @doc "Attempts a retraction delivery gets before it is given up on and surfaced."
  @spec retraction_max_attempts() :: pos_integer()
  def retraction_max_attempts, do: @retraction_max_attempts

  @doc """
  Seconds before retraction attempt `attempt + 1`: doubling from 30 seconds,
  capped at an hour. With `retraction_max_attempts/0` that spans about a day.
  """
  @spec retraction_backoff(pos_integer()) :: pos_integer()
  def retraction_backoff(attempt) when is_integer(attempt) and attempt >= 1 do
    min(@retraction_backoff_base * Integer.pow(2, min(attempt - 1, 16)), @retraction_backoff_cap)
  end

  @doc """
  Record + enqueue a delivery for every endpoint of `org` subscribed to
  `event` that receives it (`KilnCMS.CMS.WebhookEndpoint.receives?/3`): the
  active ones and, for a retraction, the auto-disabled ones too. Runs as `system/0`; the endpoint scan is tenant-scoped (epic #336)
  so a publish only fans out to its own site's endpoints. `org` defaults to
  the sole org (the single-org rollout bridge).

  The webhook fan-out never raises into the caller (it runs after a publish
  has committed), but it never fails *silently* either: an endpoint scan or a
  ledger write the policies refuse is logged as an error, and the other
  consumers of the event below still run.

  Options: `:withdraws` (default `true`) — whether the document was published
  before the action. `archived` and `deleted` also fire for drafts, which no
  consumer ever had, so `KilnCMS.CMS.Changes.NotifyWebhooks` passes `false`
  for those and the delivery is not a retraction (#1926).
  """
  @spec dispatch(String.t(), map(), Ash.ToTenant.t() | nil, keyword()) :: :ok
  def dispatch(event, payload, org \\ KilnCMS.Accounts.default_org_id(), opts \\ []) do
    fan_out(event, payload, org, Keyword.get(opts, :withdraws, true))

    # A taxonomy event (#1965) is for webhook receivers and the CDN only: its
    # verbs read like content verbs, so automation would match "any type, on
    # updated" rules against a tag, and federation would try to announce one.
    unless CMS.WebhookEndpoint.taxonomy_event?(event) do
      editorial_consumers(event, payload, org)
    end

    # The optional CDN purge (`KILN_CDN_PURGE_URL`) is the fourth consumer: a
    # publish changes what the site's cached API responses should say, and so
    # does a taxonomy write (`KilnCMS.CDN.purges?/1`). Enqueue-only and
    # non-raising, like the two below.
    KilnCMS.CDN.handle_event(event, payload, org)

    # The public change feed (#2050) is the fifth: open pages hear about the
    # same transitions webhook receivers do, as identifiers only. It decides
    # which events it carries (taxonomy and domain events are not among
    # them) and never raises, like the consumers above.
    KilnCMS.Delivery.Feed.publish(event, payload, org, Keyword.get(opts, :withdraws, true))

    :ok
  end

  defp editorial_consumers(event, payload, org) do
    # Editorial automation (#342) reacts to the same editorial events — this is
    # the single funnel every `<type>.published`/`.unpublished`/`.updated` flows
    # through. Scoped to the same org as the webhook fan-out (#336). Never raises
    # (a rule problem must not break the publish).
    KilnCMS.Automation.handle_event(event, payload, org)

    # ActivityPub federation (#491) is the third consumer of this funnel, for
    # the same reasons: it needs the same editorial events, scoped to the same
    # org, and it must never break a publish. Enqueue-only and non-raising,
    # like the automation call above.
    KilnCMS.Federation.handle_event(event, payload, org)
  end

  @doc """
  Replay a delivery: a fresh ledger row (and job) for the same endpoint,
  event, and payload — history stays immutable. Admin-triggered.

  A retraction stays one (and a draft's tombstone stays not one). A delivery
  whose endpoint has since been deleted has nowhere to go:
  `{:error, :endpoint_deleted}`.
  """
  @spec redeliver(struct()) :: struct() | {:error, :endpoint_deleted}
  def redeliver(%{endpoint_id: nil}), do: {:error, :endpoint_deleted}

  def redeliver(delivery) do
    enqueue(
      %{id: delivery.endpoint_id, url: delivery.endpoint_url},
      delivery.event,
      delivery.payload,
      delivery.org_id,
      retraction_withdraws(delivery)
    )
  end

  # A retraction-verb row that is not a retraction was a draft's tombstone.
  defp retraction_withdraws(delivery),
    do: delivery.retraction or not retraction?(delivery.event)

  @doc """
  Send a test `"ping"` event to one endpoint (delivers even when inactive, so
  a receiver can be verified before enabling). Admin-triggered.
  """
  @spec ping(struct()) :: struct()
  def ping(endpoint) do
    enqueue(
      endpoint,
      "ping",
      %{
        message: "KilnCMS webhook test",
        endpoint_url: endpoint.url,
        sent_at: DateTime.to_iso8601(DateTime.utc_now())
      },
      endpoint.org_id,
      true
    )
  end

  # The endpoint scan runs as `system/0` (#1659) with `authorize_with: :error`.
  # Under a filter policy a refused read answers `[]`, which here would mean
  # "no endpoint is subscribed": every webhook for the event silently not sent,
  # with nothing in the ledger and nothing in the log. With `:error` a lost
  # grant is a Forbidden, logged below. It is not re-raised: this runs after
  # the publish committed (`NotifyWebhooks` is an `after_transaction` hook),
  # where a raise would report a publish that happened as one that failed, and
  # would skip automation, federation and the CDN purge as well.
  defp fan_out(event, payload, org, withdraws?) do
    retraction? = withdraws? and retraction?(event)

    # The query narrows to the candidates; `receives?/3` decides, the same
    # rule the worker applies when the job runs.
    CMS.list_webhook_endpoints!(
      actor: system(),
      authorize_with: :error,
      tenant: org,
      query:
        Ash.Query.filter(
          CMS.WebhookEndpoint,
          ^event in events and (active == true or not is_nil(auto_disabled_at))
        )
    )
    |> Enum.filter(&CMS.WebhookEndpoint.receives?(&1, event, retraction?))
    |> then(fn endpoints ->
      # A publish or withdrawal opens its propagation record (#1927) BEFORE
      # any delivery is enqueued, with the count it must wait for: a job that
      # ran before its siblings were created would otherwise find nothing
      # pending and settle the record early.
      propagation = KilnCMS.Propagation.open(event, payload, org, withdraws?, length(endpoints))
      propagation_id = propagation && propagation.id

      Enum.each(endpoints, &enqueue(&1, event, payload, org, withdraws?, propagation_id))
    end)
  rescue
    error in Ash.Error.Forbidden ->
      Logger.error(
        "Webhook dispatch of #{event} for org #{inspect(org)} refused by policy, " <>
          "webhook fan-out stopped: " <> Exception.message(error)
      )
  end

  defp enqueue(endpoint, event, payload, org, withdraws?, propagation_id \\ nil) do
    # The delivery lands in the endpoint's site, and its org rides into the job
    # args so the worker settles it under the same tenant (epic #336). Written
    # as `system/0` (#1659): `WebhookDelivery` admits it for `create`. A refused
    # write raises: into `fan_out/3`'s log for a dispatch, and into the admin's
    # view for a `redeliver/1` or `ping/1`.
    delivery =
      CMS.create_webhook_delivery!(
        %{
          endpoint_id: endpoint.id,
          endpoint_url: endpoint.url,
          event: event,
          payload: payload,
          withdraws: withdraws?,
          propagation_id: propagation_id
        },
        actor: system(),
        tenant: org
      )

    delivery
    |> job_args()
    |> DeliveryWorker.new(job_opts(delivery))
    |> Oban.insert!()

    delivery
  end

  # A retraction's job says so in its args, so `DeliveryWorker.backoff/1` can
  # pick the schedule without reading the ledger row, and carries its own
  # attempt budget. A job without the key is an ordinary delivery — which is
  # also every job enqueued before #1926.
  defp job_args(%{retraction: true} = delivery),
    do: %{delivery_id: delivery.id, org_id: delivery.org_id, retraction: true}

  defp job_args(delivery), do: %{delivery_id: delivery.id, org_id: delivery.org_id}

  defp job_opts(%{retraction: true}), do: [max_attempts: @retraction_max_attempts]
  defp job_opts(_delivery), do: []

  @doc """
  The retraction deliveries for one document that exhausted their retries —
  the rows `KilnCMS.Governance.trail/3` shows on the document's trail (#1926).

  `type` is the event namespace (`"page"`, or a dynamic type's name), `id` the
  document's id. Each entry is the failed delivery with the endpoint it was
  for (named from the row's snapshot, so a deleted endpoint is still named)
  and, once a later retraction of the same document reached the same endpoint
  (a replay, or a later verb), when:

      %{id, event, endpoint_id, endpoint_url, attempts, last_error, failed_at, recovered_at}

  Newest first. Read as `system/0`, which the ledger admits for reads, with
  `authorize_with: :error`: a refused read must not read as "nothing lost".
  """
  @spec lost_retractions(String.t(), Ash.UUID.t(), Ash.ToTenant.t()) :: [map()]
  def lost_retractions(type, id, org) do
    events = for verb <- CMS.WebhookEndpoint.retraction_verbs(), do: "#{type}.#{verb}"

    CMS.list_webhook_deliveries!(
      actor: system(),
      authorize_with: :error,
      tenant: org,
      query:
        CMS.WebhookDelivery
        |> Ash.Query.filter(
          document_id == ^id and retraction == true and status == :failed and
            event in ^events
        )
        |> Ash.Query.sort(inserted_at: :desc)
    )
    |> Enum.map(fn row ->
      %{
        id: row.id,
        event: row.event,
        endpoint_id: row.endpoint_id,
        endpoint_url: row.endpoint_url,
        attempts: row.attempts,
        last_error: row.last_error,
        failed_at: CMS.WebhookDelivery.given_up_at(row),
        recovered_at: row.recovered_at
      }
    end)
  end

  @doc """
  An `unpublished`, `archived` or `deleted` delivery of `delivery`'s document
  got through to its endpoint: stamp every earlier failed retraction of that
  document to that endpoint as recovered, whatever its verb — the consumer
  has now been told the document is gone (#1926).

  Run by the worker as `system/0`. Best-effort: a stamp that cannot be written
  is logged, and the trail keeps showing the loss, which errs the safe way.
  """
  @spec mark_recovered(struct(), DateTime.t()) :: :ok
  def mark_recovered(%{document_id: document_id} = delivery, at)
      when is_binary(document_id) and is_binary(delivery.endpoint_id) do
    endpoint_id = delivery.endpoint_id

    CMS.list_webhook_deliveries!(
      actor: system(),
      authorize_with: :error,
      tenant: delivery.org_id,
      query:
        Ash.Query.filter(
          CMS.WebhookDelivery,
          document_id == ^document_id and endpoint_id == ^endpoint_id and
            retraction == true and status == :failed and is_nil(recovered_at)
        )
    )
    |> Enum.each(
      &CMS.mark_webhook_delivery_recovered!(&1, %{recovered_at: at},
        actor: system(),
        tenant: delivery.org_id
      )
    )
  rescue
    error ->
      Logger.error(
        "Webhook delivery #{delivery.id}: earlier lost retractions not marked recovered: " <>
          Exception.message(error)
      )

      :ok
  end

  def mark_recovered(_delivery, _at), do: :ok

  @doc false
  # Extra Req options (e.g. a `Req.Test` plug in the test env).
  def req_options,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :req_options, [])

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the webhook pipeline runs as (#1659): the dispatch scan, the
  ledger writes, and `KilnCMS.Webhooks.DeliveryWorker`'s re-read and
  settlement.

  A `KilnCMS.SystemActor`, admitted by action name on `CMS.WebhookEndpoint`
  (reads and the two health counters) and `CMS.WebhookDelivery` (read,
  `create`, `record_attempt`); see `docs/policy-matrix.md`, "The system
  actor". It may not create, edit or delete an endpoint, nor delete a ledger
  row.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:webhooks)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process, so a test can take the grant away and prove that the endpoint
  # scan and the worker's ledger read fail CLOSED (logged, retried) rather than
  # filtering to "no endpoints" or "row gone". Process-local, and nothing on a
  # request path calls it; code that could call it could equally pass any
  # actor it liked.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end
end
