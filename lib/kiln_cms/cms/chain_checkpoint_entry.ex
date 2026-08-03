defmodule KilnCMS.CMS.ChainCheckpointEntry do
  @moduledoc """
  One document's head anchor as a checkpoint recorded it, with the Merkle
  inclusion proof that binds it to the checkpoint's signed root (#666).

  ## Why a proof rather than the whole set

  The root commits to **every** anchored document in the org. Recomputing it to
  check one document would mean reading every leaf back — ten thousand rows to
  answer a question about one, on a page an admin opens per document. The proof
  is the `O(log n)` sibling hashes on the path instead: one entry row, one
  checkpoint row, one signature verification.

  ## Why only the changed ones are stored

  Rows are written for documents whose head **moved** since the previous
  checkpoint. A document that has not been edited keeps its last entry, and that
  entry still verifies — its proof is against *its own* checkpoint's root, which
  was signed at the time and does not become less true later. A daily checkpoint
  over a corpus where a handful of documents change therefore costs a handful of
  rows, not one per document per day.

  The root is still computed over the **full** head set, not the delta. A
  commitment to "what changed" would say nothing about what did not, and the
  document an attacker cares about is precisely the one they want to look
  unchanged.

  ## The regression rule

  A head that has moved *backwards* — fewer anchors than the last checkpoint saw
  — is the truncation this whole mechanism exists to catch. No entry is written
  for it. Recording it would overwrite the evidence with the attacker's version
  one checkpoint later; leaving the older, higher entry standing is what makes
  the verdict stick until an operator looks. See
  `KilnCMS.Governance.Checkpoint`.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "chain_checkpoint_entries"
    repo KilnCMS.Repo

    custom_indexes do
      # The per-document lookup: "the strongest head any checkpoint recorded for
      # this document". Carries the sort as well as the filter so it is a top-1
      # backward scan rather than a fetch-and-sort over every entry the document
      # has ever had. Column order matches `for_content`'s sort — see there for
      # why it is `head_sequence` and not `checkpoint_sequence`.
      index [:org_id, :resource_type, :source_id, :head_sequence, :checkpoint_sequence]

      # One entry per document per checkpoint. Minting is a read-then-write like
      # everything else here, and a duplicate would make "the newest entry"
      # ambiguous on the path that decides a tamper verdict.
      index [:org_id, :checkpoint_id, :resource_type, :source_id], unique: true
    end

    references do
      # Entries cannot outlive their checkpoint, and a checkpoint cannot be
      # excised while entries name it.
      reference :checkpoint, on_delete: :restrict, on_update: :restrict
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :checkpoint_id,
        :checkpoint_sequence,
        :resource_type,
        :source_id,
        :head_anchor_id,
        :head_sequence,
        :chain_hash,
        :version_count,
        :proof
      ]
    end

    # The **strongest** recorded head for one document — highest witnessed anchor
    # position first, and among equals the most recent checkpoint.
    #
    # Deliberately not "newest checkpoint first". Entries are append-only
    # assertions that a position held a given anchor, and each remains true after
    # later ones are written. Ordering by `checkpoint_sequence` made deleting one
    # row *demote* the witness rather than remove it: a document witnessed at
    # position 1 by checkpoint 1 and at position 3 by checkpoint 2 needs only the
    # checkpoint-2 entry gone for the surviving claim to be the weaker one, after
    # which truncating to position 2 reads as ordinary growth. With this
    # ordering, deleting entries can only ever remove claims.
    #
    # `checkpoint_sequence` is still verified against the checkpoint's own signed
    # `sequence` before any verdict is drawn from it — see
    # `KilnCMS.Governance.Checkpoint.witnessed_head/3`.
    read :for_content do
      argument :resource_type, :string, allow_nil?: false
      argument :source_id, :uuid, allow_nil?: false

      filter expr(resource_type == ^arg(:resource_type) and source_id == ^arg(:source_id))
      prepare build(sort: [head_sequence: :desc, checkpoint_sequence: :desc])
    end

    # Every entry recorded by one checkpoint — what `Checkpoint.document/2`
    # publishes. Unsorted here on purpose: the caller orders in Elixir, because
    # those bytes are compared exactly by the audit and a Postgres text collation
    # must not decide them.
    read :for_checkpoint do
      argument :checkpoint_id, :uuid, allow_nil?: false

      filter expr(checkpoint_id == ^arg(:checkpoint_id))
    end
  end

  policies do
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
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

    attribute :checkpoint_id, :uuid, allow_nil?: false, public?: true

    # Denormalized from the checkpoint so the per-document lookup is one index
    # scan rather than a join. It is a plain column and therefore rewritable, so
    # nothing trusts it on its own: verification loads the named checkpoint and
    # requires this to equal that checkpoint's SIGNED `sequence`. Repointing it
    # to promote an old entry fails that check; repointing `checkpoint_id`
    # instead fails the inclusion proof against the new checkpoint's root.
    attribute :checkpoint_sequence, :integer, allow_nil?: false, public?: true

    # The witnessed document, keyed exactly as `history_anchors` keys it — the
    # storage type name, so dynamic types resolve through the shared entry tier.
    attribute :resource_type, :string, allow_nil?: false, public?: true
    attribute :source_id, :uuid, allow_nil?: false, public?: true

    # The head anchor at checkpoint time. `head_sequence` is the comparison that
    # catches truncation; the other two catch a head replaced rather than
    # removed.
    attribute :head_anchor_id, :uuid, allow_nil?: false, public?: true
    attribute :head_sequence, :integer, allow_nil?: false, public?: true
    attribute :chain_hash, :string, allow_nil?: false, public?: true
    attribute :version_count, :integer, allow_nil?: false, public?: true

    # Sibling hashes from this entry's leaf up to the checkpoint root, leaf
    # first. See `KilnCMS.Governance.Merkle` for the encoding.
    attribute :proof, {:array, :map}, allow_nil?: false, default: [], public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :checkpoint, KilnCMS.CMS.ChainCheckpoint do
      source_attribute :checkpoint_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
