defmodule KilnCMS.Analytics.FunnelStep do
  @moduledoc """
  One ordered step in a `KilnCMS.Analytics.Funnel`: a content item
  (`content_type` + `content_id`, polymorphic and FK-less — the same shape as
  `KilnCMS.Analytics.ContentViewDay`'s, since #622 joins a step to its
  traffic by that pair) plus its `position` within the funnel.

  No count is stored here. Step traffic is derived at read time from
  `ContentViewDay` buckets (#622) — see the parent's moduledoc for why.
  """
  use Ash.Resource,
    domain: KilnCMS.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "funnel_steps"
    repo KilnCMS.Repo

    references do
      reference :funnel, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    default_accept [:funnel_id, :content_type, :content_id, :position]

    create :create, primary?: true

    update :update do
      primary? true
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end

    # All steps of one funnel, in display order — the builder's own read
    # (mirrors `FormField.:for_form`).
    read :for_funnel do
      argument :funnel_id, :uuid, allow_nil?: false
      filter expr(funnel_id == ^arg(:funnel_id))
      prepare build(sort: [position: :asc])
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): a step belongs to the same site as its funnel.
  changes do
    # A `:funnel_completion` experiment converts on this funnel's LAST step, and
    # delivery reads that from a cache (#1010).
    change KilnCMS.Analytics.Changes.BustFunnelTargets,
      on: [:create, :update, :destroy]
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # No FK on `content_id` — content is polymorphic across dynamic types,
    # same as `ContentViewDay.content_type`/`content_id`. A step whose content
    # has since been deleted resolves to zero traffic at read time (#622),
    # which the UI must render as "deleted" rather than a real drop-off.
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :funnel, KilnCMS.Analytics.Funnel do
      allow_nil? false
      public? true
    end
  end
end
