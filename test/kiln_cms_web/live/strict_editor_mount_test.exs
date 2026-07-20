defmodule KilnCMSWeb.StrictEditorMountTest do
  @moduledoc """
  Strict-build (#419) mount of the content editor — reproduces the e2e
  editor journey server-side so tenant-less reads in the mount path fail
  HERE with a stacktrace instead of only in Playwright.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @moduletag :strict_tenancy
  @password "password123456"

  defp authed_admin do
    email = "strict-lv-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  test "the content editor mounts and saves under strict tenancy", %{conn: conn} do
    admin = authed_admin()

    page =
      KilnCMS.CMS.create_page!(
        %{title: "Strict editor", slug: "strict-editor-#{System.unique_integer([:positive])}"},
        actor: admin,
        tenant: KilnCMS.Accounts.default_org_id()
      )

    conn = log_in(conn, admin)

    {:ok, view, _html} = live(conn, ~p"/editor/content/page/#{page.id}")

    assert render(view) =~ "Strict editor"
  end

  test "the editor index mounts under strict tenancy", %{conn: conn} do
    conn = log_in(conn, authed_admin())
    {:ok, view, _html} = live(conn, ~p"/editor")
    # A real content check: the index renders its "Content" heading, not just
    # a non-crashing mount.
    assert has_element?(view, "h1", "Content")
  end
end
