defmodule KilnCMSWeb.SiteSsoControllerTest do
  @moduledoc """
  A site's own single sign-on over HTTP (#1561): `/auth/site-sso` and its
  callback, and the sign-in page's button.

  `KilnCMS.Accounts.SiteSsoTest` covers the rules. This covers what only the
  web layer does: the parked state is bound to the site that started the flow,
  the callback establishes a real session (and only when admitted), and the
  sign-in page offers the site's provider only when it can be used.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.SiteSsoFixtures, as: F

  setup_all do
    %{key: F.signing_key()}
  end

  setup do
    org = KilnCMS.OrgFixtures.org("ssoweb")
    other = KilnCMS.OrgFixtures.org("ssoweb-other")
    domain = F.unique_domain("web")
    F.provider!(org)
    F.domain!(org, domain, verified: true)
    %{org: org, other: other, domain: domain}
  end

  # Start the flow on `org`'s host and return the conn (carrying the session)
  # and the parked state/nonce, read back off the authorization URL.
  defp start(conn, org, key) do
    F.stub_provider!(key, %{})
    conn = conn |> org_conn(org) |> get(~p"/auth/site-sso")

    location = redirected_to(conn, 302)
    assert String.starts_with?(location, F.issuer() <> "/authorize?")
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {conn, query}
  end

  defp finish(conn, org, key, query, claims) do
    F.stub_provider!(key, Map.put(claims, "nonce", query["nonce"]))

    conn
    |> recycle()
    |> org_conn(org)
    |> get(~p"/auth/site-sso/callback", %{"code" => "c0de", "state" => query["state"]})
  end

  test "the authorization request names this site's callback URL and PKCE",
       %{conn: conn, org: org, key: key} do
    {_conn, query} = start(conn, org, key)

    assert query["redirect_uri"] ==
             KilnCMSWeb.Tenant.base_url(org) <> "/auth/site-sso/callback"

    assert query["client_id"] == F.client_id()
    assert query["code_challenge_method"] == "S256"
    assert query["scope"] =~ "openid"
    assert is_binary(query["state"]) and is_binary(query["nonce"])
  end

  test "an admitted callback establishes a session", %{
    conn: conn,
    org: org,
    domain: domain,
    key: key
  } do
    {conn, query} = start(conn, org, key)

    conn =
      finish(conn, org, key, query, %{"email" => "person@#{domain}", "email_verified" => true})

    assert redirected_to(conn) == "/account"
    assert is_binary(get_session(conn, "user_token"))
    assert get_session(conn, :site_sso_pending) == nil
  end

  test "a site-B admin in site A's verified domain gets no session",
       %{conn: conn, org: org, other: other, domain: domain, key: key} do
    admin =
      Ash.Seed.seed!(User, %{
        email: "b-admin@#{domain}",
        hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: admin.id,
      organization_id: other.id,
      role: :admin
    })

    {conn, query} = start(conn, org, key)

    conn =
      finish(conn, org, key, query, %{"email" => "b-admin@#{domain}", "email_verified" => true})

    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, "user_token") == nil
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't use this site's single sign-on"
  end

  test "an address outside the verified domains gets no session", %{
    conn: conn,
    org: org,
    key: key
  } do
    {conn, query} = start(conn, org, key)

    conn =
      finish(conn, org, key, query, %{"email" => "x@unverified.example", "email_verified" => true})

    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, "user_token") == nil
  end

  test "a flow started on one site cannot be finished on another",
       %{conn: conn, org: org, other: other, domain: domain, key: key} do
    # The other site has a provider and the same verified domain of its own,
    # so nothing but the binding stands between the two.
    F.provider!(other)
    F.domain!(other, domain, verified: true)

    {conn, query} = start(conn, org, key)

    conn =
      finish(conn, other, key, query, %{"email" => "hop@#{domain}", "email_verified" => true})

    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, "user_token") == nil
  end

  test "a callback with no flow started is refused", %{conn: conn, org: org} do
    conn =
      conn |> org_conn(org) |> get(~p"/auth/site-sso/callback", %{"code" => "c", "state" => "s"})

    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, "user_token") == nil
  end

  test "a site with no provider sends the browser back to sign-in", %{conn: conn, other: other} do
    conn = conn |> org_conn(other) |> get(~p"/auth/site-sso")
    assert redirected_to(conn) == "/sign-in"
  end

  describe "the sign-in page" do
    test "offers the site's provider by its label", %{conn: conn, org: org} do
      {:ok, _lv, html} = conn |> org_conn(org) |> live(~p"/sign-in")

      assert html =~ ~s(id="site-sso-sign-in")
      assert html =~ "Sign in with Acme staff"
    end

    test "offers nothing on a site without one", %{conn: conn, other: other} do
      {:ok, _lv, html} = conn |> org_conn(other) |> live(~p"/sign-in")

      refute html =~ "site-sso"
    end

    test "says single sign-on is unavailable when the secret can't be read, and offers no substitute",
         %{conn: conn, org: org} do
      import Ecto.Query, only: [from: 2]

      from(p in "site_sso_providers", where: p.org_id == type(^org.id, :binary_id))
      |> KilnCMS.Repo.update_all(set: [client_secret_encrypted: "garbage"])

      {:ok, _lv, html} = conn |> org_conn(org) |> live(~p"/sign-in")

      assert html =~ ~s(id="site-sso-unavailable")
      refute html =~ ~s(id="site-sso-sign-in")
    end
  end
end
