defmodule KilnCMS.CMS.ChainCheckpoint do
  @moduledoc """
  A signed, org-wide commitment to **where every document's anchor chain had
  got to** at a moment in time (#666).

  `KilnCMS.CMS.HistoryAnchor` makes a document's history tamper-evident against
  everything except truncation: delete its newest anchors and the surviving
  prefix still verifies, because nothing says how many there were. No column on
  the anchors themselves can say — a shorter chain and a younger one are the
  same shape.

  A checkpoint is the external statement. It hashes each anchored document's
  head into a Merkle tree (`KilnCMS.Governance.Merkle`), signs the root, and is
  published outside the database by `KilnCMS.Governance.Witness`. Verification
  reads back one entry plus its inclusion proof, so a document that was
  witnessed at position 7 and now heads at position 5 is `{:tampered, …}`
  instead of `:verified`.

  Append-only and admin-read, like anchors. The one mutable part is the
  publication receipt, written after the sink accepts the checkpoint — and
  deliberately *outside* the signature, because it does not need to be inside
  it: the audit re-fetches by a key derived from `org_id` and `sequence`, both
  of which are signed, so a rewritten receipt changes nothing about what gets
  compared.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "chain_checkpoints"
    repo KilnCMS.Repo

    custom_indexes do
      # UNIQUE for the same reason `history_anchors` numbers its own sequence
      # uniquely: minting reads the predecessor and writes its successor outside
      # any lock, so two runs (a cron overlap, two nodes) pick the same number.
      # With the index the loser's insert fails and the run logs a skip; without
      # it both land and the org's checkpoint run is permanently ambiguous.
      index [:org_id, :sequence], unique: true

      # Publication retries: "checkpoints this org has not witnessed yet",
      # oldest first.
      index [:org_id, :witnessed_at, :sequence]
    end

    references do
      # A checkpoint cannot be removed while its successor names it — the same
      # narrowing `history_anchors` gets, and with the same limit: a statement
      # that deletes referrer and referent together still succeeds.
      reference :prev_checkpoint, on_delete: :restrict, on_update: :restrict
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :sequence,
        :root,
        :document_count,
        :covered_at,
        :prev_checkpoint_id,
        :prev_checkpoint_digest,
        :signature,
        :key_id,
        :witness,
        :witness_receipt,
        :witnessed_at,
        :witness_error
      ]
    end

    # The publication result, recorded after the sink answers. Narrow on
    # purpose: nothing that is inside the signature is writable here, so a
    # publication retry can never touch the commitment it is publishing.
    update :record_publication do
      accept [:witness, :witness_receipt, :witnessed_at, :witness_error]
      require_atomic? false
    end

    read :recent do
      prepare build(sort: [sequence: :desc])
    end

    # Checkpoints this org minted but never got into the sink — the retry queue,
    # oldest first so a backlog drains in order.
    read :unwitnessed do
      filter expr(is_nil(witnessed_at))
      prepare build(sort: [sequence: :asc])
    end
  end

  policies do
    # Written by the checkpoint worker as the system; reading the audit surface
    # is admin-only, like every other governance resource.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): a checkpoint covers one org's documents.
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

    # 1-based position in this org's checkpoint chain, inside the signed
    # payload. It is also what `KilnCMS.Governance.Witness.key/2` builds the
    # published object's key from, which is why the audit comparison needs
    # nothing else to be attested: the key names a signed number.
    attribute :sequence, :integer, allow_nil?: false, public?: true

    # The Merkle root over every anchored document's head at `covered_at`.
    attribute :root, :string, allow_nil?: false, public?: true

    # How many documents the root covers. Not load-bearing for a per-document
    # verdict — the inclusion proof is — but it is what makes a wholesale
    # shrinking of the corpus visible to an operator reading the trail.
    attribute :document_count, :integer, allow_nil?: false, public?: true

    # When the head set was read. Stamped by the minting run rather than taken
    # from `inserted_at`, which is written by the database and attested by
    # nothing (the mistake #666 catalogues on anchors).
    attribute :covered_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # The checkpoint this one continues from, plus a digest of its contents —
    # both inside the signed payload, so an excised middle checkpoint cannot be
    # papered over. Null only on an org's first checkpoint.
    attribute :prev_checkpoint_id, :uuid, public?: true
    attribute :prev_checkpoint_digest, :string, public?: true

    attribute :signature, :string, public?: true
    attribute :key_id, :string, public?: true

    # Where this checkpoint was published, and what the sink said. Outside the
    # signature by construction: it is written after signing, and the audit
    # fetches by a key derived from signed columns rather than trusting these.
    attribute :witness, :string, allow_nil?: false, default: "none", public?: true
    attribute :witness_receipt, :map, public?: true
    attribute :witnessed_at, :utc_datetime_usec, public?: true

    # The last publication failure, kept so a silently unwitnessed deployment is
    # visible on the dashboard rather than only in a log line from weeks ago.
    attribute :witness_error, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    # Declared for the `ON DELETE RESTRICT` above; the chain is walked in memory
    # from one query, as with anchors.
    belongs_to :prev_checkpoint, __MODULE__ do
      source_attribute :prev_checkpoint_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    has_many :entries, KilnCMS.CMS.ChainCheckpointEntry do
      destination_attribute :checkpoint_id
      public? false
    end
  end
end
