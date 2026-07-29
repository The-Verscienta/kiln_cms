defmodule KilnCMS.Analytics.ContentViewDay do
  @moduledoc """
  Per-day view counter — the time-series companion to
  `KilnCMS.Analytics.ContentView`, which is totals-only.

  One row per `content_type` + `content_id` + UTC `day`; each view upserts the
  row, atomically incrementing `views`. Still privacy-first: a bucket is just
  `(type, id, date, count)` — no visitor, session, IP or ordering data — so it
  records *how much* content was read on a day, never *who* read it.

  Buckets and the `ContentView` total are written separately and are **not**
  transactional with each other, and buckets are purged on a retention window
  (`retention_days/0`). Their sums will therefore diverge over time: the total
  is the all-time figure and stays the source of truth for "total views". Never
  derive the headline total from these buckets.

  Days are UTC calendar days. A site several hours off UTC sees its late-evening
  traffic land in the next day's bucket; that is deliberate, since a per-org
  timezone would fragment both the indexes and the retention window.
  """
  use Ash.Resource,
    domain: KilnCMS.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  # Retention window (days) before a bucket is purged. Longer than the 90 days
  # `KilnCMS.Analytics.SearchQuery` keeps: that limit exists because query text
  # can contain names, emails or confidential titles, which simply does not
  # apply to a `(type, uuid, date, count)` tuple. 400 days is the smallest
  # window in which a year-over-year comparison always resolves. Override via
  # `config :kiln_cms, :view_analytics, retention_days: N`.
  @retention_days Application.compile_env(:kiln_cms, [:view_analytics, :retention_days], 400)

  @doc "Configured retention window for daily view buckets, in days."
  def retention_days, do: @retention_days

  postgres do
    table "content_view_days"
    repo KilnCMS.Repo

    # The dashboard window (`:in_window`) and the nightly purge both scan by
    # date within one site. The `:unique_content_day` identity index leads
    # `(org_id, content_type, content_id, day)`, so `day` sits in position 4 and
    # cannot be range-seeked for "every bucket in this org since D" — that would
    # scan the org's whole partition. This companion is the `(org_id, day)`
    # prefix those two reads need (the tenant attribute is prepended
    # automatically, as `all_tenants?` defaults to false).
    #
    # Deliberately NO index on `views`: nothing else indexes it, so the second
    # and later views of an item on a given day are heap-only-tuple updates that
    # touch no index at all. Adding a `views` index — or an `include: [:views]`
    # on this one — would silently make every increment non-HOT.
    custom_indexes do
      index [:day], name: "content_view_days_trend_index"
    end
  end

  # Privacy retention: drop buckets older than the window. Mirrors the nightly
  # `SearchQuery` purge, offset by 15 minutes so the two don't contend.
  oban do
    # The scheduler scans each org (list_tenants), while the worker destroys
    # under each row's own `org_id` tenant (epic #336).
    use_tenant_from_record? true

    triggers do
      trigger :purge_expired do
        action :purge_expired
        read_action :expired
        worker_read_action :expired
        queue :default
        scheduler_cron "15 3 * * *"
        # Strict-tenancy (#419): schedulers scan per org, not globally.
        list_tenants KilnCMS.Accounts.ListOrgIds
        where expr(inserted_at <= ago(@retention_days, :day))

        worker_module_name KilnCMS.Analytics.ContentViewDay.AshOban.Worker.PurgeExpired
        scheduler_module_name KilnCMS.Analytics.ContentViewDay.AshOban.Scheduler.PurgeExpired
      end
    end
  end

  actions do
    defaults [:read]

    # Record a single view into today's bucket. Upserts the per-day counter, so
    # the first view of the day inserts a row at 1 (the attribute default) and
    # every later view increments atomically.
    #
    # `:day` is the conflict key and so must NOT appear in `upsert_fields` —
    # rewriting it would defeat the increment. It is set from its own default
    # rather than accepted, so a caller can't backdate a bucket.
    create :record do
      upsert? true
      upsert_identity :unique_content_day
      upsert_fields [:views]
      accept [:content_type, :content_id]
      change atomic_update(:views, expr(views + 1))
    end

    # Buckets on or after `since`, oldest first — the dashboard's trend source.
    #
    # The cutoff is a `:date` argument rather than `ago(n, :day)` because `ago/2`
    # returns a `:utc_datetime_usec` and `Date` only compares against `Date`, so
    # the expression form would not type-check. Taking a date also means the
    # window is whole calendar days, not "now minus N × 24h".
    #
    # This returns one row per (content, day) actually viewed — bounded by the
    # window, unlike the all-time read that audit finding P-M9 flagged, and
    # narrowed by the select. If a deployment ever outgrows folding these in the
    # LiveView, the fix is a single grouped Ecto query behind a function in
    # `KilnCMS.Analytics` (precedent: `KilnCMS.Mail`), scoped with an explicit
    # `where org_id == ^org_id` — not a second table.
    read :in_window do
      description "Daily view buckets on or after the given day, oldest first."
      argument :since, :date, allow_nil?: false
      filter expr(day >= ^arg(:since))
      prepare build(sort: [day: :asc], select: [:day, :content_type, :content_id, :views])
    end

    # Buckets first written before the retention window. Keyset pagination feeds
    # the AshOban `:purge_expired` trigger.
    #
    # Filters `inserted_at`, not `day`: `ago/2` yields a datetime that a `:date`
    # column can't be compared against, and `inserted_at` is stamped on the day's
    # first view, never rewritten by the upsert, and perfectly correlated with
    # `day` anyway.
    read :expired do
      description "View buckets first recorded before the retention window."
      pagination keyset?: true, required?: false
      filter expr(inserted_at <= ago(@retention_days, :day))
    end

    # Hard-delete expired buckets. Invoked by the nightly `:purge_expired` trigger.
    destroy :purge_expired do
      description "Deletes daily view buckets past the retention window."
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
  # viewed. The delivery-path write carries the viewed record's org, and the
  # upsert identity gains `org_id` so buckets never collide across sites.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the viewed
    # record's org) on the delivery-path write, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The content type's atom name as a string (e.g. "page", "post") + the
    # record id. Kept type-agnostic so any content type buckets with no wiring.
    # No FK on `content_id` — content is polymorphic across dynamic types, and
    # deleted content's buckets are reaped by retention (as in `ContentView`).
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    # The UTC calendar day this bucket counts. Set from its default so it is
    # always "today" for the recording process, never a caller-supplied date.
    attribute :day, :date do
      allow_nil? false
      default &Date.utc_today/0
      writable? false
      public? true
    end

    # Defaults to 1: the first view of the day inserts the row (default
    # applies), and every later view hits the upsert's atomic `views + 1`.
    attribute :views, :integer, default: 1, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :unique_content_day, [:content_type, :content_id, :day]
  end
end
