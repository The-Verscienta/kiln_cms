defmodule KilnCMSWeb.Plugs.RememberMeSignIn do
  @moduledoc """
  AshAuthentication's `sign_in_with_remember_me`, plus the sign-in marker
  (#2247).

  A remember-me cookie signs a visitor in without passing
  `KilnCMSWeb.AuthController`, so nothing there can mark how the session
  signed in. Left unmarked it would read as no marker at all, which is safe
  (`KilnCMSWeb.SignInMarker` ignores a marker for any other token), but a
  session restored from a cookie is worth saying so: it marks
  `"remember_me"`, and never inherits what an earlier sign-in in the same
  session proved.

  Marks only when this request's call actually signed someone in: a session
  that already named a user is left as it was, as the library leaves it.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMSWeb.SignInMarker

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    before = get_session(conn, "user_token")
    conn = AshAuthentication.Phoenix.Plug.sign_in_with_remember_me(conn, opts)

    case get_session(conn, "user_token") do
      token when is_binary(token) and token != before -> SignInMarker.put(conn, "remember_me")
      _unchanged -> conn
    end
  end
end
