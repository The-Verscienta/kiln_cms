defmodule KilnCMS.Security.AlertDispatch do
  @moduledoc """
  One security alert to deliver (#2245): a kind, on a channel, for one alert
  window — or one `alerts_silenced` notice, a site's or the platform's.

  A row is the debounce. `KilnCMS.Security.AlertGate` claims it with one raw
  `INSERT ... ON CONFLICT DO NOTHING` on `(scope, kind, window_index)`, in the
  transaction of the audit event that raised it, so the first event of a kind
  in a window claims the row and every later one finds it taken. The AshOban
  triggers below then deliver it: the alert once (`:deliver_alert`), and after
  the window closes a summary of how many followed (`:deliver_summary`).

  ## Shape

    * `scope` — whose alert: the org id (a site alert), `"platform"`,
      `"backup_destination:<uuid>"` (a `backup_host_key_changed` alert: a
      platform alert debounced per destination, #3201), `"notice:<uuid>"`
      (a notice: never debounced, its own scope each), or
      `"platform_notice:<uuid>"` (a platform notice, #2811, the same).
    * `kind` — the alert kind (`KilnCMS.Security.Alerts`), or
      `"alerts_silenced"` for a notice. A string, so a kind a newer release
      wrote still loads.
    * `channel` — `:site`, `:platform`, `:notice` or `:platform_notice`.
      A `KilnCMS.Types.KnownAtom` (#3496): a channel a later release adds
      loads as a `KilnCMS.Types.UnknownAtom` here rather than failing the
      read, and both triggers name the channels they deliver, so a row with
      one this release does not know is never scheduled. v1.13.0, the release
      before #2811, has plain `:atom` and no such list: it schedules a
      `:platform_notice` row it cannot load, and every attempt fails
      (`docs/security-alerts.md`, "For operators").
    * `org_id` — the site the alert is about; the default org for a platform
      alert or a platform notice. No foreign key: the row lives a day.
    * `window_index`, `window_started_at`, `window_ends_at` — the alert window
      (database clock, `KilnCMS.Security.Alerts.window_ms/0`); `0` for a notice.
    * `first_event_id` — the audit event that claimed the row (no foreign key:
      retention may prune it first; a delivery that cannot find it says less).
    * `threshold_count` — for `failed_sign_ins`, the count that crossed the
      threshold; the summary reports only when the window ended above it.
    * `notice` — a notice's `change`, `kinds`, `endpoint_id` and `actor_id`;
      for a `backup_host_key_changed` alert, whose event is in the instance
      log its delivery doesn't read, the `destination` name (#2222). Never an
      address, URL, token or email.
    * `alert_sent_at`, `summary_sent_at`, `failed_at` — delivery stamps. A
      platform notice is written with `summary_sent_at` set: it has no
      summary, and v1.13.0's summary trigger would otherwise pick it up
      once delivered (#3496, `KilnCMS.Security.AlertGate`).
    * `expires_at` — a day after the window ends; `:prune` deletes past it.

  ## Authorization

  System-only. No person, admin included, reads or writes a row, and there is
  no create action at all: the gate inserts in raw SQL. The triggers run under
  `AshOban.Checks.AshObanInteraction`; `:prune` also admits the `:operator`
  system actor, so it can be run by hand.
  """
  use Ash.Resource,
    domain: KilnCMS.Security,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  postgres do
    table "security_alert_dispatches"
    repo KilnCMS.Repo

    custom_indexes do
      # The prune's scan.
      index [:expires_at]
    end
  end

  oban do
    triggers do
      # The alert itself, within a minute of the claim: the claim commits with
      # the event, and nothing is enqueued inside the emitter's transaction.
      # Only the channels this release delivers (#3496): a row a later
      # release wrote with a new one is left for a node that knows it, never
      # scheduled here to fail ten times. A channel added to `one_of` must be
      # added here too (`AlertDispatchUnknownChannelTest` checks).
      trigger :deliver_alert do
        action :deliver_alert
        queue :default
        scheduler_cron "* * * * *"
        max_attempts 10
        on_error :mark_failed

        where expr(
                channel in [:site, :platform, :notice, :platform_notice] and
                  is_nil(alert_sent_at) and is_nil(failed_at) and inserted_at > ago(1, :day)
              )

        worker_module_name KilnCMS.Security.AlertDispatch.AshOban.Worker.DeliverAlert
        scheduler_module_name KilnCMS.Security.AlertDispatch.AshOban.Scheduler.DeliverAlert
      end

      # The window's summary, once it has closed. Notices, a site's or the
      # platform's, have none. The channels that have one are named rather
      # than the ones that don't, so a channel a later release adds is never
      # summarized here (#3496).
      trigger :deliver_summary do
        action :deliver_summary
        queue :default
        scheduler_cron "* * * * *"
        max_attempts 10
        on_error :mark_failed

        where expr(
                channel in [:site, :platform] and not is_nil(alert_sent_at) and
                  is_nil(summary_sent_at) and
                  is_nil(failed_at) and window_ends_at < ago(1, :minute) and
                  window_ends_at > ago(1, :day)
              )

        worker_module_name KilnCMS.Security.AlertDispatch.AshOban.Worker.DeliverSummary
        scheduler_module_name KilnCMS.Security.AlertDispatch.AshOban.Scheduler.DeliverSummary
      end
    end

    scheduled_actions do
      schedule :prune, "17 * * * *" do
        action :prune
        queue :default
        worker_module_name KilnCMS.Security.AlertDispatch.Workers.Prune
      end
    end
  end

  actions do
    defaults [:read]

    # Delivery of the alert: bell, email and webhooks, then `alert_sent_at`.
    update :deliver_alert do
      accept []
      require_atomic? false
      change get_and_lock_for_update()
      change {KilnCMS.Security.Changes.DeliverAlert, phase: :alert}
    end

    # Delivery of the closed window's summary, then `summary_sent_at`.
    update :deliver_summary do
      accept []
      require_atomic? false
      change get_and_lock_for_update()
      change {KilnCMS.Security.Changes.DeliverAlert, phase: :summary}
    end

    # A delivery that exhausted its attempts: stamped, so the trigger stops
    # picking the row up rather than retrying a poison row all day, and
    # reported (log and `alert_failed` telemetry, #2642). Not atomic: the
    # report runs after the stamp commits.
    update :mark_failed do
      accept []
      require_atomic? false
      change set_attribute(:failed_at, &DateTime.utc_now/0)
      change KilnCMS.Security.Changes.ReportAlertFailed
    end

    # Deletes every row past `expires_at`. Returns how many went.
    action :prune, :integer do
      run fn _input, _context -> {:ok, KilnCMS.Security.AlertGate.prune()} end
    end
  end

  policies do
    # The triggers and the scheduled prune.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action(:prune) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :operator}
    end

    # Nobody reads a row: delivery is the triggers' alone.
    policy action_type(:read) do
      forbid_if always()
    end

    policy action([:deliver_alert, :deliver_summary, :mark_failed]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scope, :string do
      allow_nil? false
      public? false
      constraints max_length: 64
    end

    attribute :kind, :string do
      allow_nil? false
      public? false
      constraints max_length: 64
    end

    attribute :channel, KilnCMS.Types.KnownAtom do
      allow_nil? false
      public? false
      constraints one_of: [:site, :platform, :notice, :platform_notice]
    end

    attribute :org_id, :uuid, allow_nil?: false, public?: false

    attribute :window_index, :integer, allow_nil?: false, public?: false
    attribute :window_started_at, :utc_datetime_usec, allow_nil?: false, public?: false
    attribute :window_ends_at, :utc_datetime_usec, allow_nil?: false, public?: false

    attribute :first_event_id, :uuid, public?: false
    attribute :threshold_count, :integer, public?: false

    attribute :notice, :map, allow_nil?: false, default: %{}, public?: false

    attribute :alert_sent_at, :utc_datetime_usec, public?: false
    attribute :summary_sent_at, :utc_datetime_usec, public?: false
    attribute :failed_at, :utc_datetime_usec, public?: false

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: false

    create_timestamp :inserted_at, type: :utc_datetime_usec
  end

  identities do
    identity :one_per_window, [:scope, :kind, :window_index]
  end
end
