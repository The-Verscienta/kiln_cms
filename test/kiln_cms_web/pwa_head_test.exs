defmodule KilnCMSWeb.PwaHeadTest do
  @moduledoc """
  Where the editor PWA advertises itself (#65).

  The manifest link is the single switch for the whole feature: the root layout
  emits it only when `:pwa` is assigned, and `app.js` registers the service
  worker only when it finds the link. So "does this page carry the link" is
  exactly "does this page install an app and a service worker" — which is why
  each surface is asserted rather than only the happy path.
  """
  use KilnCMSWeb.ConnCase, async: true

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
