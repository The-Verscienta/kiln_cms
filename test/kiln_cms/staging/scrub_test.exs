defmodule KilnCMS.Staging.ScrubTest do
  @moduledoc """
  The staging scrub turns a production clone into a PII-free, secret-free
  environment, reusing the GDPR-erasure `:anonymize` action. See
  `docs/staging-environments.md`.
  """
  use KilnCMS.DataCase, async: true

  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Staging
  alias KilnCMS.Staging.Scrub

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "admin-#{uniq()}@example.com",
      name: "Real Admin",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp seed_token(user) do
    Ash.Seed.seed!(Accounts.Token, %{
      jti: "jti-#{uniq()}",
      subject: AshAuthentication.user_to_subject(user),
      purpose: "user",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
  end

  defp seed_search_query do
    Ash.Seed.seed!(KilnCMS.Analytics.SearchQuery, %{
      query: "confidential person name #{uniq()}",
      locale: "en",
      count: 1,
      last_searched_at: DateTime.utc_now()
    })
  end

  defp org_id, do: Accounts.default_org_id()

  defp count(resource), do: Repo.aggregate(resource, :count)

  # Rows the way a production clone holds them. Seeded rather than created
  # through their actions: the actions mail, federate, or validate outward
  # (DNS, SSRF), and the scrub only ever sees the rows.
  defp seed!(resource, attrs), do: Ash.Seed.seed!(resource, attrs)

  defp seed_job!(state) do
    %{"to" => "reader-#{uniq()}@example.com"}
    |> Oban.Job.new(worker: "KilnCMS.Mail.DeliveryWorker", queue: :mail)
    |> Ecto.Changeset.put_change(:state, state)
    |> Repo.insert!()
  end

  describe "Scrub.run/1" do
    test "anonymizes accounts, keeping the row but scrubbing the PII" do
      user = admin()

      Scrub.run([])

      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert reloaded.id == user.id
      assert reloaded.email |> to_string() == "anonymized-#{user.id}@deleted.invalid"
      assert reloaded.name == nil
      assert reloaded.role == :viewer
      assert reloaded.anonymized_at != nil
    end

    test "purges API keys, auth tokens, and recorded search queries" do
      user = admin()
      expires_at = DateTime.add(DateTime.utc_now(), 86_400, :second)
      {:ok, _key} = Accounts.mint_api_key(user.id, "ci", expires_at, authorize?: false)
      seed_token(user)
      seed_search_query()

      summary = Scrub.run([])

      assert summary.api_keys_purged >= 1
      assert summary.tokens_purged >= 1
      assert summary.search_queries_purged >= 1
      assert Repo.aggregate(Accounts.ApiKey, :count) == 0
      assert Repo.aggregate(Accounts.Token, :count) == 0
      assert Repo.aggregate(KilnCMS.Analytics.SearchQuery, :count) == 0
    end

    test "de-activates webhook endpoints so a clone never fires at prod consumers" do
      admin = admin()

      endpoint =
        CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

      assert endpoint.active

      summary = Scrub.run([])

      assert summary.webhooks_deactivated >= 1
      reloaded = CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)
      refute reloaded.active
    end

    test "purges the mail settings row (with its encrypted DKIM private key)" do
      _settings = KilnCMS.Mail.ensure_settings!()
      assert Repo.aggregate(KilnCMS.Mail.Settings, :count) >= 1

      summary = Scrub.run([])

      assert summary.mail_settings_purged >= 1
      assert Repo.aggregate(KilnCMS.Mail.Settings, :count) == 0
    end

    test "purges the backup history (a clone must not carry destinations)" do
      KilnCMS.Backups.start_run!(
        %{stamp: "20260102-030000", trigger: "cron"},
        actor: KilnCMS.Backups.system()
      )

      assert Repo.aggregate(KilnCMS.Backups.Run, :count) >= 1

      summary = Scrub.run([])

      assert summary.backup_runs_purged >= 1
      assert Repo.aggregate(KilnCMS.Backups.Run, :count) == 0
    end

    # Part of #2219: a clone must not run production's backup schedule.
    test "disables every backup schedule and reports backup_schedules_disabled" do
      a = KilnCMS.Test.BackupSchedules.schedule!()
      b = KilnCMS.Test.BackupSchedules.schedule!(%{interval: :weekly})

      summary = Scrub.run([])

      assert summary.backup_schedules_disabled == 2

      for s <- [a, b] do
        assert %{enabled: false} =
                 KilnCMS.Backups.get_backup_schedule!(s.id, actor: KilnCMS.Backups.system())
      end
    end

    # #2220: a clone must not hold production's destination credentials, nor
    # back up to (and prune) production's off-site places.
    test "deletes every backup destination and reports backup_destinations_purged" do
      admin = KilnCMS.Test.BackupSchedules.platform_admin()
      KilnCMS.Test.BackupDestinations.destination!(%{}, admin)
      KilnCMS.Test.BackupDestinations.destination!(%{enabled: false}, admin)

      summary = Scrub.run([])

      assert summary.backup_destinations_purged == 2
      assert Repo.aggregate(KilnCMS.Backups.DestinationConfig, :count) == 0
    end

    test "purges the security audit log (raw IPs and email snapshots)" do
      KilnCMS.Security.record!(%{type: :sign_in, ip: "203.0.113.5"},
        actor: KilnCMS.Security.system(),
        tenant: KilnCMS.Accounts.default_org_id()
      )

      assert Repo.aggregate(KilnCMS.Security.Event, :count) >= 1

      summary = Scrub.run([])

      assert summary.security_events_purged >= 1
      assert Repo.aggregate(KilnCMS.Security.Event, :count) == 0
    end

    test "purges the instance security log (platform admins' addresses and IPs)" do
      KilnCMS.Security.record_instance_event!(%{type: :backup_canceled},
        actor: KilnCMS.Security.system()
      )

      assert Repo.aggregate(KilnCMS.Security.InstanceEvent, :count) >= 1

      summary = Scrub.run([])

      assert summary.instance_security_events_purged >= 1
      assert Repo.aggregate(KilnCMS.Security.InstanceEvent, :count) == 0
    end

    test "purges recorded 404 paths (production traffic data)" do
      # authorize?: false: the 404 recorder runs with no actor, as a request does.
      CMS.record_missed_path!(%{path: "/scrub-missed", locale: "en"},
        authorize?: false,
        tenant: KilnCMS.Accounts.default_org_id()
      )

      assert Repo.aggregate(KilnCMS.CMS.MissedPath, :count) >= 1

      summary = Scrub.run([])

      assert summary.missed_paths_purged >= 1
      assert Repo.aggregate(KilnCMS.CMS.MissedPath, :count) == 0
    end

    test "purges pending security alerts (they would notify production admins)" do
      KilnCMS.Repo.transaction(fn ->
        KilnCMS.Security.AlertGate.insert_notice!(KilnCMS.Accounts.default_org_id(), %{
          change: "kind_disabled"
        })
      end)

      assert Repo.aggregate(KilnCMS.Security.AlertDispatch, :count) >= 1

      summary = Scrub.run([])

      assert summary.security_alert_dispatches_purged >= 1
      assert Repo.aggregate(KilnCMS.Security.AlertDispatch, :count) == 0
    end

    test "purges pending site invitations (production addresses, live links)" do
      KilnCMS.Accounts.invite_to_org!(
        %{
          organization_id: KilnCMS.Accounts.default_org_id(),
          email: "scrub-invitee-#{System.unique_integer([:positive])}@example.com"
        },
        actor: admin()
      )

      assert Repo.aggregate(KilnCMS.Accounts.Invitation, :count) >= 1

      summary = Scrub.run([])

      assert summary.invitations_purged >= 1
      assert Repo.aggregate(KilnCMS.Accounts.Invitation, :count) == 0
    end

    test "purges newsletter subscribers and their segment memberships" do
      subscriber =
        seed!(KilnCMS.Newsletter.Subscriber, %{
          org_id: org_id(),
          email: "reader-#{uniq()}@example.com",
          name: "A Reader",
          confirm_token: "confirm-#{uniq()}",
          unsubscribe_token: "unsub-#{uniq()}"
        })

      segment =
        seed!(KilnCMS.Newsletter.Segment, %{
          org_id: org_id(),
          name: "Weekly",
          slug: "weekly-#{uniq()}"
        })

      seed!(KilnCMS.Newsletter.SegmentMembership, %{
        org_id: org_id(),
        segment_id: segment.id,
        subscriber_id: subscriber.id
      })

      summary = Scrub.run([])

      assert summary.newsletter_segment_memberships_purged == 1
      assert summary.newsletter_subscribers_purged == 1
      assert count(KilnCMS.Newsletter.Subscriber) == 0
      assert count(KilnCMS.Newsletter.SegmentMembership) == 0
      # The segment itself is site configuration and stays.
      assert count(KilnCMS.Newsletter.Segment) == 1
    end

    test "purges form submissions and clears each form's notify_email, keeping the form" do
      form = KilnCMS.FormFixtures.form!(%{notify_email: "inbox@example.com"})
      quiet = KilnCMS.FormFixtures.form!()

      seed!(KilnCMS.CMS.FormSubmission, %{
        org_id: org_id(),
        form_id: form.id,
        data: %{"email" => "visitor@example.com", "message" => "call me"}
      })

      summary = Scrub.run([])

      assert summary.form_submissions_purged == 1
      assert summary.form_notify_emails_cleared == 1
      assert count(KilnCMS.CMS.FormSubmission) == 0

      assert %{notify_email: nil} = CMS.get_form!(form.id, authorize?: false)
      assert %{notify_email: nil} = CMS.get_form!(quiet.id, authorize?: false)
    end

    test "purges both suppression lists" do
      seed!(KilnCMS.Mail.SuppressedRecipient, %{email: "bounced-#{uniq()}@example.com"})

      seed!(KilnCMS.Mail.SiteSuppressedRecipient, %{
        org_id: org_id(),
        email: "site-bounced-#{uniq()}@example.com"
      })

      summary = Scrub.run([])

      assert summary.suppressed_recipients_purged == 1
      assert summary.site_suppressed_recipients_purged == 1
      assert count(KilnCMS.Mail.SuppressedRecipient) == 0
      assert count(KilnCMS.Mail.SiteSuppressedRecipient) == 0
    end

    test "purges federation followers, pending deliveries and the site's actor key" do
      KilnCMS.FederationFixtures.enable_site!(org_id())

      follower =
        seed!(KilnCMS.Federation.Follower, %{
          org_id: org_id(),
          actor_uri: "https://remote.example/users/someone",
          inbox_uri: "https://remote.example/users/someone/inbox"
        })

      seed!(KilnCMS.Federation.Delivery, %{
        org_id: org_id(),
        follower_id: follower.id,
        inbox_uri: follower.inbox_uri,
        activity_type: :create,
        activity: %{"type" => "Create"}
      })

      summary = Scrub.run([])

      assert summary.federation_deliveries_purged == 1
      assert summary.federation_followers_purged == 1
      assert summary.federation_sites_purged == 1
      assert count(KilnCMS.Federation.Delivery) == 0
      assert count(KilnCMS.Federation.Follower) == 0
      assert count(KilnCMS.Federation.SiteFederation) == 0
    end

    test "purges push subscriptions and the site's VAPID keys" do
      user = admin()

      # The account is anonymized first, which removes its subscriptions, so
      # this one is the backstop's: owned by an account already a tombstone.
      Accounts.anonymize_user!(user,
        authorize?: false,
        context: KilnCMS.Accounts.Validations.NotLastAdmin.exempt()
      )

      seed!(KilnCMS.Accounts.PushSubscription, %{
        org_id: org_id(),
        user_id: user.id,
        endpoint: "https://push.example/#{uniq()}",
        p256dh: "p256dh",
        auth: "auth"
      })

      seed!(KilnCMS.CMS.SiteVapidKey, %{org_id: org_id(), public_key: "public"})

      summary = Scrub.run([])

      assert summary.push_subscriptions_purged == 1
      assert summary.vapid_keys_purged == 1
      assert count(KilnCMS.Accounts.PushSubscription) == 0
      assert count(KilnCMS.CMS.SiteVapidKey) == 0
    end

    test "deactivates social accounts and drops their credentials, keeping the post history" do
      account =
        seed!(KilnCMS.Social.Account, %{
          org_id: org_id(),
          provider: :mastodon,
          credential_encrypted: "ciphertext",
          enabled: true
        })

      seed!(KilnCMS.Social.Post, %{
        org_id: org_id(),
        account_id: account.id,
        provider: :mastodon,
        content_type: "post",
        content_id: Ecto.UUID.generate(),
        content_published_at: DateTime.utc_now()
      })

      summary = Scrub.run([])

      assert summary.social_accounts_deactivated == 1

      assert [%{enabled: false, credential_encrypted: nil}] =
               Repo.all(KilnCMS.Social.Account)

      assert count(KilnCMS.Social.Post) == 1
    end

    test "disables automation rules and drops a send_email rule's recipient" do
      mail =
        seed!(KilnCMS.Automation.Rule, %{
          org_id: org_id(),
          name: "Tell the editor",
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "editor@example.com", "subject" => "Published"}
        })

      other =
        seed!(KilnCMS.Automation.Rule, %{
          org_id: org_id(),
          name: "Reindex",
          trigger_event: :published,
          action: :reindex,
          config: %{"to" => "not-a-recipient"}
        })

      summary = Scrub.run([])

      assert summary.automation_rules_disabled == 2

      assert %{enabled: false, config: %{"subject" => "Published"} = config} =
               Repo.get!(KilnCMS.Automation.Rule, mail.id)

      refute Map.has_key?(config, "to")

      # Only a send_email rule's "to" is a recipient; another action's config
      # is left as it was.
      assert %{enabled: false, config: %{"to" => "not-a-recipient"}} =
               Repo.get!(KilnCMS.Automation.Rule, other.id)
    end

    test "purges the webhook delivery log (payloads carry form submissions)" do
      seed!(KilnCMS.CMS.WebhookDelivery, %{
        org_id: org_id(),
        event: "form.submitted",
        payload: %{"data" => %{"email" => "visitor@example.com"}}
      })

      summary = Scrub.run([])

      assert summary.webhook_deliveries_purged == 1
      assert count(KilnCMS.CMS.WebhookDelivery) == 0
    end

    test "purges per-site mail relay, SSO, AI and search integrations" do
      seed!(KilnCMS.CMS.SiteMailRelay, %{org_id: org_id(), host: "smtp.prod.example"})
      seed!(KilnCMS.CMS.SiteSsoProvider, %{org_id: org_id()})
      seed!(KilnCMS.CMS.SiteAiProvider, %{org_id: org_id()})
      seed!(KilnCMS.CMS.SiteMeilisearch, %{org_id: org_id(), url: "https://search.prod.example"})

      summary = Scrub.run([])

      assert summary.mail_relays_purged == 1
      assert summary.sso_providers_purged == 1
      assert summary.ai_providers_purged == 1
      assert summary.meilisearch_sites_purged == 1

      for resource <- [
            KilnCMS.CMS.SiteMailRelay,
            KilnCMS.CMS.SiteSsoProvider,
            KilnCMS.CMS.SiteAiProvider,
            KilnCMS.CMS.SiteMeilisearch
          ] do
        assert count(resource) == 0, inspect(resource)
      end
    end

    test "purges rate-limit counters and cached idempotent responses" do
      # Counters can be committed outside the sandbox by an earlier test's
      # throttle, so count what is there rather than assume an empty table.
      seed!(KilnCMS.Accounts.ThrottleCounter, %{
        bucket: "sign_in",
        key_hash: :crypto.hash(:sha256, "203.0.113.5"),
        window_index: 1,
        count: 3,
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

      seed!(KilnCMS.Accounts.IdempotentRequest, %{
        org_id: org_id(),
        scope: "api",
        key: "key-#{uniq()}",
        fingerprint: "fingerprint"
      })

      counters = count(KilnCMS.Accounts.ThrottleCounter)
      requests = count(KilnCMS.Accounts.IdempotentRequest)
      assert counters >= 1 and requests >= 1

      summary = Scrub.run([])

      assert summary.throttle_counters_purged == counters
      assert summary.idempotent_requests_purged == requests
      assert count(KilnCMS.Accounts.ThrottleCounter) == 0
      assert count(KilnCMS.Accounts.IdempotentRequest) == 0
    end

    test "purges the backup lock and production's node heartbeats" do
      seed!(KilnCMS.Backups.Lock, %{name: "backups"})

      seed!(KilnCMS.Backups.NodeBeat, %{
        node: "prod-node-#{uniq()}",
        boot_id: Ecto.UUID.generate(),
        beat_at: DateTime.utc_now()
      })

      summary = Scrub.run([])

      assert summary.backup_locks_purged == 1
      assert summary.backup_node_beats_purged == 1
      assert count(KilnCMS.Backups.Lock) == 0
      assert count(KilnCMS.Backups.NodeBeat) == 0
    end

    test "purges production's backup notices" do
      seed!(KilnCMS.Backups.Notice, %{
        kind: :retention,
        scope: "dest:#{Ecto.UUID.generate()}",
        label: "production bucket",
        outcome: :skipped,
        reason: "couldn't read the backup history",
        at: DateTime.utc_now()
      })

      summary = Scrub.run([])

      assert summary.backup_notices_purged == 1
      assert count(KilnCMS.Backups.Notice) == 0
    end

    test "purges queued jobs in every state (their args carry recipients)" do
      states = ~w(available scheduled executing retryable completed discarded cancelled)
      Enum.each(states, &seed_job!/1)

      summary = Scrub.run([])

      assert summary.oban_jobs_purged == length(states)
      assert count(Oban.Job) == 0
    end

    test "a mail queued on production is not delivered from the clone" do
      :ok =
        Swoosh.Email.new(
          to: "reader-#{uniq()}@example.com",
          from: {"KilnCMS", "cms@example.com"},
          subject: "Your receipt",
          text_body: "Thanks",
          html_body: "<p>Thanks</p>"
        )
        |> KilnCMS.Mail.enqueue!()

      assert count(Oban.Job) == 1

      Scrub.run([])
      drain_oban()

      assert_no_email_sent()
    end

    test "provisions one usable pre-confirmed admin when credentials are given" do
      _real = admin()

      summary =
        Scrub.run(admin_email: "staging@example.com", admin_password: "staging-pass-123456")

      assert summary.admin_provisioned == "staging@example.com"

      seeded = Accounts.get_user_by_email!("staging@example.com", authorize?: false)
      assert seeded.role == :admin
      assert seeded.confirmed_at != nil
      # Created after anonymization, so it is not itself scrubbed.
      assert seeded.anonymized_at == nil
    end

    test "provisions no admin without both credentials" do
      admin()
      summary = Scrub.run(admin_email: "staging@example.com")
      assert summary.admin_provisioned == nil
    end

    test "is idempotent — a second run finds nothing left to do" do
      admin()
      KilnCMS.FormFixtures.form!(%{notify_email: "inbox@example.com"})

      seed!(KilnCMS.Social.Account, %{
        org_id: org_id(),
        provider: :bluesky,
        credential_encrypted: "ciphertext"
      })

      seed!(KilnCMS.Automation.Rule, %{
        org_id: org_id(),
        name: "Tell the editor",
        trigger_event: :published,
        action: :send_email,
        config: %{"to" => "editor@example.com"}
      })

      first = Scrub.run([])
      assert first.users_anonymized >= 1
      assert first.form_notify_emails_cleared == 1
      assert first.social_accounts_deactivated == 1
      assert first.automation_rules_disabled == 1

      second = Scrub.run([])
      counts = Map.delete(second, :admin_provisioned)

      assert Enum.reject(counts, fn {_key, n} -> n == 0 end) == []
    end
  end

  describe "the scrub table in docs/staging-environments.md" do
    # The table drifted once (#2454): five purges were added to the scrub with
    # no row. Every row now names its summary key, so the keys a real run
    # returns are the list the table must cover.
    @guide "docs/staging-environments.md"

    # The core's keys: a plugin's tables (`{:plugin, name, table}`) are its
    # own to document, not rows of the core's table.
    test "names every key of the scrub's summary" do
      keys = Scrub.run([]) |> Map.keys() |> Enum.filter(&is_atom/1) |> Enum.sort()
      table = scrub_table!()

      missing = Enum.reject(keys, &String.contains?(table, "(`#{&1}`)"))

      assert missing == [], """
      The scrub table in #{@guide} ("## The scrub") has no row for:

        #{Enum.map_join(missing, "\n  ", &inspect/1)}

      Add a row for each that says what is purged or de-activated and why,
      with its summary key in the Action column, e.g. "purged (`#{List.first(missing)}`)".
      """
    end

    test "names no key the scrub no longer returns" do
      keys = Scrub.run([]) |> Map.keys() |> Enum.filter(&is_atom/1) |> Enum.map(&to_string/1)

      named =
        ~r/\(`([a-z_]+)`\)/
        |> Regex.scan(scrub_table!(), capture: :all_but_first)
        |> List.flatten()

      stale = Enum.uniq(named) -- keys

      assert stale == [], """
      The scrub table in #{@guide} ("## The scrub") names keys Scrub.run/1 no
      longer returns: #{inspect(stale)}. Remove or rename those rows.
      """
    end

    defp scrub_table! do
      [_, section] = @guide |> File.read!() |> String.split("\n## The scrub\n", parts: 2)
      [section | _] = String.split(section, "\n## ", parts: 2)

      section
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| "))
      |> Enum.join("\n")
    end
  end

  describe "scrub!/1 guards" do
    test "refuses without explicit confirmation" do
      assert_raise RuntimeError, ~r/without explicit confirmation/, fn ->
        Staging.scrub!(confirm?: false, shell: fn _ -> :ok end)
      end
    end

    test "refuses when the target database name doesn't look ephemeral" do
      # The test database is `kiln_cms_test*` — not an ephemeral-looking name.
      assert_raise RuntimeError, ~r/doesn't look ephemeral/, fn ->
        Staging.scrub!(confirm?: true, shell: fn _ -> :ok end)
      end
    end

    test "refuses a node whose Oban queues are live, and changes nothing" do
      user = admin()

      assert_raise RuntimeError, ~r/Oban queues are running/, fn ->
        Staging.scrub!(confirm?: true, force?: true, oban_live?: true, shell: fn _ -> :ok end)
      end

      assert %{anonymized_at: nil} = Accounts.get_user!(user.id, authorize?: false)
    end

    test "with allow_live?, pauses the queues, says to restart, and scrubs" do
      user = admin()
      test = self()

      summary =
        Staging.scrub!(
          confirm?: true,
          force?: true,
          oban_live?: true,
          allow_live?: true,
          shell: &send(test, {:shell, &1})
        )

      assert summary.users_anonymized >= 1
      assert %{anonymized_at: %DateTime{}} = Accounts.get_user!(user.id, authorize?: false)
      assert_received {:shell, "Oban is live on this node: every queue is now paused." <> rest}
      assert rest =~ "Restart the application"
    end

    test "the test build's Oban is not live (it executes no jobs)" do
      refute Staging.oban_live?()
      refute Staging.oban_live?(:"oban-#{uniq()}-not-started")
    end

    test "an inline Oban is live: it runs a job the moment one is inserted" do
      name = :"oban-#{uniq()}-inline"
      start_supervised!({Oban, name: name, repo: KilnCMS.Repo, testing: :inline})

      assert Staging.oban_live?(name)
    end

    test "reports every count in the summary" do
      test = self()
      summary = Staging.scrub!(confirm?: true, force?: true, shell: &send(test, {:shell, &1}))

      assert_received {:shell, "Scrub complete:\n" <> report}

      for {key, _count} <- Map.delete(summary, :admin_provisioned) do
        label = Staging.report_label(key)
        assert report =~ ~r/^  #{Regex.escape(label)}: +\d+$/m, "no line for #{inspect(key)}"
      end

      assert_received {:shell, "  staging admin:" <> admin_line}
      assert admin_line =~ "NONE"
    end

    test "runs once confirmed and forced past the name check" do
      user = admin()

      summary = Staging.scrub!(confirm?: true, force?: true, shell: fn _ -> :ok end)

      assert summary.users_anonymized >= 1
      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert reloaded.anonymized_at != nil
    end
  end

  describe "mix kiln.staging.scrub boots Oban inert" do
    test "it requires only the config, starting the application itself" do
      requirements = Mix.Task.requirements(Mix.Tasks.Kiln.Staging.Scrub)

      assert "app.config" in requirements
      refute "app.start" in requirements
    end

    test "the inert Oban config executes no jobs and keeps everything else" do
      config = [queues: [mail: 5], plugins: [{Oban.Plugins.Cron, []}], testing: :disabled]

      assert Staging.inert_oban_config(config) == [
               testing: :manual,
               queues: [mail: 5],
               plugins: [{Oban.Plugins.Cron, []}]
             ]
    end

    test "the backup heartbeat is off" do
      assert Staging.inert_backups_config(heartbeat?: true, other: 1) ==
               [heartbeat?: false, other: 1]
    end
  end
end
