defmodule KilnCMSWeb.SecondFactorStepUpTest do
  @moduledoc """
  Who stops at the second-factor prompt (#2247), through both sign-in doors.

  Characterization: this release changes nothing about who is diverted. Only
  an account with the authenticator app is; a passkey-only account's password
  still completes its sign-in, because nothing requires a second factor of it
  yet (owner decision 2: "once enforced").
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.PasskeyFixtures

  alias KilnCMS.TwoFactorFixtures
  alias KilnCMSWeb.SecondFactorStepUp

  @password "password123456"

  defp password_sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/sign_in", %{
      "user" => %{"email" => to_string(user.email), "password" => @password}
    })
  end

  defp api_sign_in(conn, user) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/sign_in", %{"email" => to_string(user.email), "password" => @password})
  end

  defp passkey_only do
    user = passkey_user(:editor)
    {:ok, _} = enroll(user, "su-char-#{user.id}")
    user
  end

  defp app_holder(extra \\ []) do
    {user, _secret} = TwoFactorFixtures.enabled_user([role: :editor] ++ extra)
    user
  end

  describe "decide/2" do
    test "prompts exactly the authenticator app's holders", %{conn: conn} do
      assert SecondFactorStepUp.decide(conn, app_holder()) == :prompt
      assert SecondFactorStepUp.decide(conn, passkey_only()) == :none
      assert SecondFactorStepUp.decide(conn, passkey_user(:editor)) == :none

      both = app_holder()
      {:ok, _} = enroll(both, "su-both-#{both.id}")
      assert SecondFactorStepUp.decide(conn, both) == :prompt
    end
  end

  describe "the browser door" do
    test "a passkey-only account's password completes its sign-in", %{conn: conn} do
      signed_in = password_sign_in(conn, passkey_only())

      assert redirected_to(signed_in) == ~p"/editor/overview"
      assert is_binary(get_session(signed_in, :user_token))
      assert get_session(signed_in, :pending_2fa) == nil
    end

    test "an authenticator-app holder still stops at the prompt", %{conn: conn} do
      diverted = password_sign_in(conn, app_holder())

      assert redirected_to(diverted) == ~p"/sign-in/verify"
      assert get_session(diverted, :user_token) == nil
      assert is_binary(get_session(diverted, :pending_2fa))
    end

    test "so does an account with both factors", %{conn: conn} do
      both = app_holder()
      {:ok, _} = enroll(both, "su-both-web-#{both.id}")

      assert redirected_to(password_sign_in(conn, both)) == ~p"/sign-in/verify"
    end
  end

  describe "the headless door" do
    test "a passkey-only account's password gets its token", %{conn: conn} do
      assert %{"token" => token} = conn |> api_sign_in(passkey_only()) |> json_response(201)
      assert is_binary(token)
    end

    test "an authenticator-app holder still owes a code", %{conn: conn} do
      assert %{"two_factor_required" => true, "pending_token" => _} =
               conn |> api_sign_in(app_holder()) |> json_response(200)
    end

    test "a passkey-only blob cannot be redeemed with a code", %{conn: conn} do
      # The code route asks for the authenticator app: an account that
      # dropped it mid-prompt, keeping only a passkey, gets nothing to verify.
      user = app_holder()
      {:ok, _} = enroll(user, "su-api-#{user.id}")

      assert %{"pending_token" => pending} =
               conn |> api_sign_in(user) |> json_response(200)

      Ash.Seed.update!(user, %{totp_confirmed_at: nil})

      assert %{"errors" => [%{"code" => "pending_expired"}]} =
               build_conn()
               |> unique_ip()
               |> put_req_header("content-type", "application/json")
               |> post("/api/auth/sign_in/verify", %{
                 "pending_token" => pending,
                 "code" => "000000"
               })
               |> json_response(401)
    end
  end
end
