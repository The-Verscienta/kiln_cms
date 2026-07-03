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

  test "the plugin nav item is role-gated", %{conn: conn} do
    {:ok, _lv, admin_html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")
    assert admin_html =~ ~s(href="/editor/fixture")
    assert admin_html =~ "Fixture"

    {:ok, _lv, editor_html} = build_conn() |> log_in(authed_user(:editor)) |> live(~p"/editor")
    refute editor_html =~ ~s(href="/editor/fixture")
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
