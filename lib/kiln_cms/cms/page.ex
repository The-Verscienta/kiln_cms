defmodule KilnCMS.CMS.Page do
  @moduledoc """
  A Page — strongly-modeled content with an embedded block tree (D3),
  full version history (AshPaperTrail) and a publishing workflow
  (AshStateMachine: draft → in_review → published → archived).
  """
  # Days trashed content is retained before the nightly auto-purge (see the
  # `purge_trashed` trigger). Configurable via `config :kiln_cms, :trash`.
  @trash_retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [
      AshPaperTrail.Resource,
      AshStateMachine,
      AshOban,
      AshArchival.Resource,
      AshJsonApi.Resource,
      AshGraphql.Resource,
      AshAdmin.Resource
    ]

  graphql do
    type :page
  end

  json_api do
    type "page"
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at])
    # No FK from version -> page, so a `:purge` can hard-delete a page whose
    # history exists. Versions of purged content are left as audit records.
    reference_source?(false)
    mixin({KilnCMS.CMS.VersionPolicies, :policies, []})
    version_extensions(authorizers: [Ash.Policy.Authorizer])
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :submit_for_review, from: :draft, to: :in_review
      transition :publish, from: [:draft, :in_review], to: :published
      transition :publish_scheduled, from: [:draft, :in_review], to: :published
      transition :unpublish, from: :published, to: :draft
      transition :archive, from: [:draft, :in_review, :published], to: :archived
    end
  end

  # Background publishing of scheduled content. The `AshOban`-generated
  # scheduler runs every minute and triggers `publish_scheduled` on each page
  # whose `scheduled_at` has passed.
  oban do
    triggers do
      trigger :publish_scheduled do
        action :publish_scheduled
        queue :default
        scheduler_cron "* * * * *"

        where expr(
                state in [:draft, :in_review] and not is_nil(scheduled_at) and
                  scheduled_at <= now()
              )

        worker_read_action :read
        worker_module_name KilnCMS.CMS.Page.Workers.PublishScheduled
        scheduler_module_name KilnCMS.CMS.Page.Schedulers.PublishScheduled
      end

      # Permanently delete pages that have sat in the trash for 30+ days, so
      # soft-deleted content doesn't accumulate forever. Runs nightly.
      trigger :purge_trashed do
        action :purge
        read_action :trashed
        worker_read_action :trashed
        queue :default
        scheduler_cron "0 3 * * *"

        where expr(archived_at <= ago(^@trash_retention_days, :day))

        worker_module_name KilnCMS.CMS.Page.Workers.PurgeTrashed
        scheduler_module_name KilnCMS.CMS.Page.Schedulers.PurgeTrashed
      end
    end
  end

  # Let the `:trashed` read action see soft-deleted rows (every other read
  # keeps AshArchival's automatic `is_nil(archived_at)` filter), and let
  # `:purge` actually hard-delete instead of re-archiving.
  archive do
    exclude_read_actions([:trashed])
    exclude_destroy_actions([:purge])
  end

  postgres do
    table "pages"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :title,
      :slug,
      :blocks,
      :seo_title,
      :seo_description,
      :seo_image,
      :canonical_url,
      :locale,
      :scheduled_at
    ]

    create :create do
      primary? true
      # Stamp the acting user as the author (system/seed creates with no actor
      # simply leave it nil).
      change relate_actor(:author, allow_nil?: true)
      change KilnCMS.CMS.Changes.SanitizeBlocks
      change KilnCMS.CMS.Changes.SetSearchText
    end

    update :update do
      primary? true
      require_atomic? false
      change KilnCMS.CMS.Changes.SanitizeBlocks
      change KilnCMS.CMS.Changes.SetSearchText
    end

    # Full-text search over the denormalized `search_text` (title + SEO +
    # block text). Goes through the read policy, so anonymous callers only
    # match published pages.
    read :search do
      argument :query, :string, allow_nil?: false

      filter expr(
               fragment(
                 "to_tsvector('english', coalesce(?, '')) @@ plainto_tsquery('english', ?)",
                 search_text,
                 ^arg(:query)
               )
             )
    end

    update :submit_for_review do
      require_atomic? false
      change transition_state(:in_review)
    end

    update :publish do
      require_atomic? false
      change transition_state(:published)
      change set_attribute(:published_at, &DateTime.utc_now/0)
      change KilnCMS.CMS.Changes.NotifyWebhooks
    end

    update :publish_scheduled do
      # Run by the AshOban scheduler for content whose `scheduled_at` has passed.
      require_atomic? false
      change transition_state(:published)
      change set_attribute(:published_at, &DateTime.utc_now/0)
      change set_attribute(:scheduled_at, nil)
      change KilnCMS.CMS.Changes.NotifyWebhooks
    end

    update :restore_version do
      # Reverts content fields to a previous PaperTrail version (captured as a
      # new version itself). Workflow state is left unchanged.
      require_atomic? false
      accept []
      argument :version_id, :uuid, allow_nil?: false
      change KilnCMS.CMS.Changes.RestoreVersion
      change KilnCMS.CMS.Changes.SanitizeBlocks
    end

    update :unpublish do
      require_atomic? false
      change transition_state(:draft)
      change {KilnCMS.CMS.Changes.NotifyWebhooks, event: "unpublished"}
    end

    update :archive do
      require_atomic? false
      change transition_state(:archived)
    end

    # Soft-deleted ("trashed") pages — the only read that bypasses AshArchival's
    # automatic `is_nil(archived_at)` filter (see the `archive` block).
    read :trashed do
      # Keyset pagination is required for the AshOban auto-purge trigger;
      # `required?: false` keeps plain `list_trashed_*` calls returning lists.
      pagination keyset?: true, required?: false
      filter expr(not is_nil(archived_at))
    end

    # Bring a soft-deleted page back by clearing its archival timestamp.
    update :restore do
      accept []
      require_atomic? false
      change set_attribute(:archived_at, nil)
    end

    # Permanent hard delete (bypasses archival — see the `archive` block). Used
    # by "Empty trash" and the nightly auto-purge trigger; admin/system only
    # via the destroy policy.
    destroy :purge do
    end
  end

  policies do
    # The AshOban scheduler publishes scheduled content as a trusted system job.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Admins may do anything.
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Published pages are world-readable (headless delivery / public site);
    # unpublished content (draft/in_review/archived) is editors-only.
    policy action_type(:read) do
      authorize_if expr(state == :published)
      authorize_if actor_attribute_equals(:role, :editor)
    end

    # Authoring and workflow transitions are reserved for editors (and admins
    # via the bypass above). Every state-machine action is an update action.
    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :editor)
    end

    # Hard deletes are admin-only (allowed by the bypass; denied here for all
    # other roles).
    policy action_type(:destroy) do
      forbid_if always()
    end

    # Trash browsing and restore are admin-only too (mirrors delete). Admins
    # pass via the bypass above; everyone else is denied here.
    policy action([:trashed, :restore]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true

    attribute :blocks, {:array, KilnCMS.CMS.Block} do
      default []
      public? true
    end

    attribute :seo_title, :string, public?: true
    attribute :seo_description, :string, public?: true
    # og:image URL and rel=canonical for SEO/social.
    attribute :seo_image, :string, public?: true
    attribute :canonical_url, :string, public?: true
    attribute :locale, :string, default: "en", public?: true
    attribute :published_at, :utc_datetime_usec, public?: true

    # When set in the future, the AshOban scheduler publishes this page once the
    # time passes (cleared on publish).
    attribute :scheduled_at, :utc_datetime_usec, public?: true

    # Denormalized plain-text (title + SEO + block text) maintained by
    # `Changes.SetSearchText` and queried by the `search` action. Internal.
    attribute :search_text, :string

    timestamps()
  end

  relationships do
    # The user who authored this page. Nullable so existing/system content
    # without an actor is valid. Not exposed via the public APIs (User has no
    # GraphQL/JSON:API type).
    belongs_to :author, KilnCMS.Accounts.User do
      allow_nil? true
      public? true
    end
  end

  calculations do
    # Convenience flag for the published state (no `?` suffix — GraphQL names
    # can't contain it).
    calculate :published, :boolean, expr(state == :published) do
      public? true
    end

    # Total word count across the embedded block tree.
    calculate :word_count, :integer, KilnCMS.CMS.Calculations.WordCount do
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug, :locale]
  end
end
