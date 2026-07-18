defmodule KilnCMSWeb.AutomationLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Automation

  @password "password123456"

  defp authed_user(role) do
    email = "auto-live-#{System.unique_integer([:positive])}@example.com"

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
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/automation")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "You need admin access to view that page."}}}} =
               live(conn, ~p"/editor/automation")
    end
  end

  describe "managing rules" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "an admin can create a rule", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view
      |> form("#new-rule-form",
        rule: %{
          name: "Notify on publish",
          trigger_event: "published",
          content_type: "post",
          action: "broadcast",
          config: ~s({"topic": "editorial"})
        }
      )
      |> render_submit()

      assert render(view) =~ "Notify on publish"
      assert render(view) =~ "post.published"

      rule =
        Enum.find(Automation.list_rules!(authorize?: false), &(&1.name == "Notify on publish"))

      assert rule.trigger_event == :published
      assert rule.action == :broadcast
      assert rule.config == %{"topic" => "editorial"}
    end

    test "invalid JSON in the config is rejected with a flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      html =
        view
        |> form("#new-rule-form",
          rule: %{
            name: "Bad",
            trigger_event: "published",
            content_type: "",
            action: "broadcast",
            config: "not json"
          }
        )
        |> render_submit()

      assert html =~ "valid JSON"
      assert Automation.list_rules!(authorize?: false) == []
    end

    test "an admin can toggle and delete a rule", %{conn: conn} do
      {:ok, rule} =
        Automation.create_rule(
          %{name: "Toggle me", trigger_event: :updated, action: :invalidate_cache},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view |> element("#rule-#{rule.id} button", "Disable") |> render_click()
      assert {:ok, %{enabled: false}} = Automation.get_rule(rule.id, authorize?: false)

      view |> element("#rule-#{rule.id} button[aria-label='Delete rule']") |> render_click()
      assert Automation.list_rules!(authorize?: false) == []
    end
  end
end
