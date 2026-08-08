defmodule KilnCMS.Experiments.Experiment do
  @moduledoc """
  One A/B test over one published document (#499).

  Targets a document by `(content_type, document_id)` — a type-name string and a
  uuid, the pair `KilnCMSWeb.ViewTracking` and the webhook payloads already use.
  Not a foreign key, deliberately: a dynamic content type (D17) has no resource
  to point at, and an experiment should work for one.

  ## Lifecycle

      draft ──start──▶ running ──conclude──▶ concluded ──archive──▶ archived
        │                  │                     │
        └──────archive─────┴─────────────────────┘

  `draft` is editable and serves nothing. `running` serves variants and
  accumulates results. `concluded` records a `winner_variant_id` and stops
  serving. `archived` is the audit trail.

  ## Concluding is not promoting

  Concluding records which variant won. **Promoting** the winner — writing its
  patch into the document — is a separate, explicit act, and it goes through the
  document's ordinary `:update` action so it cuts a normal version, fires
  artifacts and notifies webhooks exactly as a human edit would.

  Keeping them apart matters: an experiment that concludes without promotion has
  simply been measured, which is a legitimate outcome and the common one for a
  test whose result was "no difference".
  """
  use Ash.Resource,
    domain: KilnCMS.Experiments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  postgres do
    table "content_experiments"
    repo KilnCMS.Repo

    # `RequireVariants` also checks this, for a readable error — but a read with
    # no lock is a check-then-act: two `:start` calls on two drafts targeting the
    # same document both see zero running rows, both pass, both commit. A partial
    # unique index is the only thing that actually makes it true. It cannot be an
    # Ash `identity` because those cannot carry a `WHERE`.
    custom_indexes do
      index [:org_id, :content_type, :document_id],
        unique: true,
        where: "state = 'running'",
        name: "content_experiments_one_running_per_document"
    end
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :start, from: :draft, to: :running
      transition :conclude, from: :running, to: :concluded
      transition :archive, from: [:draft, :running, :concluded], to: :archived
    end
  end

  actions do
    defaults [:read]

    default_accept [:name, :content_type, :document_id, :goal, :goal_form_id, :goal_document_id]

    create :create do
      primary? true
    end

    update :update do
      primary? true
      require_atomic? false
      # Only a draft is editable: changing the split or the patch of a running
      # experiment silently invalidates every result gathered so far.
      validate attribute_equals(:state, :draft),
        message: "only a draft experiment can be edited"
    end

    read :running do
      description "Experiments currently serving variants."
      filter expr(state == :running)
    end

    update :start do
      require_atomic? false
      accept []
      # Without a goal form nothing can ever convert: `Delivery.converts?/3`
      # requires the submitted form to BE the goal. Starting anyway would cost
      # the page its shared cache, accumulate impressions on every arm, and
      # report 0.0% forever.
      validate present(:goal_form_id),
        message: "a form-submission experiment needs a goal form before it can start"

      change transition_state(:running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change KilnCMS.Experiments.Changes.RequireVariants
    end

    update :conclude do
      require_atomic? false
      accept []
      argument :winner_variant_id, :uuid, allow_nil?: true

      change transition_state(:concluded)
      change set_attribute(:concluded_at, &DateTime.utc_now/0)
      change set_attribute(:winner_variant_id, arg(:winner_variant_id))
      change KilnCMS.Experiments.Changes.NotifyConcluded
    end

    update :archive do
      require_atomic? false
      accept []
      change transition_state(:archived)
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Running an experiment changes what visitors see and costs the page its
    # shared cache. That is an admin decision.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  changes do
    # Delivery reads the running set from a per-site cache, so any write has to
    # drop it or a started experiment stays invisible for the TTL.
    change KilnCMS.Experiments.Changes.BustExperimentCache,
      on: [:create, :update, :destroy]
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string, allow_nil?: false, public?: true

    # The public type name ("post", "recipe"), not the storage tier — a dynamic
    # type's documents all live in `:entry` but experiment per type name.
    attribute :content_type, :string, allow_nil?: false, public?: true

    attribute :document_id, :uuid, allow_nil?: false, public?: true

    # `:content_view` is deliberately NOT in this set yet. Attributing a view
    # that happens on a later page needs a stable visitor key, which the
    # built-in site does not have and will not until the sticky-assignment
    # cookie gets its own privacy review (phase 3, see the plan doc). Accepting
    # it here would let an operator create and start a test that silently never
    # records a conversion — the worst failure mode a measurement feature has.
    attribute :goal, :atom do
      constraints one_of: [:form_submission]
      default :form_submission
      allow_nil? false
      public? true
    end

    # Which form counts as a conversion, for a `:form_submission` goal.
    attribute :goal_form_id, :uuid, public?: true

    # Reserved for the `:content_view` goal (phase 3). The column exists so the
    # migration that turns the goal on is additive; nothing reads it yet.
    attribute :goal_document_id, :uuid, public?: true

    attribute :winner_variant_id, :uuid, writable?: false, public?: true

    attribute :started_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :concluded_at, :utc_datetime_usec, writable?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    has_many :variants, KilnCMS.Experiments.Variant do
      destination_attribute :experiment_id
      public? true
    end
  end

  identities do
    # One running experiment per document is enforced in `RequireVariants`
    # rather than here: a document may have many *concluded* experiments, and a
    # partial index expressing that is not something Ash identities model.
    identity :unique_name, [:org_id, :name]
  end
end
