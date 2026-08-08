defmodule KilnCMSWeb.AuthTitlesTest do
  @moduledoc """
  Page titles, and the brand suffix that used to be appended twice (#559).

  `live_title/1` renders `prefix <> present(slot, default) <> suffix` — the
  suffix appended whether or not the slot was empty — so a page that set no
  `page_title` fell back to `default` and then had the brand appended to it. On
  a white-labelled site the tab read `Acme Docs · Acme Docs`.

  Two halves are under test: the pages that now carry a title, and the
  conditional suffix that makes a page without one degrade to the bare brand
  name rather than to the bug.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import KilnCMS.OrgFixtures

  alias KilnCMSWeb.AuthPageTitle

  # The name has to come from the org's own branding row for a doubling to be
  # visible as anything but "KilnCMS · KilnCMS".
  defp branded_host(name) do
    o = org("authtitle")
    Ash.Seed.seed!(KilnCMS.CMS.SiteBranding, %{org_id: o.id, site_name: name})
    KilnCMS.Cache.bust_branding(o.id)
    "#{o.slug}.#{KilnCMSWeb.Tenant.base_host()}"
  end

  defp title_of(html) do
    case Regex.run(~r{<title[^>]*>(.*?)</title>}s, html) do
      [_, title] -> String.trim(title)
      nil -> nil
    end
  end

  describe "the auth pages carry their own title" do
    # Discovered from the router by live_session name, not by guessing at module
    # names: `:auth_*` is what AshAuthentication's route macros declare, so a
    # page added by an upstream release lands in here automatically. Matching on
    # the view module's spelling would miss a `VerifyLive` and drag in an
    # unrelated `ConfirmDeleteLive`.
    defp auth_live_routes do
      Enum.filter(KilnCMSWeb.Router.__routes__(), fn route ->
        case route.metadata[:phoenix_live_view] do
          {_view, _action, _opts, %{name: name}} -> to_string(name) =~ ~r/^auth_/
          _not_a_live_route -> false
        end
      end)
    end

    test "every auth live route resolves to a title" do
      routes = auth_live_routes()

      # Guards the discovery itself: a filter that silently matched nothing
      # would make every assertion below vacuous.
      assert length(routes) >= 6

      for route <- routes do
        assert AuthPageTitle.title(route.plug_opts),
               "#{route.path} (live_action #{inspect(route.plug_opts)}) has no title in " <>
                 "KilnCMSWeb.AuthPageTitle — it would render the bare brand name, and its " <>
                 "live session would emit no data-suffix for pages patched to after it"
      end
    end

    # An action with no title resolves to `nil`, and `put_title/1` assigns
    # nothing for it — `assign(:page_title, nil)` would be indistinguishable
    # from never setting it to everything downstream except the conditional
    # suffix, which reads the assign's presence. What that leaves on screen is
    # asserted for real by "the home page reads just the brand name" below.
    test "an unmapped action has no title" do
      assert AuthPageTitle.title(:no_such_action) == nil
    end

    for {path, expected} <- [
          {"/sign-in", "Sign in"},
          {"/register", "Create an account"},
          {"/reset", "Reset your password"}
        ] do
      test "#{path} reads its own name, not the brand twice", %{conn: conn} do
        html =
          %{conn | host: branded_host("Acme Docs")} |> get(unquote(path)) |> html_response(200)

        assert title_of(html) == "#{unquote(expected)} · Acme Docs"
      end
    end

    # `/sign-in`, `/register` and `/reset` are one LiveView in one live session,
    # and the links between them are `live_patch`. A mount-only hook titles the
    # page you arrive on and then leaves that title in place — so the
    # registration form would sit under a tab reading "Sign in", which is a
    # wrong answer where the doubling was merely a redundant one.
    test "patching between auth pages retitles, and keeps the suffix", %{conn: conn} do
      conn = %{conn | host: branded_host("Acme Docs")}

      {:ok, lv, html} = live(conn, "/sign-in")
      assert title_of(html) == "Sign in · Acme Docs"

      # The suffix has to be on the tag for the client to append it on a patch.
      assert html =~ ~s(data-suffix=" · Acme Docs")

      # `page_title/1`, not the rendered body: a patch pushes the title as its
      # own diff, and the client appends `data-suffix` — asserted above — rather
      # than the server re-rendering the whole <title>.
      render_patch(lv, "/register")
      assert page_title(lv) == "Create an account"

      render_patch(lv, "/reset")
      assert page_title(lv) == "Reset your password"

      render_patch(lv, "/sign-in")
      assert page_title(lv) == "Sign in"
    end
  end

  describe "a page with no title of its own" do
    # The issue said the auth pages were the only ones. They were not: the site
    # home page and the delivery 404 rendered the doubling too, and the home
    # page is the one a white-label customer opens first.
    test "the home page reads just the brand name", %{conn: conn} do
      html = %{conn | host: branded_host("Acme Docs")} |> get("/") |> html_response(200)

      assert title_of(html) == "Acme Docs"
    end

    test "the delivery 404 names itself", %{conn: conn} do
      html =
        %{conn | host: branded_host("Acme Docs")}
        |> get("/no-such-page-#{System.unique_integer([:positive])}")
        |> html_response(404)

      assert title_of(html) == "Page not found · Acme Docs"
    end

    # Phoenix builds `render_errors`' assigns itself, so this one cannot be
    # given a title. The conditional suffix is what keeps it from doubling.
    test "a NoRouteError 404 reads just the brand name", %{conn: conn} do
      html =
        %{conn | host: branded_host("Acme Docs")}
        |> post("/definitely-no-route-#{System.unique_integer([:positive])}")
        |> html_response(404)

      assert title_of(html) == "Acme Docs"
    end
  end
end
