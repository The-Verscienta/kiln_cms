defmodule KilnCMS.Accounts.IdleTimeoutTest do
  @moduledoc """
  The idle timeout's decisions (#2246), against real token rows: the policy a
  site resolves to, the timeout a tier gets, the database's clock, the race
  with a touch from another tab, the clamp to when the policy changed, the
  site a row is bound to, and the "sign out everyone" watermark.

  Rows are seeded with the shape the sign-in writes; "how long ago" is always
  set with the database's `now()`, never the test's clock.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Accounts.IdleTimeout.Policy
  alias KilnCMS.Accounts.Token
  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Security

  @moduletag :capture_log

  defp uniq, do: System.unique_integer([:positive])

  defp user(role \\ :editor) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "idle-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp token!(user, attrs) do
    Ash.Seed.seed!(
      Token,
      Map.merge(
        %{
          jti: "jti-#{uniq()}",
          subject: "user?id=#{user.id}",
          purpose: "user",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        attrs
      )
    )
  end

  # `last_used_at` set `seconds` before the database's own now.
  defp idle_for!(jti, seconds) do
    Repo.query!(
      "UPDATE tokens SET last_used_at = (now() AT TIME ZONE 'utc') - make_interval(secs => $1) WHERE jti = $2",
      [seconds * 1.0, jti]
    )
  end

  defp row(jti), do: Repo.one!(Ecto.Query.from(t in Token, where: t.jti == ^jti))

  defp policy!(org, attrs) do
    CMS.save_site_session_policy!(attrs, authorize?: false, tenant: org.id)
    KilnCMS.Cache.bust_session_policy(org.id)
    IdleTimeout.policy(org.id)
  end

  # A policy saved a day ago, so the clamp to `policy_changed_at` is out of
  # the way. (The test's transaction freezes the database's `now()` at its
  # start, so a policy saved during the test is always "just now".)
  defp aged_policy!(org, attrs) do
    CMS.save_site_session_policy!(attrs, authorize?: false, tenant: org.id)

    Repo.query!(
      "UPDATE site_session_policy SET policy_changed_at = (now() AT TIME ZONE 'utc') - interval '1 day' WHERE org_id = $1",
      [Ecto.UUID.dump!(org.id)]
    )

    KilnCMS.Cache.bust_session_policy(org.id)
    IdleTimeout.policy(org.id)
  end

  defp events(org, type) do
    admin = user(:admin)

    Security.list_events!(actor: admin, tenant: org.id, page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  describe "the policy" do
    test "is off for a site with no row, and \"off\" is a value, not nil" do
      site = org("idle-off")

      assert %Policy{idle_seconds: nil, admin_idle_seconds: nil, revoked_at: nil} =
               IdleTimeout.policy(site.id)

      assert IdleTimeout.timeout_seconds(IdleTimeout.policy(site.id), :admin) == nil
      assert IdleTimeout.timeout_seconds(IdleTimeout.policy(site.id), :editor) == nil
    end

    test "an admin gets the shorter of the two; everyone else gets the general one" do
      both = %Policy{idle_seconds: 3600, admin_idle_seconds: 900}
      assert IdleTimeout.timeout_seconds(both, :admin) == 900
      assert IdleTimeout.timeout_seconds(both, :editor) == 3600
      assert IdleTimeout.timeout_seconds(both, :viewer) == 3600

      admin_only = %Policy{admin_idle_seconds: 900}
      assert IdleTimeout.timeout_seconds(admin_only, :admin) == 900
      assert IdleTimeout.timeout_seconds(admin_only, :editor) == nil

      general_only = %Policy{idle_seconds: 1800}
      assert IdleTimeout.timeout_seconds(general_only, :admin) == 1800
    end

    test "the touch interval is a tenth of the timeout, between 30 seconds and five minutes" do
      assert IdleTimeout.touch_interval(600) == 60
      assert IdleTimeout.touch_interval(60) == 30
      assert IdleTimeout.touch_interval(86_400) == 300
      assert IdleTimeout.touch_interval(nil) == 300
    end

    test "an unreadable row fails open, and the failure is not cached" do
      site = org("idle-unreadable")

      CMS.save_site_session_policy!(%{idle_timeout_minutes: 30},
        authorize?: false,
        tenant: site.id
      )

      KilnCMS.Cache.bust_session_policy(site.id)

      refused =
        KilnCMS.OrgSettings.with_actor(KilnCMS.SystemActor.new(:not_accounts), fn ->
          IdleTimeout.policy(site.id)
        end)

      assert refused == IdleTimeout.off()
      # The next read, with the grant back, sees the row: nothing cached the
      # refusal.
      assert IdleTimeout.policy(site.id).idle_seconds == 1800
    end

    test "editors and viewers cannot read or write the row; an admin of another site cannot" do
      site = org("idle-authz")
      other = org("idle-authz-other")

      for role <- [:editor, :viewer] do
        actor = user(role)

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.save_site_session_policy(%{idle_timeout_minutes: 30},
                   actor: actor,
                   tenant: site.id
                 )
      end

      # An admin by membership of `other` only.
      foreign_admin = user(:viewer)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: other.id,
        user_id: foreign_admin.id,
        role: :admin
      })

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_session_policy(%{idle_timeout_minutes: 30},
                 actor: foreign_admin,
                 tenant: site.id
               )

      assert {:ok, []} = CMS.list_site_session_policy(tenant: site.id, authorize?: false)
    end

    test "values run from 10 minutes to a day, and admins may not get longer than everyone" do
      site = org("idle-validate")
      admin = user(:admin)

      for bad <- [5, 1441] do
        assert {:error, %Ash.Error.Invalid{}} =
                 CMS.save_site_session_policy(%{idle_timeout_minutes: bad},
                   actor: admin,
                   tenant: site.id
                 )
      end

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.save_site_session_policy(
                 %{idle_timeout_minutes: 30, admin_idle_timeout_minutes: 60},
                 actor: admin,
                 tenant: site.id
               )

      assert {:ok, _} =
               CMS.save_site_session_policy(%{admin_idle_timeout_minutes: 15},
                 actor: admin,
                 tenant: site.id
               )
    end

    test "every save stamps when the policy changed" do
      site = org("idle-stamp")
      admin = user(:admin)

      {:ok, first} =
        CMS.save_site_session_policy(%{idle_timeout_minutes: 30}, actor: admin, tenant: site.id)

      assert %DateTime{} = first.policy_changed_at

      {:ok, second} =
        CMS.save_site_session_policy(%{idle_timeout_minutes: 15}, actor: admin, tenant: site.id)

      assert DateTime.compare(second.policy_changed_at, first.policy_changed_at) == :gt
    end
  end

  describe "check/3" do
    setup do
      site = org("idle-check")
      %{site: site, policy: aged_policy!(site, %{idle_timeout_minutes: 15})}
    end

    test "an active session stays, and says how long it has left", %{site: site} do
      owner = user()
      session = token!(owner, %{org_id: site.id})
      idle_for!(session.jti, 60)

      assert {:active, %{timeout: 900, remaining: remaining}} =
               IdleTimeout.check(session.jti, site.id, touch?: false)

      assert remaining in 830..840
      assert row(session.jti).purpose == "user"
    end

    test "an idle session is signed out with its remember-me row, and the log says so",
         %{site: site} do
      owner = user()
      cookie = token!(owner, %{purpose: "remember_me", org_id: site.id})
      session = token!(owner, %{org_id: site.id, remember_me_jti: cookie.jti})
      idle_for!(session.jti, 16 * 60)
      idle_for!(cookie.jti, 16 * 60)

      assert {:signed_out, :idle} = IdleTimeout.check(session.jti, site.id, user: owner)

      for jti <- [session.jti, cookie.jti] do
        assert %{purpose: "revocation", revoked_reason: "idle"} = row(jti)
      end

      assert [event] = events(site, :session_idle_expired)
      assert event.actor_id == owner.id

      assert event.metadata == %{
               "timeout_minutes" => "15",
               "tier" => "member",
               "surface" => "http"
             }
    end

    test "is measured by the database's clock", %{site: site} do
      owner = user()
      session = token!(owner, %{org_id: site.id})

      # Fourteen minutes and a half by the database: active, whatever the
      # node's clock says.
      idle_for!(session.jti, 14 * 60 + 30)
      assert {:active, _} = IdleTimeout.check(session.jti, site.id, touch?: false)

      idle_for!(session.jti, 15 * 60 + 30)
      assert {:signed_out, :idle} = IdleTimeout.check(session.jti, site.id, touch?: false)
    end

    test "the expiring UPDATE repeats the verdict: a touch that lands first wins",
         %{site: site} do
      owner = user()
      session = token!(owner, %{org_id: site.id})
      # Another tab used the session a moment ago.
      idle_for!(session.jti, 5)

      result =
        Accounts.expire_idle_sessions(
          Ash.Query.filter(Token, jti == ^session.jti),
          %{timeout_seconds: 900, subject: session.subject, org_id: site.id},
          authorize?: false,
          bulk_options: [strategy: :atomic, return_records?: true]
        )

      assert result.records == []
      assert row(session.jti).purpose == "user"
    end

    test "turning the timeout on starts the clock from then, not from the last use",
         %{site: site} do
      owner = user()
      session = token!(owner, %{org_id: site.id})
      # Two hours idle before the 15-minute timeout was saved (just now).
      idle_for!(session.jti, 2 * 3600)
      policy!(site, %{idle_timeout_minutes: 15})

      assert {:active, %{remaining: remaining}} =
               IdleTimeout.check(session.jti, site.id, touch?: false)

      assert remaining > 800
      assert row(session.jti).purpose == "user"
    end

    test "an admin is held to the administrators' timeout, by their tier on this site",
         %{site: site} do
      policy = aged_policy!(site, %{idle_timeout_minutes: 60, admin_idle_timeout_minutes: 15})
      admin = user(:admin)
      editor = user(:editor)
      admin_session = token!(admin, %{org_id: site.id})
      editor_session = token!(editor, %{org_id: site.id})

      idle_for!(admin_session.jti, 20 * 60)
      idle_for!(editor_session.jti, 20 * 60)

      assert {:signed_out, :idle} =
               IdleTimeout.check(admin_session.jti, site.id,
                 policy: policy,
                 tier: fn -> :admin end,
                 user: admin
               )

      assert {:active, %{timeout: 3600}} =
               IdleTimeout.check(editor_session.jti, site.id,
                 policy: policy,
                 tier: fn -> :editor end,
                 touch?: false
               )

      assert [%{metadata: %{"tier" => "admin", "timeout_minutes" => "15"}}] =
               events(site, :session_idle_expired)
    end

    test "touches at most once per interval, and the remember-me row with it", %{site: site} do
      owner = user()
      cookie = token!(owner, %{purpose: "remember_me", org_id: site.id})
      session = token!(owner, %{org_id: site.id, remember_me_jti: cookie.jti})

      # Within the 90-second interval of a 15-minute timeout: no write.
      idle_for!(session.jti, 30)
      before = row(session.jti).last_used_at
      assert {:active, _} = IdleTimeout.check(session.jti, site.id)
      assert row(session.jti).last_used_at == before

      # Past it: both rows written.
      idle_for!(session.jti, 120)
      idle_for!(cookie.jti, 120)
      stale = row(cookie.jti).last_used_at
      assert {:active, _} = IdleTimeout.check(session.jti, site.id)
      assert DateTime.compare(row(session.jti).last_used_at, before) == :gt
      assert DateTime.compare(row(cookie.jti).last_used_at, stale) == :gt
    end
  end

  describe "a row of another account" do
    test "is never acted on, however idle" do
      site = org("idle-subject")
      aged_policy!(site, %{idle_timeout_minutes: 15})
      victim = user()
      session = token!(victim, %{org_id: site.id})
      idle_for!(session.jti, 3600)

      assert {:signed_out, :missing} =
               IdleTimeout.check(session.jti, site.id, subject: "user?id=#{Ash.UUID.generate()}")

      assert row(session.jti).purpose == "user"

      # The UPDATE carries the same guard.
      result =
        Accounts.expire_idle_sessions(
          Ash.Query.filter(Token, jti == ^session.jti),
          %{timeout_seconds: 900, subject: "user?id=#{Ash.UUID.generate()}", org_id: site.id},
          authorize?: false,
          bulk_options: [strategy: :atomic, return_records?: true]
        )

      assert result.records == []
      assert row(session.jti).purpose == "user"
    end
  end

  describe "a row bound to another site" do
    test "is signed out on this host, and never touched from it" do
      home = org("idle-home")
      elsewhere = org("idle-elsewhere")
      owner = user()
      session = token!(owner, %{org_id: home.id})
      idle_for!(session.jti, 3600)
      before = row(session.jti)

      assert {:signed_out, :foreign} = IdleTimeout.check(session.jti, elsewhere.id)

      after_check = row(session.jti)
      assert after_check.purpose == "user"
      assert after_check.last_used_at == before.last_used_at
      assert after_check.org_id == home.id

      # The touch refuses it too, whoever calls it.
      KilnCMS.Accounts.Sessions.record_use([session.jti], %{}, org_id: elsewhere.id)
      assert row(session.jti).last_used_at == before.last_used_at
    end

    test "a row bound to no site is bound to the first site that uses it" do
      site = org("idle-bind")
      owner = user()
      session = token!(owner, %{})
      idle_for!(session.jti, 3600)

      assert {:active, _} = IdleTimeout.check(session.jti, site.id)
      assert row(session.jti).org_id == site.id
    end
  end

  describe "the sign-out-everyone watermark" do
    setup do
      site = org("idle-mark")
      at = DateTime.utc_now()
      CMS.record_sessions_revoked!(%{at: at}, authorize?: false, tenant: site.id)
      KilnCMS.Cache.bust_session_policy(site.id)
      %{site: site, at: at}
    end

    test "signs out a row bound to no site that predates it, with or without a timeout",
         %{site: site, at: at} do
      owner = user()
      cookie = token!(owner, %{purpose: "remember_me", created_at: DateTime.add(at, -60)})

      session =
        token!(owner, %{created_at: DateTime.add(at, -60), remember_me_jti: cookie.jti})

      assert IdleTimeout.policy(site.id).idle_seconds == nil
      assert {:signed_out, :admin_sign_out_all} = IdleTimeout.check(session.jti, site.id)

      for jti <- [session.jti, cookie.jti] do
        assert %{purpose: "revocation", revoked_reason: "admin_sign_out_all"} = row(jti)
      end
    end

    test "spares a row signed in since, and the row bound to the site it kept",
         %{site: site, at: at} do
      owner = user()
      fresh = token!(owner, %{created_at: DateTime.add(at, 60)})
      kept = token!(owner, %{org_id: site.id, created_at: DateTime.add(at, -60)})

      assert {:active, _} = IdleTimeout.check(fresh.jti, site.id)
      assert {:active, _} = IdleTimeout.check(kept.jti, site.id)
    end

    test "never reaches the same row on another site's host", %{at: at} do
      other = org("idle-mark-other")
      owner = user()
      session = token!(owner, %{created_at: DateTime.add(at, -60)})

      assert {:active, _} = IdleTimeout.check(session.jti, other.id)
      assert row(session.jti).purpose == "user"
    end
  end
end
