defmodule Acupuncture.Catalog do
  @moduledoc """
  The holistic-acupuncture site's content catalog — a *project* domain layered
  on the reusable KilnCMS core (see `projects/acupuncture/README.md`).

  Holds the content types migrated from the site's legacy Sanity backend
  (conditions, team members, testimonials, FAQs). Each is built on
  `KilnCMS.CMS.Content` with `domain: __MODULE__`, so it inherits the block
  editor, publishing workflow, versioning, search, SEO and relationships while
  keeping the core project-agnostic.

  The reusable core deliberately does **not** register this domain: it's absent
  from `ash_domains`/`content_domains` in `config/config.exs`. So it compiles
  but stays dormant — nothing migrates or serves it. A downstream/production
  config *activates* the catalog by appending `Acupuncture.Catalog` to both
  lists (see `projects/acupuncture/project.exs`), which makes
  `KilnCMS.CMS.ContentTypes` discover these types (admin, delivery, search)
  and wires the resources into migrations/AshOban.
  """
  # `validate_config_inclusion?: false`: this domain is intentionally not in
  # `config :kiln_cms, ash_domains` (the core stays project-agnostic; a
  # downstream config opts it in). Without this, Ash warns that a compiled
  # domain is missing from `ash_domains` — which `mix compile --warnings-as-errors`
  # turns into a build failure.
  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshJsonApi.Domain, AshGraphql.Domain, AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Acupuncture.Catalog.Condition do
      define :list_conditions, action: :read
      define :get_condition, action: :read, get_by: [:id]
      define :get_published_condition_by_slug, action: :public_by_slug, args: [:slug, :locale]
      define :search_conditions, action: :search, args: [:query]
      define :create_condition, action: :create
      define :update_condition, action: :update
      define :submit_condition_for_review, action: :submit_for_review
      define :return_condition_to_draft, action: :return_to_draft
      define :publish_condition, action: :publish
      define :publish_scheduled_condition, action: :publish_scheduled
      define :unpublish_condition, action: :unpublish
      define :archive_condition, action: :archive
      define :unarchive_condition, action: :unarchive
      define :restore_condition_version, action: :restore_version
      define :destroy_condition, action: :destroy
      define :list_trashed_conditions, action: :trashed
      define :restore_condition, action: :restore
      define :purge_condition, action: :purge
      define :list_published_conditions, action: :published
    end

    resource Acupuncture.Catalog.Condition.Version do
      define :list_condition_versions, action: :read
    end

    resource Acupuncture.Catalog.TeamMember do
      define :list_team_members, action: :read
      define :get_team_member, action: :read, get_by: [:id]
      define :get_published_team_member_by_slug, action: :public_by_slug, args: [:slug, :locale]
      define :search_team_members, action: :search, args: [:query]
      define :create_team_member, action: :create
      define :update_team_member, action: :update
      define :submit_team_member_for_review, action: :submit_for_review
      define :return_team_member_to_draft, action: :return_to_draft
      define :publish_team_member, action: :publish
      define :publish_scheduled_team_member, action: :publish_scheduled
      define :unpublish_team_member, action: :unpublish
      define :archive_team_member, action: :archive
      define :unarchive_team_member, action: :unarchive
      define :restore_team_member_version, action: :restore_version
      define :destroy_team_member, action: :destroy
      define :list_trashed_team_members, action: :trashed
      define :restore_team_member, action: :restore
      define :purge_team_member, action: :purge
      define :list_published_team_members, action: :published
    end

    resource Acupuncture.Catalog.TeamMember.Version do
      define :list_team_member_versions, action: :read
    end

    resource Acupuncture.Catalog.Testimonial do
      define :list_testimonials, action: :read
      define :get_testimonial, action: :read, get_by: [:id]
      define :get_published_testimonial_by_slug, action: :public_by_slug, args: [:slug, :locale]
      define :search_testimonials, action: :search, args: [:query]
      define :create_testimonial, action: :create
      define :update_testimonial, action: :update
      define :submit_testimonial_for_review, action: :submit_for_review
      define :return_testimonial_to_draft, action: :return_to_draft
      define :publish_testimonial, action: :publish
      define :publish_scheduled_testimonial, action: :publish_scheduled
      define :unpublish_testimonial, action: :unpublish
      define :archive_testimonial, action: :archive
      define :unarchive_testimonial, action: :unarchive
      define :restore_testimonial_version, action: :restore_version
      define :destroy_testimonial, action: :destroy
      define :list_trashed_testimonials, action: :trashed
      define :restore_testimonial, action: :restore
      define :purge_testimonial, action: :purge
      define :list_published_testimonials, action: :published
    end

    resource Acupuncture.Catalog.Testimonial.Version do
      define :list_testimonial_versions, action: :read
    end

    resource Acupuncture.Catalog.Faq do
      define :list_faqs, action: :read
      define :get_faq, action: :read, get_by: [:id]
      define :get_published_faq_by_slug, action: :public_by_slug, args: [:slug, :locale]
      define :search_faqs, action: :search, args: [:query]
      define :create_faq, action: :create
      define :update_faq, action: :update
      define :submit_faq_for_review, action: :submit_for_review
      define :return_faq_to_draft, action: :return_to_draft
      define :publish_faq, action: :publish
      define :publish_scheduled_faq, action: :publish_scheduled
      define :unpublish_faq, action: :unpublish
      define :archive_faq, action: :archive
      define :unarchive_faq, action: :unarchive
      define :restore_faq_version, action: :restore_version
      define :destroy_faq, action: :destroy
      define :list_trashed_faqs, action: :trashed
      define :restore_faq, action: :restore
      define :purge_faq, action: :purge
      define :list_published_faqs, action: :published
    end

    resource Acupuncture.Catalog.Faq.Version do
      define :list_faq_versions, action: :read
    end
  end
end
