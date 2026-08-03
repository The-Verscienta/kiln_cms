defmodule KilnCMS.Accounts.SignInAlert do
  @moduledoc """
  Tells an account owner, once, that someone is guessing at their credentials.

  Two alerts, for two different pieces of news:

    * `account_locked/1` — the **password** is being guessed at (#478).
      `KilnCMS.Accounts.Preparations.ThrottleSignIn` calls it when an attempt is
      actually refused. The owner is usually the only person who can tell an
      attack from their own forgotten password, and a throttle that stays silent
      hands them a mystery sign-in failure instead.

    * `second_factor_locked/1` — the **second factor** is being guessed at
      (#728), which is much worse news and used to be the silent one.

  ## Why the second one is the louder alarm

  Reaching the second-factor prompt requires a signed pending token, and that
  token is only minted after a **first factor has already succeeded**. So a
  second-factor lockout is not "someone is guessing at your account" — it is
  "someone got in far enough to be asked for a code, and is now working on the
  only thing still in their way".

  It is also structurally impossible for `account_locked/1` to cover that case.
  To keep grinding codes an attacker must keep minting pending tokens, which
  means re-running the first factor — and that step *succeeds*, so
  `ThrottleSignIn`'s `after_action` calls `AccountThrottle.forgive/1` and resets
  the sign-in counter every time. It never reaches its budget, so the password
  alert never fires. Net, before #728: in the one case where a primary
  credential was provably in someone else's hands, the owner got nothing at all.

  ## What the mail may and may not claim

  It is tempting to write "someone has your password", and that is wrong twice
  over. Both matter, because a security mail that names the wrong compromise
  sends the owner to secure the wrong thing:

    * **The first factor is not necessarily the password.**
      `KilnCMSWeb.AuthController.success/4` is the callback for *every*
      registered strategy, so a magic link and an OIDC assertion divert to the
      code prompt exactly as a password does. For those users the compromised
      thing is their **mailbox** or their **identity provider**, and a mail
      telling them to change their Kiln password leaves the actual hole open.
      (The headless gate is password-only — `PendingSignIn.mint/2` has one
      caller — but one mail serves both.)

    * **The budget is shared with the settings forms.** Since #727,
      `KilnCMS.Accounts.Changes.ThrottleSecondFactor` charges the same
      `consume_second_factor/1` bucket from `/editor/settings`. So an owner who
      fumbles five codes while regenerating their recovery set, and *then* signs
      in normally, trips this alert with no attacker anywhere — the likeliest
      trigger in practice, and the reason the "if this was you" line is near the
      top rather than buried at the bottom.

  What is always true is the sentence the mail actually leads with: someone
  completed the first step of signing in, and several two-factor codes have
  been refused. The rest is offered as *what to check*, not asserted as fact.

  The two alerts therefore need separate copy, and separate once-per-window
  budgets so the weaker signal cannot suppress the stronger one in exactly the
  order an attack produces them.

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

  Only the first of those applies to `second_factor_locked/1`, and it does not
  need to: its caller holds a **signed** pending token naming a real user id,
  so there is no attacker-chosen recipient and no address to enumerate. The
  budget and the swallow-everything discipline still apply in full — that one
  runs inside a sign-in attempt too, and it goes one step further: it *releases*
  the window it claimed if the delivery then fails
  (`AccountThrottle.forget_second_factor_alert/1`), so a wedged queue costs one
  mail rather than six hours of them.

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

  @doc """
  Mail `user` that someone who already has their password is guessing at their
  second factor, unless one already went out this window. Always returns `:ok`.

  Takes the user rather than an address because both callers already hold one,
  resolved from a signed token — see the moduledoc on why that removes the
  enumeration guard `account_locked/1` needs.

  The refusal is logged whether or not the mail goes, and whether or not it
  succeeds. A lockout here is the strongest signal this system produces about a
  specific account, and it must not be visible only to whoever happens to read
  their mail.
  """
  @spec second_factor_locked(User.t()) :: :ok
  def second_factor_locked(%User{} = user) do
    if AccountThrottle.second_factor_alert_allowed?(user.id) do
      # At `:warning` because it happens once per window, not once per refused
      # request. Logging every refusal would hand an attacker who is already
      # sending requests as fast as they can a matching stream of log lines.
      Logger.warning(
        "Second-factor budget spent for user #{user.id}: someone past the first factor is " <>
          "failing codes. Alerting the owner."
      )

      release_on_failure(user, fn -> deliver_second_factor(user) end)
    else
      # Suppression must not be silent to the operator, even while it stays
      # silent to the owner — the same rule `allow_mail?/2` follows.
      Logger.info("Suppressed a second-factor alert for user #{user.id}: one already sent.")
    end

    :ok
  rescue
    error ->
      Logger.warning("Second-factor alert failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("Second-factor alert exited: #{inspect(reason)}")
      :ok

    thrown ->
      Logger.warning("Second-factor alert threw: #{inspect(thrown)}")
      :ok
  end

  # A caller that is not a loaded user must not raise past this module's
  # handlers — a head-clause failure happens *before* the implicit `try` and
  # would 500 the sign-in this is reporting on. Nothing reaches it today; both
  # gates resolve a real record from a signed token.
  def second_factor_locked(_other), do: :ok

  # Give the window back if the mail never got out, so the next refusal can try
  # again rather than being told one already went.
  defp release_on_failure(user, fun) do
    fun.()
  rescue
    error ->
      AccountThrottle.forget_second_factor_alert(user.id)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      AccountThrottle.forget_second_factor_alert(user.id)
      :erlang.raise(kind, reason, __STACKTRACE__)
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

  # One envelope for both alerts. Their *copy* is deliberately separate — see
  # the moduledoc — but "which address, whose branding, which sender" is the
  # same question with the same answer, and two copies of it is two places for
  # the org-vs-operator branding rule below to drift.
  defp deliver(user, subject_line, html) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(user.email))
    |> subject(subject_line)
    |> html_body(html)
    |> Mail.enqueue!()
  end

  # Users are global (they hold memberships, not an `org_id`), and the sign-in
  # that triggered this may have been aimed at any site — so both alerts wear
  # the operator's own branding, like the reset mail on the read-based path.
  defp site_name, do: KilnCMS.Branding.for_org(nil).site_name

  defp deliver(user) do
    site = site_name()
    deliver(user, "Unusual sign-in activity on your #{site} account", body(site))
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

  defp deliver_second_factor(user) do
    site = site_name()

    deliver(
      user,
      "Two-factor sign-in blocked on your #{site} account",
      second_factor_body(site)
    )
  end

  # Deliberately not a variation on `body/1`: that mail's "your password has not
  # been used successfully" is the one thing that cannot be said here.
  #
  # Equally deliberately, it does not say "someone has your password". See the
  # moduledoc — the first factor may have been a magic link or an SSO
  # assertion, and the shared budget means the likeliest trigger of all is the
  # owner themselves fumbling codes in their own settings. So the mail states
  # what is known, puts the benign explanation second where a worried reader
  # will actually reach it, and offers the rest as a checklist.
  defp second_factor_body(site) do
    reset = url(~p"/reset")
    settings = url(~p"/editor/settings")

    """
    <p>Someone completed the first step of signing in to your #{site} account, and then
    several two-factor codes were refused. Sign-in for this account is paused briefly.</p>
    <p><strong>If that was you</strong> — a code mistyped a few times, an authenticator
    whose clock has drifted, or codes entered on your settings page — nothing is wrong.
    Wait a few minutes and try again.</p>
    <p><strong>If it wasn't you</strong>, someone else got past your first step. That
    means whatever you sign in with is in their hands — your password, or the mailbox
    that receives your sign-in links, or your single sign-on account. Your two-factor app
    itself is fine and does not need changing.</p>
    <p>What to do:</p>
    <ul>
      <li>Change your password: <a href="#{reset}">#{reset}</a></li>
      <li>If you sign in with a link by email, or through single sign-on, secure that
      account too — changing your #{site} password alone would not close it.</li>
      <li>Generate a fresh set of recovery codes:
      <a href="#{settings}">#{settings}</a></li>
    </ul>
    """
  end
end
