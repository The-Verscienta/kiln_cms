defmodule KilnCMS.Billing.MembershipEvent do
  @moduledoc """
  Append-only audit trail for entitlement changes.

  One row per membership transition, recording the status change **and the
  audience delta it caused**, plus the provider event that caused it. This is what
  makes "every entitlement change is visible in the governance audit trail"
  (#337) true rather than nominal; it is surfaced by
  `KilnCMS.Governance.entitlement_index/2`.

  ## Why not AshPaperTrail or `KilnCMS.History.DocumentEvent`

  Paper trail records attribute diffs with a `belongs_to_actor`, but the caller
  here is a webhook with **no actor** — every entitlement change would be
  attributed to `nil`, when the fact a reviewer needs is "provider event
  `evt_1P…` did this". It also cannot express the audience delta, because
  audiences live on `KilnCMS.Accounts.User`, a different resource with no paper
  trail: you would get a status diff on one resource and an invisible array
  mutation on another.

  `DocumentEvent` is the *block-level content* event log — `document_type` is
  `one_of: [:page, :post]` and `KilnCMS.History.replay/3` folds its rows into
  document state. Billing transitions are not documents, and widening that enum
  would pollute the fold.

  Written by `KilnCMS.Billing.Changes.RecordTransition` inside the same
  transaction as the status change and the recompute, so the three cannot
  disagree. Append-only: no `destroy` action, and `create` is reachable only with
  `authorize?: false`.
  """
  use Ash.Resource,
    domain: KilnCMS.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @kinds [
    :started,
    :activated,
    :past_due,
    :canceled,
    :comped,
    :uncomped,
    :reconciled,
    :renewed
  ]

  postgres do
    table "billing_membership_events"
    repo KilnCMS.Repo

    custom_indexes do
      index [:membership_id]
      index [:user_id]
    end
  end

  actions do
    defaults [:read]

    create :append do
      accept [
        :membership_id,
        :user_id,
        :tier_id,
        :kind,
        :from_status,
        :to_status,
        :audiences_added,
        :audiences_removed,
        :provider_event_id,
        :actor_id,
        :note,
        :metadata
      ]
    end

    read :for_membership do
      argument :membership_id, :uuid, allow_nil?: false
      filter expr(membership_id == ^arg(:membership_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :recent do
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    # GDPR: an erased account's rows survive as a pseudonymous audit trail, but
    # the acting admin's identity is cleared — mirrors
    # `KilnCMS.History.DocumentEvent.anonymize_actor`.
    update :anonymize_actor do
      accept []
      change set_attribute(:actor_id, nil)
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Append-only: writes only via `authorize?: false`, and there is no `destroy`
    # action at all. Same shape as `KilnCMS.History.DocumentEvent`.
    policy action_type([:create, :update]) do
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

    attribute :membership_id, :uuid, allow_nil?: false, public?: true
    attribute :user_id, :uuid, allow_nil?: false, public?: false
    attribute :tier_id, :uuid, public?: true

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: @kinds
      public? true
    end

    attribute :from_status, :atom do
      constraints one_of: KilnCMS.Billing.Membership.statuses()
      public? true
    end

    attribute :to_status, :atom do
      allow_nil? false
      constraints one_of: KilnCMS.Billing.Membership.statuses()
      public? true
    end

    # The actual entitlement delta — the fact a compliance reviewer wants, and the
    # one neither paper trail nor a content event log can express.
    attribute :audiences_added, {:array, :atom}, allow_nil?: false, default: [], public?: true
    attribute :audiences_removed, {:array, :atom}, allow_nil?: false, default: [], public?: true

    # Provenance: which provider event caused this. Non-nil for webhook-driven
    # transitions, nil for admin comps.
    attribute :provider_event_id, :string, public?: true

    # The admin who comped, when a human caused it. Nulled on erasure.
    attribute :actor_id, :uuid, public?: false

    attribute :note, :string, public?: false
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
    end
  end

  @doc "Every valid event kind."
  def kinds, do: @kinds
end
