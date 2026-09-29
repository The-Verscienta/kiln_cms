defmodule KilnCMS.Experiments.VariantDay do
  @moduledoc """
  Per-variant, per-day impression and conversion counters (#499).

  Two integers per variant per day — which is all a proportion test needs, and
  all this stores. No per-visitor rows, no event log, no session identifier.
  That is not a limitation to be lifted later; it is the reason Kiln can run an
  A/B test while `docs/data-flows.md` still says no visitor is tracked.

  The same upsert shape as `KilnCMS.Analytics.ContentViewDay`, and — like
  `ReferrerDay` before it (#619) — an **additional** counter rather than a new
  dimension on an existing one, so the existing per-content analytics stay
  comparable to their own history.
  """
  use Ash.Resource,
    domain: KilnCMS.Experiments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_experiment_variant_days"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept []

    create :record_impression do
      description "Count one variant served."
      upsert? true
      upsert_identity :unique_variant_day
      upsert_fields [:impressions]

      argument :variant_id, :uuid, allow_nil?: false

      change set_attribute(:variant_id, arg(:variant_id))
      # On INSERT the row starts at one impression; on conflict the atomic
      # update increments. `ContentViewDay` gets away with `default 1` because
      # it carries a single counter — this row carries two, so the one that did
      # not fire has to be explicitly zero rather than defaulted.
      change set_attribute(:impressions, 1)
      change set_attribute(:conversions, 0)
      change atomic_update(:impressions, expr(impressions + 1))
    end

    create :record_conversion do
      description "Count one conversion against the variant that was served."
      upsert? true
      upsert_identity :unique_variant_day
      upsert_fields [:conversions]

      argument :variant_id, :uuid, allow_nil?: false

      change set_attribute(:variant_id, arg(:variant_id))
      change set_attribute(:impressions, 0)
      change set_attribute(:conversions, 1)
      change atomic_update(:conversions, expr(conversions + 1))
    end

    destroy :destroy do
      primary? true
    end
  end

  # Written by delivery and by the form submission path, both of which run as
  # `KilnCMS.Experiments.system/0` (#1659): the two counters and nothing else.
  # `destroy` is not admitted — a system caller cannot erase a result. Read by
  # `mix kiln.experiment show` (the results panel reads as the viewing editor).
  policies do
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :operator}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin

      forbid_unless action([:record_impression, :record_conversion])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :experiments}
    end
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

    attribute :variant_id, :uuid, allow_nil?: false, public?: true

    attribute :day, :date do
      default &Date.utc_today/0
      allow_nil? false
      writable? false
      public? true
    end

    attribute :impressions, :integer, default: 0, allow_nil?: false, public?: true
    attribute :conversions, :integer, default: 0, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :unique_variant_day, [:variant_id, :day]
  end
end
