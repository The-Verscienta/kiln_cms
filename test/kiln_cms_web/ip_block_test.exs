defmodule KilnCMSWeb.IpBlockTest do
  @moduledoc """
  The IP block list on every surface (#2242): the HTTP plug, `/live` joins, and
  the `/ws/gql`, `/ws/collab` and `/ws/bridge` connects.

  `async: false`: the rule cache is one named Cachex instance, and the telemetry
  handlers are node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.RateLimitHelpers, only: [client_conn: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.CMS
  alias KilnCMS.Security.IpBlocklist
  alias KilnCMSWeb.{BridgeSocket, CollabSocket, GraphqlSocket}

  @moduletag :capture_log

  setup do
    IpBlocklist.clear()
    on_exit(&IpBlocklist.clear/0)

    test_pid = self()
    handler = "ipb-refused-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :ip_block, :refused],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:refused, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ipb-web-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp block!(address, org_id \\ KilnCMS.Accounts.default_org_id()) do
    CMS.create_ip_block_rule!(
      %{cidr: address |> :inet.ntoa() |> to_string()},
      actor: admin(),
      tenant: org_id,
      context: %{client_ip: {192, 0, 2, 1}}
    )
  end

  defp connect_info(address),
    do: %{
      uri: URI.parse("http://localhost/"),
      peer_data: %{address: address, port: 111, ssl_cert: nil},
      x_headers: []
    }

  defp address, do: KilnCMS.RateLimitHelpers.client_address()

  describe "HTTP" do
    test "a blocked address gets a bare 403 with an empty body", %{conn: conn} do
      {conn, _key} = client_conn(conn)
      ip = conn.remote_ip
      block!(ip)

      conn = get(conn, "/sign-in")

      assert response(conn, 403) == ""
      assert get_resp_header(conn, "content-type") == []
      assert_received {:refused, %{count: 1}, %{surface: :http}}
    end

    test "an address that is not blocked is served", %{conn: conn} do
      {first, _key} = client_conn(conn)
      ip = first.remote_ip
      block!(ip)
      {other, _key} = client_conn(conn)

      assert html_response(get(other, "/sign-in"), 200)
      refute_received {:refused, _, _}
    end

    test "a rule in another org does not block this one", %{conn: conn} do
      {conn, _key} = client_conn(conn)
      ip = conn.remote_ip
      other = KilnCMS.OrgFixtures.org("ipb-web-other")
      block!(ip, other.id)

      assert html_response(get(conn, "/sign-in"), 200)
    end

    test "/up and /ready answer a blocked address", %{conn: conn} do
      {conn, _key} = client_conn(conn)
      ip = conn.remote_ip
      block!(ip)

      assert get(conn, "/up").status == 200
      assert get(conn, "/ready").status == 200
      refute_received {:refused, _, _}
    end

    test "loopback is never blocked", %{conn: conn} do
      assert {:error, _} =
               CMS.create_ip_block_rule(%{cidr: "127.0.0.1"},
                 actor: admin(),
                 tenant: KilnCMS.Accounts.default_org_id()
               )

      assert html_response(get(conn, "/sign-in"), 200)
    end
  end

  describe "/live" do
    test "a blocked address's root join is refused with a 403 reload", %{conn: conn} do
      {conn, _key} = client_conn(conn)
      ip = conn.remote_ip

      # The dead render passes (not blocked yet); the rule lands before the join.
      conn = get(conn, "/sign-in")
      assert html_response(conn, 200)
      block!(ip)

      assert {%{reason: "reload", status: 403}, _} = catch_exit(live(conn))
      assert_received {:refused, %{count: 1}, %{surface: :live}}
    end

    test "an unblocked address joins", %{conn: conn} do
      {conn, _key} = client_conn(conn)
      assert {:ok, _view, _html} = live(conn, "/sign-in")
    end

    test "every LiveView module carries the hook (public and console)" do
      for view <- [KilnCMSWeb.SignInLive, KilnCMSWeb.CodeInjectionLive] do
        hooks = view.__live__().lifecycle.mount
        assert Enum.any?(hooks, &match?(%{id: {KilnCMSWeb.IpBlock, _}}, &1)), inspect(hooks)
      end
    end

    test "the /live socket carries the connect info on both transports" do
      {"/live", Phoenix.LiveView.Socket, opts} =
        Enum.find(KilnCMSWeb.Endpoint.__sockets__(), &match?({"/live", _, _}, &1))

      for transport <- [:websocket, :longpoll] do
        info = opts |> Keyword.fetch!(transport) |> Keyword.fetch!(:connect_info)
        assert :uri in info and :peer_data in info and :x_headers in info
      end
    end
  end

  describe "sockets" do
    test "/ws/gql refuses a blocked address and accepts another" do
      ip = address()
      block!(ip)

      assert :error = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, connect_info(ip))
      assert_received {:refused, %{count: 1}, %{surface: :gql}}

      assert {:ok, _} = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, connect_info(address()))
    end

    test "/ws/collab refuses a blocked address even with a valid token" do
      user = admin()
      token = Phoenix.Token.sign(KilnCMSWeb.Endpoint, "collab", user.id)
      ip = address()
      block!(ip)

      assert :error =
               CollabSocket.connect(%{"token" => token}, %Phoenix.Socket{}, connect_info(ip))

      assert_received {:refused, %{count: 1}, %{surface: :collab}}

      assert {:ok, _} =
               CollabSocket.connect(
                 %{"token" => token},
                 %Phoenix.Socket{},
                 connect_info(address())
               )
    end

    test "/ws/bridge refuses a blocked address" do
      ip = address()
      block!(ip)

      assert :error =
               BridgeSocket.connect(%{
                 params: %{"type" => "post", "id" => Ash.UUID.generate()},
                 connect_info: connect_info(ip)
               })

      assert_received {:refused, %{count: 1}, %{surface: :bridge}}
    end

    test "a connect with no address is not refused by the block list" do
      block!(address())
      assert {:ok, _} = GraphqlSocket.connect(%{}, %Phoenix.Socket{}, %{})
    end
  end
end
