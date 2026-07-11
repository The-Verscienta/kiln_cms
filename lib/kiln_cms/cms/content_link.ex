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

  When a relationship needs per-link attributes (a formula→ingredient link that
  carries a dosage and role, a jia-jian modification, an ordered "step N of"),
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
  end

  actions do
    defaults [:read, :create, :update, :destroy]
    default_accept [:source_id, :target_id, :kind, :position, :label, :metadata]
  end

  policies do
    # Join rows are part of editing: a write-scoped API key may link/unlink
    # (via `manage_relationship` on content updates), a read-scoped key may
    # not. Before the admin bypass so a key on an admin account can't skip it.
    policy action_type([:create, :update, :destroy]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Readable by anyone so published content can load its links for public /
    # headless delivery.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :editor)
    end
  end

  attributes do
    uuid_primary_key :id

    # Both ends are polymorphic record ids (any content type) — no foreign keys.
    attribute :source_id, :uuid, allow_nil?: false, public?: true
    attribute :target_id, :uuid, allow_nil?: false, public?: true

    # The named relationship. Open-ended so new relationship kinds need no schema
    # change; defaults to `:related` (what the editor's "related content" sets).
    attribute :kind, :atom, allow_nil?: false, default: :related, public?: true

    # Ordering of a record's links within a kind.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    # Optional short human label for the link (e.g. "Chief herb", "Step 2").
    attribute :label, :string, public?: true

    # Free-form per-link payload — the data a relation carries *about itself*
    # (dosage, role, jia-jian notes, …). Lets a data-carrying relation reuse the
    # one `content_links` table instead of needing a bespoke typed join resource.
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
  end

  identities do
    identity :unique_link, [:source_id, :target_id, :kind]
  end
end
