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
    with jti when is_binary(jti) <- Token.peeked_jti(get_session(conn, :user_token)),
         false <- get_session(conn, @stamped) == jti do
      user_agent = conn |> get_req_header("user-agent") |> List.first()
      Sessions.record_sign_in(jti, KilnCMSWeb.UserAgent.parse(user_agent), remember_me_jti(conn))
      put_session(conn, @stamped, jti)
    else
      _signed_out_or_already_stamped -> conn
    end
  end

  defp remember_me_jti(conn) do
    issued =
      case conn.resp_cookies[@remember_me_cookie] do
        %{value: value} when is_binary(value) and value != "" -> value
        _none_or_deleted -> nil
      end

    Token.peeked_jti(issued || fetch_cookies(conn).req_cookies[@remember_me_cookie])
  end
end
