defmodule KilnCMSWeb.ApiSpecsTest do
  @moduledoc """
  The API specs where production closes them: an API key opens the OpenAPI
  document and the GraphQL SDL, and nothing else does.

  Production turns off GraphQL introspection and the OpenAPI document (#567),
  which is right for a stranger and left a client author with nothing to run
  codegen against on their own site. An admin-minted key is the credential that
  says "an integration this site chose"; a JWT is not, because open
  registration hands one to anybody.

  `async: false`: both flags are process-wide application config.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts

  @password "password123456"
  @spec_path "/api/json/open_api"
  @explorer_path "/api/json/swaggerui"
  @sdl_path "/api/graphql/schema.graphql"

  defp put_flag(key, value) do
    previous = Application.get_env(:kiln_cms, key)
    Application.put_env(:kiln_cms, key, value)
    on_exit(fn -> Application.put_env(:kiln_cms, key, previous) end)
  end

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "specs-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp api_key(access) do
    key =
      Accounts.mint_api_key!(
        user(:viewer).id,
        "codegen",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp jwt do
    strategy = AshAuthentication.Info.strategy!(Accounts.User, :password)
    viewer = user(:viewer)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => viewer.email,
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp get_with(path, accept, bearer) do
    build_conn()
    |> put_req_header("accept", accept)
    |> then(fn conn ->
      if bearer, do: put_req_header(conn, "authorization", "Bearer " <> bearer), else: conn
    end)
    |> get(path)
  end

  describe "the OpenAPI document, with the docs turned off" do
    setup do
      put_flag(:api_docs, false)
      :ok
    end

    test "a read-only key opens it" do
      conn = get_with(@spec_path, "application/json", api_key(:read))

      assert %{"openapi" => _, "paths" => paths} = Jason.decode!(response(conn, 200))
      assert Map.has_key?(paths, "/api/json/posts")
    end

    test "a read_write key opens it too — the document describes, the key's scope enforces" do
      conn = get_with(@spec_path, "application/json", api_key(:read_write))

      assert response(conn, 200)
    end

    test "a JWT does not" do
      conn = get_with(@spec_path, "application/json", jwt())

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end

    test "no credential does not" do
      assert json_response(get_with(@spec_path, "application/json", nil), 404)
    end

    test "an invalid key is refused by the key plug, before the gate" do
      conn = get_with(@spec_path, "application/json", "kiln_not_a_real_key_000000")

      assert conn.status == 401
    end

    test "the explorer stays closed even to a key" do
      conn = get_with(@explorer_path, "text/html", api_key(:read))

      assert conn.status == 404
      refute conn.resp_body =~ "swagger-ui"
    end
  end

  describe "the GraphQL SDL, with introspection turned off" do
    setup do
      put_flag(:graphql_introspection, false)
      :ok
    end

    test "a key gets the running schema" do
      conn = get_with(@sdl_path, "application/graphql", api_key(:read))

      body = response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/graphql"
      assert body =~ "schema {"
      assert body =~ "type RootQueryType"
      # Personalised by credential, so no shared cache may keep it.
      assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
    end

    test "it is the same rendering the committed file is made from" do
      conn = get_with(@sdl_path, "*/*", api_key(:read))

      assert response(conn, 200) == KilnCMSWeb.ApiSpecs.graphql_sdl()
    end

    test "a JWT does not get it" do
      assert json_response(get_with(@sdl_path, "application/json", jwt()), 404)
    end

    test "no credential does not get it" do
      conn = get_with(@sdl_path, "application/json", nil)

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end

    test "a codegen tool's Accept header is not a 406" do
      # The route is deliberately outside `:api`, whose `accepts ["json"]`
      # would refuse this before the controller ran.
      conn = get_with(@sdl_path, "application/graphql, text/plain", api_key(:read))

      assert conn.status == 200
    end
  end

  describe "the GraphQL SDL, with introspection on" do
    setup do
      put_flag(:graphql_introspection, true)
      :ok
    end

    test "anyone gets it — it says nothing introspection would not" do
      assert get_with(@sdl_path, "*/*", nil) |> response(200) =~ "type RootQueryType"
    end
  end

  describe "the committed renderings" do
    test "the SDL sorts its type definitions, so an unchanged schema regenerates identically" do
      names =
        Regex.scan(
          ~r/^(?:type|input|enum|interface|union|scalar) (\w+)/m,
          KilnCMSWeb.ApiSpecs.graphql_sdl(),
          capture: :all_but_first
        )
        |> List.flatten()

      assert names != []
      assert names == Enum.sort(names)
    end

    test "the OpenAPI document names a placeholder origin, not this host, and both auth schemes" do
      spec = Jason.decode!(KilnCMSWeb.ApiSpecs.open_api())

      assert [%{"url" => "{origin}", "variables" => %{"origin" => %{"default" => _}}}] =
               spec["servers"]

      assert %{"apiKeyAuth" => %{"scheme" => "bearer"}, "bearerAuth" => _} =
               spec["components"]["securitySchemes"]

      assert Map.has_key?(spec["paths"], "/api/graphql/schema.graphql")
    end

    test "the OpenAPI document's objects are key-sorted all the way down" do
      text = KilnCMSWeb.ApiSpecs.open_api()

      assert text == text |> Jason.decode!() |> sorted_json()
    end
  end

  defp sorted_json(term) do
    term
    |> sort_keys()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {k, v} -> {k, sort_keys(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(value), do: value
end
