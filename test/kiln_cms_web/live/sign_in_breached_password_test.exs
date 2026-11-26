defmodule KilnCMSWeb.SignInBreachedPasswordTest do
  @moduledoc """
  The breached-password check at an administrator's sign-in (#2407), at each
  door that carries a password: the sign-in form (LiveView), the no-JavaScript
  form POST behind it, and `POST /api/auth/sign_in`. A refusal lands on the
  reset page (or the API's `403 password_reset_required`) with no session and
  no token; a warning signs in and says so. One lookup per sign-in, none per
  keystroke.

  What the action decides is `KilnCMS.Accounts.Preparations.CheckBreachedPasswordAtSignInTest`.

  `async: false`: the breach stub and the notice store are node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.BreachedPasswordFixtures
  import KilnCMS.RateLimitHelpers, only: [client_conn: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.PasswordNotice
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.TwoFactorFixtures
  alias KilnCMSWeb.AuthController

  @form "#user-password-sign-in-with-password"
  @hand_off "#user-password-sign-in-with-password-sign-in-with-token"

  setup do
    Cachex.clear(PasswordNotice.cache())
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  # An administrator of the default org (the host these requests resolve to),
  # by membership: a viewer globally.
  defp admin!(password) do
    user =
      Ash.Seed.seed!(User, %{
        email: "bp-door-#{uniq()}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(password),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    make_admin!(user)
  end

  defp make_admin!(user) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: Accounts.default_org_id(),
      user_id: user.id,
      role: :admin
    })

    on_exit(fn -> AccountThrottle.reset(to_string(user.email)) end)
    user
  end

  defp checks!(policy) do
    CMS.save_site_password_policy!(
      %{breached_password_policy: policy, check_on_sign_in: true},
      authorize?: false,
      tenant: Accounts.default_org_id()
    )
  end

  defp conn!, do: build_conn() |> client_conn() |> elem(0)

  defp requests(n \\ 0) do
    receive do
      {:hibp_request, _, _} -> requests(n + 1)
    after
      0 -> n
    end
  end

  defp submit(view, user, password) do
    view
    |> form(@form, user: %{email: to_string(user.email), password: password})
    |> render_submit()
  end

  describe "the sign-in form" do
    test "a blocked password goes to /reset with the flash, and no session" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:block)
      admin = admin!(pw)

      {:ok, view, _html} = live(conn!(), ~p"/sign-in")

      result = submit(view, admin, pw)
      assert {:error, {:live_redirect, %{to: "/reset"}}} = result
      assert requests() == 1

      # The flash (signed into the redirect) is shown on the reset page.
      {:ok, _reset, html} = follow_redirect(result, conn!())

      message =
        AuthController.password_reset_required_message()
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

      assert html =~ message
      refute html =~ to_string(admin.email)
    end

    test "a warned password signs in with the sign-in warning, after one lookup in all" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:warn)
      admin = admin!(pw)

      {:ok, view, _html} = live(conn!(), ~p"/sign-in")

      # Typing is not an attempt: no lookup per keystroke.
      for typed <- ["a", "ab", pw] do
        view
        |> form(@form, user: %{email: to_string(admin.email), password: typed})
        |> render_change()
      end

      assert requests() == 0

      html = submit(view, admin, pw)
      assert html =~ String.trim_leading(@hand_off, "#")

      exchanged =
        view
        |> form(@hand_off)
        |> follow_trigger_action(Phoenix.ConnTest.init_test_session(conn!(), %{}))

      # The token exchange runs no second lookup.
      assert requests() == 1
      assert get_session(exchanged, "user_token")

      assert Phoenix.Flash.get(exchanged.assigns.flash, :error) ==
               PasswordNotice.message(:sign_in)
    end

    test "a clean password signs in with nothing to show" do
      pw = password()
      enable!(&ok(&1, clean_body(pw)))
      checks!(:block)
      admin = admin!(pw)

      {:ok, view, _html} = live(conn!(), ~p"/sign-in")
      submit(view, admin, pw)

      exchanged =
        view
        |> form(@hand_off)
        |> follow_trigger_action(Phoenix.ConnTest.init_test_session(conn!(), %{}))

      assert requests() == 1
      assert get_session(exchanged, "user_token")
      assert Phoenix.Flash.get(exchanged.assigns.flash, :error) == nil
    end

    test "a wrong password is the usual refusal, with no lookup" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:block)
      admin = admin!(pw)

      {:ok, view, _html} = live(conn!(), ~p"/sign-in")
      html = submit(view, admin, pw <> "-wrong")

      assert is_binary(html)
      assert requests() == 0
    end
  end

  describe "the form POST" do
    defp post_sign_in(user, password) do
      conn!()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post(~p"/auth/user/password/sign_in", %{
        "user" => %{"email" => to_string(user.email), "password" => password}
      })
    end

    test "a blocked password redirects to /reset with the flash, and no session token" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:block)

      conn = post_sign_in(admin!(pw), pw)

      assert redirected_to(conn) == "/reset"
      assert get_session(conn, "user_token") == nil
      assert get_session(conn, :pending_2fa) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               AuthController.password_reset_required_message()
    end

    test "a blocked two-factor administrator is sent to /reset, not to the code prompt" do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :viewer)
      make_admin!(user)
      pw = TwoFactorFixtures.password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:block)

      conn = post_sign_in(user, pw)

      assert redirected_to(conn) == "/reset"
      assert get_session(conn, :pending_2fa) == nil
    end

    test "a warned two-factor administrator gets the code prompt, carrying the warning" do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :viewer)
      make_admin!(user)
      pw = TwoFactorFixtures.password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:warn)

      conn = post_sign_in(user, pw)

      assert redirected_to(conn) == "/sign-in/verify"
      assert get_session(conn, :pending_2fa)
      assert get_session(conn, :password_breach_notice) == "sign_in"
    end
  end

  describe "POST /api/auth/sign_in" do
    defp api_sign_in(user, password) do
      conn!()
      |> put_req_header("content-type", "application/json")
      |> post("/api/auth/sign_in", %{email: to_string(user.email), password: password})
    end

    test "a blocked password is 403 password_reset_required, with no token" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:block)

      conn = api_sign_in(admin!(pw), pw)
      body = json_response(conn, 403)

      assert [%{"code" => "password_reset_required", "detail" => detail}] = body["errors"]
      assert detail =~ "A reset link has been emailed"
      refute Map.has_key?(body, "token")
    end

    test "a warned password is the 201, with the additive password_breach field" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:warn)
      admin = admin!(pw)

      body = json_response(api_sign_in(admin, pw), 201)

      assert is_binary(body["token"])
      assert body["password_breach"] == %{"status" => "breached"}
      # A headless sign-in leaves no note for a browser to show.
      refute PasswordNotice.take(admin.id)
    end

    test "a clean password is the 201 it always was" do
      pw = password()
      enable!(&ok(&1, clean_body(pw)))
      checks!(:block)

      body = json_response(api_sign_in(admin!(pw), pw), 201)

      assert is_binary(body["token"])
      refute Map.has_key?(body, "password_breach")
    end

    test "a two-factor administrator: blocked is the 403; clean is the pending 200" do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :viewer)
      make_admin!(user)
      pw = TwoFactorFixtures.password()
      checks!(:block)

      enable!(&ok(&1, breached_body(pw, 9)))

      assert [%{"code" => "password_reset_required"}] =
               json_response(api_sign_in(user, pw), 403)["errors"]

      enable!(&ok(&1, clean_body(pw)))
      assert %{"two_factor_required" => true} = json_response(api_sign_in(user, pw), 200)
    end

    test "a wrong password is the generic 401, with no lookup" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      checks!(:block)

      assert [%{"code" => "invalid_credentials"}] =
               json_response(api_sign_in(admin!(pw), pw <> "x"), 401)["errors"]

      assert requests() == 0
    end
  end
end
