defmodule KilnCMS.Staging.ScrubTest do
  @moduledoc """
  The staging scrub turns a production clone into a PII-free, secret-free
  environment, reusing the GDPR-erasure `:anonymize` action. See
  `docs/staging-environments.md`.
  """
  use KilnCMS.DataCase, async: true

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

    test "is idempotent — a second run re-anonymizes nothing" do
      admin()
      first = Scrub.run([])
      assert first.users_anonymized >= 1

      second = Scrub.run([])
      assert second.users_anonymized == 0
    end
  end

  describe "the scrub table in docs/staging-environments.md" do
    # The table drifted once (#2454): five purges were added to the scrub with
    # no row. Every row now names its summary key, so the keys a real run
    # returns are the list the table must cover.
    @guide "docs/staging-environments.md"

    test "names every key of the scrub's summary" do
      keys = Scrub.run([]) |> Map.keys() |> Enum.sort()
      table = scrub_table!()

      missing = Enum.reject(keys, &String.contains?(table, "(`#{&1}`)"))

      assert missing == [], """
      The scrub table in #{@guide} ("## The scrub") has no row for:

        #{Enum.map_join(missing, "\n  ", &inspect/1)}

      Add a row for each that says what is purged or de-activated and why,
      with its summary key in the Action column, e.g. "purged (`#{List.first(missing)}`)".
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

    test "runs once confirmed and forced past the name check" do
      user = admin()

      summary = Staging.scrub!(confirm?: true, force?: true, shell: fn _ -> :ok end)

      assert summary.users_anonymized >= 1
      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert reloaded.anonymized_at != nil
    end
  end
end
