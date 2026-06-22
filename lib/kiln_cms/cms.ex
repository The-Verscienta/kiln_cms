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
    end

    resource KilnCMS.CMS.WebhookEndpoint do
      define :list_webhook_endpoints, action: :read
      define :get_webhook_endpoint, action: :read, get_by: [:id]
      define :create_webhook_endpoint, action: :create
      define :update_webhook_endpoint, action: :update
      define :destroy_webhook_endpoint, action: :destroy
    end
  end
end
