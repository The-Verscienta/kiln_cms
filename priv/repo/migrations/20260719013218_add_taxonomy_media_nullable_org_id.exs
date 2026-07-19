defmodule KilnCMS.Repo.Migrations.AddTaxonomyMediaNullableOrgId do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4a — **step 1 of 3** for the taxonomy,
  media, and join tables (`categories`, `tags`, `taggings`, `content_links`,
  `media_items`).

  Adds a **nullable** `org_id` (+ FK to `organizations`) to each table and
  rewrites each identity's unique index to lead with `org_id`
  (`(org_id, slug)` / `(org_id, subject_id, tag_id)` / …), plus `all_tenants?`
  companion single-column lookup indexes so tenant-less lookups still seek.
  `org_id` stays nullable here so existing rows don't violate `NOT NULL`; the
  companion `backfill_taxonomy_media_org` data migration stamps them to the
  default org, and `require_taxonomy_media_org_id_not_null` then adds the
  constraint (the same nullable → backfill → not-null recipe PR 1 used).

  The `pages`/`posts`/`entries` FK constraints and the `media_items` search GIN
  are dropped and re-created with **byte-identical DDL**: Ash re-emits them only
  because their referenced tables (`categories`/`media_items`/`tags`) now record
  a multitenancy block in the resource snapshot — no actual schema change to
  those objects.
  """

  use Ecto.Migration

  def up do
    alter table(:content_links) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "content_links_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create index(:content_links, [:target_id], name: "content_links_target_lookup_index")

    create index(:content_links, [:source_id], name: "content_links_source_lookup_index")

    drop_if_exists unique_index(:content_links, [:source_id, :target_id, :kind],
                     name: "content_links_unique_link_index"
                   )

    create unique_index(:content_links, [:org_id, :source_id, :target_id, :kind],
             name: "content_links_unique_link_index"
           )

    drop constraint(:taggings, "taggings_tag_id_fkey")

    alter table(:taggings) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "taggings_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create index(:taggings, [:subject_id], name: "taggings_subject_lookup_index")

    drop_if_exists unique_index(:taggings, [:subject_id, :tag_id],
                     name: "taggings_unique_link_index"
                   )

    create unique_index(:taggings, [:org_id, :subject_id, :tag_id],
             name: "taggings_unique_link_index"
           )

    alter table(:taggings) do
      modify :tag_id,
             references(:tags,
               column: :id,
               name: "taggings_tag_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    alter table(:categories) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "categories_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create index(:categories, [:slug], name: "categories_slug_lookup_index")

    drop_if_exists unique_index(:categories, [:slug], name: "categories_unique_slug_index")

    create unique_index(:categories, [:org_id, :slug], name: "categories_unique_slug_index")

    drop constraint(:entries, "entries_featured_image_id_fkey")

    drop constraint(:entries, "entries_category_id_fkey")

    alter table(:entries) do
      modify :category_id,
             references(:categories,
               column: :id,
               name: "entries_category_id_fkey",
               type: :uuid,
               prefix: "public"
             )

      modify :featured_image_id,
             references(:media_items,
               column: :id,
               name: "entries_featured_image_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop constraint(:posts, "posts_featured_image_id_fkey")

    drop constraint(:posts, "posts_category_id_fkey")

    alter table(:posts) do
      modify :category_id,
             references(:categories,
               column: :id,
               name: "posts_category_id_fkey",
               type: :uuid,
               prefix: "public"
             )

      modify :featured_image_id,
             references(:media_items,
               column: :id,
               name: "posts_featured_image_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop_if_exists index(
                     :media_items,
                     [
                       "to_tsvector('english', coalesce(filename, '') || ' ' || coalesce(alt, '') || ' ' || coalesce(caption, ''))"
                     ],
                     name: "media_items_search_gin_index"
                   )

    alter table(:media_items) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "media_items_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create index(
             :media_items,
             [
               "to_tsvector('english', coalesce(filename, '') || ' ' || coalesce(alt, '') || ' ' || coalesce(caption, ''))"
             ],
             name: "media_items_search_gin_index",
             using: "gin"
           )

    drop constraint(:pages, "pages_featured_image_id_fkey")

    drop constraint(:pages, "pages_category_id_fkey")

    alter table(:pages) do
      modify :category_id,
             references(:categories,
               column: :id,
               name: "pages_category_id_fkey",
               type: :uuid,
               prefix: "public"
             )

      modify :featured_image_id,
             references(:media_items,
               column: :id,
               name: "pages_featured_image_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    alter table(:tags) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "tags_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create index(:tags, [:slug], name: "tags_slug_lookup_index")

    drop_if_exists unique_index(:tags, [:slug], name: "tags_unique_slug_index")

    create unique_index(:tags, [:org_id, :slug], name: "tags_unique_slug_index")
  end

  def down do
    drop constraint(:tags, "tags_org_id_fkey")

    drop_if_exists unique_index(:tags, [:org_id, :slug], name: "tags_unique_slug_index")

    create unique_index(:tags, [:slug], name: "tags_unique_slug_index")

    drop_if_exists index(:tags, [:slug], name: "tags_slug_lookup_index")

    alter table(:tags) do
      remove :org_id
    end

    drop constraint(:pages, "pages_category_id_fkey")

    drop constraint(:pages, "pages_featured_image_id_fkey")

    alter table(:pages) do
      modify :featured_image_id,
             references(:media_items,
               column: :id,
               name: "pages_featured_image_id_fkey",
               type: :uuid,
               prefix: "public"
             )

      modify :category_id,
             references(:categories,
               column: :id,
               name: "pages_category_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop constraint(:media_items, "media_items_org_id_fkey")

    drop_if_exists index(
                     :media_items,
                     [
                       "to_tsvector('english', coalesce(filename, '') || ' ' || coalesce(alt, '') || ' ' || coalesce(caption, ''))"
                     ],
                     name: "media_items_search_gin_index"
                   )

    alter table(:media_items) do
      remove :org_id
    end

    create index(
             :media_items,
             [
               "to_tsvector('english', coalesce(filename, '') || ' ' || coalesce(alt, '') || ' ' || coalesce(caption, ''))"
             ],
             name: "media_items_search_gin_index",
             using: "gin"
           )

    drop constraint(:posts, "posts_category_id_fkey")

    drop constraint(:posts, "posts_featured_image_id_fkey")

    alter table(:posts) do
      modify :featured_image_id,
             references(:media_items,
               column: :id,
               name: "posts_featured_image_id_fkey",
               type: :uuid,
               prefix: "public"
             )

      modify :category_id,
             references(:categories,
               column: :id,
               name: "posts_category_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop constraint(:entries, "entries_category_id_fkey")

    drop constraint(:entries, "entries_featured_image_id_fkey")

    alter table(:entries) do
      modify :featured_image_id,
             references(:media_items,
               column: :id,
               name: "entries_featured_image_id_fkey",
               type: :uuid,
               prefix: "public"
             )

      modify :category_id,
             references(:categories,
               column: :id,
               name: "entries_category_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop constraint(:categories, "categories_org_id_fkey")

    drop_if_exists unique_index(:categories, [:org_id, :slug],
                     name: "categories_unique_slug_index"
                   )

    create unique_index(:categories, [:slug], name: "categories_unique_slug_index")

    drop_if_exists index(:categories, [:slug], name: "categories_slug_lookup_index")

    alter table(:categories) do
      remove :org_id
    end

    drop constraint(:taggings, "taggings_org_id_fkey")

    drop constraint(:taggings, "taggings_tag_id_fkey")

    alter table(:taggings) do
      modify :tag_id,
             references(:tags,
               column: :id,
               name: "taggings_tag_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    drop_if_exists unique_index(:taggings, [:org_id, :subject_id, :tag_id],
                     name: "taggings_unique_link_index"
                   )

    create unique_index(:taggings, [:subject_id, :tag_id], name: "taggings_unique_link_index")

    drop_if_exists index(:taggings, [:subject_id], name: "taggings_subject_lookup_index")

    alter table(:taggings) do
      remove :org_id
    end

    drop constraint(:content_links, "content_links_org_id_fkey")

    drop_if_exists unique_index(:content_links, [:org_id, :source_id, :target_id, :kind],
                     name: "content_links_unique_link_index"
                   )

    create unique_index(:content_links, [:source_id, :target_id, :kind],
             name: "content_links_unique_link_index"
           )

    drop_if_exists index(:content_links, [:source_id], name: "content_links_source_lookup_index")

    drop_if_exists index(:content_links, [:target_id], name: "content_links_target_lookup_index")

    alter table(:content_links) do
      remove :org_id
    end
  end
end
