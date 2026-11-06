defmodule KilnCMSWeb.Plugs.RejectInvalidBearerTest do
  @moduledoc """
  A bearer token that does not authenticate is a 401 when
  `:reject_invalid_bearer` is on, and an anonymous request (as before) when it
  is off (#2161).
  """
  # async: false — the flag is a global application env, and the telemetry
  # handler is attached to a global event.
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{Token, User}
  alias KilnCMSWeb.Plugs.RejectInvalidBearer

  @event [:kiln_cms, :api, :invalid_bearer]
  @gql ~s({"query": "{ __typename }"})

  setup do
    previous = Application.get_env(:kiln_cms, :reject_invalid_bearer)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kiln_cms, :reject_invalid_bearer),
        else: Application.put_env(:kiln_cms, :reject_invalid_bearer, previous)
    end)

    :ok
  end

  defp flag(value), do: Application.put_env(:kiln_cms, :reject_invalid_bearer, value)

  defp user! do
    Ash.Seed.seed!(User, %{
      email: "bearer-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp jwt!(user, opts \\ []) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{}, opts)
    token
  end

  defp api_key! do
    owner = user!()
    key = Accounts.mint_api_key!(owner.id, "reader", future(), actor: user!())
    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 30, :day)

  defp authorized(conn, value), do: put_req_header(conn, "authorization", value)

  defp gql(conn),
    do: conn |> put_req_header("content-type", "application/json") |> post("/gql", @gql)

  # What a refusal looks like, wherever it is mounted.
  defp assert_refusal(conn) do
    assert conn.status == 401
    assert conn.halted
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert "authorization" in vary(conn)
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
  end

  defp vary(conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  describe "the JSON:API surface, flag on" do
    setup do: flag(true)

    test "a garbage bearer is a 401 in the ApiError envelope", %{conn: conn} do
      conn = conn |> authorized("Bearer garbage") |> get(~p"/api/json/posts")

      assert_refusal(conn)

      assert %{
               "errors" => [
                 %{
                   "status" => "401",
                   "code" => "invalid_token",
                   "detail" => "The bearer token is missing, invalid or expired."
                 }
               ]
             } == Jason.decode!(conn.resp_body)
    end

    test "an expired JWT is refused with the same body as a malformed one", %{conn: conn} do
      expired = jwt!(user!(), token_lifetime: {-1, :minutes})

      garbage = conn |> authorized("Bearer garbage") |> get(~p"/api/json/posts")
      stale = conn |> authorized("Bearer #{expired}") |> get(~p"/api/json/posts")

      assert_refusal(stale)
      assert stale.resp_body == garbage.resp_body
    end

    test "a valid JWT is served as its user", %{conn: conn} do
      user = user!()
      conn = conn |> authorized("Bearer #{jwt!(user)}") |> get(~p"/api/json/posts")

      assert conn.status == 200
      assert conn.assigns.current_user.id == user.id
    end

    test "a revoked JWT is refused", %{conn: conn} do
      token = jwt!(user!())
      assert :ok = AshAuthentication.TokenResource.revoke(Token, token)

      assert conn |> authorized("Bearer #{token}") |> get(~p"/api/json/posts") |> assert_refusal()
    end

    test "a valid JWT for a deleted user is refused", %{conn: conn} do
      user = user!()
      token = jwt!(user)

      {1, _} =
        KilnCMS.Repo.delete_all(from(u in "users", where: u.id == type(^user.id, :binary_id)))

      assert conn |> authorized("Bearer #{token}") |> get(~p"/api/json/posts") |> assert_refusal()
    end

    test "a valid API key is served as its owner", %{conn: conn} do
      conn = conn |> authorized("Bearer #{api_key!()}") |> get(~p"/api/json/posts")
      assert conn.status == 200
    end

    test "an invalid API key is still the API-key plug's 401", %{conn: conn} do
      conn = conn |> authorized("Bearer kiln_deadbeef_00") |> get(~p"/api/json/posts")
      assert conn.status == 401
    end

    test "no header is anonymous", %{conn: conn} do
      assert conn |> get(~p"/api/json/posts") |> Map.fetch!(:status) == 200
    end

    test "another scheme is not a bearer", %{conn: conn} do
      conn = conn |> authorized("Basic dXNlcjpwYXNz") |> get(~p"/api/json/posts")
      assert conn.status == 200
    end

    test "the scheme is matched case-insensitively and with extra whitespace", %{conn: conn} do
      for value <- ["bearer garbage", "BEARER garbage", "Bearer    garbage", "  Bearer garbage"] do
        assert conn |> authorized(value) |> get(~p"/api/json/posts") |> Map.fetch!(:status) == 401,
               "expected #{inspect(value)} to be refused"
      end
    end

    test "an empty bearer value is invalid", %{conn: conn} do
      for value <- ["Bearer ", "Bearer"] do
        assert conn |> authorized(value) |> get(~p"/api/json/posts") |> Map.fetch!(:status) == 401,
               "expected #{inspect(value)} to be refused"
      end
    end

    test "every other scope on the :api pipeline refuses too", %{conn: conn} do
      for path <- ["/api/locales", "/api/search?q=a", "/api/content/post/nothing"] do
        conn = conn |> authorized("Bearer garbage") |> get(path)
        assert_refusal(conn)
      end
    end

    test "the refusal does not depend on :public_cache for its headers", %{conn: conn} do
      # `/api/locales` is on a scope without `:public_cache`.
      conn = conn |> authorized("Bearer garbage") |> get(~p"/api/locales")
      assert_refusal(conn)
    end
  end

  describe "the GraphQL surface, flag on" do
    setup do: flag(true)

    test "a garbage bearer is a 401 with a GraphQL-shaped error", %{conn: conn} do
      conn = conn |> authorized("Bearer garbage") |> gql()

      assert_refusal(conn)

      assert %{
               "errors" => [
                 %{
                   "message" => "The bearer token is missing, invalid or expired.",
                   "extensions" => %{"code" => "unauthenticated"}
                 }
               ]
             } == Jason.decode!(conn.resp_body)
    end

    test "a valid JWT and no header both run the query", %{conn: conn} do
      assert (conn |> authorized("Bearer #{jwt!(user!())}") |> gql()).status == 200
      assert (conn |> gql()).status == 200
    end

    test "a revoked JWT is refused", %{conn: conn} do
      token = jwt!(user!())
      :ok = AshAuthentication.TokenResource.revoke(Token, token)

      assert conn |> authorized("Bearer #{token}") |> gql() |> assert_refusal()
    end
  end

  describe "flag off (the default)" do
    setup do: flag(false)

    test "an unverifiable bearer is still served anonymously", %{conn: conn} do
      conn = conn |> authorized("Bearer garbage") |> get(~p"/api/json/posts")
      assert conn.status == 200
      refute conn.assigns[:current_user]
    end

    test "the same holds on /gql", %{conn: conn} do
      assert (conn |> authorized("Bearer garbage") |> gql()).status == 200
    end

    test "an unset flag behaves as off", %{conn: conn} do
      Application.delete_env(:kiln_cms, :reject_invalid_bearer)
      assert (conn |> authorized("Bearer garbage") |> get(~p"/api/json/posts")).status == 200
    end

    test "emits a telemetry event for the unverifiable bearer", %{conn: conn} do
      attach()
      conn |> authorized("Bearer garbage") |> get(~p"/api/json/posts")

      assert_receive {@event, %{count: 1}, %{pipeline: :api, enforced: false}}
    end

    test "no event for a request that is not an invalid bearer", %{conn: conn} do
      attach()
      get(conn, ~p"/api/json/posts")
      conn |> authorized("Bearer #{jwt!(user!())}") |> get(~p"/api/json/posts")

      refute_receive {@event, _, _}
    end
  end

  describe "flag on" do
    test "the event says it was enforced" do
      flag(true)
      attach()

      conn = build_conn() |> authorized("Bearer garbage") |> gql()

      assert conn.status == 401
      assert_receive {@event, %{count: 1}, %{pipeline: :graphql, enforced: true}}
    end
  end

  describe "invalid_bearer?/1 and the actor it looks at" do
    defp plug_conn(headers) do
      Enum.reduce(headers, Plug.Test.conn(:get, "/"), fn value, conn ->
        %{conn | req_headers: [{"authorization", value} | conn.req_headers]}
      end)
    end

    test "no actor from either source is invalid" do
      assert RejectInvalidBearer.invalid_bearer?(plug_conn(["Bearer x"]))
    end

    test "an actor set through Ash.PlugHelpers alone authenticates" do
      conn = plug_conn(["Bearer x"]) |> Ash.PlugHelpers.set_actor(%{id: 1})
      refute RejectInvalidBearer.invalid_bearer?(conn)
    end

    test "current_user alone authenticates" do
      conn = plug_conn(["Bearer x"]) |> Plug.Conn.assign(:current_user, %{id: 1})
      refute RejectInvalidBearer.invalid_bearer?(conn)
    end

    test "it does not look at the flag" do
      flag(false)
      assert RejectInvalidBearer.invalid_bearer?(plug_conn(["Bearer x"]))
    end

    test "any one of several authorization values being a bearer is enough" do
      assert RejectInvalidBearer.invalid_bearer?(plug_conn(["Basic abc", "Bearer x"]))
      assert RejectInvalidBearer.invalid_bearer?(plug_conn(["bearer x", "Basic abc"]))
      refute RejectInvalidBearer.invalid_bearer?(plug_conn(["Basic abc", "Digest y"]))
    end

    test "no header, an empty header and a lookalike scheme are not bearers" do
      refute RejectInvalidBearer.invalid_bearer?(plug_conn([]))
      refute RejectInvalidBearer.invalid_bearer?(plug_conn([""]))
      refute RejectInvalidBearer.invalid_bearer?(plug_conn(["Bearers x"]))
    end

    test "the plug halts only when the flag is on" do
      flag(true)
      conn = RejectInvalidBearer.call(plug_conn(["Bearer x"]), :api)
      assert conn.halted and conn.status == 401

      flag(false)
      conn = RejectInvalidBearer.call(plug_conn(["Bearer x"]), :api)
      refute conn.halted
    end
  end

  defp attach do
    id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      id,
      @event,
      fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
