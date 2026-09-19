defmodule KilnCMS.Firing.SyncExposure do
  @moduledoc """
  One row per document the sync API (`KilnCMS.Firing.Sync`) has ever handed an
  anonymous caller as an upsert.

  It exists to answer one question safely: **may a tombstone name this id?**

  A delta reports a document as deleted when it changed inside the window and
  is no longer visible to an anonymous reader. Taken alone, that rule would name
  every draft an editor touched, every members-only post, and every document
  that was passphrase-locked (#496) from the day it was written — ids that no
  anonymous caller has ever seen and that the lock exists precisely to keep off
  every discovery surface. Version history cannot settle it either: the lock is
  deliberately kept out of `*.Version` rows, so "was this public at T" is not
  something the history can say.

  So the sync API keeps its own record of what it has disclosed. A tombstone is
  emitted only for an id recorded here, which bounds what a tombstone reveals
  to ids some sync caller in this org was already given — while they were
  public, through the same response anyone could have requested.

  `type_name` / `type_definition_id` are kept because a hard-purged document
  has no row left to read its type from, and a type-scoped sync still has to
  file its tombstone under the right type.

  Written and read only by the sync API, as the system actor.
  """
  use Ash.Resource,
    domain: KilnCMS.Firing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sync_exposures"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    create :record do
      upsert? true
      upsert_identity :document
      # A dynamic type can be renamed; the latest name wins so a later
      # tombstone is filed under what the type is called now.
      upsert_fields [:type_name]
      accept [:document_type, :document_id, :type_name, :type_definition_id]
    end

    read :for_documents do
      argument :document_ids, {:array, :uuid}, allow_nil?: false
      filter expr(document_id in ^arg(:document_ids))
    end
  end

  policies do
    # Bookkeeping for one subsystem. No person has a reason to read or write
    # it: the ids it holds are only ever surfaced as tombstones, by the sync API,
    # which runs as the system actor. `authorize_if` rather than a bypass — see
    # `KilnCMS.Checks.SystemActor`.
    policy always() do
      authorize_if KilnCMS.Checks.SystemActor
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

    # The STORAGE type (`:entry` for every dynamic type, D17) — what the
    # document's table and version table are keyed on.
    attribute :document_type, :atom, allow_nil?: false, public?: true
    attribute :document_id, :uuid, allow_nil?: false, public?: true

    # The consumer-facing type name, as the upsert carried it. Bounded like
    # `TypeDefinition.name`, which is where a dynamic one comes from.
    attribute :type_name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :type_definition_id, :uuid, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :document, [:document_id]
  end
end
