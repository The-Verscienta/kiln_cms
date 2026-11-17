defmodule KilnCMS.Staging.Scrub do
  @moduledoc """
  Turns a production **clone** into a safe-to-share staging environment by
  removing personal data and outbound secrets. The one place that decides "this
  copy is safe to run somewhere less locked-down than production."

  It reuses the existing privacy work rather than re-deciding what counts as
  personal data: user accounts go through the GDPR-erasure `:anonymize` action
  (`docs/data-flows.md`), and the rest are whole-table purges / de-activations
  of the same data the retention jobs already treat as sensitive.

  Everything here is a purge or a de-activation — it never sends mail, fires a
  webhook, or contacts a subprocessor. See `KilnCMS.Staging.scrub!/1` for the
  guarded, operator-facing entry point and `docs/staging-environments.md` for
  the full flow.

  ## Which tables it handles

  `dispositions/0` names every table the scrub touches and what it does to
  it, derived from the same lists `run/1` works through. A test classifies
  every table in the schema against it (or against a reasoned keep-list), so a
  new table holding personal data cannot slip past the scrub unnoticed.

  ## Queued jobs

  `oban_jobs` is purged in every state, first and last. A cloned job is
  production's work: its args carry recipients, message bodies, form data and
  outbound URLs, and running it on the clone would mail, notify or call out on
  production's behalf. Cancelling is not enough (a cancelled row keeps its
  args), and the last pass catches whatever the scrub itself enqueued. The
  purge only helps if nothing executes jobs before it runs, which is why
  `mix kiln.staging.scrub` boots Oban inert and `KilnCMS.Staging.scrub!/1`
  refuses a node whose queues are live.

  > This is destructive by design. It must only run against a throwaway clone,
  > never production — the guards live in `KilnCMS.Staging.scrub!/1`.
  """
  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo

  @typedoc "What the scrub does to a table (see `dispositions/0`)."
  @type disposition ::
          :purged | :anonymized | :via_anonymization | :scrubbed | :deactivated | :paused

  @type summary :: %{
          users_anonymized: non_neg_integer(),
          api_keys_purged: non_neg_integer(),
          tokens_purged: non_neg_integer(),
          webhooks_deactivated: non_neg_integer(),
          mail_settings_purged: non_neg_integer(),
          search_queries_purged: non_neg_integer(),
          missed_paths_purged: non_neg_integer(),
          billing_settings_purged: non_neg_integer(),
          billing_events_purged: non_neg_integer(),
          backup_runs_purged: non_neg_integer(),
          backup_schedules_disabled: non_neg_integer(),
          backup_destinations_purged: non_neg_integer(),
          security_events_purged: non_neg_integer(),
          instance_security_events_purged: non_neg_integer(),
          security_alert_dispatches_purged: non_neg_integer(),
          invitations_purged: non_neg_integer(),
          memberships_scrubbed: non_neg_integer(),
          tiers_deactivated: non_neg_integer(),
          newsletter_segment_memberships_purged: non_neg_integer(),
          newsletter_subscribers_purged: non_neg_integer(),
          form_submissions_purged: non_neg_integer(),
          form_notify_emails_cleared: non_neg_integer(),
          suppressed_recipients_purged: non_neg_integer(),
          site_suppressed_recipients_purged: non_neg_integer(),
          federation_deliveries_purged: non_neg_integer(),
          federation_followers_purged: non_neg_integer(),
          federation_sites_purged: non_neg_integer(),
          push_subscriptions_purged: non_neg_integer(),
          vapid_keys_purged: non_neg_integer(),
          social_accounts_deactivated: non_neg_integer(),
          automation_rules_disabled: non_neg_integer(),
          webhook_deliveries_purged: non_neg_integer(),
          mail_relays_purged: non_neg_integer(),
          sso_providers_purged: non_neg_integer(),
          ai_providers_purged: non_neg_integer(),
          meilisearch_sites_purged: non_neg_integer(),
          throttle_counters_purged: non_neg_integer(),
          idempotent_requests_purged: non_neg_integer(),
          backup_locks_purged: non_neg_integer(),
          backup_node_beats_purged: non_neg_integer(),
          oban_jobs_purged: non_neg_integer(),
          admin_provisioned: String.t() | nil
        }

  # Payment credentials go FIRST, before anything else touches billing rows.
  # Nothing in this module contacts the provider today — GDPR erasure cancels
  # memberships locally only — but a clone that holds live API keys is one
  # careless change away from acting on a real payment account, so the keys are
  # removed before the rest of the scrub runs.
  @credentials_first {:billing_settings_purged, KilnCMS.Billing.Settings}

  # Whole-table purges, in the order they run: a child before its parent, so
  # each count is the rows of that table rather than whatever a cascade took.
  #
  # They run at the repo level on purpose: they are system-level scrubs that
  # bypass policies (there is no acting user), and doing them as data-only
  # writes avoids per-row side effects. An Ash destroy would send a federation
  # `Undo`, record an audit or org-settings security event, or re-run a
  # webhook's SSRF/DNS validation; a scrub wants none of those.
  @purges [
    {:api_keys_purged, KilnCMS.Accounts.ApiKey},
    {:tokens_purged, KilnCMS.Accounts.Token},
    {:mail_settings_purged, KilnCMS.Mail.Settings},
    {:search_queries_purged, KilnCMS.Analytics.SearchQuery},
    # Recorded 404 paths (#472) are traffic data about the *production* site —
    # a staging clone has no business carrying them, and a path can be
    # incidentally identifying.
    {:missed_paths_purged, KilnCMS.CMS.MissedPath},
    # Recorded provider webhooks carry the full event payload — customer emails
    # and amounts — so they are personal data, not just diagnostics.
    {:billing_events_purged, KilnCMS.Billing.WebhookEvent},
    # Backup history (#2217) records where this instance's backups go
    # (rclone destinations, operator triggers, errors): a prod clone must not
    # carry it, and the staging host's own backups start a history of their own.
    {:backup_runs_purged, KilnCMS.Backups.Run},
    # Backup destinations (#2220) are deleted, not paused: their credentials
    # are production's (a clone would hold, and could test, the keys to
    # production's off-site copies), and their places are production's, where
    # a staging backup must never land or prune.
    {:backup_destinations_purged, KilnCMS.Backups.DestinationConfig},
    # The backup lock and node heartbeats (#2218) name production's nodes and
    # the step jobs this scrub deletes. An empty lock table is a free lock.
    {:backup_locks_purged, KilnCMS.Backups.Lock},
    {:backup_node_beats_purged, KilnCMS.Backups.NodeBeat},
    # The security audit log (#2241) holds raw IPs, user agents and email
    # snapshots of the production sign-ins: personal data a clone must not carry.
    {:security_events_purged, KilnCMS.Security.Event},
    # And the instance log's (#2541): platform admins' addresses and IPs.
    {:instance_security_events_purged, KilnCMS.Security.InstanceEvent},
    # Pending security alerts (#2245) would mail and notify the production
    # admins' accounts from the clone, about production events.
    {:security_alert_dispatches_purged, KilnCMS.Security.AlertDispatch},
    # Pending site invitations (#2135) name production addresses, and each one's
    # link would set up an account on the clone for whoever holds the mail.
    {:invitations_purged, KilnCMS.Accounts.Invitation},
    # Newsletter subscribers (#2721) are readers' addresses and names, with
    # live confirm and unsubscribe tokens. Their segment memberships go first.
    {:newsletter_segment_memberships_purged, KilnCMS.Newsletter.SegmentMembership},
    {:newsletter_subscribers_purged, KilnCMS.Newsletter.Subscriber},
    # Form submissions are free-form visitor input: whatever a contact form
    # asked for, names and addresses included.
    {:form_submissions_purged, KilnCMS.CMS.FormSubmission},
    # Both suppression lists are recipients' addresses, nothing else.
    {:suppressed_recipients_purged, KilnCMS.Mail.SuppressedRecipient},
    {:site_suppressed_recipients_purged, KilnCMS.Mail.SiteSuppressedRecipient},
    # Federation: pending deliveries would post production's activities to
    # real inboxes, followers are remote people's actor and inbox URIs, and a
    # site's federation row holds the private key that signs as production's
    # actor.
    {:federation_deliveries_purged, KilnCMS.Federation.Delivery},
    {:federation_followers_purged, KilnCMS.Federation.Follower},
    {:federation_sites_purged, KilnCMS.Federation.SiteFederation},
    # Web Push: anonymization already deletes each account's subscriptions
    # (#2514); this is the backstop for any row it did not reach. The VAPID
    # keys are production's push identity.
    {:push_subscriptions_purged, KilnCMS.Accounts.PushSubscription},
    {:vapid_keys_purged, KilnCMS.CMS.SiteVapidKey},
    # The webhook delivery log keeps each payload, and a `form.submitted`
    # payload is the submission itself.
    {:webhook_deliveries_purged, KilnCMS.CMS.WebhookDelivery},
    # Per-site integrations hold production's secrets and point outward at
    # production's mail relay, identity provider, AI account and search index.
    # Deleting a row falls back to the staging host's own configuration, the
    # same way the mail settings purge above does.
    {:mail_relays_purged, KilnCMS.CMS.SiteMailRelay},
    {:sso_providers_purged, KilnCMS.CMS.SiteSsoProvider},
    {:ai_providers_purged, KilnCMS.CMS.SiteAiProvider},
    {:meilisearch_sites_purged, KilnCMS.CMS.SiteMeilisearch},
    # Rate-limit counters and cached idempotent responses: keyed on hashed
    # client identifiers, and the cached bodies are production's responses.
    {:throttle_counters_purged, KilnCMS.Accounts.ThrottleCounter},
    {:idempotent_requests_purged, KilnCMS.Accounts.IdempotentRequest}
  ]

  # In-place rewrites: rows the clone keeps, with what reaches outward or names
  # a person switched off or cleared. Each key has a `rewrite/1` clause below.
  @rewrites [
    {:webhooks_deactivated, :deactivated, KilnCMS.CMS.WebhookEndpoint},
    {:backup_schedules_disabled, :paused, KilnCMS.Backups.Schedule},
    {:memberships_scrubbed, :scrubbed, KilnCMS.Billing.Membership},
    {:tiers_deactivated, :deactivated, KilnCMS.Billing.MembershipTier},
    {:form_notify_emails_cleared, :scrubbed, KilnCMS.CMS.Form},
    {:social_accounts_deactivated, :deactivated, KilnCMS.Social.Account},
    {:automation_rules_disabled, :deactivated, KilnCMS.Automation.Rule}
  ]

  # Tables the `:anonymize` action empties of the anonymized account's rows
  # (`KilnCMS.Accounts.Changes.AnonymizeUser`). Every account is anonymized,
  # so nothing personal survives in them.
  @via_anonymization [
    KilnCMS.Accounts.UserIdentity,
    KilnCMS.Accounts.Passkey,
    KilnCMS.Notifications.Notification
  ]

  @doc """
  Scrub the database the repo is currently connected to. Returns a summary map
  of what was removed.

  ## Options

    * `:admin_email` / `:admin_password` — provision one usable staging admin
      after anonymizing every real account. Both must be present or no admin is
      seeded (and you won't be able to sign in to staging).

  Callers are responsible for the safety guards; use `KilnCMS.Staging.scrub!/1`
  unless you have already confirmed the target.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    {credentials_key, credentials} = @credentials_first
    {credentials_purged, _} = Repo.delete_all(credentials)

    # Queued jobs go before anything else runs, so none of production's work
    # is left to pick up while the scrub is under way.
    jobs_purged_first = purge_oban_jobs()

    users_anonymized = anonymize_users()

    purged = Map.new(@purges, fn {key, resource} -> {key, delete_all(resource)} end)
    rewritten = Map.new(@rewrites, fn {key, _kind, _resource} -> {key, rewrite(key)} end)

    admin_provisioned = maybe_provision_admin(opts[:admin_email], opts[:admin_password])

    # And last, for any job the scrub itself set off: anonymization runs each
    # account's erasure changes, and a job one of them queues (none does
    # today) would carry that account as production had it.
    jobs_purged_last = purge_oban_jobs()

    purged
    |> Map.merge(rewritten)
    |> Map.merge(%{
      credentials_key => credentials_purged,
      oban_jobs_purged: jobs_purged_first + jobs_purged_last,
      users_anonymized: users_anonymized,
      admin_provisioned: admin_provisioned
    })
  end

  @doc """
  Every table the scrub handles, mapped to what it does there and the summary
  key that counts it.

  Derived from the lists `run/1` works through, so the two cannot disagree.
  `test/kiln_cms/staging/scrub_coverage_test.exs` checks it against every table
  in the schema.
  """
  @spec dispositions() :: %{String.t() => {disposition(), atom()}}
  def dispositions do
    purges =
      Map.new([@credentials_first | @purges], fn {key, resource} ->
        {table(resource), {:purged, key}}
      end)

    rewrites =
      Map.new(@rewrites, fn {key, kind, resource} -> {table(resource), {kind, key}} end)

    anonymized =
      Map.new(@via_anonymization, &{table(&1), {:via_anonymization, :users_anonymized}})

    purges
    |> Map.merge(rewrites)
    |> Map.merge(anonymized)
    |> Map.put(table(User), {:anonymized, :users_anonymized})
    |> Map.put(Oban.Job.__schema__(:source), {:purged, :oban_jobs_purged})
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp delete_all(resource) do
    {count, _} = Repo.delete_all(resource)
    count
  end

  # Every state, not only the pending ones: a completed or cancelled job keeps
  # its args (recipients, bodies, form data) until the Pruner deletes the row a
  # week later. Repo-level, because the release path runs with no Oban at all.
  defp purge_oban_jobs do
    prefix = :kiln_cms |> Application.get_env(Oban, []) |> Keyword.get(:prefix, "public")
    {count, _} = Repo.delete_all(Oban.Job, prefix: prefix)
    count
  end

  defp rewrite(:webhooks_deactivated) do
    {count, _} =
      Repo.update_all(
        from(e in KilnCMS.CMS.WebhookEndpoint, where: e.active == true),
        set: [active: false, auto_disabled_at: DateTime.utc_now()]
      )

    count
  end

  # In-app backup schedules (part of #2219) are paused, not deleted: a clone
  # must not run production's schedule against the staging host's backup
  # directory, but whoever runs staging can see them and resume one.
  defp rewrite(:backup_schedules_disabled) do
    {count, _} =
      Repo.update_all(
        from(s in KilnCMS.Backups.Schedule, where: s.enabled == true),
        set: [enabled: false]
      )

    count
  end

  # Memberships are SCRUBBED, not deleted: `billing_membership_events`
  # references them, and the entitlement trail should stay referentially intact
  # (the same audit-retention decision #219 made for content history). What
  # must go is the live external reference — a clone holding real provider
  # subscription ids is exactly what this module exists to prevent. Belt to the
  # per-user cascade in `AnonymizeUser`, which has already run; this catches
  # any row whose owner was already a tombstone.
  defp rewrite(:memberships_scrubbed) do
    {count, _} =
      Repo.update_all(
        from(m in KilnCMS.Billing.Membership,
          where: not is_nil(m.provider_customer_id) or not is_nil(m.provider_subscription_id)
        ),
        set: [provider_customer_id: nil, provider_subscription_id: nil, status: :canceled]
      )

    count
  end

  # Tiers are DEACTIVATED rather than deleted (the `WebhookEndpoint` posture):
  # the catalogue shape keeps staging useful, while the price pointers that
  # could bill a real account are severed.
  #
  # The pointer is replaced with a per-row tombstone rather than nulled:
  # `provider_price_id` is NOT NULL and carries a unique index per org, so nil
  # violates the constraint and a shared placeholder collides between tiers.
  defp rewrite(:tiers_deactivated) do
    {count, _} =
      Repo.update_all(
        from(t in KilnCMS.Billing.MembershipTier,
          where: t.active == true,
          update: [set: [active: false, provider_price_id: fragment("'scrubbed_' || ?", t.id)]]
        ),
        []
      )

    count
  end

  # Forms stay (they are site content), but the address each submission is
  # mailed to is a production person's inbox.
  defp rewrite(:form_notify_emails_cleared) do
    {count, _} =
      Repo.update_all(
        from(f in KilnCMS.CMS.Form, where: not is_nil(f.notify_email)),
        set: [notify_email: nil]
      )

    count
  end

  # Social accounts are switched off and lose their credential rather than
  # being deleted: a delete cascades to the post history, which is content.
  defp rewrite(:social_accounts_deactivated) do
    {count, _} =
      Repo.update_all(
        from(a in KilnCMS.Social.Account,
          where: a.enabled == true or not is_nil(a.credential_encrypted)
        ),
        set: [enabled: false, credential_encrypted: nil]
      )

    count
  end

  # Automation rules are disabled, and a `send_email` rule loses its `"to"`:
  # the rule is useful to see on staging, its recipient is a production inbox.
  defp rewrite(:automation_rules_disabled) do
    {count, _} =
      Repo.update_all(
        from(r in KilnCMS.Automation.Rule,
          where:
            r.enabled == true or
              fragment("(? = 'send_email' AND jsonb_exists(?, 'to'))", r.action, r.config),
          update: [
            set: [
              enabled: false,
              config:
                fragment(
                  "CASE WHEN ? = 'send_email' THEN ? - 'to' ELSE ? END",
                  r.action,
                  r.config,
                  r.config
                )
            ]
          ]
        ),
        []
      )

    count
  end

  # Anonymize every account that isn't already scrubbed, via the real GDPR
  # erasure action (scrambles credentials, revokes tokens, nulls audit actors —
  # `KilnCMS.Accounts.Changes.AnonymizeUser`). Runs as a system job (no actor),
  # so it bypasses the admin-only policy that guards the action at runtime.
  defp anonymize_users do
    # authorize?: false — operator scrub of a clone must see every account; no system User grant
    Accounts.list_users!(authorize?: false)
    |> Enum.reject(& &1.anonymized_at)
    # The one caller `NotLastAdmin` is written to exempt: a scrubbed clone must
    # hold no real operator's credentials, so erasing the last admin is the point.
    |> Enum.map(
      # authorize?: false — erasure is admin-only; a system grant would be a standing right to erase
      &Accounts.anonymize_user!(&1,
        authorize?: false,
        context: KilnCMS.Accounts.Validations.NotLastAdmin.exempt()
      )
    )
    |> length()
  end

  # Seed one pre-confirmed admin so the scrubbed environment is usable. Safe to
  # do as a plain `Ash.Seed` (mirroring priv/repo/seeds.exs): it runs *after*
  # anonymization, so every real email is already a tombstone and this address
  # is guaranteed free.
  defp maybe_provision_admin(email, password)
       when is_binary(email) and is_binary(password) and email != "" and password != "" do
    Ash.Seed.seed!(User, %{
      email: email,
      name: "Staging Admin",
      hashed_password: Bcrypt.hash_pwd_salt(password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    email
  end

  defp maybe_provision_admin(_email, _password), do: nil
end
