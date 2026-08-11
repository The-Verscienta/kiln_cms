defmodule KilnCMSWeb.PwaHeadTest do
  @moduledoc """
  Where the editor PWA advertises itself (#65).

  The manifest link is the single switch for the whole feature: the root layout
  emits it only when `:pwa` is assigned, and `app.js` registers the service
  worker only when it finds the link. So "does this page carry the link" is
  exactly "does this page install an app and a service worker" — which is why
  each surface is asserted rather than only the happy path.
  """
  # `async: false` — the app-icon cases below write a branding row for the
  # default org and bust the shared branding cache.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  describe "authoring pages" do
    test "an editor page links the manifest and the iOS home-screen icon", %{conn: conn} do
      html = conn |> log_in(authed_user(:editor)) |> get(~p"/editor") |> html_response(200)

      assert html =~ ~s(rel="manifest")
      assert html =~ "/manifest.webmanifest"
      assert html =~ ~s(rel="apple-touch-icon")
      assert html =~ ~s(name="apple-mobile-web-app-capable")
      assert html =~ ~s(name="mobile-web-app-capable")
    end

    test "the manifest link carries the request's locale (#630)", %{conn: conn} do
      # The link is what decides which locale a browser installs under — the
      # controller must never read it from the session, or the installed app is
      # named after whichever locale happened to trigger the first fetch.
      # No app-env mutation here: `config/test.exs` already configures "fr", so
      # none is needed. Narrowing `:i18n` globally would leak to everything that
      # runs after this module — the flip to `async: false` (for the branding
      # cases below) bounds the blast radius, it does not remove it.
      html =
        conn
        |> log_in(authed_user(:editor))
        |> Plug.Test.init_test_session(locale: "fr")
        |> get(~p"/editor")
        |> html_response(200)

      assert html =~ "/manifest.webmanifest?locale=fr"
    end

    test "an admin-only page links it too", %{conn: conn} do
      html = conn |> log_in(authed_user(:admin)) |> get(~p"/editor/trash") |> html_response(200)

      assert html =~ ~s(rel="manifest")
    end
  end

  describe "everywhere else" do
    test "a public delivery page does not — readers get no install prompt", %{conn: conn} do
      page =
        CMS.create_page!(
          %{title: "Public", slug: "pwa-public-#{System.unique_integer([:positive])}"},
          authorize?: false
        )

      CMS.publish_page!(page, %{}, authorize?: false)

      html = conn |> get(~p"/#{page.slug}") |> html_response(200)

      refute html =~ ~s(rel="manifest")
      refute html =~ "/manifest.webmanifest"
      refute html =~ ~s(rel="apple-touch-icon")
    end

    test "a signed-in reader with no editor tier does not", %{conn: conn} do
      html = conn |> log_in(authed_user(:viewer)) |> get(~p"/account") |> html_response(200)

      refute html =~ ~s(rel="manifest")
    end

    test "the sign-in page does not — it is reachable without any tier", %{conn: conn} do
      html = conn |> get(~p"/sign-in") |> html_response(200)

      refute html =~ ~s(rel="manifest")
    end
  end

  # #629. The iOS home-screen icon is the one PWA asset with no manifest to carry
  # a declared size, so it follows the same gate for a different reason: iOS
  # scales whatever it is handed, and a wordmark scaled to a square tile is the
  # unmistakably-broken look the stock mark avoids.
  describe "the iOS home-screen icon (#629)" do
    setup do
      on_exit(fn -> KilnCMS.Cache.bust_branding(KilnCMS.Accounts.default_org_id()) end)
      :ok
    end

    defp head_with_branding(conn, attrs) do
      Ash.Seed.seed!(
        KilnCMS.CMS.SiteBranding,
        Map.merge(%{org_id: KilnCMS.Accounts.default_org_id(), site_name: "Icon Co"}, attrs)
      )

      KilnCMS.Cache.bust_branding(KilnCMS.Accounts.default_org_id())

      conn |> log_in(authed_user(:editor)) |> get(~p"/editor") |> html_response(200)
    end

    test "a verified icon replaces the stock apple-touch-icon", %{conn: conn} do
      html = head_with_branding(conn, %{app_icon_url: "/uploads/icon.png", app_icon_size: 512})

      assert html =~ ~s(rel="apple-touch-icon" href="/uploads/icon.png")
    end

    test "an unverified URL falls back to the stock mark", %{conn: conn} do
      html =
        head_with_branding(conn, %{app_icon_url: "/uploads/wordmark.png", app_icon_size: nil})

      assert html =~ ~s(href="/images/apple-touch-icon.png")
      refute html =~ "wordmark.png"
    end

    test "an unbranded site keeps the stock mark", %{conn: conn} do
      html = conn |> log_in(authed_user(:editor)) |> get(~p"/editor") |> html_response(200)

      assert html =~ ~s(href="/images/apple-touch-icon.png")
    end
  end

  defp authed_user(role) do
    email = "pwa-head-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
