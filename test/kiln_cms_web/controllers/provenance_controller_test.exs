defmodule KilnCMSWeb.ProvenanceControllerTest do
  @moduledoc "Public provenance verification endpoints (#340)."
  # async: false — provenance config + signing key are global env state.
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.TypedFixtures

  alias KilnCMS.CMS

  setup do
    pem = KilnCMS.Keys.generate_rsa_pem()
    var = "KILN_TEST_PROV_C_#{System.unique_integer([:positive])}"
    System.put_env(var, pem)
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)

    Application.put_env(:kiln_cms, KilnCMS.Provenance,
      enabled: true,
      signer: "Kiln Editorial",
      origin: "https://example.test",
      ai_disclosure: :human,
      signing_key: {:env, %{"var" => var}}
    )

    on_exit(fn ->
      if prev, do: Application.put_env(:kiln_cms, KilnCMS.Provenance, prev)
      System.delete_env(var)
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "provc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()
    slug = "provc-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Trusted",
          slug: slug,
          blocks:
            typed_blocks([%{type: :heading, content: "Signed", data: %{"level" => 1}, order: 0}])
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    slug
  end

  test "serves the signed manifest for a published artifact", %{conn: conn} do
    slug = published_page()
    manifest = conn |> get(~p"/api/provenance/page/#{slug}") |> json_response(200)

    assert manifest["kiln_provenance"] == "1.0"
    assert manifest["artifact"]["type"] == "page"
    assert manifest["artifact"]["surface"] == "json"
    assert manifest["artifact"]["hash"]["value"] |> is_binary()
    assert manifest["claim"]["signer"] == "Kiln Editorial"
    assert manifest["claim"]["ai_disclosure"] == "human"
    assert manifest["signature"]["value"] |> is_binary()
  end

  test "the manifest surface tracks ?surface=", %{conn: conn} do
    slug = published_page()
    manifest = conn |> get(~p"/api/provenance/page/#{slug}?surface=web") |> json_response(200)
    assert manifest["artifact"]["surface"] == "web"
  end

  test "verify returns a passing verdict for the live artifact", %{conn: conn} do
    slug = published_page()
    verdict = conn |> get(~p"/api/provenance/page/#{slug}/verify") |> json_response(200)

    assert verdict["verified"] == true
    assert verdict["unaltered"] == true
    assert verdict["authentic"] == true
    assert verdict["claim"]["signer"] == "Kiln Editorial"
  end

  test "publishes the signing key for offline verification", %{conn: conn} do
    info = conn |> get(~p"/api/provenance/public-key") |> json_response(200)

    assert info["alg"] == "rsa-sha256"
    assert info["key_id"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert info["public_key_pem"] =~ "BEGIN PUBLIC KEY"
    assert is_binary(info["public_key_b64"])
  end

  test "advertises the manifest URL on the delivery response", %{conn: conn} do
    slug = published_page()
    served = get(conn, ~p"/api/content/page/#{slug}")
    assert json_response(served, 200)
    assert [url] = get_resp_header(served, "x-kiln-provenance")
    assert url == "/api/provenance/page/#{slug}?surface=json"
  end

  describe "GET /api/provenance/verify/:type/:slug (#1929)" do
    defp status(conn, slug, query \\ "") do
      conn |> get("/api/provenance/verify/page/#{slug}#{query}")
    end

    # The stored row, as the engine wrote it. SQL so the test reaches past
    # every cache to the bytes a tamperer would change.
    defp artifact_sql!(sql, slug) do
      KilnCMS.Repo.query!(
        """
        UPDATE published_artifacts a SET #{sql}
        FROM pages p
        WHERE a.document_id = p.id AND p.slug = $1 AND a.surface = 'json'
        """,
        [slug]
      )

      KilnCMS.Firing.Cache.clear()
    end

    test "a freshly fired artifact is verified, anonymously and cacheably", %{conn: conn} do
      slug = published_page()
      conn = status(conn, slug)
      body = json_response(conn, 200)

      assert body["status"] == "verified"
      assert body["type"] == "page"
      assert body["slug"] == slug
      assert body["surface"] == "json"
      assert body["unaltered"] == true and body["authentic"] == true
      assert body["key_id"] =~ ~r/^sha256:/
      assert body["claim"]["signer"] == "Kiln Editorial"
      assert ["public, max-age=60"] = get_resp_header(conn, "cache-control")
    end

    test "a body changed after it was fired is tampered", %{conn: conn} do
      slug = published_page()
      artifact_sql!("body = jsonb_set(a.body, '{title}', '\"Forged\"')", slug)

      body = conn |> status(slug) |> json_response(200)
      assert body["status"] == "tampered"
      assert body["unaltered"] == false
    end

    test "a forged signature is tampered", %{conn: conn} do
      slug = published_page()
      forged = Base.encode64(:crypto.strong_rand_bytes(256))

      artifact_sql!(
        "manifest = jsonb_set(a.manifest, '{signature,value}', to_jsonb('#{forged}'::text))",
        slug
      )

      body = conn |> status(slug) |> json_response(200)
      assert body["status"] == "tampered"
      assert body["authentic"] == false
    end

    test "an artifact fired with no manifest is unsigned, not refused", %{conn: conn} do
      slug = published_page()
      artifact_sql!("manifest = NULL", slug)

      body = conn |> status(slug) |> json_response(200)
      assert body["status"] == "unsigned"
      assert body["key_id"] == nil
      # And the content itself is still served.
      assert conn |> get(~p"/api/content/page/#{slug}") |> json_response(200)
    end

    test "a manifest from a key this instance no longer holds is unverifiable", %{conn: conn} do
      slug = published_page()

      # Rotate to a new key without registering the old one as retired.
      pem = KilnCMS.Keys.generate_rsa_pem()
      var = "KILN_TEST_PROV_ROT_#{System.unique_integer([:positive])}"
      System.put_env(var, pem)
      on_exit(fn -> System.delete_env(var) end)
      cfg = Application.get_env(:kiln_cms, KilnCMS.Provenance)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Provenance,
        Keyword.put(cfg, :signing_key, {:env, %{"var" => var}})
      )

      assert conn |> status(slug) |> json_response(200) |> Map.fetch!("status") ==
               "unverifiable"
    end

    test "?surface= picks the artifact, and an unknown one 404s", %{conn: conn} do
      slug = published_page()

      assert conn |> status(slug, "?surface=web") |> json_response(200) |> Map.fetch!("surface") ==
               "web"

      assert conn |> status(slug, "?surface=nope") |> json_response(404)
    end

    test "the manifest endpoint serves the manifest stored at fire time", %{conn: conn} do
      slug = published_page()
      manifest = conn |> get(~p"/api/provenance/page/#{slug}") |> json_response(200)

      %{rows: [[stored]]} =
        KilnCMS.Repo.query!(
          "SELECT a.manifest FROM published_artifacts a JOIN pages p ON p.id = a.document_id WHERE p.slug = $1 AND a.surface = 'json'",
          [slug]
        )

      assert manifest == stored
    end

    test "404s when provenance is switched off", %{conn: conn} do
      slug = published_page()
      cfg = Application.get_env(:kiln_cms, KilnCMS.Provenance)
      Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.put(cfg, :enabled, false))

      assert %{"errors" => [%{"code" => "provenance_disabled"}]} =
               conn |> status(slug) |> json_response(404)
    end
  end

  test "404s for unknown content", %{conn: conn} do
    assert conn |> get(~p"/api/provenance/page/does-not-exist") |> json_response(404)
    assert conn |> get(~p"/api/provenance/widget/whatever") |> json_response(404)
  end

  test "all endpoints 404 when provenance is disabled", %{conn: conn} do
    slug = published_page()
    cfg = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.put(cfg, :enabled, false))

    assert %{"errors" => [%{"code" => "provenance_disabled"}]} =
             conn |> get(~p"/api/provenance/page/#{slug}") |> json_response(404)

    assert conn |> get(~p"/api/provenance/public-key") |> json_response(404)
    # And the delivery response no longer advertises a manifest.
    served = get(conn, ~p"/api/content/page/#{slug}")
    assert get_resp_header(served, "x-kiln-provenance") == []
  end
end
