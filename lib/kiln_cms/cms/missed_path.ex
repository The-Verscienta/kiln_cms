defmodule KilnCMS.CMS.MissedPath do
  @moduledoc """
  An **aggregated 404 counter**: one row per `(path, locale)` that delivery
  couldn't resolve, with how many times it was asked for and when it was last
  seen (#472).

  This is the other half of the redirect story. `KilnCMS.CMS.Redirect` can
  point a retired URL at a record, but until now nothing told an editor *which*
  URLs were breaking — delivery resolves misses quietly on purpose ("no log
  noise", `KilnCMS.Firing.Delivery`). After a migration off WordPress that is
  precisely the question worth answering, so `/editor/redirects` grows a **404s**
  tab that lists the top missed paths with a one-click "create redirect".

  ## Shape

  Aggregated, not a request log: a row is a counter keyed by `(org_id, path,
  locale)`, upserted with an atomic increment. That honours the no-noise intent
  — a crawler hammering one dead URL adds one row, not ten thousand — and keeps
  the table small enough to read straight into an admin page.

  ## Privacy

  Paths only. No IP, no user agent, no referrer, no actor — consistent with the
  privacy-first analytics stance (`docs/advanced-analytics-plan.md`). A path can
  still be incidentally identifying (`/invoices/jane-doe`), so rows are not kept
  indefinitely: a nightly AshOban trigger purges anything not seen inside the
  retention window.

  ## Bounds

  A 404 counter is written by anonymous traffic, so it is attacker-reachable by
  construction: anyone can ask for a million distinct nonexistent paths. Three
  things bound it, all in `KilnCMSWeb.MissedPathTracking`:

    * a **junk filter** — probe-shaped paths (asset/config/script extensions,
      absurd lengths) are never recorded;
    * a **hard cap** on rows per org — at the cap a new path evicts the
      least-requested row rather than being refused, so the table cannot grow
      past `max_paths` (plus whatever one flight inserts) *and* a cheap flood
      can't pin it full of junk and deny the feature outright;
    * **retention** — the nightly purge.

  Configure with

      config :kiln_cms, :missed_paths,
        enabled: true,
        retention_days: 30,
        max_paths: 5_000
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshAdmin.Resource]

  # Compile-time because the retention window is baked into the `:expired` read
  # and the purge filter as an `expr` — the other two knobs are read on the
  # write path and stay runtime-configurable.
  @retention_days Application.compile_env(:kiln_cms, [:missed_paths, :retention_days], 30)

  @default_max_paths 5_000

  @doc "Days a missed-path counter is kept after it was last seen."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc "Most rows one org's 404 table may hold before recording pauses."
  @spec max_paths() :: pos_integer()
  def max_paths, do: settings()[:max_paths] || @default_max_paths

  @doc """
  Whether delivery records its 404s. On by default; set

      config :kiln_cms, :missed_paths, enabled: false

  to turn capture off entirely (delivery then behaves exactly as it did before
  #472 — no extra work, no rows).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: settings()[:enabled] != false

  defp settings, do: Application.get_env(:kiln_cms, :missed_paths, [])

  admin do
    resource_group :system
    table_columns [:path, :locale, :count, :inserted_at, :last_seen_at]
  end

  postgres do
    table "missed_paths"
    repo KilnCMS.Repo
  end

  oban do
    # The nightly purge scheduler scans each org (list_tenants); the worker
    # destroys under each row's own `org_id` tenant (epic #336), so one site's
    # retention sweep never touches another's counters.
    use_tenant_from_record? true

    triggers do
      # 3:40 — after `SearchQuery` (3:00), `ContentViewDay` (3:15) and the
      # webhook ledger (3:20), so the nightly retention sweeps don't contend.
      trigger :purge_expired do
        action :purge_expired
        read_action :expired
        worker_read_action :expired
        queue :default
        scheduler_cron "40 3 * * *"
        # Strict-tenancy prep (#419): schedulers scan per org, not globally.
        list_tenants KilnCMS.Accounts.ListOrgIds
        where expr(last_seen_at <= ago(^@retention_days, :day))

        worker_module_name KilnCMS.CMS.MissedPath.Workers.PurgeExpired
        scheduler_module_name KilnCMS.CMS.MissedPath.Schedulers.PurgeExpired
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    # Record one miss. Upserts the per-(path, locale) counter, so the first
    # request inserts a row at 1 and later ones increment atomically.
    create :record do
      accept [:path, :locale]
      upsert? true
      upsert_identity :unique_missed_path
      upsert_fields [:count, :last_seen_at]
      change atomic_update(:count, expr(count + 1))
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    # Most-requested misses first — what an editor should fix next.
    read :top do
      prepare build(sort: [count: :desc, last_seen_at: :desc])
    end

    # Rows whose most-recent hit predates the retention window. Keyset
    # pagination feeds the AshOban `:purge_expired` trigger.
    read :expired do
      description "Missed-path rows last seen before the retention window."
      pagination keyset?: true, required?: false
      filter expr(last_seen_at <= ago(^@retention_days, :day))
    end

    # Hard-delete expired rows. Invoked by the nightly `:purge_expired` trigger.
    destroy :purge_expired do
      description "Deletes missed-path rows past the retention window."
      change filter(expr(last_seen_at <= ago(^@retention_days, :day)))
    end
  end

  policies do
    # Scoped to reads/destroys on purpose, unlike the blanket admin bypass on
    # sibling analytics resources: "written only by delivery, never by a caller"
    # is the invariant this table's privacy story rests on, and a bypass that
    # covered `:create` would leave it unenforced for the one role most able to
    # reach an admin surface.
    bypass action_type([:read, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    # The nightly retention trigger reads + destroys as a trusted system job
    # (no actor); let AshOban's scheduler/worker through.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # The 404 list sits next to redirect management, whose writes are
    # admin-only — and a path list is closer to server logs than to editorial
    # data, so it stays behind the admin tier rather than the editor one.
    policy action_type([:read, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    # Written only by delivery (`authorize?: false`); never by a caller.
    policy action_type(:create) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): a miss belongs to the site whose host was asked.
  # `global?: true` keeps the tenant optional; the record write carries the
  # request's org and the upsert identity gains `org_id`.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the request's
    # org) on record, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The unresolvable public path, normalized the same way `Redirect.path` is:
    # locale prefix already stripped (`Plugs.SetLocale` runs before the router),
    # no query string, no trailing slash — so a row can be handed straight to
    # the redirect form.
    attribute :path, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    attribute :locale, :string,
      allow_nil?: false,
      default: "en",
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    attribute :count, :integer, default: 1, allow_nil?: false, public?: true

    # `allow_nil? false` is load-bearing, not tidiness: this is the *only* key
    # the retention purge filters on, and in Postgres `NULL <= x` is NULL — a
    # null row would be immortal, holding a capped slot forever, while sorting
    # NULLS FIRST to the top of the admin list.
    attribute :last_seen_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # `inserted_at` is the "first seen" half of the issue's ask — and it really
    # is first-seen, because `upsert_fields` deliberately excludes it. Public so
    # the 404s tab can show it: "started 404ing the day of the migration" and
    # "started yesterday" are different problems.
    timestamps public?: true
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
    identity :unique_missed_path, [:path, :locale]
  end
end
