defmodule KilnCMS.Accounts.SignOutEveryoneTest do
  @moduledoc """
  "Sign out everyone on every site" (#2491), `InstanceSessions.sign_out_everyone`.

  Refusals first: every actor who is not a platform admin by effective role,
  an API-key actor, a wrong phrase and a kept session that is not the
  caller's revoke nothing and record nothing. Then the scope: every unexpired
  session, app token, remember-me cookie and two-factor hold on every site
  and on none, never an API key; the caller's own browser kept when asked;
  the instance event; the rollback when it cannot be recorded; one eviction
  per session.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.InstanceSessions
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.SignOutEveryone
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Repo
  alias KilnCMS.Security

  @moduletag :capture_log

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp user(role \\ :editor, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "soe-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp member!(user, org, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })

    user
  end

  defp token!(user, attrs \\ %{}) do
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

  defp sign_out_everyone(actor, opts \\ []) do
    Accounts.sign_out_everyone_on_every_site(
      %{
        confirmation: Keyword.get(opts, :confirmation, SignOutEveryone.phrase()),
        except_session_jti: Keyword.get(opts, :except)
      },
      actor: actor
    )
  end

  defp events do
    Security.list_instance_events!(actor: user(:admin), page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :all_sessions_revoked_everywhere))
  end

  setup do
    site = org("soe")
    platform = user(:admin)
    victim = user()
    victim_session = token!(victim, %{org_id: site.id})
    %{site: site, platform: platform, victim: victim, victim_session: victim_session}
  end

  describe "refused" do
    test "a site's admin, an editor, a viewer and a signed-out caller", ctx do
      site_admin = member!(user(:viewer), ctx.site, :admin)
      editor = member!(user(:viewer), ctx.site, :editor)
      viewer = member!(user(:viewer), ctx.site, :viewer)
      standing_editor = user(:editor)

      for actor <- [site_admin, editor, viewer, standing_editor, nil] do
        assert {:error, %Ash.Error.Forbidden{}} = sign_out_everyone(actor)
      end

      assert live?(ctx.victim_session.jti)
      assert events() == []
    end

    test "a system actor", ctx do
      for subsystem <- [:accounts, :security, :operator] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 sign_out_everyone(KilnCMS.SystemActor.new(subsystem))
      end

      assert live?(ctx.victim_session.jti)
      assert events() == []
    end

    test "a platform admin whose temporary grant has just expired", ctx do
      lapsed =
        user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      assert {:error, %Ash.Error.Forbidden{}} = sign_out_everyone(lapsed)
      assert live?(ctx.victim_session.jti)
      assert events() == []
    end

    test "a platform admin signed in with an API key", ctx do
      expires = DateTime.add(DateTime.utc_now(), 86_400, :second)
      key = Accounts.mint_api_key!(ctx.platform.id, "ci", expires, authorize?: false)
      key_actor = Ash.Resource.set_metadata(ctx.platform, %{using_api_key?: true, api_key: key})

      assert {:error, %Ash.Error.Forbidden{}} = sign_out_everyone(key_actor)
      assert live?(ctx.victim_session.jti)
      assert events() == []
    end

    test "a refused caller is refused whatever phrase they type", ctx do
      site_admin = member!(user(:viewer), ctx.site, :admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               sign_out_everyone(site_admin, confirmation: "not the phrase")

      assert live?(ctx.victim_session.jti)
    end

    test "the token write itself, by a platform admin or anyone", ctx do
      for actor <- [ctx.platform, nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.revoke_all_sessions(Token, %{keep: []},
                   actor: actor,
                   bulk_options: [strategy: :atomic, return_errors?: true]
                 )
      end

      assert live?(ctx.victim_session.jti)
    end

    test "a wrong, empty or missing phrase", ctx do
      for typed <- ["wrong.example.com", "", "   ", nil, SignOutEveryone.phrase() <> "x"] do
        assert {:error, %Ash.Error.Invalid{}} =
                 sign_out_everyone(ctx.platform, confirmation: typed)
      end

      assert live?(ctx.victim_session.jti)
      assert events() == []
    end

    test "keeping a session that is not the caller's own", ctx do
      remember = token!(ctx.platform, %{purpose: "remember_me"})

      for jti <- [ctx.victim_session.jti, remember.jti, "no-such-jti"] do
        assert {:error, %Ash.Error.Invalid{}} = sign_out_everyone(ctx.platform, except: jti)
      end

      assert live?(ctx.victim_session.jti)
      assert live?(remember.jti)
      assert events() == []
    end
  end

  describe "a platform admin" do
    test "the phrase is the instance's host, any case, spaces around it ignored", ctx do
      assert SignOutEveryone.phrase() == String.downcase(KilnCMSWeb.Endpoint.host())

      typed = "  " <> String.upcase(SignOutEveryone.phrase()) <> " "
      assert {:ok, 1} = sign_out_everyone(ctx.platform, confirmation: typed)
      refute live?(ctx.victim_session.jti)
    end

    test "signs out every session, cookie, hold and app token on every site and none", ctx do
      other = org("soe-b")
      both = user()
      here = token!(both, %{org_id: ctx.site.id})
      there = token!(both, %{org_id: other.id})
      # Signed in before sessions recorded a site.
      unbound = token!(user(), %{created_at: DateTime.add(DateTime.utc_now(), -86_400)})
      cookie = token!(ctx.victim, %{purpose: "remember_me", org_id: ctx.site.id})
      held = token!(ctx.victim, %{purpose: "pending_second_factor"})
      # A headless sign-in (`POST /api/auth/sign_in`): a stored "user" row
      # bound to no site, minted by the real strategy.
      headless = headless_sign_in!(user())

      # Exactly the "user" rows: the victim's, both of `both`'s, the unbound
      # one and the headless one. Not the cookie or the hold.
      assert {:ok, 5} = sign_out_everyone(ctx.platform)

      for jti <- [ctx.victim_session.jti, here.jti, there.jti, unbound.jti, headless, cookie.jti] do
        assert %{purpose: "revocation", revoked_reason: "instance_sign_out_all"} = row(jti)
      end

      refute live?(held.jti)
    end

    test "leaves expired rows, other purposes and API keys alone", ctx do
      expired =
        token!(ctx.victim, %{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})

      reset = token!(ctx.victim, %{purpose: "password_reset"})
      expires = DateTime.add(DateTime.utc_now(), 86_400, :second)
      key = Accounts.mint_api_key!(ctx.victim.id, "ci", expires, authorize?: false)
      plaintext = Ash.Resource.get_metadata(key, :plaintext_api_key)

      assert {:ok, 1} = sign_out_everyone(ctx.platform)

      assert row(expired.jti).purpose == "user"
      assert row(reset.jti).purpose == "password_reset"
      assert {:ok, %{revoked_at: nil}} = Accounts.get_api_key(key.id, authorize?: false)

      # And it still signs in.
      strategy = AshAuthentication.Info.strategy!(Accounts.User, :api_key)

      assert {:ok, %Accounts.User{id: id}} =
               AshAuthentication.Strategy.action(
                 strategy,
                 :sign_in,
                 %{"api_key" => plaintext},
                 []
               )

      assert id == ctx.victim.id
    end

    test "a temporary platform admin may run it", ctx do
      temporary =
        user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert {:ok, 1} = sign_out_everyone(temporary)
      refute live?(ctx.victim_session.jti)
    end

    test "keeps exactly this browser and its remember-me cookie, when asked", ctx do
      cookie = token!(ctx.platform, %{purpose: "remember_me", org_id: ctx.site.id})
      mine = token!(ctx.platform, %{org_id: ctx.site.id, remember_me_jti: cookie.jti})
      other_cookie = token!(ctx.platform, %{purpose: "remember_me", org_id: ctx.site.id})
      my_other = token!(ctx.platform, %{org_id: org("soe-mine").id})

      assert {:ok, 2} = sign_out_everyone(ctx.platform, except: mine.jti)

      assert live?(mine.jti)
      assert live?(cookie.jti)
      refute live?(other_cookie.jti)
      refute live?(my_other.jti)
      refute live?(ctx.victim_session.jti)
    end

    test "is logged in the instance log, with the count and whether the caller stayed", ctx do
      mine = token!(ctx.platform)
      assert {:ok, 1} = sign_out_everyone(ctx.platform, except: mine.jti)

      assert [event] = events()
      assert event.actor_id == ctx.platform.id
      assert event.target_type == "instance"
      assert event.target_id == nil
      assert event.metadata == %{"count" => "1", "except_self" => "true"}

      # Not in any site's log.
      site_events =
        Security.list_events!(actor: ctx.platform, tenant: ctx.site.id, page: [limit: 50])

      refute Enum.any?(site_events.results, &(&1.type == :all_sessions_revoked))
    end

    test "rolls everything back when the event cannot be written", ctx do
      Phoenix.PubSub.subscribe(
        KilnCMS.PubSub,
        SessionEviction.session_topic(ctx.victim_session.jti)
      )

      # The `:security` system actor taken away: the instance event's create
      # is refused, so `Recorder.record/2` returns an error.
      assert {:error, _} = Security.with_actor(nil, fn -> sign_out_everyone(ctx.platform) end)

      assert live?(ctx.victim_session.jti)
      assert events() == []
      refute_receive {:session_revoked, _}
    end

    test "rolls everything back when the event is skipped", ctx do
      Phoenix.PubSub.subscribe(
        KilnCMS.PubSub,
        SessionEviction.session_topic(ctx.victim_session.jti)
      )

      # An acting account already anonymized: `Recorder.record/2` writes no
      # event for it and returns `:skipped`.
      erased = %{ctx.platform | anonymized_at: DateTime.utc_now()}

      assert {:error, _} = sign_out_everyone(erased)

      assert live?(ctx.victim_session.jti)
      assert events() == []
      refute_receive {:session_revoked, _}
    end

    test "closes each session's pages and sockets by its own topic, never the per-user one",
         ctx do
      second = token!(ctx.victim, %{org_id: org("soe-c").id})
      jtis = [ctx.victim_session.jti, second.jti]

      for jti <- jtis do
        Phoenix.PubSub.subscribe(KilnCMS.PubSub, SessionEviction.session_topic(jti))
        KilnCMSWeb.Endpoint.subscribe(SessionEviction.session_socket_topic(jti))
      end

      KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(ctx.victim.id))

      assert {:ok, 2} = sign_out_everyone(ctx.platform)

      for jti <- jtis do
        topic = SessionEviction.session_socket_topic(jti)
        assert_receive {:session_revoked, ^jti}
        assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      end

      user_topic = SessionEviction.topic(ctx.victim.id)
      refute_receive %Phoenix.Socket.Broadcast{topic: ^user_topic}
    end
  end

  describe "Sessions.revoke_everywhere/1" do
    test "returns the revoked sessions' jtis and nothing of the other rows it revokes", ctx do
      cookie = token!(ctx.victim, %{purpose: "remember_me", org_id: ctx.site.id})
      held = token!(ctx.victim, %{purpose: "pending_second_factor"})
      other = token!(user())

      assert {:ok, jtis} = Sessions.revoke_everywhere([])

      assert Enum.sort(jtis) == Enum.sort([ctx.victim_session.jti, other.jti])
      refute live?(cookie.jti)
      refute live?(held.jti)
    end

    test "keeps the rows it is told to, and returns none of them", ctx do
      kept = token!(ctx.platform, %{org_id: ctx.site.id})

      assert {:ok, [jti]} = Sessions.revoke_everywhere([kept.jti])
      assert jti == ctx.victim_session.jti
      assert live?(kept.jti)
    end
  end

  describe "not an API surface" do
    test "absent from JSON:API, GraphQL and the MCP tools" do
      refute AshJsonApi.Resource in Spark.extensions(InstanceSessions)
      refute AshGraphql.Resource in Spark.extensions(InstanceSessions)

      tool_domains =
        Enum.filter(
          Application.fetch_env!(:kiln_cms, :ash_domains),
          &(AshAi in Spark.extensions(&1))
        )

      assert tool_domains != []

      for domain <- tool_domains do
        refute Enum.any?(AshAi.Info.tools(domain), &(&1.resource == InstanceSessions))
      end
    end
  end

  defp headless_sign_in!(user) do
    strategy = AshAuthentication.Info.strategy!(Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(user.email), "password" => @password},
        []
      )

    jti = Token.peeked_jti(signed_in.__metadata__.token)
    assert %{purpose: "user", org_id: nil} = row(jti)
    jti
  end
end
