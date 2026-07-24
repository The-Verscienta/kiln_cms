defmodule KilnCMSWeb.SlugRegenLiveTest do
  @moduledoc """
  /editor/slugs (#455): admin-only access, dry-run preview, and background
  apply through the Oban worker (drained inline here) with the completion
  broadcast updating the view.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "slugregen-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  test "anonymous and non-admin users are turned away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/slugs")

    conn = log_in(conn, authed_user(:editor))

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "You need admin access" <> _}}}} =
             live(conn, ~p"/editor/slugs")
  end

  test "preview lists renames and apply performs them in the background", %{conn: conn} do
    admin = authed_user(:admin)
    page = CMS.create_page!(%{title: "A Regen Live Guide"}, actor: admin)
    # Title-only edit leaves the slug stale, so include_pinned surfaces it.
    CMS.update_page!(page, %{title: "Renamed Regen Live Guide"}, actor: admin)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/slugs")

    html =
      lv
      |> form("#slug-regen-options", %{"kind" => "page", "include_pinned" => "true"})
      |> render_change()

    assert html =~ "regen-live-guide"
    assert html =~ "renamed-regen-live-guide"

    lv |> element(~s{button[phx-click="apply"]}) |> render_click()
    KilnCMS.DataCase.drain_oban()

    assert CMS.get_page!(page.id, actor: admin).slug == "renamed-regen-live-guide"
    # The worker's completion broadcast reaches the subscribed view.
    assert render(lv) =~ "Done:"
  end
end
