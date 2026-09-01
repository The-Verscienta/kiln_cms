defmodule KilnCMSWeb.SchemaControllerTest do
  @moduledoc """
  `GET /api/schema` — the live delivery schema for the requesting site (#430).
  """
  use KilnCMSWeb.ConnCase, async: false

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
end
