defmodule KilnCMS.CMS.Tagging do
  @moduledoc """
  Polymorphic join between a `Tag` and **any** content record.

  Unlike a typed join table (one per content type), a single `taggings` table
  links a tag to a record of any type via `subject_id`. Because record ids are
  globally-unique UUIDs, no `subject_type` discriminator is needed — a content
  type's `tags` many-to-many simply joins on `subject_id`, and a tag's reverse
  `pages`/`posts`/… join back the same way. New content types become taggable
  with no schema change.

  Managed implicitly through `manage_relationship` on the parent content
  resource; not exposed via the public APIs.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "taggings"
    repo KilnCMS.Repo

    references do
      # Drop link rows when the tag is hard-deleted. `subject_id` is polymorphic
      # (no FK); rows orphaned by a purged record are invisible to reads (they
      # no longer join to any content) and can be swept separately if desired.
      reference :tag, on_delete: :delete
    end

    # `:unique_link` is now `(org_id, subject_id, tag_id)`, which can't seek a
    # tenant-less lookup by `subject_id` — the reverse of every content type's
    # `tags` many-to-many join. This `all_tenants?: true` companion keeps a plain
    # `(subject_id)` index so those joins still seek under `global?: true`.
    custom_indexes do
      index [:subject_id], name: "taggings_subject_lookup_index", all_tenants?: true
    end
  end

  actions do
    defaults [:read, :create, :update, :destroy]
    default_accept [:subject_id, :tag_id]
  end

  policies do
    # Join rows are part of editing: a write-scoped API key may tag/untag (via
    # `manage_relationship` on content updates), a read-scoped key may not.
    # Before the admin bypass so a key on an admin account can't skip it.
    policy action_type([:create, :update, :destroy]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Readable by anyone so published content can load its tags for public /
    # headless delivery.
    policy action_type(:read) do
      authorize_if always()
    end

    # Link/unlink is an editing action — editors only (admins via the bypass).
    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :editor)
    end
  end

  # Multi-tenancy (epic #336): a tagging belongs to the same site as the tag and
  # subject it links. `global?: true` keeps a tenant OPTIONAL; the tenant is
  # propagated from the parent content changeset via `manage_relationship`, so a
  # `tag_id` in another org simply won't resolve under the tenant (cross-org guard).
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

    # The tagged record's id (any content type). Polymorphic — no foreign key.
    attribute :subject_id, :uuid, allow_nil?: false, public?: true
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :tag, KilnCMS.CMS.Tag do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_link, [:subject_id, :tag_id]
  end
end
