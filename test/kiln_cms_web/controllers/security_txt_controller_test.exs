defmodule KilnCMSWeb.SecurityTxtControllerTest do
  @moduledoc """
  `/.well-known/security.txt` (#1873): served per site from its own row, 404
  until a contact is configured, and each tenant host names itself.

  `async: false` — the resolver caches in the shared Cachex.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.CMS
  alias KilnCMSWeb.Tenant

  setup do
    org = org("sectxtctl")
    on_exit(fn -> KilnCMS.Cache.bust_security_txt(org.id) end)
    %{org: org}
  end

  defp configure(org, attrs \\ %{}) do
    %{contacts: ["mailto:security@example.com"], expires_on: ~D[2099-12-31]}
    |> Map.merge(attrs)
    |> CMS.save_site_security_txt!(authorize?: false, tenant: org.id)
  end

  test "serves the configured file as text/plain; charset=utf-8", %{conn: conn, org: org} do
    configure(org, %{
      policy_url: "https://example.com/security",
      preferred_languages: ["en", "fr"]
    })

    conn = conn |> org_conn(org) |> get(~p"/.well-known/security.txt")

    body = response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    assert body == """
           Contact: mailto:security@example.com
           Expires: 2099-12-31T23:59:59Z
           Preferred-Languages: en, fr
           Canonical: #{Tenant.base_url(org)}/.well-known/security.txt
           Policy: https://example.com/security
           """
  end

  test "404s when the site has no row", %{conn: conn, org: org} do
    conn = conn |> org_conn(org) |> get(~p"/.well-known/security.txt")
    assert response(conn, 404)
  end

  test "404s when the row has no contact — never a file missing its required field",
       %{conn: conn, org: org} do
    CMS.save_site_security_txt!(%{policy_url: "https://example.com/security"},
      authorize?: false,
      tenant: org.id
    )

    conn = conn |> org_conn(org) |> get(~p"/.well-known/security.txt")
    assert response(conn, 404)
  end

  test "a save is served on the next request, not after the cache TTL", %{conn: conn, org: org} do
    assert conn |> org_conn(org) |> get(~p"/.well-known/security.txt") |> response(404)

    configure(org)

    body = build_conn() |> org_conn(org) |> get(~p"/.well-known/security.txt") |> response(200)
    assert body =~ "Contact: mailto:security@example.com"
  end

  test "the legacy /security.txt redirects to the .well-known path", %{conn: conn, org: org} do
    conn = conn |> org_conn(org) |> get(~p"/security.txt")
    assert redirected_to(conn, 301) == "/.well-known/security.txt"
  end

  describe "per-site isolation" do
    test "each site serves its own file, canonical on its own host", %{conn: conn, org: org} do
      other = org("sectxtother")
      on_exit(fn -> KilnCMS.Cache.bust_security_txt(other.id) end)

      configure(org, %{contacts: ["mailto:first@example.com"]})
      configure(other, %{contacts: ["mailto:second@example.com"]})

      first = conn |> org_conn(org) |> get(~p"/.well-known/security.txt") |> response(200)

      second =
        build_conn() |> org_conn(other) |> get(~p"/.well-known/security.txt") |> response(200)

      assert first =~ "mailto:first@example.com"
      refute first =~ "second@"
      assert first =~ "Canonical: #{Tenant.base_url(org)}/.well-known/security.txt"

      assert second =~ "mailto:second@example.com"
      refute second =~ "first@"
      assert second =~ "Canonical: #{Tenant.base_url(other)}/.well-known/security.txt"
    end

    test "one site's file is not served on another site's host", %{conn: conn, org: org} do
      configure(org)
      other = org("sectxtbare")

      conn = conn |> org_conn(other) |> get(~p"/.well-known/security.txt")
      assert response(conn, 404)
    end
  end
end
