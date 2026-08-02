defmodule KilnCMS.Accounts.SignInAlert do
  @moduledoc """
  Tells an account owner, once, that someone is guessing at their password (#478).

  `KilnCMS.Accounts.Preparations.ThrottleSignIn` calls this when an attempt is
  actually refused. The owner is usually the only person who can tell an attack
  from their own forgotten password, and a throttle that stays silent hands them
  a mystery sign-in failure instead.

  ## It must not become the amplifier

  Anyone can name any address at a sign-in form, so every path here is guarded:

    * the address is looked up first, and an address with no account sends
      nothing — the alert exists to warn an owner, and there isn't one;
    * the once-per-window budget (`KilnCMS.Accounts.AccountThrottle.alert_allowed?/1`)
      is spent **last**, after the lookup and the enqueue, so a lock against an
      address that has no account yet — or a moment when mail is broken — can't
      silently eat the next window's real alert;
    * failures are swallowed, `exit`s included. This runs inside a sign-in, and
      an alert that can break authentication is worse than the attack it
      reports. The mail goes through `Mail.enqueue!/1`, which reaches Oban, and
      the branding lookup reaches a Cachex `GenServer.call` — neither is an
      exception when it goes wrong.

  The mail names no attacker detail — not the source IP, not the attempt count.
  Those come from the request, and echoing request-controlled data into an email
  an attacker can trigger is how a throttle alert becomes a phishing channel. It
  also doesn't promise a duration: the lock runs to the end of a fixed window, so
  any number it quoted would be an overstatement.
  """
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User
  alias KilnCMS.Mail

  @doc """
  Mail the owner of `identifier` that their account is being guessed at, unless
  one already went out this window. Always returns `:ok`.
  """
  @spec account_locked(String.t()) :: :ok
  def account_locked(identifier) do
    with %User{} = user <- lookup(identifier),
         true <- AccountThrottle.alert_allowed?(identifier) do
      deliver(user)
    end

    :ok
  rescue
    error ->
      Logger.warning("Sign-in alert failed: #{Exception.message(error)}")
      :ok
  catch
    # A saturated cache or a wedged Oban queue exits rather than raising, and an
    # exit here would 500 a sign-in that should have returned a generic 401.
    :exit, reason ->
      Logger.warning("Sign-in alert exited: #{inspect(reason)}")
      :ok
  end

  defp lookup(identifier) do
    User
    |> Ash.Query.filter(email == ^String.trim(identifier))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %User{} = user} -> user
      _other -> nil
    end
  end

  defp deliver(user) do
    # Users are global (they hold memberships, not an `org_id`), and the sign-in
    # that triggered this may have been aimed at any site — so the alert wears
    # the operator's own branding, like the reset mail on the read-based path.
    site = KilnCMS.Branding.for_org(nil).site_name

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(user.email))
    |> subject("Unusual sign-in activity on your #{site} account")
    |> html_body(body(site))
    |> Mail.enqueue!()
  end

  defp body(site) do
    url = url(~p"/reset")

    """
    <p>Someone has made repeated failed sign-in attempts against your #{site} account.</p>
    <p>Sign-in for this account is paused briefly. If that was you, nothing is wrong —
    wait a few minutes and try again, or reset your password:</p>
    <p><a href="#{url}">#{url}</a></p>
    <p>If it wasn't you, your password has not been used successfully. Resetting it,
    and turning on two-factor authentication or a passkey, will end the attempts.</p>
    """
  end
end
