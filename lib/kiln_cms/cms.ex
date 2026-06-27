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
      define :get_published_page_by_slug, action: :public_by_slug, args: [:slug, :locale]
      define :list_page_translations, action: :published_translations, args: [:slug]
      define :search_pages, action: :search, args: [:query]
      define :semantic_search_pages, action: :search_semantic, args: [:query]
      define :autocomplete_pages, action: :autocomplete, args: [:prefix]
      define :create_page, action: :create
      define :update_page, action: :update
      define :submit_page_for_review, action: :submit_for_review
      define :return_page_to_draft, action: :return_to_draft
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
      define :get_published_post_by_slug, action: :public_by_slug, args: [:slug, :locale]
      define :list_post_translations, action: :published_translations, args: [:slug]
      define :list_published_posts, action: :published
      define :search_posts, action: :search, args: [:query]
      define :semantic_search_posts, action: :search_semantic, args: [:query]
      define :autocomplete_posts, action: :autocomplete, args: [:prefix]
      define :create_post, action: :create
      define :update_post, action: :update
      define :submit_post_for_review, action: :submit_for_review
      define :return_post_to_draft, action: :return_to_draft
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
      define :search_media, action: :search, args: [:query]
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

    # Admin-UI-defined custom fields: the runtime field registry that backs the
    # `custom_fields` map on content (decision D4 — data-driven *fields*, not a
    # runtime meta-model of *types*). `field_definitions_for` is the per-type
    # lookup the editor and the write change call with `authorize?: false`.
    resource KilnCMS.CMS.FieldDefinition do
      define :list_field_definitions, action: :read
      define :get_field_definition, action: :read, get_by: [:id]
      define :field_definitions_for, action: :for_type, args: [:content_type]
      define :create_field_definition, action: :create
      define :update_field_definition, action: :update
      define :destroy_field_definition, action: :destroy
    end

    resource KilnCMS.CMS.Herb do
      define :list_herbs, action: :read
      define :get_herb, action: :read, get_by: [:id]
      define :get_published_herb_by_slug, action: :public_by_slug, args: [:slug]
      define :search_herbs, action: :search, args: [:query]
      define :create_herb, action: :create
      define :update_herb, action: :update
      define :submit_herb_for_review, action: :submit_for_review
      define :return_herb_to_draft, action: :return_to_draft
      define :publish_herb, action: :publish
      define :publish_scheduled_herb, action: :publish_scheduled
      define :unpublish_herb, action: :unpublish
      define :archive_herb, action: :archive
      define :restore_herb_version, action: :restore_version
      define :destroy_herb, action: :destroy
      define :list_trashed_herbs, action: :trashed
      define :restore_herb, action: :restore
      define :purge_herb, action: :purge
      define :list_published_herbs, action: :published
    end

    resource KilnCMS.CMS.Herb.Version do
      define :list_herb_versions, action: :read
    end

    resource KilnCMS.CMS.Formula do
      define :list_formulas, action: :read
      define :get_formula, action: :read, get_by: [:id]
      define :get_published_formula_by_slug, action: :public_by_slug, args: [:slug]
      define :search_formulas, action: :search, args: [:query]
      define :create_formula, action: :create
      define :update_formula, action: :update
      define :submit_formula_for_review, action: :submit_for_review
      define :return_formula_to_draft, action: :return_to_draft
      define :publish_formula, action: :publish
      define :publish_scheduled_formula, action: :publish_scheduled
      define :unpublish_formula, action: :unpublish
      define :archive_formula, action: :archive
      define :restore_formula_version, action: :restore_version
      define :destroy_formula, action: :destroy
      define :list_trashed_formulas, action: :trashed
      define :restore_formula, action: :restore
      define :purge_formula, action: :purge
      define :list_published_formulas, action: :published
    end

    resource KilnCMS.CMS.Formula.Version do
      define :list_formula_versions, action: :read
    end

    resource KilnCMS.CMS.Condition do
      define :list_conditions, action: :read
      define :get_condition, action: :read, get_by: [:id]
      define :get_published_condition_by_slug, action: :public_by_slug, args: [:slug]
      define :search_conditions, action: :search, args: [:query]
      define :create_condition, action: :create
      define :update_condition, action: :update
      define :submit_condition_for_review, action: :submit_for_review
      define :return_condition_to_draft, action: :return_to_draft
      define :publish_condition, action: :publish
      define :publish_scheduled_condition, action: :publish_scheduled
      define :unpublish_condition, action: :unpublish
      define :archive_condition, action: :archive
      define :restore_condition_version, action: :restore_version
      define :destroy_condition, action: :destroy
      define :list_trashed_conditions, action: :trashed
      define :restore_condition, action: :restore
      define :purge_condition, action: :purge
      define :list_published_conditions, action: :published
    end

    resource KilnCMS.CMS.Condition.Version do
      define :list_condition_versions, action: :read
    end

    resource KilnCMS.CMS.Practitioner do
      define :list_practitioners, action: :read
      define :get_practitioner, action: :read, get_by: [:id]
      define :get_published_practitioner_by_slug, action: :public_by_slug, args: [:slug]
      define :search_practitioners, action: :search, args: [:query]
      define :create_practitioner, action: :create
      define :update_practitioner, action: :update
      define :submit_practitioner_for_review, action: :submit_for_review
      define :return_practitioner_to_draft, action: :return_to_draft
      define :publish_practitioner, action: :publish
      define :publish_scheduled_practitioner, action: :publish_scheduled
      define :unpublish_practitioner, action: :unpublish
      define :archive_practitioner, action: :archive
      define :restore_practitioner_version, action: :restore_version
      define :destroy_practitioner, action: :destroy
      define :list_trashed_practitioners, action: :trashed
      define :restore_practitioner, action: :restore
      define :purge_practitioner, action: :purge
      define :list_published_practitioners, action: :published
    end

    resource KilnCMS.CMS.Practitioner.Version do
      define :list_practitioner_versions, action: :read
    end

    resource KilnCMS.CMS.Clinic do
      define :list_clinics, action: :read
      define :get_clinic, action: :read, get_by: [:id]
      define :get_published_clinic_by_slug, action: :public_by_slug, args: [:slug]
      define :search_clinics, action: :search, args: [:query]
      define :create_clinic, action: :create
      define :update_clinic, action: :update
      define :submit_clinic_for_review, action: :submit_for_review
      define :return_clinic_to_draft, action: :return_to_draft
      define :publish_clinic, action: :publish
      define :publish_scheduled_clinic, action: :publish_scheduled
      define :unpublish_clinic, action: :unpublish
      define :archive_clinic, action: :archive
      define :restore_clinic_version, action: :restore_version
      define :destroy_clinic, action: :destroy
      define :list_trashed_clinics, action: :trashed
      define :restore_clinic, action: :restore
      define :purge_clinic, action: :purge
      define :list_published_clinics, action: :published
    end

    resource KilnCMS.CMS.Clinic.Version do
      define :list_clinic_versions, action: :read
    end

    resource KilnCMS.CMS.Modality do
      define :list_modalities, action: :read
      define :get_modality, action: :read, get_by: [:id]
      define :get_published_modality_by_slug, action: :public_by_slug, args: [:slug]
      define :search_modalities, action: :search, args: [:query]
      define :create_modality, action: :create
      define :update_modality, action: :update
      define :submit_modality_for_review, action: :submit_for_review
      define :return_modality_to_draft, action: :return_to_draft
      define :publish_modality, action: :publish
      define :publish_scheduled_modality, action: :publish_scheduled
      define :unpublish_modality, action: :unpublish
      define :archive_modality, action: :archive
      define :restore_modality_version, action: :restore_version
      define :destroy_modality, action: :destroy
      define :list_trashed_modalities, action: :trashed
      define :restore_modality, action: :restore
      define :purge_modality, action: :purge
      define :list_published_modalities, action: :published
    end

    resource KilnCMS.CMS.Modality.Version do
      define :list_modality_versions, action: :read
    end
  end
end
