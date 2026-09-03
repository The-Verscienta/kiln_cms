defmodule KilnCMSWeb.ErrorHTMLTest do
  # `async: true` holds because every key this module writes is unique to a test
  # — `org/1` suffixes the slug, org ids are UUIDs — so the process-global
  # branding cache is never contended. Nothing here asserts the DEFAULT org's
  # branding CONTENT any more (#1355): a tenantless render resolves the default
  # org's `SiteBranding` row (`Branding.for_org(nil)` routes there), so any
  # async test seeding that row — even just `show_attribution: false` — would
  # have flipped those assertions. Tenantless renders are asserted on
  # branding-immune structure; the stock-attribution claim runs against an org
  # this module owns; the nil-routes-to-default seam is pinned directly.
  use KilnCMSWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]
  import KilnCMS.OrgFixtures

  # #145: 404 is a branded page in the public chrome with recovery links.
  # Structure only — a tenantless render resolves the DEFAULT org's branding,
  # which this async module cannot own; the attribution content is asserted
  # below against an org of this module's own (#1355).
  test "renders a branded 404.html with public chrome and recovery links" do
    html = render_to_string(KilnCMSWeb.ErrorHTML, "404", "html", [])

    assert html =~ "Page not found"
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

    # The stock-attribution branch, on an org THIS test owns: a tenant without
    # its own `SiteBranding` row goes through the same `branded?/1` fallback a
    # tenantless render does, so the "Powered by KilnCMS." rendering is pinned
    # here — where no other async test's default-org seed can touch it (#1355).
    test "an org without its own branding renders the stock attribution" do
      o = org("unbranded")
      conn = %{Phoenix.ConnTest.build_conn() | assigns: %{current_org: o}}

      html = render_to_string(KilnCMSWeb.ErrorHTML, "404", "html", conn: conn)

      assert html =~ "Powered by KilnCMS."
    end

    # The seam the tenantless renders below rely on, pinned without depending
    # on WHAT the default org's branding currently says: no resolved tenant
    # resolves as the default org (#1124's fail-open direction), whatever row
    # some other test may have seeded there.
    test "no resolved tenant resolves the default org's branding" do
      assert KilnCMS.Branding.for_org(nil) ==
               KilnCMS.Branding.for_org(KilnCMS.Accounts.default_org_id())
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
      # replaces it. Structural evidence (the layout's header nav), not the
      # attribution line: this conn resolves the DEFAULT org, whose branding —
      # including `show_attribution: false` — any other test may seed (#1355).
      assert html =~ ~s(href="/blog")
      assert html =~ "<header"
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

    # Not every error page has a tenant behind it: an exception raised before
    # `SetTenant` runs, a template rendered directly. This guards the shape the
    # issue proposed — `current_org={@conn.assigns[:current_org]}` — which raises
    # `KeyError` on `@conn` for a render with no conn at all, turning an error
    # page into a second error.
    #
    # Every templated status, not just 404: the 500 page is the one that has to
    # tolerate a half-built conn, because that is precisely the request that
    # raised. A 500 renderer that itself raises is the loop (#558).
    for status <- ["403", "404", "500"] do
      test "#{status} with no resolved tenant still renders" do
        # Branding-immune structure only (#1355): what the default org's
        # branding SAYS is another test's row to seed. The status copy and a
        # recovery link prove the render happened and the template is whole.
        copy = status_copy(unquote(status))

        assert render_to_string(KilnCMSWeb.ErrorHTML, unquote(status), "html", []) =~ copy

        bare = %{Phoenix.ConnTest.build_conn() | assigns: %{}}

        assert render_to_string(KilnCMSWeb.ErrorHTML, unquote(status), "html", conn: bare) =~
                 copy
      end

      # ...and the same through the ROOT layout, which is where the real risk
      # lives: #681 put `Layouts.root` on the error path, and it runs the theme
      # boot script and `Layouts.brand_tokens/1` against whatever assigns the
      # failed request left behind. `render_to_string/4` above renders the inner
      # template only, so it cannot see a root layout that raises.
      #
      # This reproduces what `Phoenix.Controller.RenderErrors` does on its last
      # two lines. Going through the endpoint instead would need a route that
      # raises on demand, which is a bigger fixture than the thing under test.
      test "#{status} renders inside the root layout with a half-built conn" do
        html =
          %{Phoenix.ConnTest.build_conn() | assigns: %{}}
          |> Plug.Conn.put_private(:phoenix_endpoint, KilnCMSWeb.Endpoint)
          |> Phoenix.Controller.put_root_layout(html: {KilnCMSWeb.Layouts, :root})
          |> Phoenix.Controller.put_layout(false)
          |> Phoenix.Controller.put_view(KilnCMSWeb.ErrorHTML)
          |> Phoenix.Controller.render(unquote(status) <> ".html", %{})
          |> Map.fetch!(:resp_body)

        assert html =~ "<!DOCTYPE html"
        assert html =~ "/assets/css/app.css"
        assert html =~ status_copy(unquote(status))
      end
    end

    defp status_copy("403"), do: "Access denied"
    defp status_copy("404"), do: "Page not found"
    defp status_copy("500"), do: "Something went wrong"
  end
end
