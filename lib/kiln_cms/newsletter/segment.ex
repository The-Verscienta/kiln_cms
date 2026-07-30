defmodule KilnCMS.Newsletter.Segment do
  @moduledoc """
  A named group of newsletter subscribers — the "send this to audience X" axis.

  Distinct from `KilnCMS.CMS.Audiences` (a compile-time enum that gates
  signed-in *read* access to published content): a segment is a data-defined
  grouping of external subscribers. It may optionally *reference* an audience
  (`audience`) as a label, but membership lives in the join table, not the
  read-axis. Admin-managed.
  """
  use Ash.Resource,
    domain: KilnCMS.Newsletter,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :system
    table_columns [:name, :slug, :audience, :inserted_at]
  end

  postgres do
    table "newsletter_segments"
    repo KilnCMS.Repo

    references do
      # A managed segment exists only to serve its tier, so it goes with it.
      # Without the cascade the FK would block tier deletion outright — and
      # `KilnCMS.Billing.Membership` already restricts deleting a tier that has
      # live members, which is the constraint that actually matters.
      reference :tier, on_delete: :delete
    end

    check_constraints do
      # Same atom-cast hazard as every other enum column here, plus the pairing
      # invariant: a tier-managed segment must actually name a tier, so manual
      # SQL can't leave a half-managed row that the send guard would then read.
      check_constraint :managed_by, "newsletter_segments_managed_by_must_be_known",
        check: "managed_by IN ('admin', 'tier')"

      check_constraint :tier_id, "newsletter_segments_tier_required_when_managed",
        check: "managed_by <> 'tier' OR tier_id IS NOT NULL"
    end
  end

  actions do
    defaults [:read]

    # Explicit (not a default) so a tier-backed segment can't be deleted out from
    # under the billing sync that maintains it.
    destroy :destroy do
      primary? true
      require_atomic? false
      validate KilnCMS.Newsletter.Validations.SegmentNotManaged
    end

    create :create do
      primary? true
      accept [:name, :slug, :description, :audience]
    end

    update :update do
      primary? true
      accept [:name, :slug, :description, :audience]
      require_atomic? false
      validate KilnCMS.Newsletter.Validations.SegmentNotManaged
    end

    # A tier's auto-maintained segment. System-only: `managed_by`/`tier_id` are
    # never writable from input, so a hand-built segment can't be promoted into a
    # tier-backed one by setting a foreign key — which would let an admin widen a
    # gated blast to a list they curated themselves.
    create :for_tier do
      accept [:name, :slug, :description]
      upsert? true
      upsert_identity :unique_slug
      upsert_fields [:name, :description]

      argument :tier_id, :uuid, allow_nil?: false

      argument :audience, :atom do
        allow_nil? false
        constraints one_of: KilnCMS.CMS.Audiences.all()
      end

      change set_attribute(:managed_by, :tier)
      change set_attribute(:tier_id, arg(:tier_id))
      # Derived from the tier, never hand-set: `ensure_sendable/2` matches this
      # against the document's audience, so it must not be an editable label.
      change set_attribute(:audience, arg(:audience))
    end

    # Keep a managed segment's display copy in step with its tier. System-only.
    update :sync_managed do
      accept [:name, :description]
      require_atomic? false
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # The tier-backed lifecycle is driven by billing, not by a human.
    policy action([:for_tier, :sync_managed]) do
      forbid_if always()
    end

    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): a segment belongs to one site, so its slug is
  # unique per org. `global?: true` keeps the tenant optional.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on create, else
    # the default org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    # For a hand-built segment this is a label and **not** an access boundary —
    # setting it grants nothing. For a `managed_by: :tier` segment it is derived
    # from the tier and IS load-bearing: the send guard in `KilnCMS.Newsletter`
    # matches it against the document's audience to decide whether gated content
    # may be sent (#337 Phase 2).
    attribute :audience, :atom do
      constraints one_of: KilnCMS.CMS.Audiences.all()
      public? true
    end

    # Who owns this segment's membership. `:admin` — curated by hand, the
    # pre-existing behaviour. `:tier` — auto-maintained from active paid
    # memberships, not hand-editable, and the only kind that may receive gated
    # content.
    attribute :managed_by, :atom do
      allow_nil? false
      default :admin
      constraints one_of: [:admin, :tier]
      writable? false
      public? true
    end

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

    # The tier whose active members this segment tracks (nil for hand-built).
    belongs_to :tier, KilnCMS.Billing.MembershipTier do
      allow_nil? true
      attribute_writable? false
      public? true
    end

    many_to_many :subscribers, KilnCMS.Newsletter.Subscriber do
      through KilnCMS.Newsletter.SegmentMembership
      source_attribute_on_join_resource :segment_id
      destination_attribute_on_join_resource :subscriber_id
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
