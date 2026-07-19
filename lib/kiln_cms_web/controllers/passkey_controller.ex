defmodule KilnCMSWeb.PasskeyController do
  @moduledoc """
  The anonymous half of passkey sign-in (#331) — a two-step JSON ceremony
  driven by progressive-enhancement JS on `/sign-in`
  (`assets/js/passkeys.js`):

    1. `POST /auth/passkey/options` mints a WebAuthn authentication challenge,
       parks it in the (encrypted) session, and returns the
       `navigator.credentials.get` options.
    2. `POST /auth/passkey/verify` consumes the parked challenge, verifies the
       assertion (`KilnCMS.Accounts.WebAuthn.authenticate/2`), establishes the
       session, and returns the redirect target.

  Runs behind the `:browser_auth` pipeline: CSRF-protected (the JS sends the
  page's csrf-token) and under the same tight per-IP `:auth` rate limit as
  every credential endpoint.

  A verified passkey completes sign-in on its own — no TOTP diversion. Every
  Kiln passkey is registered *and* asserted with user verification required,
  so the ceremony already proves possession + PIN/biometric (the same
  two-factor bar the TOTP flow enforces).
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMSWeb.SafeRedirect

  @challenge_key :passkey_challenge

  def options(conn, _params) do
    challenge = WebAuthn.authentication_challenge()

    conn
    |> put_session(@challenge_key, challenge)
    |> json(%{publicKey: WebAuthn.authentication_options(challenge)})
  end

  def verify(conn, params) do
    challenge = get_session(conn, @challenge_key)
    conn = delete_session(conn, @challenge_key)

    with %Wax.Challenge{} <- challenge,
         {:ok, user} <- WebAuthn.authenticate(challenge, params) do
      default = if user.role in [:editor, :admin], do: ~p"/editor/overview", else: ~p"/"
      return_to = SafeRedirect.local_path(get_session(conn, :return_to), default)

      conn
      |> delete_session(:return_to)
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> put_flash(:info, gettext("Signed in with a passkey."))
      |> json(%{redirect_to: return_to})
    else
      # One generic failure: don't leak whether the credential exists, failed
      # verification, or arrived without a parked challenge.
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: gettext("Passkey sign-in failed. Try another method.")})
    end
  end
end
