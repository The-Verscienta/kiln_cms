defmodule KilnCMSWeb.ApiExplorerRoutesTest do
  @moduledoc """
  Route availability for the headless API explorers.

  The **GraphQL playground** stays a dev-only convenience. The **OpenAPI spec**
  and its **Swagger UI** are published in every environment (issue #37), so this
  suite — which runs with `dev_routes` false — asserts they are reachable here.
  """
  use KilnCMSWeb.ConnCase, async: true

  test "GraphQL playground UI is not served without dev_routes" do
    refute dev_routes?()

    # `/gql/playground` falls through to the headless Absinthe plug (no GraphiQL
    # UI) — a JSON error, not an interactive explorer page.
    conn = get(build_conn(), "/gql/playground")

    assert json_response(conn, 400)
    refute explorer_html?(conn)
  end

  test "Swagger UI is served in all environments" do
    refute dev_routes?()

    conn = get(build_conn(), "/api/json/swaggerui")

    assert html = html_response(conn, 200)
    assert html =~ "swagger-ui"
    # The inline boot script runs under a per-request nonce, not 'unsafe-inline'.
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src 'self' 'nonce-"
    refute csp =~ "unsafe-eval"
  end

  test "OpenAPI spec is served in all environments" do
    refute dev_routes?()

    conn = get(build_conn(), "/api/json/open_api")

    # AshJsonApi's spec controller sends the JSON body without a JSON
    # content-type header, so decode the raw body rather than `json_response/2`.
    assert conn.status == 200
    spec = Jason.decode!(conn.resp_body)
    assert spec["openapi"] =~ "3."
    assert spec["info"]["title"] == "KilnCMS Headless API"
    assert is_binary(spec["info"]["description"])
    # Covers auth: the bearer scheme is published and applied as *optional*
    # (an empty requirement sits alongside it).
    assert spec["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
    assert %{} in spec["security"]
    assert %{"bearerAuth" => []} in spec["security"]
    # Covers core content endpoints (paths carry the mount prefix).
    assert Map.has_key?(spec["paths"], "/api/json/pages")
    assert Map.has_key?(spec["paths"], "/api/json/posts")
    # Covers auth: the headless sign-in endpoint is documented and public.
    assert get_in(spec, ["paths", "/api/auth/sign_in", "post", "operationId"]) == "signIn"
    assert get_in(spec, ["paths", "/api/auth/sign_in", "post", "security"]) == []

    # #191: the artifact + preview delivery surfaces are documented as operations.
    assert get_in(spec, ["paths", "/api/content/{type}/{slug}", "get", "operationId"]) ==
             "getArtifact"

    assert get_in(spec, ["paths", "/preview/{token}", "get", "operationId"]) == "getPreview"
  end

  test "headless GraphQL endpoint remains available" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/gql", ~s({"query": "{ health }"}))

    assert %{"data" => %{"health" => "ok"}} = json_response(conn, 200)
  end

  defp dev_routes?, do: Application.get_env(:kiln_cms, :dev_routes, false)

  defp explorer_html?(conn) do
    ct = get_resp_header(conn, "content-type") |> List.first() || ""

    String.starts_with?(ct, "text/html") and
      (String.contains?(conn.resp_body, "swagger") or
         String.contains?(conn.resp_body, "graphiql"))
  end
end
