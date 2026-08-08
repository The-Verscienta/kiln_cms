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

    test "an admin can scope a rule to task events (#501)", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/editor/automation")

      # The content-type picker offers "Tasks" so a task.assigned/task.overdue
      # rule can be scoped correctly, rather than left at "Any content type"
      # (which would also match every content-publish event) or pointed at an
      # actual content type (which `Rule.matching`'s exact string match would
      # then never fire for).
      assert html =~ "Tasks"

      view
      |> form("#new-rule-form",
        rule: %{
          name: "Notify on task assignment",
          trigger_event: "assigned",
          content_type: "task",
          action: "broadcast",
          config: ~s({"topic": "tasks"})
        }
      )
      |> render_submit()

      assert render(view) =~ "Notify on task assignment"
      assert render(view) =~ "task.assigned"

      rule =
        Enum.find(
          Automation.list_rules!(authorize?: false),
          &(&1.name == "Notify on task assignment")
        )

      assert rule.trigger_event == :assigned
      assert rule.content_type == "task"
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

    test "config that can never work is refused, beside the field (#944)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      html =
        view
        |> form("#new-rule-form",
          rule: %{
            name: "Never sends",
            trigger_event: "published",
            content_type: "",
            action: "send_email",
            config: ~s({"subject": "Live: {{title}}"})
          }
        )
        |> render_submit()

      # Not a flash and not a log: the message has to be where the JSON was
      # typed, which is why the hand-rolled textarea now renders its errors.
      assert html =~ "missing `to`"
      assert Automation.list_rules!(authorize?: false) == []
    end

    test "the string \"true\" on allow_egress is named as the mistake it is", %{conn: conn} do
      # Every other key in that textarea is a string, so this is the natural
      # thing to type — and the runtime gate fails closed, leaving a rule that
      # looks enabled and emails nothing forever.
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      html =
        view
        |> form("#new-rule-form",
          rule: %{
            name: "Drafts metadata",
            trigger_event: "in_review",
            content_type: "",
            action: "suggest_metadata",
            config: ~s({"to": "team@example.com", "allow_egress": "true"})
          }
        )
        |> render_submit()

      assert html =~ "allow_egress"
      assert html =~ "not a string"
      assert Automation.list_rules!(authorize?: false) == []
    end

    test "the accepted keys beside the field come from the enforcing table", %{conn: conn} do
      # Rendered from ActionConfig.shapes/0, so it cannot drift from what the
      # save allows — a hand-maintained list is the failure mode #944 is about.
      {:ok, view, html} = live(conn, ~p"/editor/automation")

      # The first action kind is what the untouched select displays.
      assert html =~ "send_email accepts: to (required), subject, body"

      html =
        view
        |> form("#new-rule-form", rule: %{action: "suggest_metadata"})
        |> render_change()

      assert html =~ "suggest_metadata accepts: to (required), allow_egress"

      html =
        view
        |> form("#new-rule-form", rule: %{action: "reindex"})
        |> render_change()

      assert html =~ "reindex accepts: no config"
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
