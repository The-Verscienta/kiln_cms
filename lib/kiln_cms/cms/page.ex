defmodule KilnCMS.CMS.Page do
  @moduledoc """
  A Page — strongly-modeled content with an embedded block tree (D3),
  full version history (AshPaperTrail) and a publishing workflow
  (AshStateMachine: draft → in_review → published → archived).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [
      AshPaperTrail.Resource,
      AshStateMachine,
      AshOban,
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
    end
  end

  postgres do
    table "pages"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:title, :slug, :blocks, :seo_title, :seo_description, :locale, :scheduled_at]

    create :create do
      primary? true
      # Stamp the acting user as the author (system/seed creates with no actor
      # simply leave it nil).
      change relate_actor(:author, allow_nil?: true)
      change KilnCMS.CMS.Changes.SetSearchText
    end

    update :update do
      primary? true
      require_atomic? false
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
    end

    update :publish_scheduled do
      # Run by the AshOban scheduler for content whose `scheduled_at` has passed.
      require_atomic? false
      change transition_state(:published)
      change set_attribute(:published_at, &DateTime.utc_now/0)
      change set_attribute(:scheduled_at, nil)
    end

    update :unpublish do
      require_atomic? false
      change transition_state(:draft)
    end

    update :archive do
      require_atomic? false
      change transition_state(:archived)
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
