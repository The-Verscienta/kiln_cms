defmodule KilnCMSWeb.WebhookLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @tag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "wh-live-#{System.unique_integer([:positive])}@example.com"

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
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/webhooks")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "You need admin access to view that page."}}}} =
               live(conn, ~p"/editor/webhooks")
    end

    test "admins can load the page and see selectable events", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")
      assert html =~ "Webhooks"
      assert html =~ "page.updated"
      assert html =~ "post.published"
    end
  end

  describe "create" do
    test "admin creates an endpoint with selected events", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      html =
        lv
        |> form("#new-webhook-form",
          webhook: %{
            url: "https://hooks.test/incoming",
            events: ["page.published", "page.updated"]
          }
        )
        |> render_submit()

      assert html =~ "https://hooks.test/incoming"

      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      assert endpoint.url == "https://hooks.test/incoming"
      assert Enum.sort(endpoint.events) == ["page.published", "page.updated"]
      # A signing secret is generated and surfaced to the admin.
      assert is_binary(endpoint.secret)
      assert html =~ endpoint.secret
    end
  end

  describe "manage" do
    defp seed_endpoint do
      Ash.Seed.seed!(KilnCMS.CMS.WebhookEndpoint, %{
        url: "https://hooks.test/existing",
        events: ["page.published"],
        active: true,
        secret: "s3cret"
      })
    end

    test "admin toggles an endpoint active/inactive", %{conn: conn} do
      endpoint = seed_endpoint()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      lv
      |> element(~s(button[phx-click="toggle_active"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      refute CMS.get_webhook_endpoint!(endpoint.id, authorize?: false).active
    end

    test "admin deletes an endpoint", %{conn: conn} do
      endpoint = seed_endpoint()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      lv
      |> element(~s(button[phx-click="delete"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      assert {:error, _} = CMS.get_webhook_endpoint(endpoint.id, authorize?: false)
    end
  end
end
