defmodule KilnCMSWeb.Plugs.SessionTracking do
  @moduledoc """
  Notes, once per sign-in, which browser a session belongs to and which
  remember-me cookie it was issued with (#1823) — for the session list on the
  settings page, and so that signing a session out also retires its cookie.

  Runs on `:browser_auth`, the pipeline every browser sign-in passes through:
  password, magic link, single sign-on, passkey, the two-factor prompt, and the
  remember-me cookie itself. Rather than wire each of those, it looks at the
  **response**: a `before_send` that finds a session token the session has not
  been stamped for writes the stamp and remembers the jti it stamped. So the
  check is one session read per response, and the write happens once per
  sign-in.

  The remember-me cookie that belongs to this browser is the one on the
  response (just issued) or, failing that, the one the request carried. Its
  jti is recorded, not the cookie.

  The stamp also records the site (org) the session signed in on, and binds
  the remember-me cookie to it (#2246) — see `KilnCMS.Accounts.IdleTimeout`.

  What is stored is coarse on purpose: a browser family and an operating
  system from `KilnCMSWeb.UserAgent`. No user agent string, no IP address.
  """
  import Plug.Conn

  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.Token

  # The session key the stamped jti is kept under. A session whose token jti
  # differs from it has signed in since the last stamp.
  @stamped :tracked_session_jti

  @remember_me_cookie to_string(
                        KilnCMSWeb.SessionCookie.remember_me_key(
                          Application.compile_env(:kiln_cms, :secure_session_cookie, false)
                        )
                      )

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts), do: register_before_send(conn, &stamp/1)

  @doc false
  # Public for the test that drives it without a sign-in.
  def stamp(conn) do
    with token when is_binary(token) <- get_session(conn, :user_token),
         jti when is_binary(jti) <- Token.peeked_jti(token),
         false <- get_session(conn, @stamped) == jti do
      user_agent = conn |> get_req_header("user-agent") |> List.first()

      # The session's token is the server's own (the session cookie is signed),
      # so peeking it is safe; the remember-me cookie is verified below.
      Sessions.record_sign_in(
        jti,
        KilnCMSWeb.UserAgent.parse(user_agent),
        remember_me_jti(conn),
        org_id(conn),
        peeked_subject(token)
      )

      put_session(conn, @stamped, jti)
    else
      _signed_out_or_already_stamped -> conn
    end
  end

  # The site the session signs in on (#2246): sessions and remember-me cookies
  # are bound to it, for the idle timeout and "sign out everyone".
  defp org_id(conn) do
    case conn.assigns[:current_org] do
      %{id: id} when is_binary(id) -> id
      _none -> nil
    end
  end

  # The cookie just issued on this response is the server's own; one the
  # request carried is the client's and is verified first (#2246) — its row is
  # bound to the site, so a forged one must not name someone else's.
  defp remember_me_jti(conn) do
    case conn.resp_cookies[@remember_me_cookie] do
      %{value: value} when is_binary(value) and value != "" ->
        Token.peeked_jti(value)

      _none_or_deleted ->
        conn
        |> fetch_cookies()
        |> Map.get(:req_cookies)
        |> Map.get(@remember_me_cookie)
        |> verified_jti()
    end
  end

  defp verified_jti(token) when is_binary(token) do
    case AshAuthentication.Jwt.verify(token, :kiln_cms) do
      {:ok, %{"jti" => jti}, _resource} when is_binary(jti) -> jti
      _invalid -> nil
    end
  rescue
    _malformed -> nil
  end

  defp verified_jti(_token), do: nil

  defp peeked_subject(token) do
    case AshAuthentication.Jwt.peek(token) do
      {:ok, %{"sub" => sub}} when is_binary(sub) -> sub
      _ -> nil
    end
  rescue
    _malformed -> nil
  end
end
