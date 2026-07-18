defmodule KilnCMSWeb.ProvenanceControllerTest do
  @moduledoc "Public provenance verification endpoints (#340)."
  # async: false — provenance config + signing key are global env state.
  use KilnCMSWeb.ConnCase, async: false

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
          blocks: [%{type: :heading, content: "Signed", data: %{"level" => 1}, order: 0}]
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
