defmodule KilnCMSWeb.PasskeyControllerTest do
  @moduledoc "Anonymous passkey sign-in ceremony over HTTP (#331)."
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.PasskeyFixtures

  # The :auth bucket keeps its REAL (tight) limit in tests; a unique client IP
  # per test keeps this suite out of the shared 127.0.0.1 window (the
  # documented rate-limit test flake).
  setup %{conn: conn} do
    octet = rem(System.unique_integer([:positive]), 254) + 1
    %{conn: %{conn | remote_ip: {127, 0, octet, 1}}}
  end

  test "options parks a nonce and returns WebAuthn get() options", %{conn: conn} do
    conn = post(conn, ~p"/auth/passkey/options")

    assert %{"publicKey" => %{"challenge" => challenge, "userVerification" => "required"}} =
             json_response(conn, 200)

    assert is_binary(challenge)
    # Only an opaque nonce lives in the session — the challenge parks
    # server-side (single use).
    assert is_binary(get_session(conn, :passkey_challenge_nonce))
  end

  test "verify signs in with a valid assertion and returns the destination", %{conn: conn} do
    editor = passkey_user(:editor)
    {:ok, _} = enroll(editor, "ctrl-cred")

    conn = post(conn, ~p"/auth/passkey/options")
    conn = post(conn, ~p"/auth/passkey/verify", assertion("ctrl-cred"))

    assert %{"redirect_to" => "/editor/overview"} = json_response(conn, 200)
    assert get_session(conn, :passkey_challenge_nonce) == nil
    # With require_token_presence_for_authentication?, the session stores the
    # minted token under the subject's token key.
    assert is_binary(get_session(conn, "user_token"))
  end

  test "a captured verify request cannot be replayed (single-use challenge)", %{conn: conn} do
    editor = passkey_user(:editor)
    {:ok, _} = enroll(editor, "ctrl-replay")

    optioned = post(conn, ~p"/auth/passkey/options")

    assert %{"redirect_to" => _} =
             optioned
             |> post(~p"/auth/passkey/verify", assertion("ctrl-replay"))
             |> json_response(200)

    # Same conn state (same cookie, same nonce) replayed: the parked challenge
    # was consumed, so the identical request is refused.
    assert %{"error" => _} =
             optioned
             |> post(~p"/auth/passkey/verify", assertion("ctrl-replay"))
             |> json_response(401)
  end

  test "verify without a parked challenge is rejected", %{conn: conn} do
    editor = passkey_user(:editor)
    {:ok, _} = enroll(editor, "ctrl-nochal")

    conn = post(conn, ~p"/auth/passkey/verify", assertion("ctrl-nochal"))
    assert %{"error" => _} = json_response(conn, 401)
  end

  test "verify with an unknown credential is rejected without detail", %{conn: conn} do
    conn = post(conn, ~p"/auth/passkey/options")
    conn = post(conn, ~p"/auth/passkey/verify", assertion("ctrl-ghost"))

    assert %{"error" => message} = json_response(conn, 401)
    refute message =~ "unknown"
  end

  test "a viewer lands on the site root, not the console", %{conn: conn} do
    viewer = passkey_user(:viewer)
    {:ok, _} = enroll(viewer, "ctrl-viewer")

    conn = post(conn, ~p"/auth/passkey/options")
    conn = post(conn, ~p"/auth/passkey/verify", assertion("ctrl-viewer"))

    assert %{"redirect_to" => "/"} = json_response(conn, 200)
  end
end
