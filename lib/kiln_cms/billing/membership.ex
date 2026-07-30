defmodule KilnCMS.Billing.Membership do
  @moduledoc """
  One reader's subscription to one `KilnCMS.Billing.MembershipTier`.

  An active membership is what grants its tier's audience to the user, via
  `KilnCMS.Billing.Entitlements.recompute/1`. The row is the local mirror of a
  subscription the payment provider owns: the provider is the source of truth for
  status, and every transition here is driven by a signature-verified webhook.

  ## Not to be confused with `KilnCMS.Accounts.OrgMembership`

  Two different "membership" concepts live in this codebase. `OrgMembership` is
  *editorial*: which organizations a user belongs to and their RBAC tier there.
  This resource is *commercial*: what a reader pays for. They meet in exactly one
  place — the entitlement recompute writes the resolved audiences onto both the
  user and their `OrgMembership` — and nowhere else. Human-facing copy says
  "membership" for this and "team member" for that, matching `/editor/team`.

  ## Statuses

    * `:incomplete` — created before redirecting to checkout, so the provider
      session can carry a stable membership id. Grants nothing.
    * `:active` — paid and current. Grants.
    * `:past_due` — a payment failed and the provider is retrying (dunning).
      **Still grants**: the provider keeps the subscription alive through its
      retry schedule, and locking a member out mid-dunning would punish them for
      an expiring card. Revocation waits for the provider to give up.
    * `:canceled` — terminal. Grants nothing.
    * `:comped` — granted by an admin with no provider subscription behind it.
      Grants. This exists so a complimentary membership reads coherently in the
      member UI *and* survives the recompute, which treats any tier-claimed
      audience as billing-owned (see `KilnCMS.Billing.Entitlements`).

  Provider state is applied **only** by the webhook worker and the reconcile
  sweep; `:apply_provider_state` is `forbid_if always()` so no human — admin
  included — can hand-edit it into disagreement with the provider. Comping is the
  sanctioned admin lever.
  """
  use Ash.Resource,
    domain: KilnCMS.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @statuses [:incomplete, :active, :past_due, :canceled, :comped]

  # The statuses that grant their tier's audience. `:past_due` is deliberately
  # here; see the moduledoc.
  @entitling [:active, :past_due, :comped]

  @statuses_sql Enum.map_join(@statuses, ", ", &"'#{&1}'")

  postgres do
    table "billing_memberships"
    repo KilnCMS.Repo

    references do
      reference :tier, on_delete: :restrict
    end

    custom_indexes do
      # The webhook resolution path probes both provider ids; Postgres does not
      # index them for us.
      index [:provider_subscription_id]
      index [:provider_customer_id]
      index [:user_id]
    end

    # Same reasoning as `KilnCMS.Billing.Settings`: Ash casts this column to an
    # atom on read, and this one sits directly on the entitlement path.
    check_constraints do
      check_constraint :status, "billing_memberships_status_must_be_known",
        check: "status IN (#{@statuses_sql})"
    end
  end

  actions do
    defaults [:read]

    # Created before redirecting to checkout so the provider session metadata can
    # carry a stable membership id. Upserts, so re-clicking "join" reuses an
    # abandoned row rather than violating the identity — and `upsert_fields` is
    # narrow so a retry can never clobber provider ids we already hold.
    create :start do
      accept [:user_id, :tier_id]
      upsert? true
      upsert_identity :one_per_user_and_tier
      upsert_fields [:status]
      change set_attribute(:status, :incomplete)
    end

    # The single write path for provider-driven state. Recomputes entitlements and
    # records an audit event in the same transaction, so status, audiences and the
    # trail can never disagree.
    update :apply_provider_state do
      accept [
        :status,
        :provider_customer_id,
        :provider_subscription_id,
        :current_period_end,
        :cancel_at_period_end
      ]

      require_atomic? false

      # Threaded into the audit row so a replay investigation can trace which
      # provider event caused which grant.
      argument :provider_event_id, :string

      change KilnCMS.Billing.Changes.RecordTransition
    end

    # A complimentary membership: no provider subscription, still entitling.
    create :comp do
      accept [:user_id, :tier_id, :note]
      upsert? true
      upsert_identity :one_per_user_and_tier
      upsert_fields [:status, :note]
      change set_attribute(:status, :comped)
      change KilnCMS.Billing.Changes.RecordTransition
    end

    update :uncomp do
      accept []
      require_atomic? false
      change set_attribute(:status, :canceled)
      change set_attribute(:canceled_at, &DateTime.utc_now/0)
      change KilnCMS.Billing.Changes.RecordTransition
    end

    # GDPR erasure (#212 × #337 Phase 2): terminate the membership locally and
    # drop the provider identifiers, while KEEPING the row so the entitlement
    # audit trail stays referentially intact.
    #
    # System-only, like `:apply_provider_state`: this must not be a lever a human
    # can pull to sever billing state by hand.
    update :anonymize do
      accept []
      require_atomic? false
      change set_attribute(:status, :canceled)
      change set_attribute(:provider_customer_id, nil)
      change set_attribute(:provider_subscription_id, nil)
      change set_attribute(:note, nil)
      change set_attribute(:canceled_at, &DateTime.utc_now/0)
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(load: [:tier], sort: [inserted_at: :desc])
    end

    # Entitlement input: every membership that should grant, for one user, across
    # ALL organizations.
    #
    # `multitenancy :bypass` because the answer is inherently cross-org —
    # `User.audiences` is a single global column, so the recompute must see the
    # user's whole commercial picture, not one site's slice. The per-org values it
    # writes are derived from `org_id` on each row it finds.
    # Deliberately does NOT load `:tier`: a `belongs_to` load off a bypassed read
    # raises `Ash.Error.Invalid.TenantRequired` under strict tenancy, because the
    # tier is tenant-scoped and this query has no tenant. The caller
    # (`KilnCMS.Billing.Entitlements`) resolves tier audiences with its own
    # bypassed read and joins them in memory.
    read :entitling_for_user do
      multitenancy :bypass
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status in ^@entitling)
      prepare build(select: [:id, :org_id, :user_id, :tier_id, :status])
    end

    # Every membership a person holds, across ALL organizations, in any status.
    #
    # `multitenancy :bypass` because both callers are inherently cross-org: a GDPR
    # export answers "what do you hold about me" for the whole instance, and
    # erasure must reach every row regardless of which host the request arrived
    # on. Callers re-scope any follow-up WRITE with each row's own `org_id`.
    read :all_for_user do
      multitenancy :bypass
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc])
    end

    # Webhook resolution. `multitenancy :bypass` per the sanctioned exception
    # (`KilnCMS.Newsletter.Subscriber.by_unsubscribe_token`): the org is unknown
    # until the row is found, and the caller re-scopes every follow-up write with
    # the found row's own `org_id`.
    read :by_subscription do
      get? true
      multitenancy :bypass
      argument :provider_subscription_id, :string, allow_nil?: false
      filter expr(provider_subscription_id == ^arg(:provider_subscription_id))
      prepare build(load: [:tier])
    end

    read :by_customer do
      multitenancy :bypass
      argument :provider_customer_id, :string, allow_nil?: false
      filter expr(provider_customer_id == ^arg(:provider_customer_id))
      prepare build(load: [:tier])
    end

    # Memberships whose paid period lapsed without an update — we missed an
    # event. Backs the reconcile sweep.
    read :stale do
      argument :before, :utc_datetime_usec, allow_nil?: false

      filter expr(
               status in [:active, :past_due] and not is_nil(provider_subscription_id) and
                 not is_nil(current_period_end) and current_period_end < ^arg(:before)
             )
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # A member reads their own memberships (`/account`); an org admin reads the
    # site's.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
      authorize_if expr(user_id == ^actor(:id))
    end

    # Starting checkout is self-service, for yourself only.
    policy action(:start) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Comping is a per-site product decision.
    policy action([:comp, :uncomp]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    # Provider state is applied only by the verified webhook worker and the
    # reconcile sweep, both of which run `authorize?: false` (or via the AshOban
    # bypass above). Unlike `KilnCMS.Accounts.User`, this resource has NO admin
    # bypass, so `forbid_if always()` genuinely closes the action to every
    # authorized caller.
    policy action([:apply_provider_state, :anonymize]) do
      forbid_if always()
    end
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

    attribute :user_id, :uuid do
      allow_nil? false
      public? false
    end

    attribute :status, :atom do
      allow_nil? false
      default :incomplete
      constraints one_of: @statuses
      public? true
    end

    # Provider identifiers. Not public: they are pseudonymous references to a
    # subprocessor's records and have no business on an API surface.
    attribute :provider_customer_id, :string, public?: false
    attribute :provider_subscription_id, :string, public?: false

    # Display only ("renews on…"). Revocation follows the provider's status, not
    # a local timer — see `KilnCMS.Billing.Subscriptions`.
    attribute :current_period_end, :utc_datetime_usec, public?: true

    attribute :cancel_at_period_end, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :activated_at, :utc_datetime_usec, public?: true
    attribute :canceled_at, :utc_datetime_usec, public?: true

    # Why a membership was comped. Operator-facing, never shown to the member.
    attribute :note, :string, public?: false

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
    end

    belongs_to :tier, KilnCMS.Billing.MembershipTier do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    # `org_id`-scoped per the #336 convention for tenant-scoped resources.
    identity :one_per_user_and_tier, [:org_id, :user_id, :tier_id]
  end

  @doc "Every valid status."
  def statuses, do: @statuses

  @doc "The statuses that grant their tier's audience."
  def entitling_statuses, do: @entitling

  @doc "Whether `status` grants its tier's audience."
  def entitling?(status), do: status in @entitling
end
