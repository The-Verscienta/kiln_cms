defmodule KilnCMSWeb.Plugs.IdleTimeout do
  @moduledoc """
  The idle timeout and "sign out everyone" (#2246) on browser requests. The
  decisions are `KilnCMS.Accounts.IdleTimeout`'s; this is where a request acts
  on them. Four modes:

    * `:session` — on `:browser`, after `load_from_session`. A signed-in
      request whose session is idle, predates the site's last "sign out
      everyone", or is bound to another site is served signed out. It notes
      the use when the session is active. It **writes no session and no
      cookie**: `:browser` serves the public site, whose pages are
      `cache-control: public` (#699), and a `Set-Cookie` there could be stored
      by a shared cache and handed to every visitor. The session cookie keeps
      naming the revoked token until the browser reaches `:browser_auth`.
    * `{:session, writes_session?: true}` — the same on `:browser_auth`, which
      may write: it also drops the token from the session, deletes the
      remember-me cookie and says why in the flash.
    * `:remember_me` — on `:browser_auth`, ahead of `sign_in_with_remember_me`,
      acting only on a cookie whose signature verifies, and only on the row of
      the account it names.
      A remember-me cookie whose row is idle, predates "sign out everyone", or
      is bound to another site does not sign the browser in: idle wins over
      remember-me.
    * `:notice` — on `:browser_auth`, ahead of `load_from_session`: when the
      session names a token this module (or a page) revoked for inactivity or
      by "sign out everyone", the sign-in page says so.
    * `:read_only` — on `:media_transform`, which ignores the session: only
      while the site has a timeout or a recent "sign out everyone", a session
      that is no longer good is served as anonymous. Nothing is written,
      the token row included.

  A row that cannot be read leaves the request as `load_from_session` found
  it: the check fails open, logged.
  """
  import Plug.Conn

  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Security.Recorder

  @secure? Application.compile_env(:kiln_cms, :secure_session_cookie, false)
  @remember_me_cookie to_string(KilnCMSWeb.SessionCookie.remember_me_key(@secure?))

  @doc false
  def init(:session), do: {:session, []}
  def init({:session, opts}) when is_list(opts), do: {:session, opts}
  def init(mode) when mode in [:remember_me, :notice, :read_only], do: mode

  @doc false
  def call(conn, {:session, opts}), do: session(conn, opts)
  def call(conn, :remember_me), do: remember_me(conn)
  def call(conn, :notice), do: notice(conn)
  def call(conn, :read_only), do: read_only(conn)

  # --- :session ----------------------------------------------------------------

  defp session(conn, opts) do
    with %{} = user <- conn.assigns[:current_user],
         jti when is_binary(jti) <- session_jti(conn),
         org_id when is_binary(org_id) <- org_id(conn) do
      case IdleTimeout.check(jti, org_id,
             subject: AshAuthentication.user_to_subject(user),
             tier: fn -> Scoping.effective_tier(user, org_id) end,
             user: user,
             surface: "http",
             labels: labels(conn),
             request: Recorder.request_context(conn)
           ) do
        {:signed_out, why} -> signed_out(conn, why, opts)
        _active_or_unreadable -> conn
      end
    else
      _signed_out_or_no_site -> conn
    end
  end

  defp signed_out(conn, why, opts) do
    conn = assign(conn, :current_user, nil)

    cond do
      not Keyword.get(opts, :writes_session?, false) ->
        conn

      # Bound to another site: this host's session simply does not hold it.
      # Nothing was revoked, so there is nothing to tell the person.
      why == :foreign ->
        delete_session(conn, :user_token)

      true ->
        conn
        |> delete_session(:user_token)
        |> forget_remember_me()
        |> put_reason_flash(why)
    end
  end

  # --- :remember_me ------------------------------------------------------------

  defp remember_me(conn) do
    conn = fetch_cookies(conn)

    with nil <- get_session(conn, :user_token),
         {:ok, %{"jti" => jti, "sub" => subject}} <- verified(conn.cookies[@remember_me_cookie]),
         org_id when is_binary(org_id) <- org_id(conn) do
      case IdleTimeout.check(jti, org_id,
             subject: subject,
             # The cookie's own account, on this site — read only when the
             # tier changes the answer.
             tier: fn row -> Scoping.effective_tier(IdleTimeout.user_for(row), org_id) end,
             touch?: false,
             surface: "remember_me",
             request: Recorder.request_context(conn)
           ) do
        {:signed_out, :foreign} ->
          # Copied from another site's host: not a credential here. The
          # browser's cookie is left alone; this request just does not use it.
          drop_request_cookie(conn)

        {:signed_out, why} ->
          conn |> forget_remember_me() |> put_reason_flash(why)

        _active_or_unreadable ->
          conn
      end
    else
      _session_or_no_cookie -> conn
    end
  end

  # --- :notice -----------------------------------------------------------------

  defp notice(conn) do
    with jti when is_binary(jti) <- session_jti(conn),
         {:ok, %Token{purpose: "revocation"} = row} <- IdleTimeout.read(jti, IdleTimeout.off()) do
      put_reason_flash(conn, IdleTimeout.revoked_reason(row))
    else
      _live_or_unknown -> conn
    end
  end

  # --- :read_only --------------------------------------------------------------

  defp read_only(conn) do
    with %{} = user <- conn.assigns[:current_user],
         jti when is_binary(jti) <- session_jti(conn),
         org_id when is_binary(org_id) <- org_id(conn),
         policy = IdleTimeout.policy(org_id),
         true <- enforcing?(policy),
         {:ok, row} <- IdleTimeout.read(jti, policy) do
      case IdleTimeout.verdict(row, policy, org_id,
             subject: AshAuthentication.user_to_subject(user),
             tier: fn -> Scoping.effective_tier(user, org_id) end
           ) do
        {:active, _state} -> conn
        _no_longer_good -> assign(conn, :current_user, nil)
      end
    else
      _anonymous_off_or_unreadable -> conn
    end
  end

  defp enforcing?(policy),
    do: IdleTimeout.timeout_seconds(policy, :admin) != nil or IdleTimeout.watermark?(policy)

  # --- helpers -----------------------------------------------------------------

  defp session_jti(conn), do: Token.peeked_jti(get_session(conn, :user_token))

  # A remember-me cookie, verified (signature, expiry) before anything is done
  # about the row it names: the cookie is the client's, and a peeked jti would
  # let a forged one act on another account's row. A failure leaves the
  # cookie to `sign_in_with_remember_me`, which refuses it.
  defp verified(token) when is_binary(token) do
    case AshAuthentication.Jwt.verify(token, :kiln_cms) do
      {:ok, %{"jti" => jti, "sub" => sub} = claims, _resource}
      when is_binary(jti) and is_binary(sub) ->
        {:ok, claims}

      _invalid ->
        :invalid
    end
  rescue
    _malformed -> :invalid
  end

  defp verified(_token), do: :invalid

  defp org_id(conn) do
    case conn.assigns[:current_org] do
      %{id: id} when is_binary(id) -> id
      _none -> nil
    end
  end

  defp labels(conn),
    do: conn |> get_req_header("user-agent") |> List.first() |> KilnCMSWeb.UserAgent.parse()

  # Deleted on the response, with the attributes it was set with (the
  # `__Host-` prefix needs them to match), and dropped from this request so
  # `sign_in_with_remember_me` does not read it.
  defp forget_remember_me(conn) do
    conn
    |> drop_request_cookie()
    |> delete_resp_cookie(
      @remember_me_cookie,
      KilnCMSWeb.SessionCookie.remember_me_options(@secure?)
    )
  end

  defp drop_request_cookie(conn) do
    %{
      conn
      | cookies: Map.delete(conn.cookies, @remember_me_cookie),
        req_cookies: Map.delete(conn.req_cookies, @remember_me_cookie)
    }
  end

  defp put_reason_flash(conn, why) do
    case KilnCMSWeb.IdleSession.reason_message(why) do
      nil -> conn
      message -> Phoenix.Controller.put_flash(conn, :info, message)
    end
  end
end
