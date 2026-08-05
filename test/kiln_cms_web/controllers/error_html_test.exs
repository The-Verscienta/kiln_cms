defmodule KilnCMSWeb.ErrorHTMLTest do
  # `async: true` holds because every key this module writes is unique to a test
  # — `org/1` suffixes the slug, org ids are UUIDs — so the process-global
  # branding cache is never contended. The one globally-observable assertion is
  # that the DEFAULT org renders the stock attribution, which would flake if any
  # async test ever seeded a `SiteBranding` row on the default org.
  use KilnCMSWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]
  import KilnCMS.OrgFixtures

  # #145: 404 is a branded page in the public chrome with recovery links.
  test "renders a branded 404.html with public chrome and recovery links" do
    html = render_to_string(KilnCMSWeb.ErrorHTML, "404", "html", [])

    assert html =~ "Page not found"
    assert html =~ "Powered by KilnCMS."
    assert html =~ ~s(href="/blog")
  end

  # 500 and 403 are branded pages too (audit): a crash or forbidden page gets
  # public chrome and a recovery link, not bare status text.
  test "renders a branded 500.html with recovery links" do
    html = render_to_string(KilnCMSWeb.ErrorHTML, "500", "html", [])

    assert html =~ "Something went wrong"
    assert html =~ ~s(href="/")
  end

  test "renders a branded 403.html with a sign-in link" do
    html = render_to_string(KilnCMSWeb.ErrorHTML, "403", "html", [])

    assert html =~ "Access denied"
    assert html =~ ~s(href="/sign-in")
  end

  # Statuses without a template still fall through to the plain status message.
  test "renders the plain status message for untemplated statuses" do
    assert render_to_string(KilnCMSWeb.ErrorHTML, "502", "html", []) == "Bad Gateway"
  end

  describe "an error page wears the requesting site's branding (#656)" do
    # The name comes from the org's own `SiteBranding` row, so the org needs one
    # for the leak to be observable — an unbranded org falls back to the
    # instance defaults either way, which is what made this invisible.
    defp branded_org(name) do
      o = org("errbrand")
      Ash.Seed.seed!(KilnCMS.CMS.SiteBranding, %{org_id: o.id, site_name: name})
      KilnCMS.Cache.bust_branding(o.id)
      o
    end

    for status <- ["403", "404", "500"] do
      test "#{status} renders the resolved tenant's name, not the default org's" do
        o = branded_org("Acme Tenant")
        conn = %{Phoenix.ConnTest.build_conn() | assigns: %{current_org: o}}

        html = render_to_string(KilnCMSWeb.ErrorHTML, unquote(status), "html", conn: conn)

        assert html =~ "Acme Tenant"
      end
    end

    test "end to end: a routing 404 on a tenant's host carries that tenant's brand",
         %{conn: conn} do
      o = branded_org("Acme Tenant")

      # A POST to an unrouted path, deliberately: a GET falls into the
      # `/:slug` catch-all and 404s through `ContentController.not_found/1`,
      # an ordinary controller render. Only a `NoRouteError` reaches the
      # endpoint's `render_errors` — the surface this issue is about, and the
      # one where `layout: false` means `Layouts.public` is all the branding
      # there is.
      html =
        %{conn | host: "#{o.slug}.#{KilnCMSWeb.Tenant.base_host()}"}
        |> post("/definitely-no-route-here-#{System.unique_integer([:positive])}")
        |> html_response(404)

      # The footer, not the title: the root layout sets `<title>` from the same
      # assign and does so with or without this fix, so asserting the name alone
      # would pass against the bug. `Branding.branded?/1` picks the "Powered by
      # <name>" branch only when the resolved org has its own `site_name`.
      assert html =~ "Powered by Acme Tenant."
    end

    # The root layout — <!DOCTYPE>, the app.css link, the brand tokens, the
    # <title> — wraps a /:slug 404 (an ordinary controller render through the
    # :browser pipeline) but used NOT to wrap a NoRouteError 404 or a 500, which
    # the endpoint's render_errors renderer produced with `layout: false` and no
    # root layout. The two 404s on one host looked nothing alike (#681).
    test "a NoRouteError 404 renders the full page chrome, not raw unstyled markup",
         %{conn: conn} do
      html =
        conn
        |> post("/definitely-no-route-#{System.unique_integer([:positive])}")
        |> html_response(404)

      assert html =~ "<!DOCTYPE html"
      assert html =~ "/assets/css/app.css"
      assert html =~ "<title"
      # The inner chrome is still there too — root wraps Layouts.public, not
      # replaces it.
      assert html =~ "Powered by"
    end

    test "the two 404 surfaces on one host render with the same chrome", %{conn: conn} do
      slug_404 =
        conn
        |> get("/no-such-page-#{System.unique_integer([:positive])}")
        |> html_response(404)

      route_404 =
        conn
        |> post("/no-route-#{System.unique_integer([:positive])}")
        |> html_response(404)

      for marker <- ["<!DOCTYPE html", "/assets/css/app.css"] do
        assert slug_404 =~ marker, "the /:slug 404 is missing #{marker}"
        assert route_404 =~ marker, "the NoRouteError 404 is missing #{marker}"
      end
    end

    test "a request with no resolved tenant still renders, on the operator defaults" do
      # Not every error page has a tenant behind it: an exception raised before
      # `SetTenant` runs, a template rendered directly. This guards the shape
      # the issue proposed — `current_org={@conn.assigns[:current_org]}` — which
      # raises `KeyError` on `@conn` for a render with no conn at all, turning
      # an error page into a second error.
      assert render_to_string(KilnCMSWeb.ErrorHTML, "404", "html", []) =~ "Powered by KilnCMS."

      bare = %{Phoenix.ConnTest.build_conn() | assigns: %{}}

      assert render_to_string(KilnCMSWeb.ErrorHTML, "404", "html", conn: bare) =~
               "Powered by KilnCMS."
    end
  end
end
