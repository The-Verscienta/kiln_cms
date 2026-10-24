defmodule KilnCMS.Propagation do
  @moduledoc """
  How long a publish or a withdrawal takes to reach everything a site serves
  through (#1927): one `KilnCMS.CMS.Propagation` record per transition, the
  query that turns those records into p50/p95, and the telemetry event an
  operator graphs.

  ## What a transition is

  A content event dispatched through `KilnCMS.Webhooks.dispatch/4`:

    * **publish** — `<type>.published`;
    * **withdraw** — `<type>.unpublished`, or `<type>.deleted` of a document
      that was published (trashing a live document fires no `unpublished`).
      Not `archived`: archiving a live document fires `unpublished` as well,
      and that is the one measured.

  A domain event that happens to share a verb (`release.published`, any
  `KilnCMS.CMS.WebhookEndpoint.domain_events/0`) is about a release, not a
  document, and is not a transition. Everything else with a transition verb
  is a document's, including an entry of a dynamic type that has since been
  archived: its entries keep firing `<name>.*` (`KilnCMS.Firing.Engine.public_type/1`,
  #938), webhooks still deliver those, and the delivery is measured like any
  other. Updates to live content, drafts' tombstones and every other event
  are not transitions and open no record.

  ## What is measured

  The record is opened at dispatch, just after the transition's write
  committed (`transitioned_at`). It settles once each of the
  `endpoints_expected` webhook deliveries is terminal — a 2xx, or given up
  on — and the CDN purge it enqueued, if purging is configured, has been
  acknowledged or has failed. Settling stamps:

    * `endpoint_latency_ms` — transition to the **last** endpoint's 2xx
      (`WebhookDelivery.delivered_at`). Nil when there were no endpoints, or
      when any delivery was given up on: there is then no "last endpoint
      delivered", and `endpoints_failed` counts the ones lost;
    * `cdn_latency_ms` — transition to the purge's acknowledgement, when it
      was acknowledged. One purge covers every transition enqueued before it
      started (the purge is per site and coalesces a burst), so each of them
      is stamped with the time *it* waited.

  `percentiles/2` reads `endpoint_latency_ms` over a window. The number the
  path forward asks for, unpublish-to-last-endpoint p95, is
  `percentiles(org, kind: :withdraw)`; `mix kiln.propagation` prints it.

  ## Telemetry

  Settling emits `[:kiln_cms, :propagation, :complete]`, once per record:

    * measurements — `endpoint_latency_ms` and `cdn_latency_ms` (each left out
      when there is none), `endpoints` (expected) and `endpoints_failed`;
    * metadata — `kind`, `event`, `org_id`, `cdn_status`.

  `KilnCMSWeb.Telemetry` summarises the two latencies by kind.

  ## Failure handling

  Bookkeeping, never control flow: nothing here raises into a publish, a
  delivery or a purge. A record that cannot be opened or settled is logged,
  and a record that never settles stays open, which `percentiles/2` reports as
  `open` rather than folding into the latency.
  """
  require Ash.Query
  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint

  @event [:kiln_cms, :propagation, :complete]

  @doc "The telemetry event a settled record emits."
  def telemetry_event, do: @event

  @doc """
  The kind of transition `event`'s verb makes it, or `nil` when it is not
  one. `withdraws?` is whether the document was published before the action
  (`KilnCMS.Webhooks.dispatch/4`'s `:withdraws`). Domain events are ruled out
  by `open/5`.
  """
  @spec kind(String.t(), boolean()) :: :publish | :withdraw | nil
  def kind(event, withdraws?) do
    case WebhookEndpoint.event_parts(event) do
      {_type, "published"} -> :publish
      {_type, "unpublished"} -> :withdraw
      {_type, "deleted"} -> if withdraws?, do: :withdraw
      _ -> nil
    end
  end

  @doc """
  Open the record for a transition dispatched to `endpoints` webhook
  endpoints. `nil` (logged) when `event` is not a transition, or when the
  record cannot be written. Run by the fan-out as `KilnCMS.Webhooks.system/0`.
  """
  @spec open(String.t(), map(), Ash.ToTenant.t(), boolean(), non_neg_integer()) ::
          struct() | nil
  def open(event, payload, org, withdraws?, endpoints) do
    # The exact domain events, not a registry lookup: the registry
    # (`ContentTypes.get/2`) leaves archived dynamic types out, whose entries
    # still fire and deliver `<name>.*`. New types can't take a domain
    # namespace as their name (#1994); a type named `release` from before that
    # rule is the one this misses.
    with false <- event in WebhookEndpoint.domain_events(),
         kind when not is_nil(kind) <- kind(event, withdraws?),
         {type, _verb} <- WebhookEndpoint.event_parts(event),
         document_id when is_binary(document_id) <- CMS.WebhookDelivery.document_id(payload) do
      now = DateTime.utc_now()
      purging? = KilnCMS.CDN.enabled?() and KilnCMS.CDN.purges?(event)

      record =
        CMS.open_propagation!(
          %{
            kind: kind,
            event: event,
            document_type: type,
            document_id: document_id,
            transitioned_at: now,
            endpoints_expected: endpoints,
            cdn_status: if(purging?, do: :pending, else: :not_configured),
            cdn_enqueued_at: if(purging?, do: now)
          },
          actor: KilnCMS.Webhooks.system(),
          tenant: org
        )

      # Nothing to wait for: no endpoint and no purge.
      if endpoints == 0 and not purging?, do: settle(record.id, record.org_id)

      record
    else
      _not_a_transition -> nil
    end
  rescue
    error ->
      Logger.error("Propagation record for #{event} not opened: " <> Exception.message(error))
      nil
  end

  @doc """
  A delivery of a transition reached a terminal state: settle its record if
  that was the last thing it waited for. Called by
  `KilnCMS.Webhooks.DeliveryWorker`.
  """
  @spec delivery_settled(struct()) :: :ok
  def delivery_settled(%{propagation_id: id, org_id: org_id}) when is_binary(id),
    do: settle(id, org_id)

  def delivery_settled(_delivery), do: :ok

  @doc """
  A CDN purge for `org_id` that started at `started_at` finished with
  `status` (`:acknowledged` or `:failed`): settle the purge half of every
  record still waiting on one that was enqueued before it started, then
  settle each record. Called by `KilnCMS.CDN.PurgeWorker` as the `:cdn`
  system actor.
  """
  @spec cdn_settled(String.t(), DateTime.t(), :acknowledged | :failed) :: :ok
  def cdn_settled(org_id, %DateTime{} = started_at, status)
      when status in [:acknowledged, :failed] do
    actor = KilnCMS.SystemActor.new(:cdn)
    now = DateTime.utc_now()

    CMS.list_propagations!(
      actor: actor,
      authorize_with: :error,
      tenant: org_id,
      query:
        Ash.Query.filter(
          CMS.Propagation,
          cdn_status == :pending and cdn_enqueued_at <= ^started_at
        )
    )
    |> Enum.each(fn record ->
      record
      |> CMS.settle_propagation_cdn!(%{cdn_status: status, cdn_settled_at: now},
        actor: actor,
        tenant: org_id
      )
      |> then(&settle(&1.id, org_id))
    end)
  rescue
    error ->
      Logger.error(
        "CDN purge for org #{org_id} not recorded on its propagation records: " <>
          Exception.message(error)
      )

      :ok
  end

  @doc """
  Settle record `id` when every expected delivery is terminal and the purge is
  not pending: stamp the latencies, once, and emit the telemetry event.
  `:ok` whether or not it was ready.

  Always as `KilnCMS.Webhooks.system/0`, whoever calls it: the readiness check
  counts the record's deliveries, and a count under an actor the ledger does
  not admit is a refused read, which counts zero and would settle the record
  early.
  """
  @spec settle(String.t(), String.t()) :: :ok
  def settle(id, org_id) do
    actor = KilnCMS.Webhooks.system()

    record =
      CMS.get_propagation!(id,
        actor: actor,
        authorize_with: :error,
        tenant: org_id,
        load: [:deliveries_succeeded, :deliveries_failed, :last_delivered_at]
      )

    if ready?(record), do: complete(record, actor)
    :ok
  rescue
    error ->
      Logger.error("Propagation record #{id} not settled: " <> Exception.message(error))
      :ok
  end

  defp ready?(%{completed_at: %DateTime{}}), do: false
  defp ready?(%{cdn_status: :pending}), do: false

  defp ready?(record),
    do: record.deliveries_succeeded + record.deliveries_failed >= record.endpoints_expected

  defp complete(record, actor) do
    attrs = %{
      completed_at: DateTime.utc_now(),
      endpoints_failed: record.deliveries_failed,
      endpoint_latency_ms: endpoint_latency(record),
      cdn_latency_ms: cdn_latency(record)
    }

    case CMS.complete_propagation(record, attrs, actor: actor, tenant: record.org_id) do
      # After the commit when there is an outer one (a release): a rolled-back
      # transition must not be counted as propagated.
      {:ok, completed} -> KilnCMS.AfterCommit.run(fn -> emit(completed) end)
      # Another delivery settled it first (the `is_nil(completed_at)` filter).
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} -> :ok
      {:error, error} -> raise error
    end
  end

  defp endpoint_latency(%{endpoints_expected: 0}), do: nil
  defp endpoint_latency(%{deliveries_failed: failed}) when failed > 0, do: nil
  defp endpoint_latency(%{last_delivered_at: nil}), do: nil

  defp endpoint_latency(record),
    do: max(DateTime.diff(record.last_delivered_at, record.transitioned_at, :millisecond), 0)

  defp cdn_latency(%{cdn_status: :acknowledged, cdn_settled_at: %DateTime{} = at} = record),
    do: max(DateTime.diff(at, record.transitioned_at, :millisecond), 0)

  defp cdn_latency(_record), do: nil

  defp emit(record) do
    # A latency there is none of is left out of the measurements rather than
    # sent as nil: a reporter that reads a missing measurement skips the
    # event, and one that reads nil may crash or record a zero.
    :telemetry.execute(
      @event,
      Map.reject(
        %{
          endpoint_latency_ms: record.endpoint_latency_ms,
          cdn_latency_ms: record.cdn_latency_ms,
          endpoints: record.endpoints_expected,
          endpoints_failed: record.endpoints_failed
        },
        fn {_key, value} -> is_nil(value) end
      ),
      %{
        kind: record.kind,
        event: record.event,
        org_id: record.org_id,
        cdn_status: record.cdn_status
      }
    )
  end

  @doc """
  The propagation numbers for `org` over a window:

      %{kind, since, count, p50_ms, p95_ms, max_ms, lost, no_endpoints, open}

  `count` and the percentiles cover records whose every endpoint was reached
  (`endpoint_latency_ms` set); `lost` counts settled records where at least
  one endpoint was given up on, `no_endpoints` settled records that went to
  none, and `open` records in the window still waiting. The percentiles are
  nearest-rank over the measured latencies, `nil` when there are none.

  Options: `kind` (`:withdraw`, the default, or `:publish`), `since` (a
  `DateTime`; default 7 days ago). Read as `KilnCMS.Webhooks.system/0`.
  """
  @spec percentiles(Ash.ToTenant.t(), keyword()) :: map()
  def percentiles(org, opts \\ []) do
    kind = Keyword.get(opts, :kind, :withdraw)
    since = Keyword.get_lazy(opts, :since, fn -> DateTime.add(DateTime.utc_now(), -7, :day) end)
    actor = KilnCMS.Webhooks.system()

    settled =
      CMS.completed_propagations_since!(kind, since,
        actor: actor,
        authorize_with: :error,
        tenant: org,
        query:
          Ash.Query.select(CMS.Propagation, [
            :endpoint_latency_ms,
            :endpoints_failed,
            :endpoints_expected
          ])
      )

    open =
      CMS.open_propagations_since!(kind, since,
        actor: actor,
        authorize_with: :error,
        tenant: org,
        query: Ash.Query.select(CMS.Propagation, [:id])
      )

    latencies =
      settled |> Enum.map(& &1.endpoint_latency_ms) |> Enum.reject(&is_nil/1) |> Enum.sort()

    %{
      kind: kind,
      since: since,
      count: length(latencies),
      p50_ms: nearest_rank(latencies, 50),
      p95_ms: nearest_rank(latencies, 95),
      max_ms: List.last(latencies),
      lost: Enum.count(settled, &((&1.endpoints_failed || 0) > 0)),
      no_endpoints: Enum.count(settled, &(&1.endpoints_expected == 0)),
      open: length(open)
    }
  end

  @doc false
  # Nearest-rank percentile of an ascending list: the smallest value with at
  # least `p` percent of the values at or below it.
  @spec nearest_rank([number()], number()) :: number() | nil
  def nearest_rank([], _p), do: nil

  def nearest_rank(sorted, p) do
    rank = max(ceil(p / 100 * length(sorted)), 1)
    Enum.at(sorted, rank - 1)
  end
end
