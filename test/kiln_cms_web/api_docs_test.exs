defmodule KilnCMSWeb.ApiDocsTest do
  @moduledoc """
  The API documentation surface is served only where it is turned on (#567).

  The OpenAPI document and its explorer shipped unauthenticated in every
  environment, production included — unlike `/dev/dashboard`, `/dev/mailbox`,
  `/admin` and the GraphQL playground, which are all behind `dev_routes`.

  Disclosure rather than access: every route the spec describes is still
  enforced by the Ash policies and the API key's scope. What it removes is the
  guesswork, and since #330 the described surface includes the **write** routes
  — so the document is a complete machine-readable map of the mutation API,
  sitting next to a GraphQL endpoint whose introspection production already
  disables. That inconsistency is what this closes.

  `async: false`: the flag is process-wide application config.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMSWeb.Plugs.ApiDocs

  @spec_path "/api/json/open_api"
  @explorer_path "/api/json/swaggerui"

  defp set_api_docs(value) do
    previous = Application.get_env(:kiln_cms, :api_docs)
    Application.put_env(:kiln_cms, :api_docs, value)
    on_exit(fn -> Application.put_env(:kiln_cms, :api_docs, previous) end)
  end

  describe "enabled" do
    setup do
      set_api_docs(true)
      :ok
    end

    test "the OpenAPI document is served", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get(@spec_path)

      # `response/2` rather than `json_response/2`: AshJsonApi serves the spec
      # with no content-type header at all, which is its own small oddity and
      # not this change's business.
      assert %{"openapi" => _, "paths" => paths} = Jason.decode!(response(conn, 200))
      assert map_size(paths) > 0
    end

    test "the explorer is served", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/html") |> get(@explorer_path)

      assert html_response(conn, 200) =~ "swagger"
    end

    # A response `?fields[post]=path,effective_seo_title` legitimately produces
    # was undocumented by its own OpenAPI schema (#1139): AshJsonApi describes
    # public calculations when generating the spec, but nothing pinned that
    # the content resources' schemas actually carry them, so a regression here
    # (a calc losing `public? true`, or a future ash_json_api version reverting
    # to attributes-only) would silently make the doc lie again.
    test "public calculations are described on a content resource's schema", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get(@spec_path)
      spec = Jason.decode!(response(conn, 200))

      post_attrs =
        get_in(spec, [
          "components",
          "schemas",
          "post",
          "properties",
          "attributes"
        ])

      calculated_fields = ~w(
        path effective_seo_title effective_seo_description published
        word_count reading_time_minutes related_links
      )

      for field <- calculated_fields do
        assert Map.has_key?(post_attrs["properties"], field),
               "expected the \"post\" schema's attributes to describe #{field}"
      end

      # additionalProperties: false means a client generated from this spec
      # would REJECT a response carrying an undescribed field — the failure
      # mode #1139 reported.
      assert post_attrs["additionalProperties"] == false
    end
  end

  describe "disabled" do
    setup do
      set_api_docs(false)
      :ok
    end

    test "the OpenAPI document is 404, in the standard envelope", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get(@spec_path)

      # 404 rather than 403: a 403 confirms the route exists and is merely
      # closed, which is the one thing a disabled docs endpoint should not
      # volunteer. A disabled instance answers as an unrouted path does.
      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end

    test "the explorer is 404", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/html") |> get(@explorer_path)

      assert response(conn, 404)
    end

    test "an encoded segment does not walk past it" do
      # The bypass this class is built on. `Phoenix.Router` decodes each segment
      # to pick a route but leaves `conn.path_info` raw, so a literal comparison
      # in the plug sees `%73waggerui` while the `forward "/swaggerui"` sees
      # `swaggerui`. Before the fix each of these served the whole explorer,
      # relaxed CSP and all, with the flag off.
      # The accept header follows the pipeline each path lands in, so a 406 from
      # `:accepts` cannot be mistaken for the gate doing its job.
      for {path, accept} <- [
            {"/api/json/%73waggerui", "text/html"},
            {"/api/json/swagger%75i", "text/html"},
            {"/api/json/%73%77aggerui", "text/html"},
            {"/api/json/%73waggerui/index.html", "text/html"},
            {"/api/json/%6Fpen_api", "application/json"}
          ] do
        conn = build_conn() |> put_req_header("accept", accept) |> get(path)

        assert conn.status == 404, "#{path} was served with the docs disabled"
        refute conn.resp_body =~ "swagger-ui"
      end
    end

    test "a sub-path under the explorer is gated too" do
      conn =
        build_conn()
        |> put_req_header("accept", "text/html")
        |> get("/api/json/swaggerui/index.html")

      assert conn.status == 404
    end

    test "every verb is gated, not just GET" do
      for verb <- [:head, :post, :options, :put, :delete] do
        conn = dispatch(build_conn(), @endpoint, verb, @explorer_path)
        assert conn.status == 404, "#{verb} reached the explorer"
      end
    end

    test "the content routes it sits in front of are untouched" do
      # The gate lives in the `:api` pipeline, because the spec is served from
      # inside the `AshJsonApiRouter` forward and has no route of its own here.
      # So the thing most worth pinning is that it passes everything else
      # through: a flag that 404s the whole headless API would be a far worse
      # bug than the one it fixes. Asserted per path, because a blanket
      # `refute status == 500` would pass on the very 404 that regression
      # produces.
      for {path, accept, expected} <- [
            {"/api/json/posts", "application/vnd.api+json", 200},
            {"/api/locales", "application/json", 200},
            {"/api/search?q=x", "application/json", 200},
            {"/api/content/page/nothing-here", "application/json", 404}
          ] do
        conn = build_conn() |> put_req_header("accept", accept) |> get(path)

        assert conn.status == expected,
               "#{path} answered #{conn.status}, expected #{expected} — the docs gate " <>
                 "must pass every non-documentation request through"
      end
    end

    test "a path that merely starts the same is not gated", %{conn: conn} do
      # `open_api` and `swaggerui` are matched as whole path segments. Asserted
      # against the *router's* 404 body rather than the status, because the gate
      # 404s too — only the shape tells them apart.
      conn =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/json/open_api_notes")

      assert conn.status == 404
      refute conn.resp_body =~ ~s("code":"not_found")
    end
  end

  describe "the shipped posture" do
    test "production defaults to off, everywhere else to on" do
      # Read from the config files rather than restated here, so this fails if
      # someone flips the default rather than agreeing with itself.
      assert Application.get_env(:kiln_cms, :api_docs) == true,
             "dev/test should serve the docs"

      prod = Config.Reader.read!("config/prod.exs", env: :prod)
      assert get_in(prod, [:kiln_cms, :api_docs]) == false, "production should not"
    end

    test "enabled?/0 is the single reader" do
      set_api_docs(false)
      refute ApiDocs.enabled?()

      Application.put_env(:kiln_cms, :api_docs, true)
      assert ApiDocs.enabled?()
    end
  end
end
