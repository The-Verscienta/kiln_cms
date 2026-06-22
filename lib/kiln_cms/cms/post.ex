defmodule KilnCMS.CMS.Post do
  @moduledoc """
  A Post — blog/article content. Same embedded-block model and publishing
  workflow as `Page`, plus an `excerpt` for listings/feeds.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [
      AshPaperTrail.Resource,
      AshStateMachine,
      AshJsonApi.Resource,
      AshGraphql.Resource,
      AshAdmin.Resource
    ]

  graphql do
    type :post
  end

  json_api do
    type "post"
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
      transition :unpublish, from: :published, to: :draft
      transition :archive, from: [:draft, :in_review, :published], to: :archived
    end
  end

  postgres do
    table "posts"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:title, :slug, :excerpt, :blocks, :seo_title, :seo_description, :locale]

    create :create do
      primary? true
    end

    update :update do
      primary? true
      require_atomic? false
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
    # Admins may do anything.
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Published posts are world-readable (headless delivery / public site);
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
    attribute :excerpt, :string, public?: true

    attribute :blocks, {:array, KilnCMS.CMS.Block} do
      default []
      public? true
    end

    attribute :seo_title, :string, public?: true
    attribute :seo_description, :string, public?: true
    attribute :locale, :string, default: "en", public?: true
    attribute :published_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug, :locale]
  end
end
