defmodule Verscienta.Catalog do
  @moduledoc """
  The Verscienta content catalog — a *project* domain layered on the reusable
  KilnCMS core (see `projects/verscienta/README.md`).

  Holds the domain-specific content types migrated from Verscienta's legacy
  Directus backend (herbs, formulas, conditions, practitioners, clinics,
  modalities). Each is built on `KilnCMS.CMS.Content` with `domain: __MODULE__`,
  so it inherits the block editor, publishing workflow, versioning, search, SEO
  and relationships while keeping the core project-agnostic. Listed in
  `:content_domains` so `KilnCMS.CMS.ContentTypes` discovers these types
  everywhere (admin, delivery, search).
  """
  use Ash.Domain,
    extensions: [AshJsonApi.Domain, AshGraphql.Domain, AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Verscienta.Catalog.Herb do
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

    resource Verscienta.Catalog.Herb.Version do
      define :list_herb_versions, action: :read
    end

    resource Verscienta.Catalog.Formula do
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

    resource Verscienta.Catalog.Formula.Version do
      define :list_formula_versions, action: :read
    end

    resource Verscienta.Catalog.Condition do
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

    resource Verscienta.Catalog.Condition.Version do
      define :list_condition_versions, action: :read
    end

    resource Verscienta.Catalog.Practitioner do
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

    resource Verscienta.Catalog.Practitioner.Version do
      define :list_practitioner_versions, action: :read
    end

    resource Verscienta.Catalog.Clinic do
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

    resource Verscienta.Catalog.Clinic.Version do
      define :list_clinic_versions, action: :read
    end

    resource Verscienta.Catalog.Modality do
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

    resource Verscienta.Catalog.Modality.Version do
      define :list_modality_versions, action: :read
    end
  end
end
