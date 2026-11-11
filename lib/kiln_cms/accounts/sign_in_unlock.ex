defmodule KilnCMS.Accounts.SignInUnlock do
  @moduledoc """
  An emailed link that lifts the per-account sign-in pause (#2250).

  `KilnCMS.Accounts.AccountThrottle` pauses sign-in for an address once its
  budget is spent, and keeps that pause undisclosed: a paused account answers
  exactly as a wrong password does. Until this, the owner's only way out before
  the window rolled was a password reset they may not have needed. This is the
  smaller remedy: a link, mailed to the address, that clears the sign-in counter
  and nothing else.

  ## What it lifts, and what it does not

  It clears the `signin` bucket for the account's current address
  (`AccountThrottle.unlock/1`). It does not:

    * sign anyone in, or mint a session. The owner still signs in with their
      password, their second factor and, if the deployment asks for one, a
      human-verification challenge;
    * give back the free attempts before a challenge, the second-factor budget,
      or any per-address budget (`:auth`, the challenge gate's address axis);
    * confirm the account or touch any other token it holds.

  So it is no stronger than the password reset the same mailbox can already
  ask for, and weaker: the reset changes the password and lifts the pause too.
  Against an attacker still guessing, the account pauses again within seconds;
  the link is for the owner who paused themselves.

  ## The request does the same work for every address

  `request/2` is the whole of the request path, and it never looks the address
  up. It hands the address to a task under its own supervisor
  (`__MODULE__.TaskSupervisor`, bounded at `max_children`) and returns `:ok`, so
  the caller's response and timing cannot depend on whether the address has an
  account, is paused, or was mailed. The task then decides, in order: an
  account exists, is confirmed, is not anonymized, is not the demo's shared
  account, is paused right now, and belongs to the site the request was made
  on (a membership there, or the legacy no-membership account on the default
  site: `KilnCMS.Security.AuthEvents.member_of/2`), and that site still
  exists. Only then is the per-address unlock mail budget charged (`AccountThrottle.allow_mail?(:sign_in_unlock, _)`, three an
  hour), so an address that will never be mailed writes no counter row.

  A full supervisor drops the request (logged at most once a minute). The
  requester was told the same sentence either way, and can ask again.

  ## The link

  An AshAuthentication JWT with purpose `"sign_in_unlock"`, stored like every
  other token (`store_all_tokens?`), so:

    * it is refused as a bearer credential, and by the reset, confirmation,
      magic-link and token sign-in routes, whose checks want a different
      purpose or `act`;
    * it is single use: redeeming revokes it through the token resource's
      atomic revocation, so of two concurrent redeems exactly one wins;
    * a password change or reset revokes it with every other token
      (`KilnCMS.Accounts.Changes.RevokeAllTokens`);
    * it lives `ttl_seconds/0` (15 minutes). A newer link does not revoke an
      older one; each is short-lived and single use.

  Its claims bind it to two things a stolen or stale link must not outlive:

    * `org` — the site the request was made on. The link opens on that site's
      host and is refused on any other (`wrong_site`), without being spent, so
      the owner can still use it where it belongs.
    * `ed` — a keyed HMAC of the address it was mailed to
      (`address_digest/1`). An email change since the mail went out refuses
      it. Keyed, not a plain hash: the claims are also stored in
      `tokens.extra_data`, and a bare SHA-256 of an address is a lookup away
      from the address.

  Opening the link (`GET`) spends nothing, so a mail scanner that follows it
  cannot use it up; the page asks for a click, and only the `POST` redeems.
  """
  require Logger

  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.SignInUnlockRefused
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.User.Senders.SendSignInUnlock
  alias KilnCMS.Security.AuthEvents
  alias KilnCMS.Security.Recorder

  @purpose "sign_in_unlock"
  @ttl {15, :minutes}
  @hmac_salt "sign_in_unlock"
  @shed_log_interval_seconds 60

  @doc "The token purpose, and the `act` claim, an unlock link carries."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc """
  How long a link lives, in **seconds**: AshAuthentication reads a bare
  integer lifetime as seconds, so the configured value is converted here once
  rather than at each use.
  """
  @spec ttl_seconds() :: integer()
  def ttl_seconds, do: AshAuthentication.Utils.lifetime_to_seconds(config(:ttl, @ttl))

  @doc "The supervisor the request hands off to (see the moduledoc)."
  @spec task_supervisor() :: module()
  def task_supervisor, do: __MODULE__.TaskSupervisor

  @doc """
  Ask for an unlock link for `email` on the org in `context`
  (`KilnCMS.Security.Recorder.tenant_key/0`). Always `:ok`, whatever the
  address; see the moduledoc for what happens off the request path.
  """
  @spec request(String.t(), map()) :: :ok
  def request(email, context) when is_binary(email) and is_map(context) do
    dispatch(fn -> deliver(email, context) end)
  end

  @doc """
  Redeem `token` on the org in `context`. `:ok` once the pause is lifted, or
  `{:error, %SignInUnlockRefused{}}`. Every refusal reads the same to the
  caller; its `reason` goes to the security log only.
  """
  @spec redeem(String.t(), map()) :: :ok | {:error, SignInUnlockRefused.t()}
  def redeem(token, context) when is_binary(token) and is_map(context) do
    org_id = context[Recorder.tenant_key()]

    case check(token, org_id) do
      {:ok, user} ->
        spend(token, user, context)

      {:error, reason, user} ->
        AuthEvents.sign_in_unlock_refused(context, user, Atom.to_string(reason))
        {:error, SignInUnlockRefused.exception(reason: reason)}
    end
  end

  @doc """
  The `ed` claim for `email`: an HMAC-SHA256 of the normalised address, keyed
  from the endpoint's `secret_key_base` with a salt of its own.
  """
  @spec address_digest(String.t() | Ash.CiString.t()) :: String.t()
  def address_digest(email) do
    key =
      Plug.Crypto.KeyGenerator.generate(secret_key_base(), @hmac_salt,
        length: 32,
        cache: Plug.Crypto.Keys
      )

    normalised = email |> to_string() |> String.trim() |> String.downcase()

    :hmac
    |> :crypto.mac(:sha256, key, normalised)
    |> Base.url_encode64(padding: false)
  end

  @doc false
  # Mints the link's token for `user` on `org_id`. Public for the tests, which
  # read its claims; nothing else should mint one.
  @spec mint(User.t(), String.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def mint(%User{} = user, org_id) when is_binary(org_id) do
    Jwt.token_for_user(
      user,
      %{"act" => @purpose, "org" => org_id, "ed" => address_digest(user.email)},
      purpose: :sign_in_unlock,
      token_lifetime: ttl_seconds()
    )
  end

  # ---- the request, off the request path ----------------------------------

  defp dispatch(fun) do
    if config(:async, true) do
      case Task.Supervisor.start_child(task_supervisor(), fun) do
        {:ok, _pid} -> :ok
        {:error, _max_children} -> shed()
      end
    else
      fun.()
    end

    :ok
  catch
    # `start_child/2` is a call: a supervisor that is restarting exits the
    # caller, and the requester must still get the one fixed answer.
    :exit, _reason -> shed()
  end

  # The task's own boundary: a failure here is logged and goes no further, as
  # the requester was answered before it started.
  defp deliver(email, context) do
    # The budget is charged last before the mint, so a request that would not
    # be mailed anyway (not eligible, not a member, a vanished site) spends none.
    with org_id when is_binary(org_id) <- context[Recorder.tenant_key()],
         %User{} = user <- eligible(email),
         # Only a member of the requesting site: the mail is in that site's
         # branding, and its sign-in page is the one this person uses.
         %User{} <- AuthEvents.member_of(user, org_id),
         %Accounts.Organization{} = org <- organization(org_id),
         true <- AccountThrottle.allow_mail?(:sign_in_unlock, to_string(user.email)),
         {:ok, token, _claims} <- mint(user, org_id) do
      SendSignInUnlock.deliver(user, token, org)
      AuthEvents.sign_in_unlock_requested(context, user)
    end

    :ok
  rescue
    # Only the error's type: a message or an exit reason can quote the
    # address, and anyone can name any address here.
    error ->
      Logger.warning("Sign-in unlock request failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _reason ->
      Logger.warning("Sign-in unlock request exited")
      :ok
  end

  # The account that may be mailed, or nil. Every refusal is the same nil.
  defp eligible(email) do
    with %User{} = user <- lookup(email),
         false <- is_nil(user.confirmed_at),
         true <- is_nil(user.anonymized_at),
         # The demo's shared account is one credential every visitor holds;
         # its pause is the demo reset's to lift (`AccountThrottle.forget_all/0`).
         false <- KilnCMS.Demo.locks_credentials?(user),
         true <- AccountThrottle.sign_in_paused?(to_string(user.email)) do
      user
    else
      _not_eligible -> nil
    end
  end

  defp lookup(email) do
    # authorize?: false — an anonymous request has no actor, and this runs in a
    # task after the requester was answered: nothing they see depends on it.
    case Accounts.get_user_by_email(String.trim(email),
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %User{} = user} -> user
      _none -> nil
    end
  end

  defp organization(org_id) do
    # The plain org read the accounts system actor is admitted to.
    case Accounts.get_organization(org_id, actor: Accounts.system(), not_found_error?: false) do
      {:ok, %Accounts.Organization{} = org} -> org
      _missing -> nil
    end
  end

  # A full supervisor: drop the request and say so, at most once a minute, so a
  # flood does not become a matching flood of log lines.
  defp shed do
    :telemetry.execute([:kiln_cms, :accounts, :sign_in_unlock_shed], %{count: 1}, %{})
    now = System.monotonic_time(:second)
    clock = shed_clock()
    last = :atomics.get(clock, 1)

    if now - last >= @shed_log_interval_seconds and
         :atomics.compare_exchange(clock, 1, last, now) == :ok do
      Logger.warning(
        "Dropped a sign-in unlock request: the unlock task supervisor is full. " <>
          "Further drops are not logged for a minute."
      )
    end

    :ok
  end

  defp shed_clock do
    case :persistent_term.get({__MODULE__, :shed_clock}, nil) do
      nil ->
        clock = :atomics.new(1, signed: true)
        :atomics.put(clock, 1, System.monotonic_time(:second) - @shed_log_interval_seconds)
        :persistent_term.put({__MODULE__, :shed_clock}, clock)
        clock

      clock ->
        clock
    end
  end

  # ---- redeeming ------------------------------------------------------------

  # `{:ok, user}` for a link that may be spent here, else
  # `{:error, reason, user_or_nil}`. The user comes back only once the
  # signature has verified, so a forged token never labels an event.
  defp check(token, org_id) do
    with {:ok, claims} <- signed_claims(token),
         :ok <- purpose_matches(claims),
         {:ok, claims} <- valid(token, claims),
         {:ok, user} <- subject(claims),
         :ok <- same_site(claims, org_id, user),
         :ok <- same_address(claims, user),
         :ok <- stored(claims, user) do
      {:ok, user}
    end
  end

  defp signed_claims(token) do
    signer = Jwt.Config.token_signer(User)

    case Joken.verify(token, signer) do
      {:ok, claims} -> {:ok, claims}
      _invalid -> {:error, :invalid, nil}
    end
  rescue
    # The token is whatever the URL carried: a string that is not a JWT at all
    # can raise inside the decoder, and it is refused like any other forgery.
    _malformed -> {:error, :invalid, nil}
  end

  defp purpose_matches(%{"purpose" => @purpose, "act" => @purpose}), do: :ok
  defp purpose_matches(_claims), do: {:error, :invalid, nil}

  # The library's own validation: issuer, audience, expiry and revocation.
  # Which of those failed is read back from the (verified) claims.
  defp valid(token, claims) do
    case Jwt.verify(token, User) do
      {:ok, claims, User} ->
        {:ok, claims}

      :error ->
        cond do
          expired?(claims) -> {:error, :expired, labelled(claims)}
          revoked?(claims) -> {:error, :used, labelled(claims)}
          true -> {:error, :invalid, nil}
        end
    end
  end

  defp expired?(%{"exp" => exp}) when is_integer(exp), do: exp <= System.os_time(:second)
  defp expired?(_claims), do: false

  defp revoked?(%{"jti" => jti}) when is_binary(jti),
    do: TokenResource.Actions.jti_revoked?(Token, jti)

  defp revoked?(_claims), do: false

  # The account a verified but spent or expired link names, for the event only.
  defp labelled(claims) do
    case subject(claims) do
      {:ok, user} -> user
      _gone -> nil
    end
  end

  defp subject(%{"sub" => subject}) do
    # authorize?: false — the link is the credential and its signature has
    # verified; the record is read to compare its address, never returned.
    case AshAuthentication.subject_to_user(subject, User, authorize?: false) do
      {:ok, %User{anonymized_at: nil} = user} -> {:ok, user}
      _gone -> {:error, :account_changed, nil}
    end
  end

  defp subject(_claims), do: {:error, :invalid, nil}

  defp same_site(%{"org" => org_id}, org_id, _user) when is_binary(org_id), do: :ok
  defp same_site(_claims, _org_id, user), do: {:error, :wrong_site, user}

  defp same_address(%{"ed" => digest}, user) when is_binary(digest) do
    if Plug.Crypto.secure_compare(digest, address_digest(user.email)),
      do: :ok,
      else: {:error, :account_changed, user}
  end

  defp same_address(_claims, user), do: {:error, :account_changed, user}

  # A link whose row is not stored under this purpose was not minted here.
  defp stored(%{"jti" => jti}, user) do
    case TokenResource.Actions.get_token(Token, %{"jti" => jti, "purpose" => @purpose}) do
      {:ok, [_row]} -> :ok
      _missing -> {:error, :invalid, user}
    end
  end

  defp spend(token, user, context) do
    address = to_string(user.email)
    was_paused? = AccountThrottle.sign_in_paused?(address)

    case TokenResource.Actions.revoke(Token, token, store_all_tokens?: true) do
      :ok ->
        AccountThrottle.unlock(address)
        AuthEvents.sign_in_unlocked(context, user, was_paused?)
        :ok

      {:error, _lost_the_race} ->
        AuthEvents.sign_in_unlock_refused(context, user, "used")
        {:error, SignInUnlockRefused.exception(reason: :used)}
    end
  end

  defp secret_key_base, do: KilnCMSWeb.Endpoint.config(:secret_key_base)

  defp config(key, default) do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
