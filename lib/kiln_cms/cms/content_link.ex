defmodule KilnCMS.CMS.ContentLink do
  @moduledoc """
  A polymorphic, directional link between **any two content records**, carrying
  a `kind` (`:related`, `:see_also`, …) so several named relationships can be
  modelled with one table — and an optional `metadata` payload so a relation can
  carry data *about the link itself*.

  Both ends are referenced by id only (`source_id` → `target_id`); because ids
  are globally-unique UUIDs no type discriminator is needed. A content type
  surfaces its links as a self- (or cross-) referential many-to-many through
  this resource — e.g. `Page.related_pages` joins `source_id → target_id` with
  the destination typed as `Page`. Linking a new content type to any other is
  just inserting rows; no new join table.

  ## Relations with payload

  When a relationship needs per-link attributes (a recipe→ingredient link that
  carries a quantity and role, a substitution note, an ordered "step N of"),
  set `kind` to name the relation and put the attributes in `metadata` (a free
  map) and/or `label`. This is the lightweight alternative to hand-writing a
  typed join resource per relation: one `content_links` table backs every
  data-carrying relation. Read the payload via the `content_links` /
  `incoming_links` relationships on the parent content resource. (A dedicated
  Ash join resource is still the better fit when the link attributes are
  numerous, strongly-typed, or independently queried — this covers the common
  case without that ceremony.)

  Managed through `manage_relationship` on the parent content resource (which
  defaults new rows to `kind: :related`), or directly via the `create_content_link`
  interface for payload-carrying links. Not exposed via the auto API surface,
  but reachable through the content resources' link relationships.

  ## Reference edges (#1594, D20)

  A `:reference` custom field stores a snapshot in `custom_fields`
  (`%{"id", "type", "slug", "title"}`), and that snapshot keeps its shape and
  meaning. Since 1.1 every such value **also** has an edge here, written by
  `KilnCMS.CMS.Changes.SyncReferenceLinks` whenever the record's live
  `custom_fields` change: `kind: :reference`, `field` naming the custom field,
  and `source_type` / `target_type` naming both ends' content types. The edge
  is what answers "what links here" (`list_backlinks/2`) without a jsonb scan
  over every content table. See `KilnCMS.CMS.ContentLinks`.

  Edges follow the **live** value only. A reference held in a published
  record's working copy (`working_fields`) has no edge until it is published —
  it is not a link anyone can follow yet.

  ## Who may read an edge

  An edge names both of its ends, so it is readable only when **both** are:
  editors and admins see every edge of their site, and anyone else sees an edge
  only when they may read the source *and* the target
  (`KilnCMS.CMS.Checks.LinkEndsReadable`). Before 1.1 the table was
  world-readable, so a published page's `incoming_links` named the ids of the
  drafts that linked to it.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  # No routes of its own — link edges travel as compound-document `included`
  # members when a content record is fetched with `?include=content_links` /
  # `incoming_links`. The declaration exists so those members carry a proper
  # JSON:API `type` (instead of the spec-violating `"type": null`).
  json_api do
    type "content_link"
  end

  postgres do
    table "content_links"
    repo KilnCMS.Repo

    # `:unique_field_link` is `(org_id, source_id, target_id, kind, field)`, which can't
    # seek a tenant-less lookup by `source_id` (a record's outgoing links) or
    # `target_id` (its `incoming_links`). These `all_tenants?: true` companions
    # keep plain single-column indexes so both directions still seek under
    # `global?: true` (mirrors content.ex).
    custom_indexes do
      index [:source_id], name: "content_links_source_lookup_index", all_tenants?: true
      index [:target_id], name: "content_links_target_lookup_index", all_tenants?: true
    end
  end

  actions do
    defaults [:read, :create, :update, :destroy]

    default_accept [
      :source_id,
      :target_id,
      :kind,
      :position,
      :label,
      :metadata,
      :field,
      :source_type,
      :target_type
    ]

    # "What links here" (#1594): every edge pointing at `target_id`, of every
    # kind — curated related links and `:reference` custom fields alike.
    read :backlinks do
      argument :target_id, :uuid, allow_nil?: false
      filter expr(target_id == ^arg(:target_id))
      prepare build(sort: [kind: :asc, field: :asc, position: :asc])
    end

    # A record's outgoing `:reference` edges — what `Changes.SyncReferenceLinks`
    # reconciles against the live `custom_fields`.
    read :references_from do
      argument :source_id, :uuid, allow_nil?: false
      filter expr(source_id == ^arg(:source_id) and kind == :reference)
      prepare build(sort: [field: :asc, position: :asc])
    end
  end

  policies do
    # Join rows are part of editing: a write-scoped API key may link/unlink
    # (via `manage_relationship` on content updates), a read-scoped key may
    # not. Before the admin bypass so a key on an admin account can't skip it.
    policy action_type([:create, :update, :destroy]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # An edge is readable when both of its ends are (#1594). It used to be
    # `authorize_if always()`, so published content could load its links —
    # which it still can — but the rows also named the drafts on the other
    # end. Editors see every edge of their site (simple checks first, so the
    # runtime check's queries are only paid by everyone else); the cms
    # bookkeeping reads a record's own edges to reconcile them; and the join
    # read behind a `related_*` many-to-many never hands a row to anyone
    # (`Checks.ThroughRelatedJoin`).
    policy action_type(:read) do
      access_type :runtime
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :cms_bookkeeping}
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if KilnCMS.CMS.Checks.ThroughRelatedJoin
      authorize_if KilnCMS.CMS.Checks.LinkEndsReadable
    end

    # Reference edges are the consequence of a content write, not the writer's
    # own act: a scheduled publish of a working copy, or an unpublish folding
    # one, has no person behind it. `Changes.SyncReferenceLinks` writes them as
    # `CMS.Bookkeeping.system/0`.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :cms_bookkeeping, action: [:create, :destroy]}

      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end
  end

  preparations do
    # Reference edges are not "related content" (#1594) — see the module.
    prepare KilnCMS.CMS.Preparations.RelatedLinksOnly
  end

  # Multi-tenancy (epic #336): a link belongs to the same site as the records it
  # joins. `global?: true` keeps a tenant OPTIONAL; via `manage_relationship` the
  # tenant is propagated from the parent content changeset (and the direct
  # `create_content_link` interface carries it explicitly), so a `target_id` in
  # another org won't resolve under the tenant (cross-org guard).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped create
    # (propagated from the parent content changeset), else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Both ends are polymorphic record ids (any content type) — no foreign keys.
    attribute :source_id, :uuid, allow_nil?: false, public?: true
    attribute :target_id, :uuid, allow_nil?: false, public?: true

    # The named relationship. Open-ended so new relationship kinds need no schema
    # change; defaults to `:related` (what the editor's "related content" sets).
    attribute :kind, :atom, allow_nil?: false, default: :related, public?: true

    # Ordering of a record's links within a kind.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    # Optional short human label for the link (e.g. "Main ingredient", "Step 2").
    attribute :label, :string, public?: true, constraints: [max_length: KilnCMS.Limits.line()]

    # Free-form per-link payload — the data a relation carries *about itself*
    # (quantity, role, substitution notes, …). Lets a data-carrying relation reuse the
    # one `content_links` table instead of needing a bespoke typed join resource.
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    # The custom field a `kind: :reference` edge was written from (#1594); nil
    # for curated and payload links. Part of the unique identity, so one
    # record may reference the same target from two fields.
    attribute :field, :string, public?: true, constraints: [max_length: KilnCMS.Limits.line()]

    # Both ends' content type names (`"page"`, `"post"`, a dynamic type's name)
    # — the same vocabulary as a reference snapshot's `"type"`, so a consumer
    # can fetch either end without guessing. Set on reference edges; nil on
    # links written before 1.1 and on curated links.
    attribute :source_type, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :target_type, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]
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
    # `field` joined the identity in 1.1 (#1594) so two reference fields may
    # point at the same target. NULLs are not distinct, so curated links (no
    # field) stay unique per `(source, target, kind)` exactly as before.
    identity :unique_field_link, [:source_id, :target_id, :kind, :field], nils_distinct?: false
  end
end
