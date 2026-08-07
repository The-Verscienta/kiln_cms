defmodule KilnCMS.CMS.Tag do
  @moduledoc """
  A content tag — taxonomy with a **many-to-many** relationship to content: a
  `Page`/`Post` can carry many tags and a tag applies to many pages/posts,
  linked through the shared polymorphic `Tagging` join.

  Like `Category`, tags are a lightweight, editor-managed, world-readable lookup
  resource (no versioning/workflow/soft-delete). The shape they have in common —
  API surface, policies, multitenancy, the slug identity and its index — comes
  from `KilnCMS.CMS.Taxonomy`; what follows is a tag's alone.
  """
  use KilnCMS.CMS.Taxonomy,
    type: :tag,
    # Tags carry no description: a tag is its name.
    description?: false,
    accept: [:tag_group_id],
    includes: [:tag_group],
    admin_columns: [:name, :slug, :tag_group_id, :inserted_at],
    # `TagGroupInTenant` reads the group to prove it is same-org, which can't
    # run inside an atomic UPDATE.
    atomic_update?: false

  postgres do
    custom_indexes do
      # Postgres doesn't index FK columns for you, and the derived index under
      # multitenancy would be `(org_id, tag_group_id)` — which the `ON DELETE
      # SET NULL` cascade's `tag_group_id`-only scan can't seek. `all_tenants?`
      # keeps a plain `(tag_group_id)` index for that and for `tag_count`.
      index [:tag_group_id], name: "tags_tag_group_lookup_index", all_tenants?: true
    end

    # Deleting a group must never delete its tags — they fall back to
    # "Ungrouped" in the picker.
    references do
      reference :tag_group, on_delete: :nilify
    end
  end

  validations do
    # The FK on `tag_group_id` carries no org component, so nothing else stops a
    # tag being filed under another org's group (#526). Reject at the source,
    # resolving the group under the tag's own org. Only on writes.
    validate {KilnCMS.CMS.Validations.TagGroupInTenant, []}, on: [:create, :update]
  end

  relationships do
    # The bucket this tag is filed under in the editor's tag picker (see
    # `KilnCMS.CMS.TagGroup`). Optional — a tag without one shows as "Ungrouped".
    belongs_to :tag_group, KilnCMS.CMS.TagGroup do
      allow_nil? true
      public? true
    end

    # Many-to-many inverse of each content type's `tags`, through the shared
    # polymorphic `Tagging` join (one table for all content types). Joining on
    # `subject_id` returns only records of the destination type, since ids are
    # globally unique.
    many_to_many :pages, KilnCMS.CMS.Page do
      through KilnCMS.CMS.Tagging
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :subject_id
      public? true
    end

    many_to_many :posts, KilnCMS.CMS.Post do
      through KilnCMS.CMS.Tagging
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :subject_id
      public? true
    end
  end

  aggregates do
    # Usage counts for the taxonomy management UI (and public APIs).
    count :page_count, :pages do
      public? true
    end

    count :post_count, :posts do
      public? true
    end
  end
end
