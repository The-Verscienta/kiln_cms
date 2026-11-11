defmodule KilnCMSWeb.PasswordPolicyLiveTest do
  @moduledoc """
  `/editor/password-policy` (#2240): the admin gate, saving a policy for the
  request's org only, the default shown when nothing is set, and the notice when
  the operator has switched the check off for the deployment.

  `async: false`: the kill-switch test edits application env, which is node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.BreachedPasswordFixtures, only: [enable!: 2, default_policy!: 1, ok: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    %{org: org("pwpolicylive")}
  end

  test "turns away an editor and a viewer", %{conn: conn} do
    for role <- [:editor, :viewer] do
      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> log_in(authed_user(role)) |> live(~p"/editor/password-policy")
    end
  end

  test "turns away a visitor who is not signed in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/password-policy")
  end

  test "shows warn as the default when nothing is set", %{conn: conn, org: org} do
    {:ok, lv, html} = admin_live(conn, org)

    assert has_element?(lv, "#password-policy-form select option[value=warn][selected]")
    assert has_element?(lv, "#password-policy-default", "default applies: Warn")
    refute has_element?(lv, "button", "Use the default")
    # The role-explanatory copy.
    assert html =~ "Block applies to administrators"
    assert html =~ "editors and everyone else are warned"
  end

  test "an admin saves a policy, and only for this org", %{conn: conn, org: org} do
    other = org("pwpolicyother")
    {:ok, lv, _html} = admin_live(conn, org)

    html =
      lv
      |> form("#password-policy-form", password_policy: %{"breached_password_policy" => "block"})
      |> render_submit()

    assert html =~ "Password policy saved."
    assert has_element?(lv, "#password-policy-form select option[value=block][selected]")

    assert {:ok, [row]} = CMS.list_site_password_policy(tenant: org, authorize?: false)
    assert row.breached_password_policy == :block
    assert {:ok, []} = CMS.list_site_password_policy(tenant: other, authorize?: false)

    # The other site's admin still sees the default.
    {:ok, lv2, _html} = admin_live(build_conn(), other)
    assert has_element?(lv2, "#password-policy-form select option[value=warn][selected]")
    refute has_element?(lv2, "button", "Use the default")
  end

  test "a value outside off, warn and block saves nothing", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    render_submit(lv, "save", %{"password_policy" => %{"breached_password_policy" => "nuke"}})

    assert {:ok, []} = CMS.list_site_password_policy(tenant: org, authorize?: false)
  end

  test "using the default drops the row", %{conn: conn, org: org} do
    CMS.save_site_password_policy!(%{breached_password_policy: :off},
      authorize?: false,
      tenant: org.id
    )

    {:ok, lv, _html} = admin_live(conn, org)
    assert has_element?(lv, "#password-policy-form select option[value=off][selected]")

    html = lv |> element("button", "Use the default") |> render_click()

    assert html =~ "reset to the default"
    assert {:ok, []} = CMS.list_site_password_policy(tenant: org, authorize?: false)
  end

  test "with no row, the operator's default is what the page shows", %{conn: conn, org: org} do
    default_policy!(:block)
    {:ok, lv, _html} = admin_live(conn, org)

    assert has_element?(lv, "#password-policy-form select option[value=block][selected]")
    assert has_element?(lv, "#password-policy-default", "default applies: Block")
  end

  describe "the operator's kill switch" do
    test "is announced when the check is off for the deployment", %{conn: conn, org: org} do
      # Off in the suite by default (`config/test.exs`).
      {:ok, lv, _html} = admin_live(conn, org)

      assert has_element?(lv, "#password-policy-disabled", "switched off")
      assert has_element?(lv, "#password-policy-disabled", "BREACHED_PASSWORD_CHECK=false")
    end

    test "is not shown while the check runs", %{conn: conn, org: org} do
      enable!(&ok(&1, ""), [])
      {:ok, lv, _html} = admin_live(conn, org)

      refute has_element?(lv, "#password-policy-disabled")
    end
  end

  test "the console nav lists the page for an admin", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    assert has_element?(lv, ~s(nav a[href="/editor/password-policy"]))
  end

  defp admin_live(conn, org) do
    conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/password-policy")
  end

  defp authed_user(role) do
    email = "pwpolicylive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
end
