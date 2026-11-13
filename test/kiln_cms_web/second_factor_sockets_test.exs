defmodule KilnCMSWeb.SecondFactorSocketsTest do
  @moduledoc """
  The sockets under a site's second-factor requirement (#2247), a bearer that
  does not verify on `/ws/gql` (#2634), and the two process-wide settings
  that exempt someone: demo mode's shared account and the
  `KILN_API_REJECT_INVALID_BEARER` escape hatch.

  `async: false`: subscriptions register on the global endpoint registry, the
  collab prototype, its re-check interval, demo mode and the escape hatch are
  all `Application.put_env`. Each test still uses a site of its own, never the
  default org, whose cached policy every other module reads.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]
  import Phoenix.LiveViewTest, only: [live: 2, has_element?: 2]

  use Absinthe.Phoenix.SubscriptionTest, schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMS.CMS
  alias KilnCMS.SecondFactorFixtures, as: Fixtures
  alias KilnCMSWeb.CollabSocket
  alias KilnCMSWeb.GraphqlSocket

  @endpoint KilnCMSWeb.Endpoint
  @moduletag :capture_log

  # Must track SCHEMA_VSN in assets/js/collab.js.
  @schema_vsn 3

  defp uri(site, path), do: %{uri: URI.parse("wss://#{host(site)}#{path}")}
  defp host(site), do: "#{site.slug}.#{KilnCMSWeb.Tenant.base_host()}"

  defp gql_connect(site, params),
    do: Phoenix.ChannelTest.connect(GraphqlSocket, params, connect_info: uri(site, "/ws/gql"))

  defp grace_policy!(site, opts \\ []) do
    Fixtures.policy_row!(site, Keyword.get(opts, :required_for, :editors),
      grace_days: 30,
      since: DateTime.utc_now()
    )
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

  # --- /ws/gql -----------------------------------------------------------------

  describe "/ws/gql and a bearer that does not verify (#2634)" do
    test "is refused, not served as anonymous" do
      site = org("sfs-stale")
      user = Fixtures.editor(site)
      {:ok, expired, _} = AshAuthentication.Jwt.token_for_user(user, %{"exp" => 1})

      revoked = Fixtures.jwt(user)
      :ok = KilnCMSWeb.AuthController.revoke_first_factor(revoked)

      for token <- ["garbage", "not.a.jwt", expired, revoked, "kiln_deadbeef_00"] do
        assert :error = gql_connect(site, %{"token" => token}), "#{token} connected"
      end

      assert :error = gql_connect(site, %{"Authorization" => "Bearer garbage"})
    end

    test "no bearer still connects anonymously, a good one as its account" do
      site = org("sfs-ok")
      assert {:ok, anonymous} = gql_connect(site, %{})
      assert GraphqlSocket.id(anonymous) == nil

      user = Fixtures.editor(site)
      assert {:ok, signed_in} = gql_connect(site, %{"token" => Fixtures.jwt(user)})
      assert GraphqlSocket.id(signed_in) == KilnCMS.Accounts.SessionEviction.topic(user.id)
    end

    test "the escape hatch serves it as anonymous again" do
      put_env(KilnCMSWeb.Plugs.ApiKeyAuth, reject_invalid_bearer: false)
      site = org("sfs-hatch")

      assert {:ok, socket} = gql_connect(site, %{"token" => "garbage"})
      assert GraphqlSocket.id(socket) == nil
    end
  end

  describe "/ws/gql and the second-factor requirement" do
    test "a JWT minted in grace connects, and is refused at connect past the deadline" do
      site = org("sfs-gql-connect")
      row = grace_policy!(site)
      token = site |> Fixtures.editor() |> Fixtures.jwt()

      assert {:ok, _socket} = gql_connect(site, %{"token" => token})

      Fixtures.end_grace!(row)
      assert :error = gql_connect(site, %{"token" => token})
    end

    test "every document past the deadline is refused on an open socket" do
      site = org("sfs-gql-doc")
      row = grace_policy!(site)
      token = site |> Fixtures.editor() |> Fixtures.jwt()

      {:ok, socket} = gql_connect(site, %{"token" => token})
      {:ok, socket} = join_absinthe(socket)

      ref = push_doc(socket, "{ __typename }")
      assert_reply(ref, :ok, %{data: %{"__typename" => _}}, 1_000)

      Fixtures.end_grace!(row)

      ref = push_doc(socket, "{ __typename }")

      assert_reply(
        ref,
        :error,
        %{errors: [%{extensions: %{code: "second_factor_required"}}]},
        1_000
      )
    end

    test "a socket opened in grace is closed at the deadline" do
      site = org("sfs-gql-close")
      since = DateTime.add(DateTime.utc_now(), -86_400 * 1000 + 300, :millisecond)
      Fixtures.policy_row!(site, :editors, grace_days: 1, since: since)
      token = site |> Fixtures.editor() |> Fixtures.jwt()

      # `connect/3` runs in the calling process — here the test, in production
      # the transport — so the close it arms is delivered here.
      assert {:ok, _socket} = gql_connect(site, %{"token" => token})
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 2_000
    end

    test "a passkey-only account's JWT is refused past the deadline" do
      site = org("sfs-gql-pko")
      user = Fixtures.editor(site)
      {:ok, _} = KilnCMS.PasskeyFixtures.enroll(user, "sfs-gql-pko-#{user.id}")
      row = grace_policy!(site)
      token = Fixtures.jwt(user)

      {:ok, socket} = gql_connect(site, %{"token" => token})
      {:ok, socket} = join_absinthe(socket)

      Fixtures.end_grace!(row)
      assert :error = gql_connect(site, %{"token" => token})

      ref = push_doc(socket, "{ __typename }")

      assert_reply(
        ref,
        :error,
        %{errors: [%{extensions: %{code: "second_factor_required"}}]},
        1_000
      )
    end

    test "an enrolled account and an unrequired site are untouched" do
      site = "sfs-gql-free" |> org()
      Fixtures.policy_row!(site, :editors)

      enrolled =
        site |> Fixtures.editor() |> Ash.Seed.update!(%{totp_confirmed_at: DateTime.utc_now()})

      assert {:ok, _} = gql_connect(site, %{"token" => Fixtures.jwt(enrolled)})

      free = org("sfs-gql-free-b")
      held = site |> Fixtures.editor() |> Fixtures.member!(free, :editor)
      assert {:ok, _} = gql_connect(free, %{"token" => Fixtures.jwt(held)})
      assert :error = gql_connect(site, %{"token" => Fixtures.jwt(held)})
    end
  end

  # --- /ws/collab --------------------------------------------------------------

  describe "/ws/collab" do
    setup do
      put_env(:collab_prototype, true)
      put_env(:socket_reauth_interval_ms, 50)
      Process.flag(:trap_exit, true)
      :ok
    end

    defp collab_token(user), do: Phoenix.Token.sign(@endpoint, "collab", user.id)

    defp collab_connect(user, site),
      do:
        Phoenix.ChannelTest.connect(CollabSocket, %{"token" => collab_token(user)},
          connect_info: uri(site, "/ws/collab")
        )

    # A platform administrator: an administrator on every site, so the page
    # needs no membership to be edited.
    defp admin, do: Fixtures.seed_user(%{role: :admin})

    test "a passkey-only account past the deadline needs a token from a verified session" do
      site = org("sfs-collab-pko")
      user = Fixtures.seed_user(%{role: :admin})
      {:ok, _} = KilnCMS.PasskeyFixtures.enroll(user, "sfs-pko-#{user.id}")
      Fixtures.policy_row!(site, :admins)

      connect = fn token ->
        Phoenix.ChannelTest.connect(CollabSocket, %{"token" => token},
          connect_info: uri(site, "/ws/collab")
        )
      end

      assert :error = connect.(collab_token(user))
      assert :error = connect.(CollabSocket.token(user, false))
      assert {:ok, _socket} = connect.(CollabSocket.token(user, true))
    end

    test "a held account is refused at connect" do
      site = org("sfs-collab-held")
      Fixtures.policy_row!(site, :admins)

      assert :error = collab_connect(admin(), site)
    end

    test "an open room closes when its account crosses the deadline" do
      site = org("sfs-collab-close")
      row = grace_policy!(site, required_for: :admins)
      user = admin()

      page =
        CMS.create_page!(
          %{title: "Collab", slug: "sfs-#{System.unique_integer([:positive])}"},
          actor: user,
          tenant: site.id
        )

      {:ok, socket} = collab_connect(user, site)

      {:ok, _reply, joined} =
        subscribe_and_join(socket, "collab:page:#{page.id}", %{"vsn" => @schema_vsn})

      channel = joined.channel_pid
      Fixtures.end_grace!(row)

      assert_receive {:EXIT, ^channel, {:shutdown, :unauthorized}}, 2_000
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 2_000
    end
  end

  # --- demo mode ---------------------------------------------------------------

  describe "demo mode's shared account" do
    setup do
      previous = Application.get_env(:kiln_cms, KilnCMS.Demo, [])
      Application.put_env(:kiln_cms, KilnCMS.Demo, Keyword.put(previous, :enabled, true))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Demo, previous) end)
      :ok
    end

    test "is never held: it could never set a factor up", %{conn: conn} do
      site = org("sfs-demo")
      Fixtures.policy_row!(site, :everyone)
      user = Fixtures.editor(site)

      assert html_response(conn |> Fixtures.signed_in(user, site) |> get(~p"/account"), 200)
      assert {:ok, _} = gql_connect(site, %{"token" => Fixtures.jwt(user)})

      assert json_response(
               build_conn()
               |> org_conn(site)
               |> put_req_header("authorization", "Bearer " <> Fixtures.jwt(user))
               |> get(~p"/api/locales"),
               200
             )
    end

    test "gets no grace-period reminder", %{conn: conn} do
      site = org("sfs-demo-banner")
      grace_policy!(site, required_for: :everyone)
      user = Fixtures.editor(site)

      {:ok, view, _html} = conn |> Fixtures.signed_in(user, site) |> live(~p"/account")

      refute has_element?(view, "#second-factor-banner")
    end

    test "is never evicted by a policy that holds everyone at once" do
      site = org("sfs-demo-evict")
      {admin, _secret} = KilnCMS.TwoFactorFixtures.enabled_user(role: :viewer)
      admin = Fixtures.member!(admin, site, :admin)
      user = Fixtures.editor(site)
      topic = KilnCMS.Accounts.SessionEviction.topic(user.id)
      @endpoint.subscribe(topic)

      assert {:ok, _row} =
               CMS.save_site_second_factor_policy(%{required_for: :everyone, grace_days: 0},
                 actor: admin,
                 tenant: site.id,
                 context: %{second_factor_verified_at: DateTime.utc_now()}
               )

      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
    end
  end
end
