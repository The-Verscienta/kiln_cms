defmodule KilnCMS.History.DocumentEvent do
  @moduledoc """
  An append-only block-level event (Kiln v2 — decision D14).

  Document state is a fold over these events (`KilnCMS.History.replay/3`), giving
  per-block history, time-travel, and audit from one substrate. They **coexist
  with AshPaperTrail**: PaperTrail snapshots remain the publish/restore anchor;
  events power fine-grained history between snapshots and are the same payloads
  the collaborative editor broadcasts (Phase F).
  """
  use Ash.Resource,
    domain: KilnCMS.History,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "document_events"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    create :append do
      accept [:document_type, :document_id, :seq, :kind, :payload, :actor_id]
    end

    read :for_document do
      argument :document_type, :atom, allow_nil?: false
      argument :document_id, :uuid, allow_nil?: false
      filter expr(document_type == ^arg(:document_type) and document_id == ^arg(:document_id))
      prepare build(sort: [seq: :asc])
    end

    # Privacy (#212/#219): null the actor on a user's events when that user is
    # erased, while keeping the content-history rows themselves for audit. Run as
    # a system job (`authorize?: false`) from `KilnCMS.History.anonymize_actor/1`.
    update :anonymize_actor do
      description "Clear actor_id (user erasure) while retaining the event."
      accept []
      change set_attribute(:actor_id, nil)
    end
  end

  policies do
    # History is internal; reads are editor/admin tooling, writes only via the
    # History API (authorize?: false). Non-editors get nothing.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :editor)
    end

    policy action_type(:create) do
      forbid_if always()
    end

    # Writes (incl. actor anonymization) only ever run as a trusted system job
    # (`authorize?: false`); no external caller may mutate the event log.
    policy action_type(:update) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): an event belongs to the same site as the document
  # it records. `global?: true` keeps the tenant optional; the append/read system
  # jobs (`authorize?: false`) carry the document's org. The `:doc_seq` identity
  # keeps its name (only its columns gain `org_id`), so the
  # `document_events_doc_seq_index` reference in `KilnCMS.History` stays valid.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the document's
    # org) on append, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :document_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:page, :post]],
      public?: true

    attribute :document_id, :uuid, allow_nil?: false, public?: true
    attribute :seq, :integer, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false

      constraints one_of: [
                    :snapshot,
                    :block_added,
                    :block_removed,
                    :block_updated,
                    :blocks_reordered
                  ]

      public? true
    end

    attribute :payload, :map, allow_nil?: false, default: %{}, public?: true
    attribute :actor_id, :uuid, public?: true

    create_timestamp :inserted_at
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

  identities do
    identity :doc_seq, [:document_type, :document_id, :seq]
  end
end
