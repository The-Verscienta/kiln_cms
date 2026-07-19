defmodule KilnCMSWeb.TeamLiveTest do
  @moduledoc "Team + granular-RBAC management UI (#332, slice 4)."
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User

  @password "password123456"

  defp authed_user(role) do
    email = "team-live-#{System.unique_integer([:positive])}@example.com"

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
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/team")
    end

    test "editors are turned away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/editor/team")
    end
  end

  describe "team management" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "adds a member and shows them in the list", %{conn: conn} do
      colleague = authed_user(:viewer)
      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        view
        |> form("#add-member-form", %{"member" => %{"email" => to_string(colleague.email)}})
        |> render_submit()

      assert html =~ "Member added"
      assert html =~ to_string(colleague.email)
    end

    test "adding an unknown email flashes an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        view
        |> form("#add-member-form", %{"member" => %{"email" => "nobody@example.com"}})
        |> render_submit()

      assert html =~ "No account with that email"
    end

    test "creates a custom role with scope axes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        view
        |> form("#new-role-form", %{
          "role" => %{
            "name" => "Blog editor",
            "description" => "Posts only",
            "editable_types" => "post",
            "readable_types" => "post, page",
            "field_grants" => ~s({"post": ["title"]})
          }
        })
        |> render_submit()

      assert html =~ "Role added"
      assert html =~ "Blog editor"

      [role] = Accounts.list_roles_for_org!(Accounts.default_org_id(), authorize?: false)
      assert role.editable_types == ["post"]
      assert role.readable_types == ["post", "page"]
      assert role.field_grants == %{"post" => ["title"]}
    end

    test "rejects invalid field-grants JSON", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/team")

      html =
        view
        |> form("#new-role-form", %{
          "role" => %{"name" => "Broken", "field_grants" => "not json"}
        })
        |> render_submit()

      assert html =~ "must be a JSON object"
      assert Accounts.list_roles_for_org!(Accounts.default_org_id(), authorize?: false) == []
    end

    test "assigns a custom role to a member", %{conn: conn} do
      colleague = authed_user(:editor)

      {:ok, role} =
        Accounts.create_role(
          %{name: "Assignable", org_id: Accounts.default_org_id()},
          authorize?: false
        )

      {:ok, membership} =
        Accounts.create_org_membership(
          %{
            user_id: colleague.id,
            organization_id: Accounts.default_org_id(),
            role: :editor
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/team")

      view |> element("#member-#{membership.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#edit-member-#{membership.id}", %{"member" => %{"role_id" => role.id}})
        |> render_submit()

      assert html =~ "Saved."
      assert html =~ "Assignable"
    end
  end
end
