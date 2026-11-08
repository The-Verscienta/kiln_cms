defmodule KilnCMSWeb.EnumerationSignInTest do
  @moduledoc """
  Password sign-in does not say whether an address has an account (#2255).

  Two doors take an email and a password: the browser form (a LiveView event
  over `/live`, and the form POST that backs it) and the headless
  `POST /api/auth/sign_in`. For each, a **known** address with a wrong password
  and an **unknown** address must produce the same status, redirect, flash and
  body — compared whole by `KilnCMS.EnumerationAssertions`, not by substring.

  The *work* is asserted too, where wall-clock cannot be: an unknown address
  must still pay for one bcrypt check (`Bcrypt.no_user_verify/1`), as a known
  one with a wrong password pays for `Bcrypt.verify_pass/2`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  defp address(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp seed_user(address, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: address,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        },
        attrs
      )
    )
  end

  describe "browser sign-in, the LiveView submit" do
    defp submit_sign_in(conn, address, password) do
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      view
      |> form("form[action='/auth/user/password/sign_in']",
        user: %{email: address, password: password}
      )
      |> render_submit()
    end

    test "a wrong password and an unknown address render the same page", %{conn: conn} do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      html =
        assert_indistinguishable(
          fn -> submit_sign_in(conn, known, "not-the-password") end,
          fn -> submit_sign_in(build_conn(), unknown, "not-the-password") end,
          [known, unknown]
        )

      # Pinned, so "equal" cannot mean "equally empty".
      assert html =~ "Email or password was incorrect"
    end
  end

  describe "browser sign-in, the form POST" do
    defp post_sign_in(address, password) do
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> post(~p"/auth/user/password/sign_in", %{
        "user" => %{"email" => address, "password" => password}
      })
    end

    test "a wrong password and an unknown address redirect alike, with one flash" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      seen =
        assert_indistinguishable(
          fn -> post_sign_in(known, "not-the-password") end,
          fn -> post_sign_in(unknown, "not-the-password") end,
          [known, unknown]
        )

      assert seen.status == 302
      assert seen.headers == [{"location", "/sign-in"}]
      assert seen.flash == %{"error" => "Incorrect email or password"}
    end
  end

  describe "headless sign-in, POST /api/auth/sign_in" do
    defp api_sign_in(address, password) do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/auth/sign_in", %{"email" => address, "password" => password})
    end

    test "a wrong password and an unknown address get the same 401" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      seen =
        assert_indistinguishable(
          fn -> api_sign_in(known, "not-the-password") end,
          fn -> api_sign_in(unknown, "not-the-password") end,
          [known, unknown]
        )

      assert seen.status == 401

      assert Jason.decode!(seen.body) == %{
               "errors" => [
                 %{
                   "status" => "401",
                   "code" => "invalid_credentials",
                   "detail" => "Invalid email or password"
                 }
               ]
             }
    end
  end

  describe "the work an unknown address costs" do
    @counted [{Bcrypt, :verify_pass, 2}, {Bcrypt, :no_user_verify, 1}]

    defp sign_in_action(address, password) do
      strategy = AshAuthentication.Info.strategy!(User, :password)

      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => address, "password" => password},
        []
      )
    end

    test "is one bcrypt check, the same count a wrong password costs" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      {{:error, _}, on_known} =
        count_calls(fn -> sign_in_action(known, "not-the-password") end, @counted)

      {{:error, _}, on_unknown} =
        count_calls(fn -> sign_in_action(unknown, "not-the-password") end, @counted)

      # Different functions (a real verify vs a dummy one) but the same number
      # of hash operations: neither side answers faster for being a miss.
      assert on_known[{Bcrypt, :verify_pass, 2}] == 1
      assert on_known[{Bcrypt, :no_user_verify, 1}] == 0
      assert on_unknown[{Bcrypt, :verify_pass, 2}] == 0
      assert on_unknown[{Bcrypt, :no_user_verify, 1}] == 1
    end
  end
end
