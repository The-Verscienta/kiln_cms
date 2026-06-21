defmodule KilnCMS.CMS.Page do
  @moduledoc """
  A Page — strongly-modeled content with an embedded block tree (D3),
  full version history (AshPaperTrail) and a publishing workflow
  (AshStateMachine: draft → in_review → published → archived).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshPaperTrail.Resource,
      AshStateMachine,
      AshJsonApi.Resource,
      AshGraphql.Resource,
      AshAdmin.Resource
    ]

  graphql do
    type :page
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at])
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

  json_api do
    type "page"
  end

  postgres do
    table "pages"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:title, :slug, :blocks, :seo_title, :seo_description, :locale]

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

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug, :locale]
  end
end
