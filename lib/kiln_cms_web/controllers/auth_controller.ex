defmodule KilnCMSWeb.AuthController do
  use KilnCMSWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AlreadyRegistered
  alias KilnCMS.Accounts.Errors.ChallengeRequired
  alias KilnCMS.Accounts.PasswordNotice
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Security.AuthEvents
  alias KilnCMSWeb.ChallengeComponents
  alias KilnCMSWeb.SafeRedirect
  alias KilnCMSWeb.SecondFactorStepUp
  alias KilnCMSWeb.SignInMarker

  # Same flag the session cookie rides, for the same reason: `__Host-` is only
  # honoured alongside `Secure`, and dev/test/e2e serve over plain HTTP.
  @secure_cookies Application.compile_env(:kiln_cms, :secure_session_cookie, false)
  @remember_me_cookie KilnCMSWeb.SessionCookie.remember_me_key(@secure_cookies)

  # Registering is not signing in, whether the address was new or already had
  # an account (#2255): either way the answer is the same sentence, and the
  # account's owner learns the rest from their inbox.
  def success(conn, {:password, :register}, _user, _token), do: registration_requested(conn)

  def success(conn, activity, user, token) do
    conn = carry_password_notice(conn, activity, user)

    # If the account owes a second factor, the first factor alone must not grant
    # a session: stash a signed, expiring pending token (carrying the first-factor
    # auth token, already minted + stored) and divert to the prompt. Who owes
    # one is `SecondFactorStepUp`'s decision, shared with the headless door.
    # Everything else completes the sign-in immediately.
    if SecondFactorStepUp.decide(conn, user) == :prompt do
      # Read before withholding: deleting a cookie *adds* a `resp_cookies` entry,
      # so the check has to happen first.
      remember_me? = remember_me_pending?(conn)

      conn
      |> withhold_remember_me()
      |> put_session(
        :pending_2fa,
        PendingSignIn.mint_and_hold(:session, conn, user,
          token: token,
          remember_me?: remember_me?
        )
      )
      # How the first factor was passed, for the sign-in event the code prompt
      # completes (#2241).
      |> put_session(:sign_in_method, AuthEvents.method(activity))
      |> redirect(to: ~p"/sign-in/verify")
    else
      complete_sign_in(conn, user, message_for(activity), AuthEvents.method(activity))
    end
  end

  # The "breached password" note left by a register or reset (#2240) is taken
  # only at a *password* sign-in (register, reset, sign-in, sign-in with token),
  # never at a magic link or any other method. It rides the session, as a
  # boolean, to wherever the sign-in completes: straight away below, or after
  # the second factor in `TwoFactorController`.
  defp carry_password_notice(conn, {:password, _phase}, user) do
    # Always drop any earlier marker first: one left by another account that
    # abandoned its second-factor prompt must not surface for this one.
    conn = delete_session(conn, :password_breach_notice)

    if PasswordNotice.take(user.id),
      do: put_session(conn, :password_breach_notice, true),
      else: conn
  end

  # Any other method: drop a leftover from an abandoned password attempt, so a
  # later magic-link + second-factor sign-in cannot surface it.
  defp carry_password_notice(conn, _activity, _user),
    do: delete_session(conn, :password_breach_notice)

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
  def complete_sign_in(conn, user, message),
    do: complete_sign_in(conn, user, message, get_session(conn, :sign_in_method) || "password")

  @doc """
  `complete_sign_in/3` for a caller that knows how the sign-in was made. Records
  the `:sign_in` security event (#2241) with `method`: this is where every
  password, magic-link, SSO and post-second-factor sign-in completes.

  Marks the session with how it signed in (`KilnCMSWeb.SignInMarker`, #2247).
  Options:

    * `:second_factor?` — a second factor was verified for this sign-in (the
      code prompt or the passkey step-up).
  """
  def complete_sign_in(conn, user, message, method, opts \\ []) do
    {conn, return_to} = establish_session(conn, user, message, method, opts)
    redirect(conn, to: return_to)
  end

  @doc """
  Everything `complete_sign_in/5` does but the redirect: returns the conn with
  the session established and where to send the user. For a door that answers
  JSON and lets its script follow (the passkey step-up, #2247).
  """
  @spec establish_session(Plug.Conn.t(), Accounts.User.t(), String.t(), String.t(), keyword()) ::
          {Plug.Conn.t(), String.t()}
  def establish_session(conn, user, message, method, opts \\ []) do
    return_to = sign_in_destination(conn, user)
    notice? = get_session(conn, :password_breach_notice) == true

    AuthEvents.signed_in(conn, user, method)

    conn =
      conn
      |> delete_session(:sign_in_method)
      |> delete_session(:return_to)
      |> delete_session(:password_breach_notice)
      |> delete_session(:pending_2fa)
      |> store_in_session(user)
      # After the store: the marker is keyed to the token just stored.
      |> SignInMarker.put(method, second_factor?: Keyword.get(opts, :second_factor?, false))
      |> put_live_socket_id(user)
      # If your resource has a different name, update the assign name here (i.e :current_admin)
      |> assign(:current_user, user)
      |> put_flash(:info, message)
      |> flash_password_notice(notice?)

    {conn, return_to}
  end

  # `:error`, not `:info`: the info flash dismisses itself, and this is a
  # nudge to act on.
  defp flash_password_notice(conn, true), do: put_flash(conn, :error, PasswordNotice.message())
  defp flash_password_notice(conn, false), do: conn

  @doc """
  Key this session's LiveView socket to its user, so it can be dropped (#675).

  LiveView sockets are disconnected by broadcasting on the session's
  `live_socket_id`, and nothing was setting one — so `/live` could not be
  disconnected at all, and a demoted or deleted editor kept every mounted view
  until they closed the tab.

  Keyed on the user rather than on the session, so one broadcast reaches every
  session they have open, on the same topic every other socket listens on.
  Public because the passkey ceremony establishes its session without passing
  through `complete_sign_in/3` — the one place that would otherwise have been
  missed.
  """
  @spec put_live_socket_id(Plug.Conn.t(), KilnCMS.Accounts.User.t()) :: Plug.Conn.t()
  def put_live_socket_id(conn, user),
    do: put_session(conn, :live_socket_id, KilnCMS.Accounts.SessionEviction.topic(user.id))

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
    default =
      if KilnCMS.Accounts.RoleGrant.effective_role(user) in [:editor, :admin],
        do: ~p"/editor/overview",
        else: ~p"/account"

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

  def failure(conn, {:password, phase} = activity, reason) when phase in [:sign_in, :register] do
    cond do
      challenge = ChallengeRequired.find(reason) -> challenge_required(conn, phase, challenge)
      phase == :register and AlreadyRegistered.in?(reason) -> registration_requested(conn)
      true -> rejected(conn, activity, reason)
    end
  end

  # A confirmation asks for the sign-up password as well as the link (#2594).
  # A wrong or missing password goes back to the page the link opened, with
  # the link's token, which a refused confirmation does not use up. Only a
  # token that checked out reaches the password check (`Actions.confirm`
  # verifies it before the action runs), so a made-up or spent one still lands
  # on sign-in like any other refusal: this tells the holder of a valid link,
  # and no one else, that the password was wrong.
  def failure(conn, {:confirm_new_user, :confirm} = activity, reason) do
    case {password_refused?(reason), confirm_token(conn.params)} do
      {true, token} when is_binary(token) ->
        conn
        |> put_flash(
          :error,
          gettext(
            "That isn't the password this account was signed up with. " <>
              "Try again, or reset the password instead."
          )
        )
        |> redirect(to: ~p"/confirm_new_user/#{token}")

      _other ->
        rejected(conn, activity, reason)
    end
  end

  def failure(conn, activity, reason), do: rejected(conn, activity, reason)

  defp password_refused?(%AshAuthentication.Errors.AuthenticationFailed{field: :password}),
    do: true

  defp password_refused?(%Ash.Error.Changes.Required{field: :password}), do: true

  defp password_refused?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &password_refused?/1)

  defp password_refused?(%{caused_by: cause}) when is_map(cause), do: password_refused?(cause)
  defp password_refused?(_other), do: false

  defp confirm_token(%{"user" => %{"confirm" => token}}) when is_binary(token), do: token
  defp confirm_token(%{"confirm" => token}) when is_binary(token), do: token
  defp confirm_token(_params), do: nil

  # The form POST behind the sign-in and registration pages was refused for
  # want of a human-verification challenge (#2249). Back to the page it came
  # from with `?challenge=1`, which draws the widget from the first render, and
  # the refusal's reason in the flash. Never "Incorrect email or password": the
  # password was not checked, and saying it was wrong would send a user with
  # the right one to retype it into a form that is asking for something else.
  defp challenge_required(conn, phase, %ChallengeRequired{reason: reason}) do
    action = if phase == :register, do: :register, else: :sign_in
    path = if phase == :register, do: ~p"/register?challenge=1", else: ~p"/sign-in?challenge=1"

    conn
    |> put_flash(:error, ChallengeComponents.reason_text(reason, action))
    |> redirect(to: path)
  end

  defp registration_requested(conn) do
    conn
    |> put_flash(
      :info,
      gettext("Check your email - we have sent instructions for what to do next.")
    )
    |> redirect(to: ~p"/sign-in")
  end

  defp rejected(conn, activity, reason) do
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
