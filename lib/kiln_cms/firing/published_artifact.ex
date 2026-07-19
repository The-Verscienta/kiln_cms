defmodule KilnCMS.Firing.PublishedArtifact do
  @moduledoc """
  An immutable, pre-serialized output of firing a document (Kiln v2 — decision D9).

  One row per `{document, surface}`. `body` is the compiled artifact for that
  surface (`web` → `%{"html" => …}`, `json`/`json_ld` → the structured map).
  Public reads hit these (via `KilnCMS.Firing.Cache`), never the live block tree.
  """
  use Ash.Resource,
    domain: KilnCMS.Firing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "published_artifacts"
    repo KilnCMS.Repo

    # Point-lookup index for the delivery hot path. The `:doc_surface` identity is
    # now the `org_id`-LEADING `(org_id, document_type, document_id, surface)`
    # composite, which Postgres can't seek for the tenant-less `get_surface` /
    # `for_document` delivery reads (PR1 sets no tenant under `global?: true`).
    # `all_tenants?: true` keeps this `org_id`-free so those lookups seek again;
    # redundant with the composite once the delivery path threads the tenant.
    custom_indexes do
      index [:document_type, :document_id, :surface],
        name: "published_artifacts_doc_surface_lookup_index",
        all_tenants?: true
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_document do
      argument :document_type, :atom, allow_nil?: false
      argument :document_id, :uuid, allow_nil?: false
      filter expr(document_type == ^arg(:document_type) and document_id == ^arg(:document_id))
    end

    read :get_surface do
      get? true
      argument :document_type, :atom, allow_nil?: false
      argument :document_id, :uuid, allow_nil?: false
      argument :surface, :atom, allow_nil?: false

      filter expr(
               document_type == ^arg(:document_type) and document_id == ^arg(:document_id) and
                 surface == ^arg(:surface)
             )
    end

    create :upsert do
      upsert? true
      upsert_identity :doc_surface

      accept [
        :document_type,
        :document_id,
        :surface,
        :format_version,
        :body,
        :source_version_id,
        :fired_at
      ]
    end
  end

  policies do
    # Fired artifacts are public output; writes happen only via the firing engine
    # (which runs authorize?: false), so they're forbidden through normal policy.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): artifacts are partitioned by the owning org so the
  # delivery hot path (and cache eviction) stays per-site. `global?: true` keeps
  # the tenant optional for the current tenant-less firing engine; the org_id is
  # stamped from the tenant on write, or the default org otherwise. The `:edge`/
  # `:doc_surface` unique indexes gain `org_id` automatically (attribute strategy).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # Owning organization (epic #336). Set from tenant/default; never accepted
    # from input (absent from the `:upsert` accept list).
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # `:entry` is the generic tier for admin-defined dynamic types (D17): one
    # storage key for all of them, the dynamic name lives on the entry row.
    attribute :document_type, :atom do
      allow_nil? false
      constraints one_of: [:page, :post, :entry]
      public? true
    end

    attribute :document_id, :uuid, allow_nil?: false, public?: true

    attribute :surface, :atom do
      allow_nil? false
      constraints one_of: [:web, :json, :json_ld, :llm]
      public? true
    end

    attribute :format_version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :body, :map, allow_nil?: false, default: %{}, public?: true
    attribute :source_version_id, :uuid, public?: true
    attribute :fired_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  relationships do
    # FK to the owning org (epic #336); the tenant axis is the `org_id` attribute.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :doc_surface, [:document_type, :document_id, :surface]
  end
end
