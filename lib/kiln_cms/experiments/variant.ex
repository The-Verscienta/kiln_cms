defmodule KilnCMS.Experiments.Variant do
  @moduledoc """
  One arm of an experiment: a sparse patch over the targeted document (#499).

  ## The patch

      %{
        "fields" => %{"title" => "Ship faster with Kiln"},
        "blocks" => %{"3f2a…-uuid" => %{"text" => "Start free"}}
      }

  `fields` names document scalars. `blocks` is keyed by a block's stable `_id` —
  the same identity the visual-editing bridge addresses and the block union
  already carries — so a patch survives block **reordering**, which a positional
  patch would not.

  Sparse and additive: a key not mentioned keeps its canonical value. That is
  what makes a variant reviewable ("this one changes the CTA") rather than a
  whole-document fork whose difference has to be diffed out.

  ## The control

  Exactly one variant per experiment is the control, and its patch is empty. It
  exists as a row rather than as an implicit "no variant" so results have
  something to compare against and so "the control won" is a thing the data can
  say.

  ## Which fields may be patched

  `@patchable_fields` is an allowlist, and a short one. A variant that could set
  `slug` would move the page under the visitor; one that could set `state` or
  `audience` would publish or unpaywall content from a settings form. The list
  holds what a headline test actually needs.
  """
  use Ash.Resource,
    domain: KilnCMS.Experiments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Document scalars a variant may override. Deliberately excludes `slug`,
  # `state`, `audience`, `locale` and every SEO field: the first three would let
  # a variant move, publish or unpaywall a document, and the SEO fields are
  # exactly what invariant 3 keeps canonical so an experiment never reaches an
  # index.
  @patchable_fields ~w(title excerpt)

  @doc "Document scalars a variant patch may override."
  @spec patchable_fields() :: [String.t()]
  def patchable_fields, do: @patchable_fields

  postgres do
    table "content_experiment_variants"
    repo KilnCMS.Repo

    # Without this the FK defaults to NO ACTION and destroying an experiment
    # that has variants raises a bare Postgres 23503 rather than doing the
    # obvious thing. A variant has no meaning apart from its experiment.
    references do
      reference :experiment, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    default_accept [:experiment_id, :name, :weight, :patch, :control]

    create :create do
      primary? true
      validate KilnCMS.Experiments.Validations.PatchShape
    end

    # The weights and the patches live here, so this is where "only a draft is
    # editable" has to be enforced — guarding the row that holds the name while
    # leaving this one open would be a guard in name only.
    update :update do
      primary? true
      require_atomic? false
      validate KilnCMS.Experiments.Validations.PatchShape
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  changes do
    change KilnCMS.Experiments.Changes.BustExperimentCache,
      on: [:create, :update, :destroy]

    change KilnCMS.Experiments.Changes.RefuseWhenRunning, on: [:update]

    # On create and destroy as well as update. Adding a third arm to a running
    # 50/50 changes `total` from 2 to 3, which re-buckets every keyed visitor
    # onto a different variant while the counters keep climbing; removing one
    # orphans its `VariantDay` rows, since there is no foreign key on
    # `variant_id`. Both make the accumulated numbers unreadable.
    change KilnCMS.Experiments.Changes.RefuseWhenRunning,
      on: [:create, :destroy]
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

    attribute :experiment_id, :uuid, allow_nil?: false, public?: true

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # Relative share of traffic. Integers rather than percentages so a split
    # never has to add up to anything.
    attribute :weight, :integer do
      default 1
      allow_nil? false
      constraints min: 0
      public? true
    end

    attribute :patch, :map, default: %{}, allow_nil?: false, public?: true

    attribute :control, :boolean, default: false, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :experiment, KilnCMS.Experiments.Experiment do
      source_attribute :experiment_id
      define_attribute? false
      attribute_writable? false
      public? true
    end
  end

  identities do
    identity :unique_name_per_experiment, [:experiment_id, :name]
  end
end
