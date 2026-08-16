defmodule KilnCMSWeb.SurfaceTest do
  @moduledoc """
  The console/delivery/shared classification of every route (#740, step 1),
  pinned so a new route lands in the right column on purpose.

  If this fails after you added a route: decide which surface it belongs to
  (`KilnCMSWeb.Surface`'s moduledoc), make `Surface.of/1` say so if it does not
  already, and add the path to the list below. Do not widen a rule to make the
  test pass — the whole point is that "console" is a decision, not a default.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.Surface

  @console ~w(
    /editor /editor/account/export.json /editor/analytics /editor/analytics/export.csv
    /editor/analytics/export.json /editor/api-keys /editor/automation /editor/backups
    /editor/billing /editor/branding /editor/calendar /editor/code-injection
    /editor/compliance /editor/content/:type/:id /editor/federation /editor/feeds
    /editor/fields /editor/fixture /editor/forms /editor/forms/:id
    /editor/forms/:id/entries/export.csv /editor/forms/settings
    /editor/funnels /editor/funnels/:id /editor/governance /editor/governance/:type/:id
    /editor/governance/:type/:id/export.csv /editor/governance/:type/:id/export.json
    /editor/links /editor/mail /editor/menus /editor/menus/:id /editor/newsletter
    /editor/overview /editor/pages/:id /editor/posts/:id /editor/presentation/:type/:slug
    /editor/preview/:kind/:id /editor/redirects /editor/releases /editor/releases/:id
    /editor/search /editor/settings /editor/site/:type/:slug /editor/slugs /editor/social
    /editor/system /editor/tasks /editor/taxonomy /editor/team /editor/translations
    /editor/translations/export.xlf /editor/trash /editor/types /editor/webhooks /media
  )

  @shared ~w(
    /account /api/ask /api/auth/sign_in /api/auth/sign_in/verify /api/content/:type
    /api/content/:type/:slug /api/content/:type/:slug/related /api/content/:type/:slug/unlock
    /api/forms/:slug /api/json /api/json/swaggerui /api/locales /api/menus /api/menus/:key
    /api/provenance/:type/:slug /api/provenance/:type/:slug/verify /api/provenance/public-key
    /api/resolve /api/schema /api/search /api/visual-editing/:type/:slug /auth
    /auth/passkey/options /auth/passkey/verify /confirm_new_user/:token /gql /locale/:locale
    /magic_link/:token /manifest.webmanifest /mcp /media/:id/download /media/:id/stream
    /offline.html /password-reset/:token /preview/:token /preview/:token/live
    /preview/release/:token /ready /register /reset /sign-in /sign-in/verify /sign-out /up
  )

  test "the console list is exactly these routes" do
    assert console_paths() == Enum.sort(@console)
  end

  test "the shared list is exactly these routes" do
    assert shared_paths() == Enum.sort(@shared)
  end

  test "everything else is delivery, and every route classifies to one of the three" do
    all = Surface.all()
    assert Enum.all?(all, fn {surface, _} -> surface in [:console, :shared, :delivery] end)

    delivery = for {:delivery, path} <- all, do: path
    # The tenant's public surface: the catch-alls and the home page are here.
    for path <- ["/", "/:slug", "/*path", "/blog", "/forms/:slug", "/membership", "/actor"] do
      assert path in delivery, "#{path} should be delivery"
    end
  end

  test "the rules that make a route console are the router's own facts" do
    # An editor/admin live_session is console however it is spelled.
    assert Surface.of(%{
             route: "/anything",
             phoenix_live_view: {Mod, :index, [], %{name: :editor_routes}}
           }) ==
             :console

    assert Surface.of(%{
             route: "/anything",
             phoenix_live_view: {Mod, :index, [], %{name: :admin_routes}}
           }) ==
             :console

    # The dev tools pipeline is console.
    assert Surface.of(%{route: "/dev/mailbox", pipe_through: [:browser_dev_tools]}) == :console

    # `/editor` and below is console even as a controller route.
    assert Surface.of(%{route: "/editor/whatever/export.csv"}) == :console
    # …but `/editorial` is not — the prefix is segment-bounded.
    assert Surface.of(%{route: "/editorial"}) == :delivery

    # The two `/media` shapes fall on opposite sides, which is the point of
    # classifying by route rather than by prefix.
    assert Surface.of(%{route: "/media"}) == :console
    assert Surface.of(%{route: "/media/:id/stream"}) == :shared

    # Same for `/api/auth` (shared credential endpoint) vs anything under /editor.
    assert Surface.of(%{route: "/api/auth/sign_in"}) == :shared

    # An unmatched or unknown shape is delivery.
    assert Surface.of(%{route: "/some/tenant/page"}) == :delivery
  end

  defp console_paths, do: for({:console, p} <- Surface.all(), do: p) |> Enum.sort()
  defp shared_paths, do: for({:shared, p} <- Surface.all(), do: p) |> Enum.sort()
end
