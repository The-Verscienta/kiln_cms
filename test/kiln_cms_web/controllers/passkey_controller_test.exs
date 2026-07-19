defmodule KilnCMSWeb.PasskeyControllerTest do
  @moduledoc "Anonymous passkey sign-in ceremony over HTTP (#331)."
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.WebAuthn

  defp user(role \\ :editor) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pk-ctrl-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp enroll(user, credential_bytes) do
    challenge = WebAuthn.registration_challenge()

    {:ok, passkey} =
      WebAuthn.register_passkey(user, challenge, %{
        "attestation_object" => b64(credential_bytes),
        "client_data_json" => b64("{}")
      })

    passkey
  end

  defp assertion_params(credential_bytes) do
    %{
      "credential_id" => b64(credential_bytes),
      "authenticator_data" => b64("auth"),
      "signature" => b64("sig"),
      "client_data_json" => b64("{}")
    }
  end

  test "options parks a challenge and returns WebAuthn get() options", %{conn: conn} do
    conn = post(conn, ~p"/auth/passkey/options")

    assert %{"publicKey" => %{"challenge" => challenge, "userVerification" => "required"}} =
             json_response(conn, 200)

    assert is_binary(challenge)
    assert %Wax.Challenge{} = get_session(conn, :passkey_challenge)
  end

  test "verify signs in with a valid assertion and returns the destination", %{conn: conn} do
    editor = user(:editor)
    enroll(editor, "ctrl-cred")

    conn = post(conn, ~p"/auth/passkey/options")
    conn = post(conn, ~p"/auth/passkey/verify", assertion_params("ctrl-cred"))

    assert %{"redirect_to" => "/editor/overview"} = json_response(conn, 200)
    # The challenge is single-use and the session now carries the account.
    assert get_session(conn, :passkey_challenge) == nil
    assert get_session(conn, "user") || map_size(get_session(conn)) > 0
  end

  test "verify without a parked challenge is rejected", %{conn: conn} do
    editor = user(:editor)
    enroll(editor, "ctrl-nochal")

    conn = post(conn, ~p"/auth/passkey/verify", assertion_params("ctrl-nochal"))
    assert %{"error" => _} = json_response(conn, 401)
  end

  test "verify with an unknown credential is rejected without detail", %{conn: conn} do
    conn = post(conn, ~p"/auth/passkey/options")
    conn = post(conn, ~p"/auth/passkey/verify", assertion_params("ctrl-ghost"))

    assert %{"error" => message} = json_response(conn, 401)
    refute message =~ "unknown"
  end

  test "a viewer lands on the site root, not the console", %{conn: conn} do
    viewer = user(:viewer)
    enroll(viewer, "ctrl-viewer")

    conn = post(conn, ~p"/auth/passkey/options")
    conn = post(conn, ~p"/auth/passkey/verify", assertion_params("ctrl-viewer"))

    assert %{"redirect_to" => "/"} = json_response(conn, 200)
  end
end
