defmodule KilnCMSWeb.ApiKeyLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  defp authed_user(role) do
    email = "apikey-live-#{System.unique_integer([:positive])}@example.com"

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

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/api-keys")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "You need admin access to view that page."}}}} =
               live(conn, ~p"/editor/api-keys")
    end

    test "admins can load the page", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/api-keys")
      assert html =~ "API keys"
      assert html =~ "Create a key"
    end
  end

  describe "mint + revoke" do
    test "admin mints a key and sees the plaintext once", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      html =
        lv
        |> form("#new-api-key-form", %{name: "marketing-site", user_id: admin.id, days: "90"})
        |> render_submit()

      # The one-time plaintext banner shows a kiln_-prefixed key.
      assert html =~ "won&#39;t be shown again" or html =~ "won't be shown again"
      assert html =~ "kiln_"
      assert html =~ "marketing-site"
    end

    test "admin revokes a key", %{conn: conn} do
      admin = authed_user(:admin)

      key =
        KilnCMS.Accounts.mint_api_key!(
          admin.id,
          "to-revoke",
          DateTime.add(DateTime.utc_now(), 30, :day),
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      html =
        lv
        |> element("#api-key-#{key.id} button", "Revoke")
        |> render_click()

      assert html =~ "Revoked"

      reloaded = KilnCMS.Accounts.get_api_key!(key.id, actor: admin)
      assert reloaded.revoked_at
    end
  end
end
