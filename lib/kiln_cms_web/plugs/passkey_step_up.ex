defmodule KilnCMSWeb.Plugs.PasskeyStepUp do
  @moduledoc """
  A passkey-only account past its site's deadline (#2247) must not keep
  password-only access: a session that signed in with the password before the
  deadline, or that a remember-me cookie restored, never passed the passkey
  (`KilnCMSWeb.SecondFactorGate.passkey_step_up_owed?/3`). On `:browser_auth`,
  after the session is loaded (so after `RememberMeSignIn` too), such a session
  is turned back into a pending sign-in and sent through the passkey step-up,
  as a fresh password sign-in would be (`KilnCMSWeb.AuthController.success/4`):

    * on a host where the passkey ceremony runs
      (`KilnCMS.Accounts.WebAuthn.ceremony_host?/1`), the session's token is
      revoked, a fresh first-factor token is minted and held in
      `:pending_2fa` (`KilnCMS.Accounts.PendingSignIn`), and the request goes
      to `/sign-in/verify`, which offers the passkey;
    * on a host where it cannot (a tenant site host), the token is revoked,
      the remember-me cookie deleted, and the request goes to `/sign-in` with
      the reason, as the sign-in door refuses the same password there.

  `:browser` cannot write the session (#699), so the gates there send such a
  session to `/sign-in/verify`, which runs this. Sign-out and the step-up's
  own routes are left alone.
  """
  @behaviour Plug

  use Gettext, backend: KilnCMSWeb.Gettext

  import Plug.Conn

  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMSWeb.AuthController
  alias KilnCMSWeb.SecondFactorGate
  alias KilnCMSWeb.SignInMarker

  @secure? Application.compile_env(:kiln_cms, :secure_session_cookie, false)
  @remember_me_cookie to_string(KilnCMSWeb.SessionCookie.remember_me_key(@secure?))

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    if SecondFactorGate.passkey_step_up_owed?(user, org_id(conn), conn),
      do: step_up(conn, user),
      else: conn
  end

  defp step_up(conn, user) do
    method = method(conn)
    AuthController.revoke_first_factor(get_session(conn, "user_token"))

    conn =
      conn
      |> delete_session("user_token")
      |> delete_session("sign_in")
      |> assign(:current_user, nil)

    if WebAuthn.ceremony_host?(conn.host),
      do: prompt(conn, user, method),
      else: refuse(conn)
  end

  defp prompt(conn, user, method) do
    case AshAuthentication.Jwt.token_for_user(user) do
      {:ok, token, _claims} ->
        conn
        |> put_session(
          :pending_2fa,
          PendingSignIn.mint_and_hold(:session, conn, user, token: token)
        )
        |> put_session(:sign_in_method, method)
        |> continue_or_redirect(["sign-in", "verify"], "/sign-in/verify")

      _error ->
        continue_or_redirect(conn, ["sign-in"], "/sign-in")
    end
  end

  defp refuse(conn) do
    conn
    |> delete_resp_cookie(
      @remember_me_cookie,
      KilnCMSWeb.SessionCookie.remember_me_options(@secure?)
    )
    |> Phoenix.Controller.put_flash(
      :error,
      gettext(
        "Your account's second factor is a passkey, which works at %{host}. " <>
          "Sign in there, or add an authenticator app.",
        host: URI.parse(KilnCMSWeb.Endpoint.url()).host
      )
    )
    |> continue_or_redirect(["sign-in"], "/sign-in")
  end

  # Already where it is going (a sign-in page, or one of the step-up's own
  # routes): carry on with the session as it now is.
  defp continue_or_redirect(%Plug.Conn{path_info: path_info} = conn, prefix, to) do
    if List.starts_with?(path_info, prefix) or path_info == ["sign-out"] do
      conn
    else
      conn
      |> Phoenix.Controller.redirect(to: to)
      |> halt()
    end
  end

  # How the session signed in, for the sign-in event the step-up completes.
  defp method(conn) do
    case SignInMarker.read(conn) do
      %{method: method} -> method
      nil -> "password"
    end
  end

  defp org_id(conn) do
    case conn.assigns[:current_org] do
      %{id: id} when is_binary(id) -> id
      _none -> nil
    end
  end
end
