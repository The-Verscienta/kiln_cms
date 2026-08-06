defmodule KilnCMS.CMS.ContentRelease do
  @moduledoc """
  A **content release** (#500): a named bundle of pending publishes/unpublishes
  that goes live as one coordinated unit — the Contentful Launch / Sanity
  Releases analogue.

  Kiln's per-item `scheduled_at`/`unpublish_at` can only line up N identical
  timestamps and hope. A release replaces that with one object an editorial team
  plans around: add the landing page, three posts and a fragment to it, preview
  the site as if the release were live, publish the lot at 09:00 — and roll the
  whole group back afterwards if it was wrong.

  ## What "atomic" means here

  Every side effect of the per-item `:publish` / `:unpublish` actions is a
  **database write**: `NotifyWebhooks` records ledger rows and inserts an Oban
  job, `FireArtifacts` inserts an Oban job, automation dispatch inserts an Oban
  job, and `KilnCMS.Governance.Chain` writes anchor rows. Nothing on the publish
  path makes a synchronous HTTP or object-store call — the actual POSTs and
  renders are Oban jobs, and Oban shares `KilnCMS.Repo`.

  That is what makes true all-or-nothing possible: `KilnCMS.CMS.Releases` runs
  every item inside **one** `Repo.transaction`, so a failure on item 7 rolls
  back items 1–6 *and* the webhooks, artifact fires and automation jobs they
  queued. Nothing has escaped the database yet, so observers never see a
  half-live campaign — the release lands in `:failed` naming the item that broke,
  and the site is untouched.

  ## States

      open ⇄ scheduled ──┬─ start ─▶ publishing ─┬─▶ published ─┬─▶ archived
                         │                       │              │
                         │                       └─▶ failed ──▶ open (reopen)
                         │                                      │
                         └──────────────────────────────────────┘

      published ─ start_rollback ─▶ rolling_back ─┬─▶ rolled_back ─▶ archived
                                                  └─▶ published (rollback failed)

  `:publishing` and `:rolling_back` are **claim** states, not cosmetics: the
  minute-cron scheduler and the "Publish now" button both transition into them
  before any work starts, so a go-live that outlives its minute can't be picked
  up twice.

  ## Who may do what

  Publishing content is an admin approval step (see `KilnCMS.CMS.Content`'s
  `:publish` policy), so the release actions that *cause* a publish —
  `:schedule`, `:start`, `:start_rollback` — are admin-only here. Otherwise an
  editor could publish content they aren't allowed to publish simply by putting
  it in a release: the worker necessarily runs `authorize?: false`, since it
  publishes on behalf of the release across types the acting user may not
  individually hold. Editors compose releases; admins ship them — the same shape
  as "editors submit for review, admins publish".

  The admin who schedules or starts a release is recorded as `triggered_by`, and
  the worker passes that user as the `actor` for every item's publish, so version
  history and the audit chain attribute the release to a person rather than to
  nobody.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshOban, AshAdmin.Resource]

  # States in which a release is still *composing*: its items keep reserving
  # their content records against every other release (the partial unique
  # identity on `KilnCMS.CMS.ReleaseItem`). `:failed` is deliberately in here —
  # a release that aborted is going to be fixed and retried, and letting another
  # release grab its content in the meantime is how you get two teams publishing
  # the same page.
  @pending_states [:open, :scheduled, :publishing, :failed]

  # States an editor may still add items to or remove them from.
  @editable_states [:open, :scheduled, :failed]

  @doc "States in which a release's items still reserve their content records."
  @spec pending_states() :: [atom()]
  def pending_states, do: @pending_states

  @doc "States in which a release's item list can still be edited."
  @spec editable_states() :: [atom()]
  def editable_states, do: @editable_states

  admin do
    resource_group :content
    table_columns [:name, :state, :scheduled_at, :published_at, :inserted_at]
  end

  postgres do
    table "content_releases"
    repo KilnCMS.Repo

    custom_indexes do
      # The scheduler's due-release scan and the console's state tabs.
      index [:org_id, :state, :scheduled_at], name: "content_releases_state_index"
    end
  end

  state_machine do
    initial_states [:open]
    default_initial_state :open

    transitions do
      transition :schedule, from: [:open, :scheduled], to: :scheduled
      transition :unschedule, from: :scheduled, to: :open
      # The claim: both the minute cron and "Publish now" land here first.
      transition :start, from: [:open, :scheduled], to: :publishing
      transition :mark_published, from: :publishing, to: :published
      transition :mark_failed, from: :publishing, to: :failed
      transition :reopen, from: :failed, to: :open
      transition :start_rollback, from: :published, to: :rolling_back
      transition :mark_rolled_back, from: :rolling_back, to: :rolled_back
      # A rollback that aborts leaves the release exactly as it was: published.
      transition :mark_rollback_failed, from: :rolling_back, to: :published
      # The way out of a claim whose worker never ran (see `:abandon`).
      transition :abandon, from: :publishing, to: :failed
      transition :abandon, from: :rolling_back, to: :published

      transition :archive,
        from: [:open, :scheduled, :failed, :published, :rolled_back],
        to: :archived
    end
  end

  oban do
    # Multi-tenancy (epic #336): the scheduler scans each org explicitly, and the
    # claim runs under the release's own `org_id` tenant.
    use_tenant_from_record? true

    triggers do
      # Minute cron, mirroring the per-item `:publish_scheduled` trigger on
      # `KilnCMS.CMS.Content`. This only CLAIMS the release (`:scheduled` →
      # `:publishing`) and enqueues the worker; the multi-item publish runs in
      # `KilnCMS.CMS.Workers.ReleaseWorker` so it owns its own transaction
      # boundary rather than nesting inside AshOban's.
      trigger :go_live do
        action :start
        queue :scheduling
        scheduler_cron "* * * * *"
        # Strict-tenancy prep (#419): schedulers scan per org, not globally.
        list_tenants KilnCMS.Accounts.ListOrgIds

        where expr(state == :scheduled and not is_nil(scheduled_at) and scheduled_at <= now())

        worker_read_action :read
        worker_module_name KilnCMS.CMS.ContentRelease.Workers.GoLive
        scheduler_module_name KilnCMS.CMS.ContentRelease.Schedulers.GoLive
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "Start a new release."
      primary? true
      # `scheduled_at` is deliberately NOT accepted here. Setting it on create
      # and starting the release in `:scheduled` would hand any editor the exact
      # thing `:schedule` is admin-gated to prevent: the minute cron fires a
      # `:scheduled` release under AshOban's bypass, and the worker publishes
      # every item unauthorized — with `triggered_by_id` nil, so the publishes
      # aren't even attributable. A release is always created open; scheduling it
      # is a second, admin-only step.
      accept [:name, :description]

      change KilnCMS.CMS.Changes.StampReleaseCreator
    end

    update :update do
      description "Rename a release or change its notes."
      primary? true
      accept [:name, :description]
      require_atomic? false
    end

    update :schedule do
      description "Set (or move) the release's go-live datetime."
      accept [:scheduled_at]
      require_atomic? false

      validate present(:scheduled_at)
      change transition_state(:scheduled)
      change KilnCMS.CMS.Changes.StampReleaseTrigger
    end

    update :unschedule do
      description "Drop the go-live datetime; the release goes back to manual."
      accept []
      require_atomic? false

      change set_attribute(:scheduled_at, nil)
      change transition_state(:open)
    end

    update :start do
      description "Claim the release for publishing and enqueue the go-live worker."
      accept []
      require_atomic? false

      # The claim has to be a compare-and-SWAP, not a compare-and-hope. The
      # state machine only validates the state of the struct it was handed, so a
      # console page held open since 08:59 still says `:scheduled` at 09:00:05 —
      # after the cron claimed the release — and "Publish now" would sail
      # through and enqueue a second worker. This `filter` puts the guard in the
      # UPDATE's own WHERE clause: the second writer matches no row and gets a
      # `StaleRecord` error instead of a duplicate go-live.
      change filter(expr(state in [:open, :scheduled]))
      change transition_state(:publishing)
      change KilnCMS.CMS.Changes.StampReleaseTrigger
      change {KilnCMS.CMS.Changes.EnqueueReleaseWorker, mode: :publish}
    end

    update :mark_published do
      description "System: the go-live transaction committed."
      accept []
      require_atomic? false

      change transition_state(:published)
      change set_attribute(:published_at, &DateTime.utc_now/0)
      change set_attribute(:failure_reason, nil)
      change set_attribute(:failed_item_id, nil)
    end

    update :mark_failed do
      description "System: the go-live transaction rolled back; nothing went live."
      accept []
      require_atomic? false

      argument :failure_reason, :string
      argument :failed_item_id, :uuid

      change set_attribute(:failure_reason, arg(:failure_reason))
      change set_attribute(:failed_item_id, arg(:failed_item_id))
      change transition_state(:failed)
    end

    update :reopen do
      description "Return a failed release to open so it can be fixed and retried."
      accept []
      require_atomic? false

      change transition_state(:open)
      change set_attribute(:failure_reason, nil)
      change set_attribute(:failed_item_id, nil)
    end

    update :start_rollback do
      description "Claim a published release for rollback and enqueue the worker."
      accept []
      require_atomic? false

      # Compare-and-swap, for the same reason `:start` is — see there.
      change filter(expr(state == :published))
      change transition_state(:rolling_back)
      change KilnCMS.CMS.Changes.StampReleaseTrigger
      change {KilnCMS.CMS.Changes.EnqueueReleaseWorker, mode: :rollback}
    end

    update :abandon do
      description "Release a claim whose worker never ran, so the release can be retried."
      accept []
      require_atomic? false

      # The way out of `:publishing` / `:rolling_back`. Those states mean "a
      # worker owns this right now", and a worker that died — node restart, a
      # job discarded at `max_attempts: 1` — leaves nobody to say otherwise.
      # Without this the release is stuck forever AND its items keep reserving
      # their content against every other release, with no UI to free them.
      #
      # A claim that IS still running would be interrupted mid-transaction by an
      # abandon, which is why it's admin-only and confirmed in the console: it
      # asserts "no worker is running", and only a human can know that.
      change filter(expr(state in [:publishing, :rolling_back]))

      # An abandoned go-live lands in `:failed` (nothing shipped, retry after
      # reopening); an abandoned ROLLBACK goes back to `:published`, because
      # that is still what is true of the site.
      change fn changeset, _context ->
        {target, reason} =
          case changeset.data.state do
            :rolling_back -> {:published, "Abandoned: the rollback worker never finished."}
            _ -> {:failed, "Abandoned: the go-live worker never finished."}
          end

        changeset
        |> AshStateMachine.transition_state(target)
        |> Ash.Changeset.force_change_attribute(:failure_reason, reason)
      end
    end

    update :mark_rolled_back do
      description "System: the rollback transaction committed."
      accept []
      require_atomic? false

      change transition_state(:rolled_back)
      change set_attribute(:rolled_back_at, &DateTime.utc_now/0)
      change set_attribute(:failure_reason, nil)
      change set_attribute(:failed_item_id, nil)
    end

    update :mark_rollback_failed do
      description "System: the rollback rolled back; the release stays published."
      accept []
      require_atomic? false

      argument :failure_reason, :string
      argument :failed_item_id, :uuid

      change set_attribute(:failure_reason, arg(:failure_reason))
      change set_attribute(:failed_item_id, arg(:failed_item_id))
      change transition_state(:published)
    end

    update :archive do
      description "Close a release out; its items stop reserving their content."
      accept []
      require_atomic? false

      change transition_state(:archived)
      change KilnCMS.CMS.Changes.CancelPendingReleaseItems
    end

    destroy :destroy do
      description "Delete a release that never shipped (its items cascade)."
      primary? true
      require_atomic? false
      validate KilnCMS.CMS.Validations.ReleaseDeletable
    end

    read :editable do
      description "Releases an editor can still add content to, newest first."
      filter expr(state in ^@editable_states)
      prepare build(sort: [inserted_at: :desc])
    end

    read :by_state do
      description "Releases in one state (the console's tabs), newest first."
      argument :state, :atom, allow_nil?: false

      filter expr(state == ^arg(:state))
      prepare build(sort: [inserted_at: :desc])
    end

    read :in_window do
      description "Releases whose go-live or publish moment falls in a window (calendar)."
      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false

      filter expr(
               (state == :scheduled and scheduled_at >= ^arg(:from) and scheduled_at < ^arg(:to)) or
                 (not is_nil(published_at) and published_at >= ^arg(:from) and
                    published_at < ^arg(:to))
             )
    end
  end

  policies do
    # The go-live scheduler claims due releases as a trusted job.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # There is deliberately NO blanket `OrgAdmin` bypass here. A bypass that
    # matches authorizes the whole request and skips every policy below it,
    # which would make the system `mark_*` writes callable by any org admin —
    # letting a human stamp a release `:published` that never published, or
    # rewrite an item's captured `prior_version_id` and quietly corrupt what
    # rollback restores. Admins reach everything they should through the
    # explicit policies below; the worker reaches the `mark_*` actions the only
    # way anything should, with `authorize?: false`.

    # Editor-facing only — a release is never part of a delivered document.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Composing a release is editor work.
    policy action([:create, :update, :reopen]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Shipping one is admin work — publishing content is an admin approval step,
    # and a release must not be a way around it.
    policy action([:schedule, :unschedule, :start, :start_rollback, :abandon]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    # Closing out is editor work UNTIL the release is somebody else's decision.
    # Archiving is one-way and there is no transition out of `:archived`, so an
    # editor archiving a published release would permanently destroy its group
    # rollback; archiving a scheduled one would silently cancel an admin's
    # coordinated launch. Both are admin calls.
    policy action(:archive) do
      forbid_unless KilnCMS.CMS.Checks.OrgEditor
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
      authorize_if expr(is_nil(published_at) and state != :scheduled)
    end

    # Same shape for delete: `ReleaseDeletable` already refuses anything that
    # shipped or is mid-flight, so the only extra case is a scheduled release,
    # which is an admin's plan to cancel, not an editor's.
    policy action_type(:destroy) do
      forbid_unless KilnCMS.CMS.Checks.OrgEditor
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
      authorize_if expr(state != :scheduled)
    end
  end

  # Multi-tenancy (epic #336): a release belongs to one site. `global?: true`
  # keeps the tenant optional.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped
    # create, else the default org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    # The go-live moment. `nil` means "manual trigger only" — the issue's
    # "target datetime *or* manual trigger". A time already in the past simply
    # fires at the next minute tick, exactly like a per-item `scheduled_at`.
    attribute :scheduled_at, :utc_datetime_usec, public?: true

    attribute :published_at, :utc_datetime_usec do
      writable? false
      public? true
    end

    attribute :rolled_back_at, :utc_datetime_usec do
      writable? false
      public? true
    end

    # Why the last go-live (or rollback) attempt aborted, and which item broke.
    # Kept on the release rather than only in the log: "it didn't ship, and here
    # is the item to fix" is the whole point of the `:failed` state.
    attribute :failure_reason, :string do
      writable? false
      public? true
    end

    attribute :failed_item_id, :uuid do
      writable? false
      public? true
    end

    attribute :creator_id, :uuid do
      writable? false
      public? false
    end

    # The admin who last claimed the release (scheduled it, or hit "Publish
    # now"). The worker publishes as this user so version history and the audit
    # chain name a person — see the moduledoc.
    attribute :triggered_by_id, :uuid do
      writable? false
      public? false
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :creator, KilnCMS.Accounts.User do
      source_attribute :creator_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :triggered_by, KilnCMS.Accounts.User do
      source_attribute :triggered_by_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    has_many :items, KilnCMS.CMS.ReleaseItem do
      destination_attribute :release_id
      sort inserted_at: :asc
      public? true
    end
  end
end
