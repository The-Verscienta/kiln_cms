defmodule KilnCMS.CMS.WebhookDelivery do
  @moduledoc """
  The **delivery ledger** for outbound webhooks: one row per dispatched
  delivery, updated on every attempt, so admins can see exactly what was
  sent where, what came back, and replay failures (`/editor/webhooks`).

  Lifecycle: created `:pending` when a delivery is enqueued; every worker
  attempt records the attempt count and the last HTTP status / error;
  `:succeeded` on a 2xx, `:failed` once Oban's retries are exhausted (an
  exhausted delivery also counts against the endpoint's
  `consecutive_failures` — see `KilnCMS.Webhooks`). Rows are pruned after
  the retention window by a nightly AshOban trigger.

  A **retraction** (`retraction`: an `unpublished`, `archived` or `deleted`
  event for a document that was published, #1926) does not count against the
  endpoint, and a failed one is never pruned: it is the record, on the
  document's governance trail, that a consumer may still be serving something
  the site withdrew. It keeps that record through the deletion of its endpoint
  (the reference nilifies; `endpoint_url` is a snapshot), carries its
  document's id in `document_id`, and is stamped `recovered_at` when a later
  retraction of the same document reaches the same endpoint. Past the
  retention window its payload is cut down to the tombstone's identity
  fields (`payload_scrubbed_at`): a withdrawn body is not kept forever.

  `delivered_at` is the 2xx time, per row and so per endpoint — the input to
  the unpublish-to-last-endpoint measurement.

  Written exclusively by the delivery pipeline (system jobs); admin-only to
  read. Replays create a *new* delivery row, so history stays immutable.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshAdmin.Resource]

  # Days a delivery row is kept before the nightly prune.
  @retention_days Application.compile_env(:kiln_cms, [:webhooks, :delivery_retention_days], 30)

  @doc "Days delivery history is retained."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  When `delivery` was given up on, or nil when it was not (or when it cannot
  be told). `failed_at` where the row has it; on a row given up on before
  that column existed, `updated_at`, but only while nothing has written to
  the row since: a recovery stamp (`recovered_at`) or the payload scrub moves
  `updated_at` to their own time, and a wrong give-up time is worse than none.
  """
  @spec given_up_at(struct()) :: DateTime.t() | nil
  def given_up_at(%{status: :failed, failed_at: %DateTime{} = at}), do: at

  def given_up_at(%{status: :failed, recovered_at: nil, payload_scrubbed_at: nil} = delivery),
    do: delivery.updated_at

  def given_up_at(_delivery), do: nil

  admin do
    resource_group :system
    table_columns [:event, :status, :attempts, :last_status, :inserted_at]
  end

  postgres do
    table "webhook_deliveries"
    repo KilnCMS.Repo

    references do
      # Deleting an endpoint leaves its delivery history behind, endpoint-less,
      # for the prune to collect — and a failed retraction, which the prune
      # keeps, on the document's governance trail (#1926). Deleting the dead
      # endpoint must not erase the record that a consumer was never told.
      reference :endpoint, on_delete: :nilify

      # Propagation records are pruned on their own schedule (#1927); a kept
      # delivery (a failed retraction) outlives its record.
      reference :propagation, on_delete: :nilify
    end

    custom_indexes do
      # `KilnCMS.Webhooks.lost_retractions/3`, on every governance trail view.
      index [:org_id, :document_id], where: "document_id IS NOT NULL", concurrently: true
    end
  end

  oban do
    # The nightly prune scheduler scans each org (list_tenants), while the
    # prune worker runs under each row's own `org_id` tenant (epic #336) — one
    # site's retention sweep never touches another's ledger.
    use_tenant_from_record? true

    triggers do
      # Nightly ledger prune — delivery history is operational data, not an
      # archive.
      trigger :prune_deliveries do
        action :destroy
        queue :default
        scheduler_cron "20 3 * * *"
        # Strict-tenancy prep (#419): schedulers scan per org, not globally.
        list_tenants KilnCMS.Accounts.ListOrgIds

        # A failed retraction is kept (#1926): it is what the document's
        # governance trail shows, and pruning it would quietly turn a
        # consumer still serving withdrawn content back into "nothing lost".
        where expr(
                inserted_at <= ago(^@retention_days, :day) and
                  not (retraction == true and status == :failed)
              )

        worker_read_action :read
        worker_module_name KilnCMS.CMS.WebhookDelivery.Workers.PruneDeliveries
        scheduler_module_name KilnCMS.CMS.WebhookDelivery.Schedulers.PruneDeliveries
      end

      # The kept failed retractions lose their body at the same age the rest
      # of the ledger is deleted: an `unpublished` payload is the whole
      # document, and content withdrawn for a legal or privacy reason must not
      # outlive the retention window just because a consumer was unreachable.
      trigger :scrub_retraction_payloads do
        action :scrub_payload
        queue :default
        scheduler_cron "25 3 * * *"
        list_tenants KilnCMS.Accounts.ListOrgIds

        where expr(
                retraction == true and status == :failed and
                  inserted_at <= ago(^@retention_days, :day) and is_nil(payload_scrubbed_at)
              )

        worker_read_action :read
        worker_module_name KilnCMS.CMS.WebhookDelivery.Workers.ScrubRetractionPayloads
        scheduler_module_name KilnCMS.CMS.WebhookDelivery.Schedulers.ScrubRetractionPayloads
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:endpoint_id, :endpoint_url, :event, :payload, :propagation_id]
      # Optional on the row (it nilifies when the endpoint is deleted), never
      # on a new delivery.
      require_attributes [:endpoint_id]

      # Whether the document was published before the action that emitted
      # this event (`KilnCMS.CMS.Changes.NotifyWebhooks`). `archived` and
      # `deleted` fire for drafts too; a draft was never delivered, so its
      # tombstone retracts nothing (#1926).
      argument :withdraws, :boolean, default: true, allow_nil?: false

      # Derived from the event, never accepted: whether a delivery is exempt
      # from auto-disable is the event's property, not the caller's say-so.
      change fn changeset, _context ->
        event = Ash.Changeset.get_attribute(changeset, :event)

        retraction? =
          KilnCMS.Webhooks.retraction?(event) and
            Ash.Changeset.get_argument(changeset, :withdraws)

        # The document id rides on every retraction-VERB delivery, a draft's
        # tombstone included: any of them reaching an endpoint tells that
        # consumer the document is gone, which recovers an earlier loss.
        changeset
        |> Ash.Changeset.force_change_attribute(:retraction, retraction?)
        |> Ash.Changeset.force_change_attribute(
          :document_id,
          if(KilnCMS.Webhooks.retraction?(event),
            do: document_id(Ash.Changeset.get_attribute(changeset, :payload))
          )
        )
      end
    end

    # A later retraction of the same document reached the same endpoint
    # (`KilnCMS.Webhooks.DeliveryWorker`): this failed one no longer leaves a
    # consumer serving withdrawn content.
    update :mark_recovered do
      accept [:recovered_at]
    end

    # Past the retention window a kept failed retraction keeps its identity and
    # outcome, not the document body (the nightly trigger above).
    update :scrub_payload do
      require_atomic? false

      change fn changeset, _context ->
        keep = Enum.map(KilnCMS.CMS.ContentSerializer.tombstone_fields(), &to_string/1)

        payload =
          (changeset.data.payload || %{})
          |> Map.new(fn {key, value} -> {to_string(key), value} end)
          |> Map.take(keep)

        changeset
        |> Ash.Changeset.force_change_attribute(:payload, payload)
        |> Ash.Changeset.force_change_attribute(:payload_scrubbed_at, DateTime.utc_now())
      end
    end

    # One worker attempt's outcome: bump the attempt counter, record what came
    # back, and (on success / exhaustion) settle the status.
    update :record_attempt do
      accept [:status, :attempts, :last_status, :last_error, :delivered_at, :failed_at]
    end

    # Recent history for the admin panel, newest first.
    read :recent do
      prepare build(sort: [inserted_at: :desc], limit: 25)
    end
  end

  policies do
    # The prune trigger runs as a system job.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Delivery history is admin-only.
    #
    # The pipeline (`KilnCMS.Webhooks.system/0`, #1659) writes one ledger row
    # per delivery, re-reads it in the worker and records each attempt on it.
    # It may NOT `destroy` one: the ledger is pruned by the trigger above, and
    # a system caller cannot erase the record of whether a POST went out.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin

      forbid_unless action([:read, :create, :record_attempt, :mark_recovered])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :webhooks}
    end
  end

  # Multi-tenancy (epic #336): a delivery belongs to the same site as its
  # endpoint. `global?: true` keeps the tenant optional; the pipeline create
  # (`KilnCMS.Webhooks.enqueue`, as the system actor) carries the endpoint's org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the endpoint's
    # org) on the pipeline create, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The event name as sent (`page.published`, `ping`, …).
    attribute :event, :string, allow_nil?: false, public?: true

    # Whether the event withdraws a document (`KilnCMS.Webhooks.retraction?/1`,
    # #1926): exempt from auto-disable, retried longer, surfaced on exhaustion,
    # and kept past the retention window when it failed. Set at create.
    attribute :retraction, :boolean,
      allow_nil?: false,
      default: false,
      writable?: false,
      public?: true

    # The document an `unpublished` / `archived` / `deleted` delivery is about
    # — its payload's `id`, kept in a column so the governance trail's lookup
    # is an index read, not a scan of every payload. Nil on other events.
    attribute :document_id, :uuid, writable?: false, public?: true

    # The endpoint's URL when the delivery was made: what the governance trail
    # names after the endpoint itself has been deleted.
    attribute :endpoint_url, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    # When a later retraction of the same document got through to the same
    # endpoint (set on a failed retraction only).
    attribute :recovered_at, :utc_datetime_usec, public?: true

    # When a kept failed retraction's payload was cut down to identity.
    attribute :payload_scrubbed_at, :utc_datetime_usec, writable?: false, public?: true

    # The payload as dispatched (already serializer-shaped).
    attribute :payload, :map, allow_nil?: false, default: %{}, public?: true

    attribute :status, :atom do
      constraints one_of: [:pending, :succeeded, :failed]
      default :pending
      allow_nil? false
      public? true
    end

    # Attempts made so far (Oban's attempt counter at the last try).
    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true

    # The last HTTP status received, if the endpoint responded at all.
    attribute :last_status, :integer, public?: true

    # The last failure, human-readable ("endpoint returned HTTP 500",
    # "delivery failed: timeout", "blocked webhook URL: …").
    attribute :last_error, :string, public?: true

    # When the delivery finally succeeded: the 2xx time at this row's endpoint.
    attribute :delivered_at, :utc_datetime_usec, public?: true

    # When the delivery was given up on: its last attempt failed (#1928). Not
    # `updated_at`, which a later recovery stamp or the payload scrub moves.
    # Nil on rows given up on before this column existed.
    attribute :failed_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    # The publish or withdrawal this delivery carried (#1927): set by the
    # fan-out, nil on a redelivery, a ping or any other event.
    belongs_to :propagation, KilnCMS.CMS.Propagation do
      allow_nil? true
      public? true
    end

    # Nil once the endpoint has been deleted (the reference nilifies, #1926).
    belongs_to :endpoint, KilnCMS.CMS.WebhookEndpoint do
      allow_nil? true
      public? true
    end
  end

  # A payload's document id, when it carries a valid one. A payload read back
  # from storage has string keys; one handed straight from a dispatch may have
  # atom keys.
  @doc false
  def document_id(payload) when is_map(payload) do
    id = Map.get(payload, "id") || Map.get(payload, :id)

    case Ecto.UUID.cast(id || "") do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  def document_id(_payload), do: nil
end
