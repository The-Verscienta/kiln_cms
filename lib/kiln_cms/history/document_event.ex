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

    # Every event one user produced, across documents: the rows the GDPR
    # erasure sweep (`KilnCMS.History.anonymize_actor/1`) redacts. A bulk
    # update authorizes its query as a read, so the sweep needs a read action
    # of its own for the system actor to be admitted to (#1659).
    read :by_actor do
      argument :actor_id, :uuid, allow_nil?: false
      filter expr(actor_id == ^arg(:actor_id))
    end

    # Privacy (#212/#219): null the actor on a user's events when that user is
    # erased, while keeping the content-history rows themselves for audit. Run as
    # `KilnCMS.History.system/0` from `KilnCMS.History.anonymize_actor/1`.
    update :anonymize_actor do
      description "Clear actor_id (user erasure) while retaining the event."
      accept []
      change set_attribute(:actor_id, nil)
    end
  end

  policies do
    # History is internal; reads are editor/admin tooling. Non-editors get
    # nothing. The History API reads as `KilnCMS.History.system/0` (#1659):
    # one document's events (`for_document`) and one erased user's
    # (`by_actor`), narrowed inside this policy rather than granted by a
    # bypass. The plain `read` is not admitted: nothing in the History API
    # lists the whole log.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      forbid_unless action([:for_document, :by_actor])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :history}
    end

    # Writes (the append, and actor anonymization) only ever run through the
    # History API as `KilnCMS.History.system/0`, each admitted by name. No
    # person, admin included, may write to or rewrite the event log.
    policy action_type(:create) do
      forbid_unless action(:append)
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :history}
    end

    policy action_type(:update) do
      forbid_unless action(:anonymize_actor)
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :history}
    end
  end

  # Multi-tenancy (epic #336): an event belongs to the same site as the document
  # it records. `global?: true` keeps the tenant optional; the append/read system
  # jobs (`KilnCMS.History.system/0`) carry the document's org. The `:doc_seq` identity
  # keeps its name (only its columns gain `org_id`), so the
  # `document_events_doc_seq_index` reference in `KilnCMS.History` stays valid.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
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
