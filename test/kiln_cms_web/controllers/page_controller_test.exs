defmodule KilnCMSWeb.PageControllerTest do
  use KilnCMSWeb.ConnCase

  alias KilnCMS.Accounts.User

  defp user(role) do
    email = "page-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => "password123456"
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Model content once"
    assert html_response(conn, 200) =~ "KilnCMS"
  end

  # #319: the header/footer API links land on a served docs page, not on the
  # raw endpoints (which 404/400 in a browser).
  test "GET /developers serves the API docs page", %{conn: conn} do
    html = conn |> get(~p"/developers") |> html_response(200)

    assert html =~ "Developer APIs"
    # Onward links to the browsable explorer + spec and the auth endpoint.
    assert html =~ "/api/json/swaggerui"
    assert html =~ "/api/json/open_api"
    assert html =~ "/api/auth/sign_in"
    assert html =~ "GraphQL"
  end

  test "home and nav point API links at the docs page, not raw endpoints", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(href="/developers#graphql")
    assert html =~ ~s(href="/developers#json-api")
    refute html =~ ~s(href="/gql")
    refute html =~ ~s(href="/api/json")
  end

  # #142: viewer-role accounts (the self-registration default) get onboarding
  # copy explaining that editor access requires an admin upgrade.
  test "a viewer sees onboarding about needing an editor upgrade", %{conn: conn} do
    html = conn |> log_in(user(:viewer)) |> get(~p"/") |> html_response(200)

    assert html =~ "signed in as a viewer"
    assert html =~ "upgrade your account"
  end

  test "an editor sees the editor CTA and not the viewer onboarding", %{conn: conn} do
    html = conn |> log_in(user(:editor)) |> get(~p"/") |> html_response(200)

    refute html =~ "signed in as a viewer"
    assert html =~ "Open editor"
  end

  # Both actions used to render `<Layouts.app>` without `current_org`, so the
  # nil-defaulted attr fell through to `Branding.for_org(nil)` — the DEFAULT
  # org's logo and site name, served under a tenant's own hostname. Surfaced
  # while reviewing #563; the `current_org_id/1` raise cannot catch this class,
  # because the tenant is dropped at an attr rather than at that function.
  describe "the site header on a tenant host (#563 residual)" do
    import KilnCMS.OrgFixtures

    # The header name comes from the org's own `SiteBranding` row, so the org
    # needs one for the leak to be observable at all — an unbranded org falls
    # back to the instance defaults either way.
    defp branded_org do
      o = org("pagebrand")

      Ash.Seed.seed!(KilnCMS.CMS.SiteBranding, %{
        org_id: o.id,
        site_name: "Acme Tenant"
      })

      KilnCMS.Cache.bust_branding(o.id)
      o
    end

    for {label, path} <- [{"home", "/"}, {"developers", "/developers"}] do
      test "#{label} renders the requesting org's name, not the default org's", %{conn: conn} do
        o = branded_org()

        html =
          %{conn | host: "#{o.slug}.#{KilnCMSWeb.Tenant.base_host()}"}
          |> get(unquote(path))
          |> html_response(200)

        assert html =~ "Acme Tenant"
      end
    end

    test "the default org's own site is unaffected", %{conn: conn} do
      assert conn |> get(~p"/") |> html_response(200) =~ "KilnCMS"
    end
  end
end
