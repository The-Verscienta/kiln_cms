defmodule KilnCMSWeb.AuthController do
  use KilnCMSWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias KilnCMS.Accounts
  alias KilnCMSWeb.SafeRedirect

  # Salt + lifetime for the short-lived token that carries "this account passed
  # the first factor and is awaiting its TOTP code" across the redirect. It is
  # NOT a session — the user isn't signed in until the second factor verifies.
  @pending_2fa_salt "two-factor pending"
  @pending_2fa_max_age 300

  def success(conn, activity, user, token) do
    # If the account has two-factor enabled, the first factor alone must not grant
    # a session: stash a signed, expiring pending token (carrying the first-factor
    # auth token, already minted + stored) and divert to the code prompt.
    # Everything else completes the sign-in immediately.
    if Accounts.totp_enabled?(user) do
      conn
      |> put_session(:pending_2fa, sign_pending(conn, user, token))
      |> redirect(to: ~p"/sign-in/verify")
    else
      complete_sign_in(conn, user, message_for(activity))
    end
  end

  @doc """
  Establish the session for `user` and redirect to their destination. Shared by
  the no-2FA path here and by `TwoFactorController` once the code is verified.
  """
  def complete_sign_in(conn, user, message) do
    # Editors/admins land on the console overview by default; viewers (and
    # anyone with an explicit return_to) keep their intended destination (#157).
    default = if user.role in [:editor, :admin], do: ~p"/editor/overview", else: ~p"/"
    return_to = SafeRedirect.local_path(get_session(conn, :return_to), default)

    conn
    |> delete_session(:return_to)
    |> delete_session(:pending_2fa)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  @doc "Sign a pending-2FA token binding the sign-in to a user id + first-factor token."
  def sign_pending(conn, user, token),
    do: Phoenix.Token.sign(conn, @pending_2fa_salt, %{"user_id" => user.id, "token" => token})

  @doc ~S'Verify a pending-2FA token, returning `{:ok, %{"user_id" => _, "token" => _}}` or an error.'
  def verify_pending(conn, pending) when is_binary(pending) do
    Phoenix.Token.verify(conn, @pending_2fa_salt, pending, max_age: @pending_2fa_max_age)
  end

  def verify_pending(_conn, _pending), do: {:error, :missing}

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

  def sign_out(conn, _params) do
    return_to = SafeRedirect.local_path(get_session(conn, :return_to), ~p"/")

    conn
    |> clear_session(:kiln_cms)
    |> put_flash(:info, gettext("You are now signed out"))
    |> redirect(to: return_to)
  end
end
