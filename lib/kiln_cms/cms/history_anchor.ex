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
      # The `for_content` lookup: anchors for one document within its site,
      # in timestamp order. Kept for the governance trail and exports, which
      # display anchors chronologically; verification does not use it.
      index [:org_id, :resource_type, :source_id, :inserted_at, :id]

      # The chain's own order (#666), and what `latest_anchor/3` actually reads
      # in. It carries the sort, not just the filter: on the filter columns alone
      # Postgres fetches every anchor the document has and top-N sorts them,
      # which is O(anchors per document) on a path that runs per write —
      # `anchor_every_write` mints one anchor per save, so an hour of debounced
      # typing leaves ~1200, and both `mint/3` and `CoalesceAutosaveVersions`
      # ask for the latest on every one of those saves. `sequence` is `NOT NULL`,
      # so a backward scan of this plain btree serves `ORDER BY sequence DESC` as
      # a top-1 with no sort node. (A `NULLS LAST` ordering would have been
      # servable by no btree at all — a second reason the column is not
      # nullable.)
      #
      # UNIQUE because `next_sequence/1` is a read-then-write in
      # `after_transaction`, outside the document's own transaction: two
      # concurrent mints read the same predecessor and pick the same number.
      # Without this both land, the run reads `[2, 2, 1]`, and the document is
      # permanently and falsely tampered — unrepairable, since anchors have no
      # destroy action. With it the loser's insert fails into `Chain.anchor/2`
      # and `extend/2`'s existing rescue: a logged skip, which is what an
      # anchoring problem is supposed to cost.
      index [:org_id, :resource_type, :source_id, :sequence], unique: true
    end

    references do
      # `ON DELETE RESTRICT` on the predecessor link (#597): an anchor cannot be
      # removed while a SURVIVING anchor names it.
      #
      # It does not stop a wipe, and the difference matters. Postgres checks the
      # constraint after the statement's rows are gone, so `DELETE FROM
      # history_anchors WHERE source_id = …` removes referrer and referent
      # together and succeeds. What this buys is that a *middle* anchor cannot be
      # excised on its own — the attacker has to take its successor too, which is
      # precisely the shape `Chain.chain_intact/1`'s sequence check catches. Both
      # behaviours are pinned by tests so neither is assumed.
      reference :prev_anchor, on_delete: :restrict, on_update: :restrict
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
        :attribution_hash,
        :last_version_id,
        :last_version_at,
        :published_version_id,
        :signature,
        :key_id,
        :actor_id,
        :prev_anchor_id,
        :prev_anchor_digest,
        :sequence
      ]
    end

    # Anchors for one document, newest first — the verification baseline is the
    # latest one.
    #
    # Ordered by the SIGNED `sequence`, not by `inserted_at` (#666). The
    # timestamp is neither signed nor digested, so ordering by it meant
    # `UPDATE history_anchors SET inserted_at = now() WHERE id = <older>` made
    # the shorter anchor the baseline — the doctored versions then fell outside
    # the anchored prefix and were never hashed, with nothing deleted at all.
    # `sequence` is inside the signed payload, so repointing it breaks the
    # signature. It is `NOT NULL` and unique per document, so this is a total
    # order with no null case to reason about — see the attribute.
    read :for_content do
      argument :resource_type, :string, allow_nil?: false
      argument :source_id, :uuid, allow_nil?: false

      filter expr(resource_type == ^arg(:resource_type) and source_id == ^arg(:source_id))
      prepare build(sort: [sequence: :desc])
    end
  end

  policies do
    # Written by the publish pipeline (`authorize?: false`); reading the audit
    # surface is admin-only.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
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

    # A second fold over the covered versions' attribution — author and action
    # type — kept separate from `chain_hash` so it can be added without
    # invalidating every anchor already minted (#713). `chain_hash`'s
    # `item_digest` never covered `user_id`, so rewriting a version row's author
    # left the chain reading `:verified` next to attribution that had been
    # changed. Inside the SIGNED payload from `v: 5` on, so on a keyed deployment
    # it can't be repointed without breaking the signature. Null on anchors
    # minted before #713 — their attribution is simply not attested, the honest
    # pre-fix state, and they keep verifying.
    attribute :attribution_hash, :string, public?: true

    # Where the next incremental fold resumes (#598): the full sort key of the
    # last version this anchor covered, in the `(version_inserted_at, id)` order
    # the chain folds in. The timestamp is stored rather than looked up from the
    # id because version rows are legitimately deleted in ordinary operation —
    # `KilnCMS.CMS.Changes.CoalesceAutosaveVersions` destroys superseded
    # autosave rows on every debounced save — and a boundary that evaporates
    # with its row would send the fold back to the count-based resume the whole
    # of #598 is about.
    #
    # `last_version_at` is inside the SIGNED anchor payload, and its presence is
    # what selects the v3 payload shape, so it cannot be repointed to steer a
    # later fold without breaking the signature. Null only on anchors minted
    # before #598 and on a document with no versions at all.
    attribute :last_version_id, :uuid, public?: true
    attribute :last_version_at, :utc_datetime_usec, public?: true

    # The publish snapshot this anchor was minted with (#338 linkage).
    attribute :published_version_id, :uuid, public?: true

    # Detached RSA signature over the canonical anchor payload + the signing
    # key id — nil when no signing key is configured (the anchor is then a
    # plain integrity checksum, upgraded to non-repudiable once keys exist).
    attribute :signature, :string, public?: true
    attribute :key_id, :string, public?: true

    # The anchor this one continues from, and a digest binding that anchor's
    # CONTENT (#597). `prev_anchor_id` alone would let a deleted predecessor be
    # replaced by a forged row reusing the id; the digest covers the hash, count
    # and signature too, and both are inside the signed payload — so an attacker
    # without the signing key cannot mint a consistent link.
    #
    # Null only on a document's FIRST anchor. A non-null id that resolves to no
    # row is the deletion this exists to make visible.
    attribute :prev_anchor_id, :uuid, public?: true
    attribute :prev_anchor_digest, :string, public?: true

    # This anchor's position in the document's chain, 1-based and assigned at
    # write time (#666). Two things depend on it, and neither could be built on
    # `inserted_at`, which is written by the database and attested by nothing:
    #
    #   * it is the **order** `for_content` reads in, so the verification
    #     baseline cannot be changed by rewriting a timestamp;
    #   * a **gap** in it is visible. The predecessor links already catch a
    #     middle anchor removed while its successor survives; a position catches
    #     the same removal when the successor is removed too.
    #
    # `allow_nil? false` is load-bearing, not tidiness. A nullable position is a
    # one-statement way to redo the very attack this closes: null the newest
    # anchors' positions, an older and shorter anchor becomes the baseline, the
    # doctored versions fall outside the anchored prefix, and the verdict is
    # `:verified` with nothing deleted. **Nothing attests an absent value**, so
    # the column refuses to be absent. Existing anchors were backfilled in
    # `(inserted_at, id)` order by the migration that added it.
    #
    # It is inside the signed payload from v4 on, so a v4 anchor cannot be
    # renumbered without the signing key. Backfilled anchors were signed before
    # it existed and so are renumberable — which is why `Chain.chain_intact/1`
    # also requires `version_count` to be non-decreasing along the run — on
    # columns the signature sweep has established are attested, which is why an
    # anchor it cannot judge floors the chain rather than being skipped. A short
    # anchor cannot be promoted to the head without violating that.
    #
    # It does **not** catch a clean truncation of the newest anchors — nothing
    # inside the document's own anchor set can, since a shorter chain is
    # indistinguishable from a younger one. That needs a witness outside the
    # database; see `KilnCMS.Governance.Chain` and #666.
    attribute :sequence, :integer, allow_nil?: false, public?: true

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

    # Declared only so the `references` block above can put `ON DELETE RESTRICT`
    # on `prev_anchor_id` (#597). The chain is walked in memory from one query
    # rather than through this relationship — see `Chain.chain_intact/1`.
    belongs_to :prev_anchor, __MODULE__ do
      source_attribute :prev_anchor_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
