defmodule KilnCMSWeb.PluginSurfaceTest do
  @moduledoc """
  The plugin contract's web surface (D18), via the fixture plugin: its nav
  item renders role-gated, its admin route mounts inside the admin-gated live
  session, and its block appears in the editor's block palette.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "ps-#{System.unique_integer([:positive])}@example.com"

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

  # The sidebar preset a user is on. This test is about ROLE-gating, so both users
  # are put on Everything: a new account starts on Essentials, which draws no
  # plugin items for anyone — and the editor's refute would then pass whatever
  # the role gate did.
  defp everything(user) do
    {:ok, _} = KilnCMS.Accounts.set_nav_preset(user, :everything, actor: user)
    user
  end

  test "the plugin nav item is role-gated", %{conn: conn} do
    {:ok, admin_lv, _html} = conn |> log_in(everything(authed_user(:admin))) |> live(~p"/editor")
    assert has_element?(admin_lv, ~s(aside a.side-link[href="/editor/fixture"]), "Fixture")

    {:ok, editor_lv, _html} =
      build_conn() |> log_in(everything(authed_user(:editor))) |> live(~p"/editor")

    # Scoped to the sidebar, and the sidebar is proven to be the full one — so
    # the absence is the role gate's doing, not the preset's.
    assert has_element?(editor_lv, "aside #nav-preset-switch", "Show essentials")
    refute has_element?(editor_lv, ~s(aside a.side-link[href="/editor/fixture"]))
  end

  # Essentials hides plugin items from the sidebar — a link, never the screen:
  # an admin still reaches it through ⌘K, and through "Show all tools".
  test "on Essentials the plugin item leaves the sidebar but stays reachable", %{conn: conn} do
    admin = authed_user(:admin)
    assert admin.nav_preset == :essentials

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")
    refute has_element?(lv, ~s(aside a.side-link[href="/editor/fixture"]))

    assert "/editor/fixture" in Enum.map(
             KilnCMSWeb.ConsoleNav.search("fixture", admin, nil),
             & &1.path
           )

    lv |> element("#nav-preset-switch", "Show all tools") |> render_click()
    assert has_element?(lv, ~s(aside a.side-link[href="/editor/fixture"]), "Fixture")

    # And the route itself never depended on the sidebar.
    {:ok, _lv, html} = build_conn() |> log_in(admin) |> live("/editor/fixture")
    assert html =~ "Fixture plugin panel"
  end

  test "the plugin admin route mounts in the admin live session", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live("/editor/fixture")
    assert html =~ "Fixture plugin panel"

    # Non-admins are bounced by the live_session guard, like any admin route.
    assert {:error, {:redirect, %{to: "/"}}} =
             build_conn() |> log_in(authed_user(:editor)) |> live("/editor/fixture")
  end

  test "the plugin block appears in the editor's block palette", %{conn: conn} do
    editor = authed_user(:editor)

    page =
      CMS.create_page!(
        %{title: "Palette", slug: "pal-#{System.unique_integer([:positive])}"},
        actor: editor
      )

    {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")
    assert html =~ "callout"
  end
end
