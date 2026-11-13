defmodule KilnCMSWeb.SignInMarker do
  @moduledoc """
  How this browser session signed in, and whether it passed a second factor
  (#2247).

  One session key, `"sign_in"`, holding a map:

    * `"jti"` — the jti of the session token the marker describes;
    * `"method"` — how the first factor was passed, as
      `KilnCMS.Security.AuthEvents.method/1` names it (`"password"`,
      `"magic_link"`, `"sso"`, `"password_reset"`, …), `"passkey"` for a
      passkey sign-in, or `"remember_me"` for a session the remember-me cookie
      restored;
    * `"second_factor_at"` — Unix seconds when a second factor was verified
      for this sign-in (the code prompt, the passkey step-up, or a passkey
      sign-in, which is both factors at once); absent otherwise.

  When the session signed in is not stored: it is the session token's own
  `iat`, which `read/1` returns as `signed_in_at`.

  ## Keyed to the token, so a stale one reads as nothing

  The session outlives the token it was signed in with. An idle timeout or a
  "sign out everyone" drops the token and keeps the rest; a remember-me cookie
  then signs the same session in again. A marker that was simply a set of
  keys would be inherited by that next sign-in, and a session restored from a
  cookie would read as "verified with a passkey ten days ago". So the marker
  names the token it belongs to, and `read/1` answers only while that token is
  still the session's. Anything else — no marker, a marker for another token,
  a session from before this shipped — is `nil`, which a reader must treat as
  the weakest case: a password session with no second factor.

  Written once per sign-in by every path that establishes a session:
  `KilnCMSWeb.AuthController.complete_sign_in/5` (every strategy and both
  step-ups), `KilnCMSWeb.PasskeyController`, and
  `KilnCMSWeb.Plugs.RememberMeSignIn`. Sign-out clears the whole session.
  """
  import Plug.Conn

  @key "sign_in"

  @typedoc "What `read/1` returns for a session whose marker is current."
  @type t :: %{
          method: String.t(),
          signed_in_at: DateTime.t() | nil,
          second_factor_at: DateTime.t() | nil
        }

  @doc """
  Mark the session `conn` has just stored as signed in with `method`.

  Call **after** the token is in the session (`store_in_session/2`): the
  marker is keyed to it. A session without a token is left unmarked.

  Options:

    * `:second_factor?` — a second factor was verified for this sign-in.
  """
  @spec put(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def put(conn, method, opts \\ []) when is_binary(method) do
    case claims(get_session(conn, "user_token")) do
      %{"jti" => jti} when is_binary(jti) ->
        marker =
          %{"jti" => jti, "method" => method}
          |> put_second_factor(Keyword.get(opts, :second_factor?, false))

        put_session(conn, @key, marker)

      _no_token ->
        delete_session(conn, @key)
    end
  end

  defp put_second_factor(marker, true),
    do: Map.put(marker, "second_factor_at", System.system_time(:second))

  defp put_second_factor(marker, false), do: marker

  @doc """
  The marker of the session `source` carries — a conn, or a session map as a
  LiveView's `mount/3` receives it — or `nil` when it has none that belongs to
  its current token.
  """
  @spec read(Plug.Conn.t() | map()) :: t() | nil
  def read(%Plug.Conn{} = conn), do: read(get_session(conn))

  def read(%{} = session) do
    with %{"jti" => jti, "method" => method} when is_binary(method) <- Map.get(session, @key),
         %{"jti" => ^jti} = claims <- claims(Map.get(session, "user_token")) do
      %{
        method: method,
        signed_in_at: from_unix(claims["iat"]),
        second_factor_at: from_unix(Map.get(session, @key)["second_factor_at"])
      }
    else
      _stale_or_absent -> nil
    end
  end

  def read(_session), do: nil

  # The session's own token, so peeking it is safe: the session cookie is
  # signed and the token was put there by the server. `Jwt.peek/1` raises on a
  # malformed token rather than answering, and a session that cannot be read
  # is simply unmarked.
  defp claims(token) when is_binary(token) do
    case AshAuthentication.Jwt.peek(token) do
      {:ok, %{} = claims} -> claims
      _ -> nil
    end
  rescue
    _malformed -> nil
  end

  defp claims(_token), do: nil

  defp from_unix(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> at
      _ -> nil
    end
  end

  defp from_unix(_seconds), do: nil
end
