defmodule KilnCMS.Analytics.ReferrerDay do
  @moduledoc """
  Per-day, per-source arrival counter (#619, phase 2 of
  `docs/advanced-analytics-plan.md`) — the referrer-attribution companion to
  `KilnCMS.Analytics.ContentViewDay`, same table shape and policy block.

  One row per `content_type` + `content_id` + coarse `source` category + UTC
  `day`; each classified arrival upserts the row, atomically incrementing
  `hits`. Still privacy-first: a bucket is `(type, id, source, date, count)` —
  no visitor, session, IP, or raw referrer URL. `source` is bounded to five
  categories by the type system (`one_of/1` below), so no future caller can
  widen a row into a host list.

  The classification that produces `source` happens in the **web** layer
  (`KilnCMSWeb.ReferrerSource.classify/2`) — this resource's public API
  (`KilnCMS.Analytics.record_referrer/4`) accepts only the already-classified
  atom, never a URL or host. That makes persisting a raw referrer impossible
  through this domain, not merely discouraged.

  Days are UTC calendar days, matching `ContentViewDay`.
  """
  use Ash.Resource,
    domain: KilnCMS.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  # Same retention window and config key as `ContentViewDay` — both are daily
  # bucket counters governed by the same "how long do we keep a day's numbers"
  # policy, not a privacy limit (there is no free text or visitor data here,
  # unlike `SearchQuery`'s separate 90-day clock).
  @retention_days Application.compile_env(:kiln_cms, [:view_analytics, :retention_days], 400)

  @doc "Configured retention window for daily referrer buckets, in days."
  def retention_days, do: @retention_days

  postgres do
    table "referrer_days"
    repo KilnCMS.Repo

    # The `(org_id, day)` companion index `ContentViewDay` keeps for its own
    # `:in_window` dashboard read — the `:unique_referrer_day` identity index
    # leads with `content_type`/`content_id`/`source`, so `day` alone can't be
    # range-seeked from it. Added ahead of #620's `:in_window`/`:in_range`
    # reads below (added in #619, before either action existed) so growing
    # into it never means a second migration plus a build-time table scan.
    # NOT for the retention purge, which filters `inserted_at`, not `day`
    # (see `:expired` below).
    #
    # Deliberately NO index on `hits`, for the same heap-only-tuple reason
    # `ContentViewDay` gives: this is the second and later hit of a row, which
    # should never touch an index.
    custom_indexes do
      index [:day], name: "referrer_days_trend_index"
    end
  end

  # Privacy retention: drop buckets older than the window. Its own cron
  # minute so the nightly purges don't contend — `SearchQuery` runs `0 3`,
  # `ContentViewDay` `15 3`, this one `30 3`.
  oban do
    use_tenant_from_record? true

    triggers do
      trigger :purge_expired do
        action :purge_expired
        read_action :expired
        worker_read_action :expired
        queue :default
        scheduler_cron "30 3 * * *"
        list_tenants KilnCMS.Accounts.ListOrgIds
        where expr(inserted_at <= ago(@retention_days, :day))

        worker_module_name KilnCMS.Analytics.ReferrerDay.AshOban.Worker.PurgeExpired
        scheduler_module_name KilnCMS.Analytics.ReferrerDay.AshOban.Scheduler.PurgeExpired
      end
    end
  end

  actions do
    defaults [:read]

    # Record a single classified arrival into today's bucket for this source.
    # `:day` is the conflict key (via the identity) and so must NOT appear in
    # `upsert_fields` — rewriting it would defeat the increment; it is set
    # from its own default rather than accepted, so a caller can't backdate a
    # bucket.
    create :record do
      upsert? true
      upsert_identity :unique_referrer_day
      upsert_fields [:hits]
      accept [:content_type, :content_id, :source]
      change atomic_update(:hits, expr(hits + 1))
    end

    # Buckets on or after `since`, oldest first — the dashboard's breakdown
    # source (#620). Mirrors `ContentViewDay.:in_window` exactly, including
    # why `since` is a `:date` argument rather than `ago(n, :day)`: `ago/2`
    # returns a `:utc_datetime_usec`, and `Date` only compares against `Date`.
    read :in_window do
      description "Daily referrer buckets on or after the given day, oldest first."
      argument :since, :date, allow_nil?: false
      filter expr(day >= ^arg(:since))

      prepare build(
                sort: [day: :asc],
                select: [:day, :content_type, :content_id, :source, :hits]
              )
    end

    # The export's source read (#620, extending #618's `ContentViewDay.:in_range`
    # precedent to referrer buckets). `id` breaks ties within a day for a
    # stable keyset cursor — `day` alone is not unique. The caller is
    # responsible for capping the span at `retention_days/0`, same contract
    # as `ContentViewDay.:in_range`.
    read :in_range do
      description "Daily referrer buckets between two days inclusive, oldest first, keyset-paginated."
      argument :from, :date, allow_nil?: false
      argument :to, :date, allow_nil?: false
      pagination keyset?: true, required?: false
      filter expr(day >= ^arg(:from) and day <= ^arg(:to))

      prepare build(
                sort: [day: :asc, id: :asc],
                select: [:id, :day, :content_type, :content_id, :source, :hits]
              )
    end

    # Buckets first written before the retention window. Keyset pagination
    # feeds the AshOban `:purge_expired` trigger.
    read :expired do
      description "Referrer buckets first recorded before the retention window."
      pagination keyset?: true, required?: false
      filter expr(inserted_at <= ago(@retention_days, :day))
    end

    # Hard-delete expired buckets. Invoked by the nightly `:purge_expired` trigger.
    destroy :purge_expired do
      description "Deletes daily referrer buckets past the retention window."
      change filter(expr(inserted_at <= ago(@retention_days, :day)))
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # The nightly `:purge_expired` retention trigger reads + destroys as a
    # trusted system job (no actor); let AshOban's scheduler/worker through.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Reading analytics is editor/admin only.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Buckets are recorded only by the system (the delivery controller, via
    # `authorize?: false`); never by an external caller.
    policy action_type(:create) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): a bucket belongs to the site whose content was
  # viewed, same as `ContentViewDay`.
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

    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    # Bounded to five categories by the type system — see the moduledoc. The
    # classifier (`KilnCMSWeb.ReferrerSource`) is the only intended writer of
    # this value.
    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:direct, :internal, :search, :social, :other]
    end

    attribute :day, :date do
      allow_nil? false
      default &Date.utc_today/0
      writable? false
      public? true
    end

    # Defaults to 1: the first hit of the day for this source inserts the row
    # (default applies), every later hit increments atomically.
    attribute :hits, :integer, default: 1, allow_nil?: false, public?: true

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
    identity :unique_referrer_day, [:content_type, :content_id, :source, :day]
  end
end
