defmodule KilnCMS.CMS do
  @moduledoc """
  The CMS domain — core content modeling for KilnCMS.

  Holds the content-facing resources (`Page`, `Post`, `MediaItem`). Blocks are
  modeled as **embedded resources** stored as a JSON tree on each content
  resource (see decision D3 in the project plan), not as a separate table.
  """
  use Ash.Domain,
    extensions: [AshJsonApi.Domain, AshGraphql.Domain, AshAdmin.Domain]

  admin do
    show? true
  end

  # Domain code interfaces are the contract for calling into these resources —
  # prefer `CMS.create_page!(...)` over `Ash.create!(Page, ...)` everywhere
  # (LiveViews, controllers, seeds, tests). Ash also generates matching
  # `can_*?/2` authorization helpers (e.g. `CMS.can_publish_page?(actor, page)`)
  # for conditional UI.
  resources do
    resource KilnCMS.CMS.Page do
      define :list_pages, action: :read
      define :get_page, action: :read, get_by: [:id]
      define :get_published_page_by_slug, action: :public_by_slug, args: [:slug]
      define :search_pages, action: :search, args: [:query]
      define :create_page, action: :create
      define :update_page, action: :update
      define :submit_page_for_review, action: :submit_for_review
      define :publish_page, action: :publish
      define :publish_scheduled_page, action: :publish_scheduled
      define :unpublish_page, action: :unpublish
      define :archive_page, action: :archive
      define :restore_page_version, action: :restore_version
      define :destroy_page, action: :destroy
      define :list_trashed_pages, action: :trashed
      define :restore_page, action: :restore
      define :purge_page, action: :purge
    end

    resource KilnCMS.CMS.Page.Version do
      define :list_page_versions, action: :read
    end

    resource KilnCMS.CMS.Post do
      define :list_posts, action: :read
      define :get_post, action: :read, get_by: [:id]
      define :get_published_post_by_slug, action: :public_by_slug, args: [:slug]
      define :list_published_posts, action: :published
      define :search_posts, action: :search, args: [:query]
      define :create_post, action: :create
      define :update_post, action: :update
      define :submit_post_for_review, action: :submit_for_review
      define :publish_post, action: :publish
      define :publish_scheduled_post, action: :publish_scheduled
      define :unpublish_post, action: :unpublish
      define :archive_post, action: :archive
      define :restore_post_version, action: :restore_version
      define :destroy_post, action: :destroy
      define :list_trashed_posts, action: :trashed
      define :restore_post, action: :restore
      define :purge_post, action: :purge
    end

    resource KilnCMS.CMS.Post.Version do
      define :list_post_versions, action: :read
    end

    resource KilnCMS.CMS.MediaItem do
      define :list_media_items, action: :read
      define :get_media_item, action: :read, get_by: [:id]
      define :create_media_item, action: :create
      define :update_media_item, action: :update
      define :destroy_media_item, action: :destroy
      define :list_trashed_media_items, action: :trashed
      define :restore_media_item, action: :restore
      define :purge_media_item, action: :purge
    end

    resource KilnCMS.CMS.WebhookEndpoint do
      define :list_webhook_endpoints, action: :read
      define :get_webhook_endpoint, action: :read, get_by: [:id]
      define :create_webhook_endpoint, action: :create
      define :update_webhook_endpoint, action: :update
      define :destroy_webhook_endpoint, action: :destroy
    end

    # Taxonomy: categories (one-to-many to content) and tags (many-to-many).
    resource KilnCMS.CMS.Category do
      define :list_categories, action: :read
      define :get_category, action: :read, get_by: [:id]
      define :get_category_by_slug, action: :by_slug, args: [:slug]
      define :create_category, action: :create
      define :update_category, action: :update
      define :destroy_category, action: :destroy
    end

    resource KilnCMS.CMS.Tag do
      define :list_tags, action: :read
      define :get_tag, action: :read, get_by: [:id]
      define :get_tag_by_slug, action: :by_slug, args: [:slug]
      define :create_tag, action: :create
      define :update_tag, action: :update
      define :destroy_tag, action: :destroy
    end

    # Polymorphic join resources backing the many-to-many relationships — one
    # `Tagging` table for tags across all content types, one `ContentLink` table
    # for content-to-content links.
    #
    # `Tagging` is managed entirely through `manage_relationship` on the parent
    # content resources, so it needs no code interface. `ContentLink` also backs
    # the per-type `related_*` relationships that way, but gets interfaces too so
    # app code can create arbitrary *cross-type*, named (`kind`) links between
    # any two content records without a new join table.
    resource KilnCMS.CMS.Tagging

    resource KilnCMS.CMS.ContentLink do
      define :list_content_links, action: :read
      define :create_content_link, action: :create
      define :destroy_content_link, action: :destroy
    end
  end
end
