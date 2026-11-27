defmodule KilnCMSWeb.SessionBoundSocketsTest do
  @moduledoc """
  `/ws/collab` and `/ws/gql` live no longer than the sign-in they were opened
  from (#2490).

  A collab token names the browser session its editor was minted in, and a
  `/ws/gql` socket is bound to its bearer JWT's own row. Every per-session
  sign-out — the settings page's "Sign out" and "Sign out of all other
  sessions", the site's idle timeout and "sign out everyone", the browser's
  own Sign out — reaches the socket through
  `SessionEviction.session_socket_topic/1`; the collab channel's periodic
  re-check and the gql per-document phase catch a revocation no broadcast
  reached. Connects are refused for a session that is no longer a live
  sign-in of the account.

  `async: false`: the collab prototype flag and the re-check interval are
  `Application.put_env`, and subscriptions register on the global endpoint
  registry. Each test uses a site of its own: the session policy is cached per
  site on the whole node.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]
  import Phoenix.LiveViewTest, only: [live: 2]

  use Absinthe.Phoenix.SubscriptionTest, schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.Token
  alias KilnCMS.CMS
  alias KilnCMS.CollabTokenFixtures, as: Tokens
  alias KilnCMS.Repo
  alias KilnCMS.SecondFactorFixtures, as: Fixtures
  alias KilnCMSWeb.CollabSocket
  alias KilnCMSWeb.GraphqlSocket
  alias Phoenix.Socket.Broadcast

  require Ecto.Query

  @endpoint KilnCMSWeb.Endpoint
  @moduletag :capture_log

  # Must track SCHEMA_VSN in assets/js/collab.js.
  @schema_vsn 3

  setup do
    put_env(:collab_prototype, true)
    put_env(:socket_reauth_interval_ms, 50)
    :ok
  end

  defp put_env(key, value) do
    previous = Application.get_env(:kiln_cms, key)
    Application.put_env(:kiln_cms, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kiln_cms, key),
        else: Application.put_env(:kiln_cms, key, previous)
    end)
  end

  defp host(site), do: "#{site.slug}.#{KilnCMSWeb.Tenant.base_host()}"
  defp uri(site, path), do: %{uri: URI.parse("wss://#{host(site)}#{path}")}

  defp collab_connect(token, site),
    do:
      Phoenix.ChannelTest.connect(CollabSocket, %{"token" => token},
        connect_info: uri(site, "/ws/collab")
      )

  defp gql_connect(site, token),
    do:
      Phoenix.ChannelTest.connect(GraphqlSocket, %{"token" => token},
        connect_info: uri(site, "/ws/gql")
      )

  defp topic(jti), do: SessionEviction.session_socket_topic(jti)

  defp jti_of(jwt) do
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(jwt)
    jti
  end

  # Whether the calling process — which `Phoenix.ChannelTest.connect/3` runs
  # `connect/3` in, as the transport does — listens on the session's topic.
  defp subscribed?(jti) do
    KilnCMS.PubSub
    |> Registry.lookup(topic(jti))
    |> Enum.any?(fn {pid, _value} -> pid == self() end)
  end

  defmacrop assert_disconnected(jti) do
    quote do
      topic = topic(unquote(jti))
      assert_receive %Broadcast{event: "disconnect", topic: ^topic}, 1_000
    end
  end

  defmacrop refute_disconnected(jti) do
    quote do
      topic = topic(unquote(jti))
      refute_receive %Broadcast{event: "disconnect", topic: ^topic}, 150
    end
  end

  defp editor(site), do: Fixtures.editor(site)
  defp site_admin(site), do: Fixtures.seed_user() |> Fixtures.member!(site, :admin)

  # A platform administrator: an administrator on every site, so a page needs
  # no membership to be edited.
  defp platform_admin, do: Fixtures.seed_user(%{role: :admin})

  defp page!(user, site) do
    CMS.create_page!(
      %{title: "Collab", slug: "sbs-#{System.unique_integer([:positive])}"},
      actor: user,
      tenant: site.id
    )
  end

  defp join!(socket, page) do
    {:ok, _reply, joined} =
      subscribe_and_join(socket, "collab:page:#{page.id}", %{"vsn" => @schema_vsn})

    joined
  end

  # `last_used_at` set `seconds` before the database's own now.
  defp idle_for!(jti, seconds) do
    Repo.query!(
      "UPDATE tokens SET last_used_at = (now() AT TIME ZONE 'utc') - make_interval(secs => $1) WHERE jti = $2",
      [seconds * 1.0, jti]
    )
  end

  # A revocation that broadcasts nothing: what a lost cross-node message, an
  # old node or a path that never evicts leaves behind.
  defp revoke_silently!(jti) do
    Repo.query!("UPDATE tokens SET purpose = 'revocation' WHERE jti = $1", [jti])
  end

  defp row(jti), do: Repo.one!(Ecto.Query.from(t in Token, where: t.jti == ^jti))

  # A policy saved a day ago, so the clamp to `policy_changed_at` is out of the
  # way (the test's transaction freezes the database's `now()`).
  defp aged_policy!(site, attrs) do
    CMS.save_site_session_policy!(attrs, authorize?: false, tenant: site.id)

    Repo.query!(
      "UPDATE site_session_policy SET policy_changed_at = (now() AT TIME ZONE 'utc') - interval '1 day' WHERE org_id = $1",
      [Ecto.UUID.dump!(site.id)]
    )

    KilnCMS.Cache.bust_session_policy(site.id)
    IdleTimeout.policy(site.id)
  end

  defp sign_out_all!(admin, site, except \\ nil) do
    {:ok, _count} =
      CMS.sign_out_all_sessions(%{except_session_jti: except}, actor: admin, tenant: site.id)
  end

  defp events(site, type) do
    KilnCMS.Security.list_events!(actor: platform_admin(), tenant: site.id, page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  # --- every per-session sign-out drops the collab connection ---------------

  describe "/ws/collab: each per-session sign-out drops the connection" do
    test "signing the session out from the settings page" do
      site = org("sbs-revoke")
      user = editor(site)
      {token, jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      assert {:ok, _socket} = collab_connect(token, site)

      assert :ok = Sessions.revoke(user, jti)
      assert_disconnected(jti)
    end

    test "\"sign out of all other sessions\" drops the others, not this one" do
      site = org("sbs-others")
      user = editor(site)
      {other_token, other} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      {this_token, this} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      assert {:ok, _} = collab_connect(other_token, site)
      assert {:ok, _} = collab_connect(this_token, site)

      assert {:ok, 1} = Sessions.revoke_others(user, this)
      assert_disconnected(other)
      refute_disconnected(this)
    end

    test "the site's idle timeout" do
      site = org("sbs-idle")
      aged_policy!(site, %{idle_timeout_minutes: 15})
      user = editor(site)
      {token, jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      assert {:ok, _socket} = collab_connect(token, site)

      idle_for!(jti, 16 * 60)
      assert {:signed_out, :idle} = IdleTimeout.check(jti, site.id, user: user)
      assert_disconnected(jti)
    end

    test "the site's \"sign out everyone\", sparing the admin's kept session and other sites" do
      site = org("sbs-all")
      elsewhere = org("sbs-all-elsewhere")
      admin = site_admin(site)
      user = editor(site) |> Fixtures.member!(elsewhere, :editor)

      {user_token, user_jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      {kept_token, kept} = Tokens.collab_token_and_jti(admin, session: %{org_id: site.id})

      {other_token, other_site} =
        Tokens.collab_token_and_jti(user, session: %{org_id: elsewhere.id})

      assert {:ok, _} = collab_connect(user_token, site)
      assert {:ok, _} = collab_connect(kept_token, site)
      assert {:ok, _} = collab_connect(other_token, elsewhere)

      sign_out_all!(admin, site, kept)

      assert_disconnected(user_jti)
      refute_disconnected(kept)
      refute_disconnected(other_site)
    end

    test "the browser's own Sign out", %{conn: conn} do
      site = org("sbs-sign-out")
      user = editor(site)
      conn = Fixtures.signed_in(conn, user, site)
      jti = jti_of(get_session(conn, "user_token"))

      assert {:ok, _socket} = collab_connect(CollabSocket.token(user, false, jti), site)
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, SessionEviction.session_topic(jti))

      conn = delete(conn, ~p"/sign-out")
      assert redirected_to(conn)
      assert row(jti).purpose == "revocation"
      assert_disconnected(jti)

      # Only the sockets: the session's pages are not told, so the clicking tab
      # follows its own redirect and other tabs don't claim "another device".
      refute_receive {:session_revoked, ^jti}, 150
    end
  end

  # --- the transport really closes ------------------------------------------

  # `Phoenix.ChannelTest.connect/3` runs only `connect/3`. This drives the
  # callbacks the websocket transport calls, in its order and in one process —
  # `connect/1`, `init/1`, then `handle_info/2` with what arrived — so the
  # subscription made in `connect/3` is shown to be the socket's own, and the
  # message on it to be one `Phoenix.Socket` stops on.
  describe "the transport closes on the session's broadcast" do
    defp transport_connect(socket_module, params, connect_info) do
      socket_module.connect(%{
        endpoint: @endpoint,
        transport: :websocket,
        options: [serializer: [{Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}]],
        params: Map.put(params, "vsn", "2.0.0"),
        connect_info: connect_info
      })
    end

    test "/ws/collab" do
      site = org("sbs-transport-collab")
      user = editor(site)
      {token, jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})

      assert {:ok, state} =
               transport_connect(CollabSocket, %{"token" => token}, uri(site, "/ws/collab"))

      assert {:ok, state} = CollabSocket.init(state)

      assert :ok = Sessions.revoke(user, jti)
      topic = topic(jti)
      assert_receive %Broadcast{event: "disconnect", topic: ^topic} = message, 1_000

      assert {:stop, {:shutdown, :disconnected}, _state} =
               CollabSocket.handle_info(message, state)
    end

    test "/ws/gql" do
      site = org("sbs-transport-gql")
      user = editor(site)
      jwt = Fixtures.jwt(user)
      jti = jti_of(jwt)

      assert {:ok, state} =
               transport_connect(GraphqlSocket, %{"token" => jwt}, uri(site, "/ws/gql"))

      assert {:ok, state} = GraphqlSocket.init(state)

      assert :ok = Sessions.revoke(user, jti)
      topic = topic(jti)
      assert_receive %Broadcast{event: "disconnect", topic: ^topic} = message, 1_000

      assert {:stop, {:shutdown, :disconnected}, _state} =
               GraphqlSocket.handle_info(message, state)
    end
  end

  # --- the channel's re-check, with no broadcast -----------------------------

  describe "/ws/collab: the periodic re-check closes a room no broadcast reached" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "a session revoked silently" do
      site = org("sbs-backstop-revoked")
      user = platform_admin()
      page = page!(user, site)
      {token, jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      {:ok, socket} = collab_connect(token, site)
      channel = join!(socket, page).channel_pid

      revoke_silently!(jti)

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
      assert_receive %Broadcast{event: "disconnect", topic: "socket_disconnect"}, 1_000
      refute_received %Broadcast{event: "disconnect", topic: _}
    end

    test "a session gone idle with no page left to notice, recorded as a collab expiry" do
      site = org("sbs-backstop-idle")
      aged_policy!(site, %{idle_timeout_minutes: 15})
      user = platform_admin()
      page = page!(user, site)
      {token, jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      {:ok, socket} = collab_connect(token, site)
      channel = join!(socket, page).channel_pid

      idle_for!(jti, 16 * 60)

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
      assert %{purpose: "revocation", revoked_reason: "idle"} = row(jti)

      assert [%{metadata: %{"surface" => "collab", "timeout_minutes" => "15"}}] =
               events(site, :session_idle_expired)
    end

    test "an unbound session older than the site's \"sign out everyone\"" do
      site = org("sbs-backstop-stale")
      user = platform_admin()
      page = page!(user, site)

      {token, jti} =
        Tokens.collab_token_and_jti(user,
          session: %{created_at: DateTime.add(DateTime.utc_now(), -3600, :second)}
        )

      {:ok, socket} = collab_connect(token, site)
      channel = join!(socket, page).channel_pid

      # Bound to no site, so the sign-out itself neither revokes nor names it.
      sign_out_all!(site_admin(site), site)

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
      assert %{purpose: "revocation"} = row(jti)
    end

    test "a live session keeps its room open" do
      site = org("sbs-backstop-live")
      user = platform_admin()
      page = page!(user, site)
      token = Tokens.collab_token(user, session: %{org_id: site.id})
      {:ok, socket} = collab_connect(token, site)
      channel = join!(socket, page).channel_pid

      refute_receive {:EXIT, ^channel, _reason}, 300
    end
  end

  # --- connect refusals -------------------------------------------------------

  defp row_attrs(:revoked), do: %{purpose: "revocation"}
  defp row_attrs(:expired), do: %{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}
  defp row_attrs(:held), do: %{purpose: Token.second_factor_hold_purpose()}
  defp row_attrs(:remember_me), do: %{purpose: Token.remember_me_purpose()}

  describe "/ws/collab: a connect is refused for a session that is not a live sign-in" do
    # One test per row shape, so each refusal is proven on its own.
    for {shape, label} <- [
          revoked: "revoked",
          expired: "past its expiry",
          held: "held at the two-factor prompt",
          remember_me: "a remember-me cookie's row"
        ] do
      test "a session row #{label}" do
        site = org("sbs-refuse")
        user = editor(site)
        attrs = unquote(shape) |> row_attrs() |> Map.put(:org_id, site.id)

        assert :error = collab_connect(Tokens.collab_token(user, session: attrs), site)
      end
    end

    test "a jti naming no row at all" do
      site = org("sbs-refuse-missing")
      missing = CollabSocket.token(editor(site), false, "collab-session-never-stored")

      assert :error = collab_connect(missing, site)
    end

    test "idle on this site" do
      site = org("sbs-refuse-idle")
      aged_policy!(site, %{idle_timeout_minutes: 15})
      user = editor(site)
      {token, jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      idle_for!(jti, 16 * 60)

      assert :error = collab_connect(token, site)
      assert %{purpose: "revocation", revoked_reason: "idle"} = row(jti)
    end

    test "bound to another site" do
      site = org("sbs-refuse-foreign")
      elsewhere = org("sbs-refuse-foreign-b")
      user = editor(site) |> Fixtures.member!(elsewhere, :editor)
      token = Tokens.collab_token(user, session: %{org_id: elsewhere.id})

      assert :error = collab_connect(token, site)
      assert {:ok, _socket} = collab_connect(token, elsewhere)
    end

    test "a jti naming another account's session" do
      site = org("sbs-refuse-theirs")
      user = editor(site)
      theirs = Tokens.session!(editor(site), %{org_id: site.id})

      assert :error = collab_connect(CollabSocket.token(user, false, theirs), site)
      assert row(theirs).purpose == "user"
    end

    test "a refused connect leaves no subscription behind" do
      site = org("sbs-refuse-unsubscribed")
      user = editor(site)
      {token, jti} = Tokens.collab_token_and_jti(user, session: %{org_id: site.id})
      revoke_silently!(jti)

      assert :error = collab_connect(token, site)
      refute subscribed?(jti)

      SessionEviction.evict_session(jti, :test)
      refute_disconnected(jti)
    end

    test "an accepted connect is subscribed" do
      site = org("sbs-subscribed")
      {token, jti} = Tokens.collab_token_and_jti(editor(site), session: %{org_id: site.id})

      assert {:ok, socket} = collab_connect(token, site)
      assert socket.assigns.session_jti == jti
      assert subscribed?(jti)
    end
  end

  # --- rolling deploy ---------------------------------------------------------

  describe "/ws/collab across a rolling deploy" do
    test "a legacy token, naming no session, still connects per user, with no session check" do
      site = org("sbs-legacy")
      user = editor(site)

      assert {:ok, socket} = collab_connect(Tokens.legacy_collab_token(user), site)
      assert socket.assigns.session_jti == nil
      assert CollabSocket.id(socket) == SessionEviction.topic(user.id)
      refute KilnCMSWeb.CollabSocket.session_refused?(nil, user, site)
    end

    test "a new token reads as its user on a node still running the previous release" do
      user = Fixtures.seed_user()
      token = CollabSocket.token(user, true, "collab-session-any")

      # A frozen copy of the previous release's `claims/1`.
      previous_claims = fn
        %{"u" => user_id, "sf" => verified?} -> {user_id, verified? == true}
        user_id -> {user_id, false}
      end

      assert {:ok, claims} = Phoenix.Token.verify(@endpoint, "collab", token, max_age: 60)
      assert previous_claims.(claims) == {user.id, true}
    end

    test "no session, no token: nothing is minted without one" do
      user = Fixtures.seed_user()
      # A jti the type checker cannot see is nil, as a mount's may be.
      no_session = Process.get(:no_session_jti)
      assert_raise FunctionClauseError, fn -> CollabSocket.token(user, false, no_session) end
    end

    test "the editor mints its token for the session it is open in", %{conn: conn} do
      site = org("sbs-editor")
      user = platform_admin()

      page =
        CMS.create_page!(
          %{
            title: "Collab",
            slug: "sbs-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "rich_text", "legacy_html" => "<p>text</p>"}]
          },
          actor: user,
          tenant: site.id
        )

      conn = Fixtures.signed_in(conn, user, site)
      jti = jti_of(get_session(conn, "user_token"))

      {:ok, _lv, html} = live(conn, ~p"/editor/content/page/#{page.id}")
      [_, token] = Regex.run(~r/data-collab-token="([^"]+)"/, html)

      assert {:ok, %{"u" => user_id, "j" => ^jti}} =
               Phoenix.Token.verify(@endpoint, "collab", token, max_age: 60)

      assert user_id == user.id
    end
  end

  # --- /ws/gql ----------------------------------------------------------------

  describe "/ws/gql is bound to its bearer's own token row" do
    test "signing the bearer's token out drops its socket, and only its socket" do
      site = org("sbs-gql-revoke")
      user = editor(site)
      jwt = Fixtures.jwt(user)
      other = Fixtures.jwt(user)

      assert {:ok, socket} = gql_connect(site, jwt)
      assert {:ok, _other_socket} = gql_connect(site, other)
      assert socket.assigns.absinthe.opts[:context][:kiln_session_jti] == jti_of(jwt)

      assert :ok = Sessions.revoke(user, jti_of(jwt))
      assert_disconnected(jti_of(jwt))
      refute_disconnected(jti_of(other))
    end

    test "a lifted browser JWT bound to the site goes with the site's \"sign out everyone\"" do
      site = org("sbs-gql-lifted")
      user = editor(site)
      jwt = Fixtures.jwt(user)
      jti = jti_of(jwt)
      Sessions.bind_to_site([jti], site.id, AshAuthentication.user_to_subject(user))

      assert {:ok, _socket} = gql_connect(site, jwt)

      sign_out_all!(site_admin(site), site)
      assert_disconnected(jti)
    end

    test "a headless JWT, bound to no site, is untouched by the site's rules" do
      site = org("sbs-gql-headless")
      aged_policy!(site, %{idle_timeout_minutes: 15})
      user = editor(site)
      jwt = Fixtures.jwt(user)
      jti = jti_of(jwt)
      idle_for!(jti, 16 * 60)

      # Idle by the site's clock, yet connected: no idle check on a bearer.
      assert {:ok, socket} = gql_connect(site, jwt)
      {:ok, socket} = join_absinthe(socket)

      sign_out_all!(site_admin(site), site)
      refute_disconnected(jti)

      # And neither the watermark nor the idle timeout catches it afterwards.
      ref = push_doc(socket, "{ __typename }")
      assert_reply(ref, :ok, %{data: %{"__typename" => _}}, 1_000)
      assert {:ok, _socket} = gql_connect(site, jwt)
      assert row(jti).purpose == "user"
    end

    test "a refused connect leaves no subscription behind" do
      site = org("sbs-gql-unsubscribed")
      Fixtures.policy_row!(site, :editors)
      user = editor(site)
      jwt = Fixtures.jwt(user)

      # Held for a second factor: refused after the bearer verified.
      assert :error = gql_connect(site, jwt)
      refute subscribed?(jti_of(jwt))
    end

    test "an anonymous socket has no session" do
      site = org("sbs-gql-anonymous")

      assert {:ok, socket} =
               Phoenix.ChannelTest.connect(GraphqlSocket, %{}, connect_info: uri(site, "/ws/gql"))

      refute Map.has_key?(socket.assigns.absinthe.opts[:context], :kiln_session_jti)

      {:ok, socket} = join_absinthe(socket)
      ref = push_doc(socket, "{ __typename }")
      assert_reply(ref, :ok, %{data: %{"__typename" => _}}, 1_000)
    end
  end

  describe "/ws/gql refuses every document once its bearer is no longer a sign-in" do
    defp open_gql!(site) do
      user = editor(site)
      jwt = Fixtures.jwt(user)
      {:ok, socket} = gql_connect(site, jwt)
      {:ok, socket} = join_absinthe(socket)

      ref = push_doc(socket, "{ __typename }")
      assert_reply(ref, :ok, %{data: %{"__typename" => _}}, 1_000)

      {socket, jti_of(jwt)}
    end

    defp assert_unauthenticated(socket) do
      ref = push_doc(socket, "{ __typename }")

      assert_reply(
        ref,
        :error,
        %{errors: [%{extensions: %{code: "unauthenticated"}}]},
        1_000
      )
    end

    test "revoked with no broadcast" do
      site = org("sbs-gql-doc-revoked")
      {socket, jti} = open_gql!(site)
      revoke_silently!(jti)

      assert_unauthenticated(socket)
      # The context survives the refusal: the next one is refused the same way.
      assert_unauthenticated(socket)
    end

    test "expired" do
      site = org("sbs-gql-doc-expired")
      {socket, jti} = open_gql!(site)

      Repo.query!(
        "UPDATE tokens SET expires_at = (now() AT TIME ZONE 'utc') - interval '1 minute' WHERE jti = $1",
        [jti]
      )

      assert_unauthenticated(socket)
    end

    test "deleted" do
      site = org("sbs-gql-doc-deleted")
      {socket, jti} = open_gql!(site)
      Repo.query!("DELETE FROM tokens WHERE jti = $1", [jti])

      assert_unauthenticated(socket)
    end
  end
end
