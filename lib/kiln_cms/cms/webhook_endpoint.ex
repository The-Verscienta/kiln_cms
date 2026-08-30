defmodule KilnCMS.CMS.WebhookEndpoint do
  @moduledoc """
  A registered outbound webhook. When content is published, KilnCMS POSTs a
  signed payload to every active endpoint subscribed to that event (e.g.
  `"page.published"`). Admin-managed; the per-endpoint `secret` signs deliveries
  (HMAC-SHA256) so receivers can verify authenticity.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  # Lifecycle verbs a content type can emit. `<type>.<verb>` is the event name.
  # `in_review` / `returned_to_draft` are the review-workflow transitions (#375).
  @verbs ~w(published unpublished updated in_review returned_to_draft)

  # Verbs a NEW endpoint subscribes to by default. The review-transition events
  # carry the full serialized body of a NOT-yet-published document, so they are
  # explicit opt-in — a receiver set up for publish mirroring must never be
  # POSTed draft/embargoed content it didn't ask for.
  @default_verbs ~w(published unpublished updated)

  # Domain events that are NOT a content type crossed with a verb. Editorial
  # tasks (#501) and content releases (#500) dispatch through the same
  # `KilnCMS.Webhooks.dispatch/3` funnel with a literal type segment, so they are
  # selectable here exactly like `page.published`.
  @task_events ~w(task.assigned task.overdue)
  # `release.failed` is the abort. It is deliberately a first-class event rather
  # than a log line: a scheduled release that aborts unattended changes nothing
  # on the site, so nothing else about the system tells anybody it was supposed
  # to. It carries `mode` (`"publish"` / `"rollback"`) and the failure reason.
  @release_events ~w(release.published release.rolled_back release.failed)
  # Content experiments (#499). One event, on conclusion — an experiment that is
  # merely running has nothing a subscriber could act on.
  @experiment_events ~w(experiment.concluded)

  @doc "The lifecycle verbs every content type can emit."
  def verbs, do: @verbs

  @doc """
  Every selectable event name: each registered content type — compiled and
  admin-defined dynamic (D17) — crossed with each lifecycle verb (e.g.
  `"page.published"`, `"recipe.updated"`), plus `form.submitted` for
  admin-defined public forms, `task.assigned`/`task.overdue` for editorial
  tasks (#501), `release.published`/`release.rolled_back`/`release.failed` for
  content releases (#500), and `experiment.concluded` for A/B experiments
  (#499). Derived at
  runtime so generated and admin-defined types get events for free.

  Dynamic types are per-org (epic #336), so the console passes the request's
  org — `org_id` defaults to the sole org for tenant-less callers.
  """
  def events(org_id \\ KilnCMS.Accounts.default_org_id()) do
    types = KilnCMS.CMS.ContentTypes.all_for_org(org_id)
    content = for ct <- types, verb <- @verbs, do: "#{ct.type}.#{verb}"
    content ++ ["form.submitted"] ++ @task_events ++ @release_events ++ @experiment_events
  end

  @doc """
  The default subscription for a new endpoint: the published-content lifecycle
  plus form submissions. The review-transition events (`in_review` /
  `returned_to_draft`, #375) carry unpublished draft bodies and are therefore
  **opt-in only** — select them explicitly on the endpoint.

  Arity 0 on purpose: this is an attribute `default`, which Ash evaluates with
  no access to the changeset's tenant, so it can only resolve the default org's
  dynamic types. The console never relies on it — its create form submits an
  explicit `events` list built from `events/1` for the request's org — so this
  only applies to tenant-less programmatic creates.
  """
  def default_events do
    types = KilnCMS.CMS.ContentTypes.all_for_org(nil)
    content = for ct <- types, verb <- @default_verbs, do: "#{ct.type}.#{verb}"
    content ++ ["form.submitted"]
  end

  # AshAdmin: keep system config out of the content groups (issue #25). The
  # `secret` is sensitive? and stays redacted by default.
  admin do
    resource_group :system
    table_columns [:url, :active, :inserted_at]
  end

  postgres do
    table "webhook_endpoints"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:url, :events, :active]

    create :create do
      primary? true
      # A receiver-shared signing secret, generated once.
      change set_attribute(:secret, &__MODULE__.generate_secret/0)
      validate KilnCMS.CMS.Validations.WebhookUrl
    end

    update :update do
      primary? true
      require_atomic? false
      validate KilnCMS.CMS.Validations.WebhookUrl
      # Re-enabling (or any edit) gives the endpoint a clean slate.
      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:auto_disabled_at, nil)
    end

    # A delivery got through: the endpoint is healthy again (system action,
    # called by the delivery pipeline with authorize?: false).
    update :record_delivery_success do
      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:auto_disabled_at, nil)
    end

    # A delivery exhausted its retries. After the configured run of these in a
    # row, the endpoint is auto-disabled — a dead receiver shouldn't burn the
    # queue every publish, forever (system action).
    update :record_delivery_failure do
      require_atomic? false

      change fn changeset, _context ->
        failures = (changeset.data.consecutive_failures || 0) + 1
        changeset = Ash.Changeset.change_attribute(changeset, :consecutive_failures, failures)

        if failures >= KilnCMS.Webhooks.auto_disable_after() do
          changeset
          |> Ash.Changeset.change_attribute(:active, false)
          |> Ash.Changeset.change_attribute(:auto_disabled_at, DateTime.utc_now())
        else
          changeset
        end
      end
    end
  end

  policies do
    # Webhook configuration is admin-only. The delivery pipeline reads endpoints
    # with `authorize?: false` as a system job.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): an endpoint belongs to one site, so a publish only
  # dispatches to its own org's endpoints. `global?: true` keeps the tenant
  # optional; the dispatch scan (`KilnCMS.Webhooks.dispatch`, `authorize?: false`)
  # is scoped to the publishing record's org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped create,
    # else the default org; never accepted from input (absent from `default_accept`).
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :url, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    # Subscribed event names; defaults to the published-content lifecycle only
    # (`default_events/0`) — draft-carrying review events are explicit opt-in.
    attribute :events, {:array, :string} do
      default &KilnCMS.CMS.WebhookEndpoint.default_events/0
      public? true
    end

    attribute :active, :boolean, default: true, public?: true

    attribute :secret, :string do
      allow_nil? false
      sensitive? true
      writable? false
    end

    # Health: exhausted deliveries in a row (reset by any success or edit).
    # At `KilnCMS.Webhooks.auto_disable_after/0` the endpoint is auto-disabled
    # and `auto_disabled_at` stamped, so the admin UI can say why it's off.
    attribute :consecutive_failures, :integer, allow_nil?: false, default: 0, public?: true
    attribute :auto_disabled_at, :utc_datetime_usec, public?: true

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
  end

  @doc false
  def generate_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
