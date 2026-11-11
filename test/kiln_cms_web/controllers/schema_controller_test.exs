defmodule KilnCMSWeb.SchemaControllerTest do
  @moduledoc """
  `GET /api/schema` — the live delivery schema for the requesting site (#430).
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  test "serves the block union and one document schema per content type", %{conn: conn} do
    body = conn |> get(~p"/api/schema") |> json_response(200)

    assert body["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert Map.has_key?(body["$defs"], "block")
    assert Map.has_key?(body["$defs"], "block_heading")
    assert Map.has_key?(body["$defs"], "content_page")
    assert "#/$defs/content_page" in Enum.map(body["oneOf"], & &1["$ref"])
  end

  # `Tenant.base_url/1` rather than the raw request host: it is the origin
  # sitemap, feeds and canonical tags already agree on, and it honours an org's
  # `custom_domain` instead of echoing back whichever host was dialled.
  test "the $id follows the site's own base URL", %{conn: conn} do
    body = conn |> get(~p"/api/schema") |> json_response(200)

    assert body["$id"] ==
             KilnCMSWeb.Tenant.base_url(KilnCMS.Accounts.default_org_id()) <> "/api/schema"
  end

  test "is cacheable by shared caches", %{conn: conn} do
    conn = get(conn, ~p"/api/schema")
    assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
  end

  test "?type= restricts the export", %{conn: conn} do
    body = conn |> get(~p"/api/schema?type=post") |> json_response(200)

    assert body["x-kiln"]["content_types"] == ["post"]
    refute Map.has_key?(body["$defs"], "content_page")
  end

  test "?blocks=only drops the documents", %{conn: conn} do
    body = conn |> get(~p"/api/schema?blocks=only") |> json_response(200)

    assert body["x-kiln"]["content_types"] == []
    assert Map.has_key?(body["$defs"], "block")
    refute Map.has_key?(body, "oneOf")
  end

  test "an unknown type name is a 400 naming it, not a silent full export", %{conn: conn} do
    body = conn |> get(~p"/api/schema?type=nope") |> json_response(400)

    assert body["errors"] |> hd() |> Map.get("code") == "invalid_type"
    assert body["errors"] |> hd() |> Map.get("detail") =~ "nope"
  end

  # `oneOf` means *exactly one*, so a duplicated `$ref` would make every post
  # match two branches — a published document failing its own published schema.
  test "a repeated ?type= is deduplicated rather than published twice", %{conn: conn} do
    body = conn |> get(~p"/api/schema?type=post,post,post") |> json_response(200)

    assert body["x-kiln"]["content_types"] == ["post"]
    assert Enum.map(body["oneOf"], & &1["$ref"]) == ["#/$defs/content_post"]
  end

  test "?blocks=only still rejects an unknown type name", %{conn: conn} do
    body = conn |> get(~p"/api/schema?blocks=only&type=nope") |> json_response(400)
    assert body["errors"] |> hd() |> Map.get("code") == "invalid_type"
  end

  test "the tenant id is not published", %{conn: conn} do
    body = conn |> get(~p"/api/schema") |> json_response(200)

    refute body["x-kiln"]["org_id"]
    refute Jason.encode!(body) =~ KilnCMS.Accounts.default_org_id()
  end

  test "an admin-defined custom field shows up without a redeploy", %{conn: conn} do
    actor = admin()

    CMS.create_field_definition!(
      %{content_type: :page, name: "subtitle", label: "Subtitle", field_type: :string},
      actor: actor
    )

    body = conn |> get(~p"/api/schema") |> json_response(200)

    assert Map.has_key?(
             body["$defs"]["content_page"]["properties"]["custom_fields"]["properties"],
             "subtitle"
           )
  end

  # The document is cached per org, so this is also the invalidation test: the
  # first GET warms it and the write must evict it, or the new field would stay
  # invisible for the TTL. `Changes.BustTypeRegistry` fires on FieldDefinition
  # writes, which is what `Cache.delivery_schema_key/1` hangs off.
  test "a cached document is evicted by a registry write", %{conn: conn} do
    warm = conn |> get(~p"/api/schema") |> json_response(200)

    refute Map.has_key?(
             warm["$defs"]["content_page"]["properties"]["custom_fields"]["properties"],
             "later"
           )

    CMS.create_field_definition!(
      %{content_type: :page, name: "later", label: "Later", field_type: :string},
      actor: admin()
    )

    # A fresh conn so the read cannot ride this test's warmed plug state — but
    # with its own address: a bare `build_conn/0` peers from 127.0.0.1, the one
    # rate-limit bucket every other bare conn in the suite charges (#1356).
    body = build_conn() |> unique_ip() |> get(~p"/api/schema") |> json_response(200)

    assert Map.has_key?(
             body["$defs"]["content_page"]["properties"]["custom_fields"]["properties"],
             "later"
           )
  end

  # A section layout (#2280) is not a field or a type, so it has its own bust
  # (`Changes.BustFieldLayout`); without it a tab layout would stay out of the
  # cached document for the TTL.
  test "a cached document is evicted by a section layout write", %{conn: conn} do
    actor = admin()

    CMS.create_field_definition!(
      %{content_type: :page, name: "dosage", label: "Dosage", section: "Clinical"},
      actor: actor
    )

    warm = conn |> get(~p"/api/schema") |> json_response(200)
    dosage = warm["$defs"]["content_page"]["properties"]["custom_fields"]["properties"]["dosage"]
    refute Map.has_key?(dosage, "x-kiln-section-display")

    section =
      CMS.create_field_section!(%{content_type: :page, name: "Clinical", display: :tab},
        actor: actor
      )

    body = build_conn() |> unique_ip() |> get(~p"/api/schema") |> json_response(200)
    dosage = body["$defs"]["content_page"]["properties"]["custom_fields"]["properties"]["dosage"]
    assert dosage["x-kiln-section-display"] == "tab"

    CMS.update_field_section!(section, %{display: :fieldset}, actor: actor)

    body = build_conn() |> unique_ip() |> get(~p"/api/schema") |> json_response(200)
    dosage = body["$defs"]["content_page"]["properties"]["custom_fields"]["properties"]["dosage"]
    assert dosage["x-kiln-section-display"] == "fieldset"

    CMS.destroy_field_section!(section, actor: actor)

    body = build_conn() |> unique_ip() |> get(~p"/api/schema") |> json_response(200)
    dosage = body["$defs"]["content_page"]["properties"]["custom_fields"]["properties"]["dosage"]
    refute Map.has_key?(dosage, "x-kiln-section-display")
  end

  describe "format" do
    defp private_and_public_fields(suffix) do
      actor = admin()

      CMS.create_field_definition!(
        %{content_type: :page, name: "gql_price_#{suffix}", label: "Price", field_type: :float},
        actor: actor
      )

      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "gql_secret_#{suffix}",
          label: "Secret",
          field_type: :string,
          private: true
        },
        actor: actor
      )
    end

    test "the unparameterized response is the JSON document, byte for byte", %{conn: conn} do
      org_id = KilnCMS.Accounts.default_org_id()

      expected =
        [org_id: org_id, base_url: KilnCMSWeb.Tenant.base_url(org_id)]
        |> KilnCMS.SchemaExport.json_schema()
        |> Jason.encode!()

      plain = conn |> get(~p"/api/schema") |> response(200)
      explicit = build_conn() |> unique_ip() |> get(~p"/api/schema?format=json") |> response(200)

      assert plain == explicit
      assert Jason.decode!(plain) == Jason.decode!(expected)
      refute plain =~ "x-kiln-graphql"
    end

    test "typescript serves the .d.ts with its own content type", %{conn: conn} do
      conn = get(conn, ~p"/api/schema?format=typescript")

      assert ["application/typescript" <> _] = get_resp_header(conn, "content-type")
      assert response(conn, 200) =~ "export type KilnBlock ="
      refute conn.resp_body =~ "CustomFieldsFragment"
    end

    test "typescript-graphql adds fragments and keeps private fields out", %{conn: conn} do
      private_and_public_fields("a")

      conn = get(conn, ~p"/api/schema?format=typescript-graphql")
      body = response(conn, 200)

      assert ["application/typescript" <> _] = get_resp_header(conn, "content-type")
      assert body =~ ~s|gqlPriceA: customFloat(name: "gql_price_a")|
      assert body =~ "fragment PageCustomFields on Page {"
      refute body =~ "gql_secret_a"
    end

    test "swift-graphql and kotlin-graphql serve the models with fragments", %{conn: conn} do
      private_and_public_fields("n")

      swift = conn |> get(~p"/api/schema?format=swift-graphql")
      assert ["text/x-swift" <> _] = get_resp_header(swift, "content-type")
      body = response(swift, 200)
      assert body =~ "public indirect enum Block"
      assert body =~ ~s|gqlPriceN: customFloat(name: "gql_price_n")|
      assert body =~ "public struct PageCustomFields: Codable, Hashable, Sendable {"
      refute body =~ "gql_secret_n"

      kotlin = build_conn() |> unique_ip() |> get(~p"/api/schema?format=kotlin-graphql")
      assert ["text/x-kotlin" <> _] = get_resp_header(kotlin, "content-type")
      body = response(kotlin, 200)
      assert body =~ "package kiln"
      assert body =~ ~s|gqlPriceN: customFloat(name: "gql_price_n")|
      assert body =~ "public data class PageCustomFields("
      refute body =~ "gql_secret_n"
    end

    test "a cached swift-graphql document is evicted by a registry write", %{conn: conn} do
      warm = conn |> get(~p"/api/schema?format=swift-graphql") |> response(200)
      refute warm =~ "gql_price_m"

      private_and_public_fields("m")

      fresh =
        build_conn() |> unique_ip() |> get(~p"/api/schema?format=swift-graphql") |> response(200)

      assert fresh =~ "gql_price_m"
    end

    test "each format is cached under its own key", %{conn: conn} do
      private_and_public_fields("c")
      json = conn |> get(~p"/api/schema") |> response(200)
      ts = build_conn() |> unique_ip() |> get(~p"/api/schema?format=typescript") |> response(200)

      again =
        build_conn() |> unique_ip() |> get(~p"/api/schema?format=typescript") |> response(200)

      gql =
        build_conn()
        |> unique_ip()
        |> get(~p"/api/schema?format=typescript-graphql")
        |> response(200)

      assert ts == again
      refute ts == json
      refute ts == gql
      assert gql =~ "gql_price_c"
      refute ts =~ "CustomFieldsFragment"
      assert json == build_conn() |> unique_ip() |> get(~p"/api/schema") |> response(200)
    end

    test "a cached typescript-graphql document is evicted by a registry write", %{conn: conn} do
      warm = conn |> get(~p"/api/schema?format=typescript-graphql") |> response(200)
      refute warm =~ "gql_price_b"

      private_and_public_fields("b")

      fresh =
        build_conn()
        |> unique_ip()
        |> get(~p"/api/schema?format=typescript-graphql")
        |> response(200)

      assert fresh =~ "gql_price_b"
    end

    test "an unknown format is a 400, not a silent JSON", %{conn: conn} do
      body = conn |> get(~p"/api/schema?format=yaml") |> json_response(400)

      assert body["errors"] |> List.first() |> Map.get("code") == "invalid_format"
      assert inspect(body) =~ "typescript-graphql"
      assert inspect(body) =~ "swift-graphql"
      assert inspect(body) =~ "kotlin-graphql"
      assert inspect(body) =~ "openapi"
    end

    # The site's request carries a base URL, so the JSON document has an `$id`;
    # it names that document, not this one, and must not leak across.
    test "openapi serves the same schemas as OpenAPI 3.1 components", %{conn: conn} do
      private_and_public_fields("o")
      conn = get(conn, ~p"/api/schema?format=openapi")
      raw = response(conn, 200)
      body = Jason.decode!(raw)

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      assert body["openapi"] == "3.1.0"
      refute Map.has_key?(body, "$id")
      refute Map.has_key?(body, "$schema")
      refute raw =~ "#/$defs/"
      refute raw =~ "x-kiln-graphql"

      schemas = body["components"]["schemas"]

      assert schemas["block"]["discriminator"]["mapping"]["heading"] ==
               "#/components/schemas/block_heading"

      assert "#/components/schemas/content_page" in Enum.map(
               schemas["document"]["oneOf"],
               & &1["$ref"]
             )

      fields = schemas["content_page"]["properties"]["custom_fields"]["properties"]
      assert fields["gql_price_o"]["type"] == ["number", "null"]
      refute Map.has_key?(fields, "gql_secret_o")
    end

    test "openapi with ?blocks=only has no document component", %{conn: conn} do
      body = conn |> get(~p"/api/schema?format=openapi&blocks=only") |> json_response(200)

      assert Map.has_key?(body["components"]["schemas"], "block")
      refute Map.has_key?(body["components"]["schemas"], "document")
    end

    test "a cached openapi document is evicted by a registry write", %{conn: conn} do
      warm = conn |> get(~p"/api/schema?format=openapi") |> response(200)
      refute warm =~ "gql_price_p"

      private_and_public_fields("p")

      fresh =
        build_conn() |> unique_ip() |> get(~p"/api/schema?format=openapi") |> response(200)

      assert fresh =~ "gql_price_p"
    end

    # The controller and the bust read one list; a format only the controller
    # knew would stay stale for the TTL after every registry write.
    test "a registry bust evicts every served format's key" do
      org_id = KilnCMS.Accounts.default_org_id()

      keys =
        Enum.map(KilnCMS.SchemaExport.served_formats(), &Cache.delivery_schema_key(org_id, &1))

      for key <- keys, do: Cache.put(key, :warm, :timer.minutes(1))
      assert Enum.map(keys, &Cache.peek/1) == Enum.map(keys, fn _ -> :warm end)

      Cache.bust_type_registry(org_id)

      # `peek/1`, not `fetch/3`: a fetch's fallback would store its value under
      # the site's real key, and the next test to GET that format would be
      # served it instead of a rendered document.
      for key <- keys, do: assert(Cache.peek(key) == nil, "#{key} survived the bust")
    end

    test "format combines with ?type= and 400s on an unknown type", %{conn: conn} do
      body = conn |> get(~p"/api/schema?format=typescript&type=post") |> response(200)
      assert body =~ "PostDocument"
      refute body =~ "PageDocument"

      assert build_conn()
             |> unique_ip()
             |> get(~p"/api/schema?format=typescript&type=nope")
             |> json_response(400)
    end
  end
end
