defmodule KilnCMS.Accounts.SignOutAllTest do
  @moduledoc """
  "Sign out everyone" on one site (#2246), `SiteSessionPolicy.sign_out_all`.

  Refusals first: every actor who is not an admin of the tenant, and a call
  with no tenant, revoke nothing. Then the scope: only rows bound to this site,
  every purpose a browser signs in with, never another site's rows, never API
  keys or bearer JWTs; the caller's own browser kept only when it is theirs;
  one eviction per session and none on the per-user topic.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Token
  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Security

  @moduletag :capture_log

  defp uniq, do: System.unique_integer([:positive])

  defp user(role \\ :editor) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "soa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member!(user, org, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })

    user
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

  defp row(jti), do: Repo.one!(Ecto.Query.from(t in Token, where: t.jti == ^jti))
  defp live?(jti), do: row(jti).purpose != "revocation"

  defp sign_out_all(actor, tenant, except \\ nil) do
    CMS.sign_out_all_sessions(%{except_session_jti: except}, actor: actor, tenant: tenant)
  end

  defp events(site) do
    Security.list_events!(actor: user(:admin), tenant: site.id, page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :all_sessions_revoked))
  end

  setup do
    site = org("soa")
    admin = member!(user(:viewer), site, :admin)
    victim = user()
    victim_session = token!(victim, %{org_id: site.id})
    %{site: site, admin: admin, victim: victim, victim_session: victim_session}
  end

  describe "refused" do
    test "an editor, a viewer and a signed-out caller revoke nothing", ctx do
      editor = member!(user(:viewer), ctx.site, :editor)
      viewer = member!(user(:viewer), ctx.site, :viewer)

      for actor <- [editor, viewer, nil] do
        assert {:error, %Ash.Error.Forbidden{}} = sign_out_all(actor, ctx.site.id)
      end

      assert live?(ctx.victim_session.jti)
      assert events(ctx.site) == []
    end

    test "a system actor revokes nothing", ctx do
      for subsystem <- [:accounts, :security, :operator] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 sign_out_all(KilnCMS.SystemActor.new(subsystem), ctx.site.id)
      end

      assert live?(ctx.victim_session.jti)
    end

    test "an admin of one site cannot sign out another", ctx do
      other = org("soa-other")
      other_admin = member!(user(:viewer), other, :admin)

      assert {:error, %Ash.Error.Forbidden{}} = sign_out_all(other_admin, ctx.site.id)
      assert live?(ctx.victim_session.jti)
    end

    test "no tenant revokes nothing, a platform admin included", ctx do
      assert {:error, _} = sign_out_all(user(:admin), nil)
      assert {:error, _} = sign_out_all(ctx.admin, nil)
      assert live?(ctx.victim_session.jti)
    end

    test "the watermark cannot be written directly, by an admin or anyone", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.record_sessions_revoked(%{at: DateTime.utc_now()},
                 actor: ctx.admin,
                 tenant: ctx.site.id
               )
    end

    test "keeping a session that is not the caller's own revokes nothing", ctx do
      own_elsewhere = token!(ctx.admin, %{org_id: org("soa-elsewhere").id})

      for jti <- [ctx.victim_session.jti, own_elsewhere.jti, "no-such-jti"] do
        assert {:error, %Ash.Error.Invalid{}} = sign_out_all(ctx.admin, ctx.site.id, jti)
      end

      assert live?(ctx.victim_session.jti)
      assert events(ctx.site) == []
    end
  end

  describe "an admin of the site" do
    test "signs out every browser bound to it, and no other site's", ctx do
      other = org("soa-b")
      # One account signed in on both sites.
      both = user()
      here = token!(both, %{org_id: ctx.site.id})
      there = token!(both, %{org_id: other.id})

      assert {:ok, 2} = sign_out_all(ctx.admin, ctx.site.id)

      for jti <- [ctx.victim_session.jti, here.jti] do
        assert %{purpose: "revocation", revoked_reason: "admin_sign_out_all"} = row(jti)
      end

      assert live?(there.jti)
    end

    test "reaches remember-me cookies and held two-factor sign-ins bound to it", ctx do
      cookie = token!(ctx.victim, %{purpose: "remember_me", org_id: ctx.site.id})
      held = token!(ctx.victim, %{purpose: "pending_second_factor", org_id: ctx.site.id})

      assert {:ok, 1} = sign_out_all(ctx.admin, ctx.site.id)

      refute live?(cookie.jti)
      refute live?(held.jti)
    end

    test "a platform admin's session on the site goes too", ctx do
      platform = user(:admin)
      session = token!(platform, %{org_id: ctx.site.id})

      assert {:ok, _} = sign_out_all(ctx.admin, ctx.site.id)
      refute live?(session.jti)
    end

    test "leaves rows bound to no site alone, and the watermark catches them here only",
         ctx do
      legacy = token!(ctx.victim, %{created_at: DateTime.add(DateTime.utc_now(), -60)})

      assert {:ok, 1} = sign_out_all(ctx.admin, ctx.site.id)
      assert live?(legacy.jti)

      # Used on another site's host: untouched.
      other = org("soa-legacy-other")
      assert {:active, _} = Accounts.IdleTimeout.check(legacy.jti, other.id, touch?: false)
      assert live?(legacy.jti)

      # Used on this site's host: signed out.
      assert {:signed_out, :admin_sign_out_all} =
               Accounts.IdleTimeout.check(legacy.jti, ctx.site.id)

      refute live?(legacy.jti)
    end

    test "a two-factor hold released after it is signed out on its next use", ctx do
      held =
        token!(ctx.victim, %{
          purpose: "pending_second_factor",
          created_at: DateTime.add(DateTime.utc_now(), -60)
        })

      assert {:ok, _} = sign_out_all(ctx.admin, ctx.site.id)

      # The code lands: the hold becomes a session, and the sign-in response
      # stamps it for this site — which must not bind it past the watermark.
      Repo.query!("UPDATE tokens SET purpose = 'user' WHERE jti = $1", [held.jti])

      Accounts.Sessions.record_sign_in(
        held.jti,
        %{browser: "Firefox", platform: "macOS"},
        nil,
        ctx.site.id,
        held.subject
      )

      assert row(held.jti).org_id == nil

      assert {:signed_out, :admin_sign_out_all} =
               Accounts.IdleTimeout.check(held.jti, ctx.site.id, subject: held.subject)
    end

    test "a use between the revocation and the page's recheck cannot rescue a session",
         ctx do
      legacy = token!(ctx.victim, %{created_at: DateTime.add(DateTime.utc_now(), -60)})

      assert {:ok, _} = sign_out_all(ctx.admin, ctx.site.id)

      # A node whose cached policy predates the sign-out: it sees no
      # watermark, finds the session active, and notes the use.
      assert {:active, _} =
               Accounts.IdleTimeout.check(legacy.jti, ctx.site.id,
                 policy: Accounts.IdleTimeout.off(),
                 subject: legacy.subject
               )

      Accounts.Sessions.record_use([legacy.jti], %{}, org_id: ctx.site.id, interval_seconds: 30)
      Accounts.Sessions.bind_to_site([legacy.jti], ctx.site.id, legacy.subject)

      # Neither bound it to the site, so the next check still catches it.
      assert row(legacy.jti).org_id == nil

      assert {:signed_out, :admin_sign_out_all} =
               Accounts.IdleTimeout.check(legacy.jti, ctx.site.id, subject: legacy.subject)
    end

    test "rolls everything back when the event cannot be recorded", ctx do
      Phoenix.PubSub.subscribe(
        KilnCMS.PubSub,
        SessionEviction.session_topic(ctx.victim_session.jti)
      )

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Accounts.IdleTimeout.topic(ctx.site.id))

      assert {:error, _} =
               Security.with_actor(nil, fn -> sign_out_all(ctx.admin, ctx.site.id) end)

      assert live?(ctx.victim_session.jti)
      assert {:ok, []} = CMS.list_site_session_policy(tenant: ctx.site.id, authorize?: false)
      refute_receive {:session_revoked, _}
      refute_receive {:session_policy_changed, _}
    end

    test "the row holding the watermark cannot be deleted, by an admin either", ctx do
      assert {:ok, _} = sign_out_all(ctx.admin, ctx.site.id)
      {:ok, [policy]} = CMS.list_site_session_policy(tenant: ctx.site.id, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(policy, actor: ctx.admin, tenant: ctx.site.id, action: :destroy)

      refute function_exported?(CMS, :reset_site_session_policy, 2)
    end

    test "never touches API keys or bearer JWTs", ctx do
      # A headless sign-in's JWT is a stored "user" row bound to no site.
      bearer = token!(ctx.victim, %{created_at: DateTime.add(DateTime.utc_now(), -60)})
      expires = DateTime.add(DateTime.utc_now(), 86_400, :second)
      {:ok, key} = Accounts.mint_api_key(ctx.victim.id, "ci", expires, authorize?: false)

      assert {:ok, 1} = sign_out_all(ctx.admin, ctx.site.id)

      assert live?(bearer.jti)
      assert {:ok, %{revoked_at: nil}} = Accounts.get_api_key(key.id, authorize?: false)
    end

    test "keeps the caller's own browser and its remember-me cookie, when asked", ctx do
      cookie = token!(ctx.admin, %{purpose: "remember_me", org_id: ctx.site.id})
      mine = token!(ctx.admin, %{org_id: ctx.site.id, remember_me_jti: cookie.jti})
      my_other = token!(ctx.admin, %{org_id: ctx.site.id})

      assert {:ok, 2} = sign_out_all(ctx.admin, ctx.site.id, mine.jti)

      assert live?(mine.jti)
      assert live?(cookie.jti)
      refute live?(my_other.jti)
      refute live?(ctx.victim_session.jti)

      # And the watermark passes the kept browser by.
      assert {:active, _} = Accounts.IdleTimeout.check(mine.jti, ctx.site.id)
    end

    test "a kept browser bound to no site yet is bound to this one", ctx do
      mine = token!(ctx.admin, %{created_at: DateTime.add(DateTime.utc_now(), -60)})

      assert {:ok, _} = sign_out_all(ctx.admin, ctx.site.id, mine.jti)

      assert row(mine.jti).org_id == ctx.site.id
      assert {:active, _} = Accounts.IdleTimeout.check(mine.jti, ctx.site.id)
    end

    test "is logged, with the count and whether the caller kept their session", ctx do
      mine = token!(ctx.admin, %{org_id: ctx.site.id})
      assert {:ok, 1} = sign_out_all(ctx.admin, ctx.site.id, mine.jti)

      assert [event] = events(ctx.site)
      assert event.actor_id == ctx.admin.id
      assert event.target_type == "organization"
      assert event.target_id == ctx.site.id
      assert event.metadata == %{"count" => "1", "except_self" => "true"}
    end

    test "writes the watermark and tells the site's open pages", ctx do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Accounts.IdleTimeout.topic(ctx.site.id))

      assert {:ok, _} = sign_out_all(ctx.admin, ctx.site.id)

      assert_receive {:session_policy_changed, %{revoked_at: %DateTime{}}}
      assert %DateTime{} = Accounts.IdleTimeout.policy(ctx.site.id).revoked_at
    end

    test "closes each session's pages by its own topic, never the per-user one", ctx do
      second = token!(ctx.victim, %{org_id: ctx.site.id})

      for jti <- [ctx.victim_session.jti, second.jti] do
        Phoenix.PubSub.subscribe(KilnCMS.PubSub, SessionEviction.session_topic(jti))
      end

      KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(ctx.victim.id))

      assert {:ok, 2} = sign_out_all(ctx.admin, ctx.site.id)

      victim_jti = ctx.victim_session.jti
      second_jti = second.jti
      assert_receive {:session_revoked, ^victim_jti}
      assert_receive {:session_revoked, ^second_jti}
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end
end
