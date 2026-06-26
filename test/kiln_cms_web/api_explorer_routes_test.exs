defmodule KilnCMSWeb.ApiExplorerRoutesTest do
  @moduledoc """
  GraphQL playground and JSON:API Swagger UI are dev-only explorer tools. In
  test/prod (`dev_routes` false) they must not be mounted. The machine-readable
  JSON:API OpenAPI spec, by contrast, is published in all environments (#37).
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

  test "JSON:API Swagger UI is not served without dev_routes" do
    refute dev_routes?()

    conn = get(build_conn(), "/api/json/swaggerui")

    assert response(conn, 404)
    refute explorer_html?(conn)

    assert ["application/vnd.api+json" <> _] = get_resp_header(conn, "content-type")
  end

  test "OpenAPI spec is published even without dev_routes (issue #37)" do
    refute dev_routes?()

    conn = get(build_conn(), "/api/json/open_api")
    spec = conn |> response(200) |> Jason.decode!()

    # Self-describing metadata applied by KilnCMSWeb.OpenApi.
    assert spec["openapi"] =~ "3."
    assert spec["info"]["title"] == KilnCMSWeb.OpenApi.title()
    assert spec["info"]["version"] == KilnCMSWeb.OpenApi.version()
    assert spec["info"]["description"] =~ "Authentication"

    # Covers auth: the bearer security scheme is declared and applied globally.
    assert get_in(spec, ["components", "securitySchemes", "bearerAuth", "scheme"]) == "bearer"
    assert Enum.any?(spec["security"], &Map.has_key?(&1, "bearerAuth"))

    # Covers the core content endpoints.
    paths = Map.keys(spec["paths"])
    assert Enum.any?(paths, &String.contains?(&1, "/pages"))
    assert Enum.any?(paths, &String.contains?(&1, "/posts"))
    assert Enum.any?(paths, &String.contains?(&1, "/media-items"))
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
