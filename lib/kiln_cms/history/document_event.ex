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
  end

  attributes do
    uuid_primary_key :id

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

  identities do
    identity :doc_seq, [:document_type, :document_id, :seq]
  end
end
