defmodule KilnCMS.CMS.HistoryAnchor do
  @moduledoc """
  A **signed anchor over a document's editorial history** (#356, the
  tamper-evident half).

  At every publish, `KilnCMS.Governance.Chain` folds the document's full
  PaperTrail version list into one canonical chain hash and records it here —
  RSA-signed via the `KilnCMS.Keys` infra when a signing key is configured
  (the same key source as content provenance, #340). Verification recomputes
  the chain from the live `*_versions` rows: any later alteration, deletion,
  or reordering of anchored history changes the hash and is detected, and the
  signature proves the anchor itself wasn't rewritten alongside.

  Append-only: anchors are created by the publish pipeline as the system and
  are never updated or deleted (`destroy` is deliberately absent). Admin-only
  to read, like the rest of the governance surface.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "history_anchors"
    repo KilnCMS.Repo

    custom_indexes do
      # The `for_content` lookup: anchors for one document within its site.
      index [:org_id, :resource_type, :source_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :resource_type,
        :source_id,
        :chain_hash,
        :version_count,
        :last_version_id,
        :published_version_id,
        :signature,
        :key_id,
        :actor_id
      ]
    end

    # Anchors for one document, newest first — the verification baseline is the
    # latest one.
    read :for_content do
      argument :resource_type, :string, allow_nil?: false
      argument :source_id, :uuid, allow_nil?: false

      filter expr(resource_type == ^arg(:resource_type) and source_id == ^arg(:source_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    # Written by the publish pipeline (`authorize?: false`); reading the audit
    # surface is admin-only.
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  # Multi-tenancy (epic #336): anchors live in their document's site.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped
    # create, else the default org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The anchored document — public type name + id, the same soft polymorphic
    # reference the firing engine and consents use.
    attribute :resource_type, :string, allow_nil?: false, public?: true
    attribute :source_id, :uuid, allow_nil?: false, public?: true

    # The folded canonical hash over the first `version_count` versions
    # (ascending), and the last version it covers.
    attribute :chain_hash, :string, allow_nil?: false, public?: true
    attribute :version_count, :integer, allow_nil?: false, public?: true
    attribute :last_version_id, :uuid, public?: true

    # The publish snapshot this anchor was minted with (#338 linkage).
    attribute :published_version_id, :uuid, public?: true

    # Detached RSA signature over the canonical anchor payload + the signing
    # key id — nil when no signing key is configured (the anchor is then a
    # plain integrity checksum, upgraded to non-repudiable once keys exist).
    attribute :signature, :string, public?: true
    attribute :key_id, :string, public?: true

    attribute :actor_id, :uuid, public?: true

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
end
