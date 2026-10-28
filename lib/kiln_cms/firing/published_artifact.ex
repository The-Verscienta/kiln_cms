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

    # `get_surface` for many documents of one type at once: the sync API reads
    # a page's uncached artifacts in one query rather than one per document
    # (#1713). Same index, same policies.
    read :for_documents do
      argument :document_type, :atom, allow_nil?: false
      argument :document_ids, {:array, :uuid}, allow_nil?: false
      argument :surface, :atom, allow_nil?: false

      filter expr(
               document_type == ^arg(:document_type) and document_id in ^arg(:document_ids) and
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
        :fired_at,
        :manifest
      ]
    end

    # Re-fire named documents on request (#2048) — `KilnCMS.Firing.refire/3`,
    # which documents it. Generic rather than a write on this resource: it
    # queues the normal fire job, and the engine writes the artifacts as
    # `:firing` exactly as it does for a publish.
    action :refire, :integer do
      description "Queue a re-fire of published documents; returns how many were queued."
      argument :document_type, :string, allow_nil?: false
      argument :document_ids, {:array, :uuid}, allow_nil?: false

      run fn input, context ->
        case context.tenant do
          nil ->
            {:error, "refire needs a tenant: pass `tenant:` the org whose documents to fire"}

          tenant ->
            KilnCMS.Firing.Refire.run(
              Ash.ToTenant.to_tenant(tenant, __MODULE__),
              input.arguments.document_type,
              input.arguments.document_ids
            )
            |> case do
              {:ok, count} -> {:ok, count}
              {:error, {:unknown_type, type}} -> {:error, "no content type #{inspect(type)}"}
            end
        end
      end
    end
  end

  policies do
    # A requested re-fire (#2048). An overlay's own code calls it with no
    # person behind it — a webhook from another install, say — so it runs as
    # the `:overlay` system actor; an editor may ask too, since an edit of the
    # same document would fire it anyway. It reads and writes nothing itself
    # beyond queueing jobs: the fire runs later, as `:firing`, under the
    # policies above.
    policy action(:refire) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :overlay}
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Writes happen only via the firing engine, which is the system: the engine
    # fires a document and persists what it rendered. Nobody else has ever had a
    # write path here, and #1402 replaced the engine's `authorize?: false` with
    # a declared grant to `%KilnCMS.SystemActor{}` — `authorize_if` rather than
    # `bypass`, so a policy added to this resource later applies to the engine
    # too.
    #
    # Reads re-enforce the **audience axis** one layer down (#565). An artifact
    # carries the rendered body of its document, so `authorize_if always()` here
    # made the gate on `Content` — published + `:public`, or an audience the
    # reader holds — moot for anyone who could reach this resource. The check
    # delegates to the document's own read policy rather than restating it; see
    # `Checks.DocumentReadable` for why that beats denormalizing the audience.
    #
    # The system actor is admitted alongside it, because delivery has already
    # decided the audience question by the time it asks for a body:
    # `Firing.Delivery.resolve/5` reads the *document* first (its own filter
    # carries the published/audience/unlock grant) and only then fetches the
    # artifact by id. Re-running `DocumentReadable` there with the anonymous
    # actor would refuse every gated document delivery had just unlocked.
    #
    # `access_type :runtime` is required by the manual check: rows are fetched,
    # then filtered. Delivery does now run this policy rather than skipping it,
    # but it never reaches the manual check's query: the system clause is a
    # `SimpleCheck` on the actor struct and it is first, so the hot path costs
    # one struct match.
    policy action_type(:read) do
      access_type :runtime

      authorize_if {KilnCMS.Checks.SystemActor, subsystem: [:delivery, :firing]}

      # Editors and admins see every document, so they see every artifact. A
      # simple check, so it short-circuits before the runtime check's query.
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if KilnCMS.Firing.Checks.DocumentReadable
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :firing}
      forbid_if always()
    end
  end

  validations do
    validate {KilnCMS.Firing.Validations.KnownDocumentType, attributes: [:document_type]}
  end

  # Multi-tenancy (epic #336): artifacts are partitioned by the owning org so the
  # delivery hot path (and cache eviction) stays per-site. `global?: true` keeps
  # the tenant optional for the current tenant-less firing engine; the org_id is
  # stamped from the tenant on write, or the default org otherwise. The `:edge`/
  # `:doc_surface` unique indexes gain `org_id` automatically (attribute strategy).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
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
    # Validated against the ContentTypes registry at runtime (see
    # `Validations.KnownDocumentType`) so generated compiled types fire too.
    attribute :document_type, :atom do
      allow_nil? false
      public? true
    end

    attribute :document_id, :uuid, allow_nil?: false, public?: true

    attribute :surface, :atom do
      allow_nil? false
      constraints one_of: KilnCMS.Firing.Surfaces.all()
      public? true
    end

    attribute :format_version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :body, :map, allow_nil?: false, default: %{}, public?: true
    attribute :source_version_id, :uuid, public?: true
    attribute :fired_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # The signed provenance manifest made when this body was fired (#1929), or
    # nil: fired before 1.7, with provenance off, or with no signing key. Kept
    # beside the body so a later read can tell an unaltered artifact from a
    # tampered one (`KilnCMS.Provenance.verdict/1`); a manifest re-derived from
    # the current body would always match it.
    attribute :manifest, :map
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
