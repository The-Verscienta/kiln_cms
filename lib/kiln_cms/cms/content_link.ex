defmodule KilnCMS.CMS.ContentLink do
  @moduledoc """
  A polymorphic, directional link between **any two content records**, carrying
  a `kind` (`:related`, `:see_also`, …) so several named relationships can be
  modelled with one table.

  Both ends are referenced by id only (`source_id` → `target_id`); because ids
  are globally-unique UUIDs no type discriminator is needed. A content type
  surfaces its links as a self- (or cross-) referential many-to-many through
  this resource — e.g. `Page.related_pages` joins `source_id → target_id` with
  the destination typed as `Page`. Linking a new content type to any other is
  just inserting rows; no new join table.

  Managed through `manage_relationship` on the parent content resource (which
  defaults new rows to `kind: :related`); not exposed via the public APIs.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_links"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :create, :update, :destroy]
    default_accept [:source_id, :target_id, :kind, :position]
  end

  policies do
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
  end

  identities do
    identity :unique_link, [:source_id, :target_id, :kind]
  end
end
