defmodule KilnCMSWeb.SettingsPasswordBreachTest do
  @moduledoc """
  Changing a password on `/editor/settings` against the breached-password check
  (#2240): the form passes the request org so that org's policy applies, a
  warning rides the redirect to /sign-in and is drawn there, and a `block`
  verdict is a field error on the form.

  `async: false`: the breach stub and policy are node-wide
  (`KilnCMS.BreachedPasswordFixtures`).
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.BreachedPasswordFixtures
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.PasswordNotice
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "settings-breach-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp change_password(lv, new_password) do
    lv
    |> form("#password-form",
      user: %{
        "current_password" => @password,
        "password" => new_password,
        "password_confirmation" => new_password
      }
    )
    |> render_submit()
  end

  defp policy!(org, policy) do
    CMS.save_site_password_policy!(%{breached_password_policy: policy},
      authorize?: false,
      tenant: org.id
    )
  end

  describe "a breached new password under warn" do
    test "is accepted and the warning rides the redirect to sign-in", %{conn: conn} do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 31)))
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/settings")

      result = change_password(lv, pw)
      flash = assert_redirect(lv, ~p"/sign-in")

      assert flash["info"] =~ "Password changed"
      assert flash["error"] == PasswordNotice.message()
      # The flash is plain data on the redirect; the sign-in page draws it.
      assert {:error, {:redirect, %{to: "/sign-in"}}} = result
    end

    test "the sign-in page renders the warning", %{conn: conn} do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 31)))
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/settings")

      result = change_password(lv, pw)

      {:ok, signed_out} = follow_redirect(result, conn)
      assert html_response(signed_out, 200) =~ "appears in a public data breach"
    end

    test "a clean password adds no warning", %{conn: conn} do
      pw = password()
      enable!(&ok(&1, clean_body(pw)))
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/settings")

      change_password(lv, pw)
      flash = assert_redirect(lv, ~p"/sign-in")

      refute Map.has_key?(flash, "error")
    end
  end

  describe "a breached new password under block" do
    setup do
      %{org: org("settingsblock")}
    end

    test "is refused for an admin, as an error on the password field", %{conn: conn, org: org} do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 31)))
      policy!(org, :block)

      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(admin) |> live(~p"/editor/settings")

      html = change_password(lv, pw)

      assert is_binary(html)
      assert html =~ "This password has appeared in a known data breach."
      assert has_element?(lv, "#password-form", "known data breach")

      # Nothing changed: the old password still signs in.
      strategy = AshAuthentication.Info.strategy!(User, :password)

      assert {:ok, _} =
               AshAuthentication.Strategy.action(
                 strategy,
                 :sign_in,
                 %{"email" => to_string(admin.email), "password" => @password},
                 []
               )
    end

    test "only the request org's policy applies", %{conn: conn, org: org} do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 31)))
      # Block is set on `org` only; the default org still warns.
      policy!(org, :block)

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/settings")

      change_password(lv, pw)
      flash = assert_redirect(lv, ~p"/sign-in")

      assert flash["error"] == PasswordNotice.message()
    end

    test "an editor is warned, not blocked", %{conn: conn, org: org} do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 31)))
      policy!(org, :block)

      editor = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: editor.id,
        organization_id: org.id,
        role: :editor
      })

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(editor) |> live(~p"/editor/settings")

      change_password(lv, pw)
      flash = assert_redirect(lv, ~p"/sign-in")

      assert flash["error"] == PasswordNotice.message()
    end
  end
end
