defmodule KilnCMSWeb.AuthController do
  use KilnCMSWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMSWeb.SafeRedirect

  # Same flag the session cookie rides, for the same reason: `__Host-` is only
  # honoured alongside `Secure`, and dev/test/e2e serve over plain HTTP.
  @secure_cookies Application.compile_env(:kiln_cms, :secure_session_cookie, false)
  @remember_me_cookie KilnCMSWeb.SessionCookie.remember_me_key(@secure_cookies)

  def success(conn, activity, user, token) do
    # If the account has two-factor enabled, the first factor alone must not grant
    # a session: stash a signed, expiring pending token (carrying the first-factor
    # auth token, already minted + stored) and divert to the code prompt.
    # Everything else completes the sign-in immediately.
    if Accounts.totp_enabled?(user) do
      # Read before withholding: deleting a cookie *adds* a `resp_cookies` entry,
      # so the check has to happen first.
      remember_me? = remember_me_pending?(conn)

      conn
      |> withhold_remember_me()
      |> put_session(
        :pending_2fa,
        PendingSignIn.mint(:session, conn, user, token: token, remember_me?: remember_me?)
      )
      |> redirect(to: ~p"/sign-in/verify")
    else
      complete_sign_in(conn, user, message_for(activity))
    end
  end

  # A remember-me cookie is a *complete* sign-in in a cookie: the read plug hands
  # it to `store_in_session/2` directly, which never passes through this module
  # and so never reaches the diversion above. AshAuthentication writes it in
  # `Plug.Dispatcher` **before** calling `success/4`, so by the time we know the
  # account has a second factor the cookie is already on the response — issued to
  # someone who has proved only the first factor.
  #
  # Left alone, that is not a weakened second factor, it is no second factor at
  # all: tick the box, abandon the code prompt, and the resulting cookie signs
  # you in for thirty days without one. So the cookie is withdrawn here and the
  # *intent* is carried across the prompt instead; `KilnCMSWeb.TwoFactorController`
  # issues it once the code verifies. See #699 and #714.
  defp withhold_remember_me(conn) do
    if remember_me_pending?(conn) do
      delete_remember_me_cookie(conn, to_string(@remember_me_cookie))
    else
      conn
    end
  end

  # A remember-me cookie carrying an actual value on the response, i.e. one the
  # dispatcher just issued — as opposed to the empty, expired one a deletion
  # leaves behind.
  defp remember_me_pending?(conn) do
    case conn.resp_cookies[to_string(@remember_me_cookie)] do
      %{value: value} when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  @doc """
  Issues the remember-me cookie for a sign-in that has completed *every* factor.

  Called by `KilnCMSWeb.TwoFactorController` once a code verifies, because
  AshAuthentication issues the cookie at the first factor and this is the only
  point at which a 2FA account has actually signed in. Minting a fresh token
  rather than stashing the withheld one keeps a thirty-day credential out of the
  five-minute pending blob entirely.

  Best-effort: a sign-in that has already succeeded must not fail because a
  convenience cookie could not be minted.
  """
  @spec put_remember_me(Plug.Conn.t(), Accounts.User.t()) :: Plug.Conn.t()
  def put_remember_me(conn, user) do
    strategy = AshAuthentication.Info.strategy!(Accounts.User, :remember_me)

    case AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "remember_me"},
           purpose: :remember_me,
           token_lifetime: strategy.token_lifetime
         ) do
      {:ok, token, _claims} ->
        put_remember_me_cookie(conn, to_string(@remember_me_cookie), %{
          token: token,
          max_age: AshAuthentication.Utils.lifetime_to_seconds(strategy.token_lifetime)
        })

      _error ->
        conn
    end
  end

  @doc """
  Establish the session for `user` and redirect to their destination. Shared by
  the no-2FA path here and by `TwoFactorController` once the code is verified.
  """
  def complete_sign_in(conn, user, message) do
    return_to = sign_in_destination(conn, user)

    conn
    |> delete_session(:return_to)
    |> delete_session(:pending_2fa)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  @doc """
  Where this user lands after signing in (#157): editors/admins default to the
  console overview, viewers to the site root, and an explicit `return_to`
  session value (safe-listed to local paths) wins. Shared by every sign-in
  completion — the redirecting flows here and the JSON passkey ceremony
  (`PasskeyController`) — so the landing rules can't drift per method.
  """
  def sign_in_destination(conn, user) do
    # A reader lands on their own account page (#337 Phase 2), not the site root
    # — `/` is a dead end for someone who just signed in to manage a membership.
    default = if user.role in [:editor, :admin], do: ~p"/editor/overview", else: ~p"/account"
    SafeRedirect.local_path(get_session(conn, :return_to), default)
  end

  @doc """
  Writes the remember-me cookie with the attributes its `__Host-` name requires
  (#699).

  Overrides AshAuthentication's default writer, which hardcodes
  `secure: Mix.env() != :dev` and leaves the name unprefixed — the exact shape
  #686 closed for the session cookie, on a credential that is strictly better
  for an attacker: thirty days rather than a browser session, and it signs in a
  visitor who has no session at all.

  The attributes come from `KilnCMSWeb.SessionCookie.remember_me_options/1` so
  the production shape is constructible, and therefore assertable, from a
  non-production build — the same seam `options/1` gives the session cookie.
  """
  @impl true
  def put_remember_me_cookie(conn, cookie_name, %{token: token, max_age: max_age}) do
    opts =
      Keyword.put(
        KilnCMSWeb.SessionCookie.remember_me_options(@secure_cookies),
        :max_age,
        max_age
      )

    Plug.Conn.put_resp_cookie(conn, cookie_name, token, opts)
  end

  @doc """
  Clears the remember-me cookie on sign-out.

  The attributes have to match what `put_remember_me_cookie/3` wrote or the
  browser keeps the old cookie and the "signed out" user is signed straight back
  in on their next page load, so both come from the same place.

  In production the library's own deleter would in fact be equivalent — Plug
  defaults `path` to `"/"` and adds `Secure` on an HTTPS conn — so what this
  earns is the *test* and *dev* case, where the dep compiles
  `Mix.env() != :dev` to `true` and would emit a `Secure` deletion over plain
  HTTP, and the guarantee that the two sides cannot drift apart later.
  """
  @impl true
  def delete_remember_me_cookie(conn, cookie_name) do
    Plug.Conn.delete_resp_cookie(
      conn,
      cookie_name,
      KilnCMSWeb.SessionCookie.remember_me_options(@secure_cookies)
    )
  end

  defp message_for({:confirm_new_user, :confirm}),
    do: gettext("Your email address has now been confirmed")

  defp message_for({:password, :reset}), do: gettext("Your password has successfully been reset")
  defp message_for(_activity), do: gettext("You are now signed in")

  def failure(conn, activity, reason) do
    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          gettext(
            "You have already signed in another way, but have not confirmed your account. " <>
              "You can confirm your account using the link we sent to you, or by resetting your password."
          )

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          gettext(
            "An account with this email already exists. We've sent a link to that " <>
              "address - confirm it to finish linking this provider to your account."
          )

        # An OAuth redirect flow involves no password — "incorrect password"
        # would mislead users and mask operator misconfiguration (missing
        # OIDC_* secrets). Detail goes to the log, not the public flash.
        {{:sso, _phase}, reason} ->
          require Logger
          Logger.warning("SSO sign-in failed: #{inspect(reason)}")

          gettext(
            "Single sign-on failed — the identity couldn't be verified or linked. " <>
              "Try again, or contact an administrator."
          )

        _ ->
          gettext("Incorrect email or password")
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  @impl true
  def sign_out(conn, _params) do
    return_to = SafeRedirect.local_path(get_session(conn, :return_to), ~p"/")

    conn
    |> clear_session(:kiln_cms)
    # `clear_session/2` already deletes the remember-me cookie — but through the
    # *library's* writer, whose attributes are not the ones we wrote it with
    # (`secure: Mix.env() != :dev`, no explicit `path`). A browser only replaces
    # a cookie whose name, domain and path all match, so re-deleting it through
    # our own override is what makes sign-out actually stick. Getting this wrong
    # would sign the user straight back in on their next page load, for thirty
    # days, with no session needed — `sign_in_with_remember_me` runs ahead of
    # `load_from_session`.
    |> delete_remember_me_cookie(to_string(@remember_me_cookie))
    |> put_flash(:info, gettext("You are now signed out"))
    |> redirect(to: return_to)
  end
end
