defmodule KilnCMS.Accounts.PendingSignIn do
  @moduledoc """
  The blob that carries "this caller passed the first factor and owes a code"
  between the two halves of a sign-in (#726, #745).

  One module for **both** gates. #726 unified the code *check* into
  `KilnCMS.Accounts.SecondFactor`, so the browser and headless prompts cannot
  disagree about what counts as a valid submission; everything around it was
  still written twice — mint, resolve, the five-minute lifetime, and the
  consume/verify/forgive ordering. Each of those is a place the next hardening
  lands on whichever door its author happened to be looking at, which is what
  #726 itself was, one layer down.

  ## Two wrappings, because the blob travels differently

  The mode is the only thing that differs, and it differs for one reason: who
  holds the ciphertext.

    * `:session` — the browser gate. The blob lives in the encrypted session, so
      the client never sees it and **signing** is enough: the payload is
      readable by whoever holds the token, and nobody does.

    * `:encrypted` — the headless gate. The client holds the blob, and the
      payload carries the first-factor JWT — already minted and stored by the
      time `AshAuthentication.Strategy.action/3` returned. `Phoenix.Token.sign/4`
      *publishes* its payload; the signature only stops it being changed. So
      signing here would hand the caller the very credential the second factor
      exists to withhold, reopening #726 in a shape that looks fixed.
      `Phoenix.Token.encrypt/4` is AES-GCM keyed off `secret_key_base`.

  Distinct salts, so a browser blob and a headless one are never
  interchangeable. Same `max_age/0` for both, because it is the same step.

  It is passed on the **mint** as well as the read, but not as a ceiling — a
  reader that supplies its own `max_age` wins, so `mint_and_hold/4` cannot stop a future
  caller reading a stale blob. What it sets is the *default* for a reader that
  passes none: `Plug.Crypto` embeds `Keyword.get(opts, :max_age, 86400)` into
  the term, so without it the blob's own lifetime would be a day. The five
  minutes is enforced by `resolve/3`; the mint-time value is what a reader that
  forgets falls back to.

  ## Single use

  `:encrypted` blobs are spent on redemption, so a captured verify request
  cannot be replayed — and a *successful* request is the one most likely to be
  sitting in a log, a CI transcript or a crash report.

  `:session` blobs carry no `jti`, and the reason is *not* that deleting the
  session key makes them single-use. The session is a client-side cookie
  (`KilnCMSWeb.SessionCookie` uses `store: :cookie`), so
  `AuthController.complete_sign_in/3` only rewrites the cookie *this response*
  sets — a copy captured beforehand still carries a redeemable blob for the
  rest of its five minutes. And before that response, the cookie holds nothing
  but the pending blob, so it is not a larger credential than the blob either.

  What makes the replay uninteresting is that it buys an attacker nothing they
  did not already have: redeeming a captured pending blob still requires a
  valid code, and a captured *headless* blob is the same. The difference is
  reach — the headless blob is handed to the client, printed in logs and CI
  transcripts and crash reports, where a session cookie is not. That is what
  the `jti` is for, and why paying a row write per browser sign-in for it would
  be paying for the wrong threat.

  The record is a row on `KilnCMS.Accounts.Token` (#743), and single use is
  **exact** — on one node and on a cluster.

  It used to be a node-local `Cachex` entry, which made it fail *open* across
  nodes: a replay landing on a node that never saw the redemption was accepted.
  That is now a Postgres INSERT whose primary key is the `jti`, so the write
  **is** the check. Two redemptions of the same blob race at the database, and
  exactly one wins, wherever each request landed.

  The ordering that matters: the row is written after the code verifies, not on
  resolve — see `claim/1`.

  There is no "is it spent?" read before it, deliberately. One would only ever
  be an optimisation — the INSERT decides either way — and it cost more than it
  saved: a second query on every verify, a public read interface over a table of
  live session tokens, and a *distinguishable* fast rejection for a spent blob,
  which is an unauthenticated oracle for "has this account finished signing in
  yet?". A replay now takes the same path and the same time as a wrong code, and
  is refused by the write.

  `KilnCMS.Accounts.WebAuthn.take_challenge/1` and
  `KilnCMS.Accounts.AccountThrottle` still make the node-local trade for their
  own state; this fixes the one whose failure mode was a replayable credential.

  ## A third surface would need a decision first

  `ThrottleSignIn`'s moduledoc notes that `SignInLive` submits over `/live`, so
  a LiveView second-factor prompt is plausible. It cannot use `:session`:
  LiveView has no `put_session`, so it can neither write `:pending_2fa` nor
  clear it. That pushes it onto `:encrypted`, which deliberately drops the
  remember-me intent — a headless client has no cookie — and remember-me is the
  one thing `SignInLive` submits that would then be silently lost. Whoever
  builds it should decide that, not discover it.

  Spending is deliberately **not** done on a wrong code or a spent budget. The
  caller has not failed authentication there, and destroying their pending state
  would turn "that code isn't valid" into "start over".

  ## The token it carries is withheld from the store too (#742)

  `User` sets `store_all_tokens?`, so the first-factor JWT is minted **and
  inserted into `tokens`** by `AshAuthentication.Strategy.action/3` — before
  either controller has looked at `totp_enabled?`. What the second factor used to
  withhold was the caller's *access* to that token, not its existence: a sign-in
  abandoned at the code prompt left a live, usable row that nobody held, for the
  JWT's full lifetime — fourteen days, AshAuthentication's default, since nothing
  here narrows `tokens.token_lifetime`. #761 bounded how many an attacker could
  cause by looping the password step; it did not stop them existing.

  So `mint_and_hold/4` **holds** the token as it wraps it (#1171 put the hold in
  the name, so a call site shows it) — `hold_for_second_factor` moves
  the row off the `"user"` purpose that AshAuthentication's own
  `validate_token/3` requires of anything it authenticates, and shortens its
  expiry to the length of this step. From that instant the JWT authenticates
  nothing, wherever it is, and an exchange that is never finished leaves a row
  that is inert immediately and collected by the nightly `:expunge_expired`
  rather than one that is live for a fortnight. `claim/1` puts it back.

  Two asymmetries, both deliberate:

    * A hold that cannot be taken does **not** fail the sign-in. It logs and
      carries on, because the result is exactly the pre-#742 behaviour, and
      refusing instead would turn a token-store hiccup into "no account with a
      second factor can sign in".
    * A release that cannot be *recorded* **does** fail it, as `:unavailable`.
      Handing back a token whose row is still parked would be a 201 the client
      cannot use, and every subsequent request answering 401 with nothing to say
      why is a far worse trade than one honest "try again in a moment".
  """

  alias KilnCMS.Accounts

  require Ash.Query
  require Logger

  # `jti?` and `remember_me?` are per-mode because each answers a question only
  # one door has: single use (the session gate gets it free by deleting the
  # session key) and a cookie to remember (a headless client has none). Gating
  # them here rather than at the call sites means neither mode can be handed —
  # or can report — a field that means nothing to it.
  @modes %{
    session: %{salt: "two-factor pending", jti?: false, remember_me?: true},
    encrypted: %{salt: "api two-factor pending", jti?: true, remember_me?: false}
  }

  @max_age 300

  @typedoc "Which gate this blob belongs to — see the moduledoc."
  @type mode :: :session | :encrypted

  @typedoc "Anything `Phoenix.Token` accepts as a key source."
  @type context :: Plug.Conn.t() | Phoenix.Socket.t() | module()

  @typedoc """
  A resolved pending sign-in.

  One shape for both gates, so a caller cannot read a field that only its own
  door happens to set: `jti` is `nil` for `:session` and `remember_me?` is
  always `false` for `:encrypted` (there is no cookie to remember).
  """
  @type t :: %__MODULE__{
          user: Accounts.User.t(),
          jti: String.t() | nil,
          remember_me?: boolean()
        }

  defstruct [:user, :jti, remember_me?: false]

  @doc "How long a minted blob stays redeemable, in seconds. Both gates."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  Mint the blob for `user`, who has just passed the first factor, and **hold**
  the first-factor token it carries.

  Two things, and the name says both on purpose (#1171): the token is written
  into the blob *and* parked in the token store, so it authenticates nothing
  until `claim/1` releases it — see the moduledoc. The hold lives here rather
  than at the two call sites for the reason the whole module exists: a defence
  written twice is a defence that is eventually only on one door. There is
  deliberately no pure `mint/4` beside it — a wrapper that skips the hold is
  exactly the door that ends up unguarded, and no production caller wants one.

  ## Refuses to hold the caller's own credential

  A step-up or sudo-mode re-prompt is the natural next surface, and the natural
  mistake in building it is to hand this function the user's **current, live**
  token — which would silently de-authenticate the very session that is asking
  for the re-prompt. So when `context` is a `Plug.Conn`, and the token about to
  be held is the one that authenticates that conn (the session's `user_token`, or
  the bearer token on `assigns.current_user`), this raises `ArgumentError` rather
  than parking it. A first-factor sign-in never trips it: the token the strategy
  just minted is not the one (if any) the request arrived with.

  Options:

    * `:token` — the first-factor JWT to carry. Defaults to
      `user.__metadata__.token`, which is where it lands for a headless
      sign-in; the browser callback is handed it separately and passes it in.
    * `:remember_me?` — the ticked checkbox, carried across the code prompt as
      *intent* only. The cookie itself is withheld at the first factor and
      issued once the code verifies (#699). Ignored by `:encrypted`.
  """
  @spec mint_and_hold(mode(), context(), Accounts.User.t(), keyword()) :: String.t()
  def mint_and_hold(mode, context, user, opts \\ []) when is_map_key(@modes, mode) do
    %{jti?: jti?, remember_me?: carries_remember_me?} = Map.fetch!(@modes, mode)
    token = Keyword.get_lazy(opts, :token, fn -> user.__metadata__.token end)

    refuse_own_credential!(context, token)
    hold_first_factor(token)

    %{
      "user_id" => user.id,
      "token" => token
    }
    # Names this attempt so redeeming it can be recorded without keeping the
    # ciphertext, which is long and would key the cache on a secret.
    |> put_if(jti?, "jti", fn -> random_jti() end)
    |> put_if(carries_remember_me?, "remember_me", fn ->
      Keyword.get(opts, :remember_me?, false) == true
    end)
    |> then(&wrap(mode, context, &1))
  end

  @doc """
  Resolve a minted blob to the account awaiting its code.

  `{:ok, %PendingSignIn{}}`, with the first-factor token reattached to the
  user's `__metadata__` so a completed sign-in has something to return — or
  `:error` when the blob is missing, malformed, expired, already spent, or
  names an account that no longer has a second factor.

  Every one of those is `:error` rather than a reason, because they mean the
  same thing to a caller: this exchange is over, start again.
  """
  @spec resolve(mode(), context(), term()) :: {:ok, t()} | :error
  def resolve(mode, context, blob) when is_map_key(@modes, mode) and is_binary(blob) do
    %{jti?: jti?, remember_me?: carries_remember_me?} = Map.fetch!(@modes, mode)

    with {:ok, %{"user_id" => user_id, "token" => token} = payload} <-
           unwrap(mode, context, blob),
         {:ok, jti} <- minted_jti(jti?, payload),
         user when not is_nil(user) <-
           Accounts.get_user!(user_id, authorize?: false, not_found_error?: false),
         # Re-checked rather than trusted from the first step: an account that
         # turned two-factor off in between has no code to verify, and honouring
         # the blob anyway would complete a sign-in on a factor that no longer
         # exists.
         true <- Accounts.totp_enabled?(user) do
      {:ok,
       %__MODULE__{
         user: %{user | __metadata__: Map.put(user.__metadata__, :token, token)},
         jti: jti,
         remember_me?: carries_remember_me? and payload["remember_me"] == true
       }}
    else
      _ -> :error
    end
  end

  # Only a bad *blob* falls through to `:error`. An unknown mode raises, because
  # `mint_and_hold/4` raises on one too and the pair has to fail the same way: a silent
  # `:error` from a typo would resolve forever, and both gates render that as a
  # redirect back to `/sign-in` — an unbreakable loop with no exception, no log
  # line, and nothing in the suite to catch it.
  def resolve(mode, _context, _blob) when is_map_key(@modes, mode), do: :error

  @doc """
  Complete this attempt: release the first-factor token `mint_and_hold/4` held, and claim
  the blob so it cannot be redeemed again.

    * `:ok` — this caller got it, and the token it holds now authenticates.
    * `:taken` — someone else already did. The exchange is over.
    * `:unavailable` — the release or the claim could not be recorded. **Not**
      the same answer: the blob may well still be redeemable, and telling the
      caller to start again would be wrong advice as well as a wasted sign-in
      attempt.

  **The return value is the single-use guarantee, and a caller that ignores it
  has none.** The row's primary key is the `jti`, so two concurrent redemptions
  of one blob both reach here and exactly one INSERT succeeds; the loser gets
  `:taken` and must refuse the sign-in rather than issue a token. That is the
  whole difference from the node-local cache this replaced, where both would
  have been told they were first.

  Called once the code has verified, never on resolve: a wrong code or a spent
  budget is not a failed authentication, and spending the blob there would turn
  "that code isn't valid" into "start over". That ordering is also what makes
  the release safe — nothing puts a held token back without a code.

  ## Claim first, release second

  This order is chosen for its failure case, and the other order was written
  first and was wrong. Releasing first is friendlier when the release fails — the
  blob is unspent, so "try again in a moment" is true advice — but it fails in
  the wrong direction when the *claim* then fails: the token is already back
  under `"user"` with its full natural expiry, the caller is refused, and nobody
  holds it. That is #742 verbatim, re-created by the code that closes it.

  Claiming first cannot do that. A release that fails leaves the token parked,
  which is the safe state; the caller is told `:unavailable`, and a retry of a
  spent blob answers `:taken` and sends them back to the password step. One
  wasted round trip in a rare double failure, against re-opening the hole in a
  single one.

  A caller that loses the claim race never reaches the release at all, so only
  the winner ever moves the row.

  The release is filtered on the hold purpose **in the UPDATE's own WHERE**,
  which is what keeps it from resurrecting a token revoked in between: a password
  change fires `log_out_everywhere` and an erasure fires `AnonymizeUser`, both of
  which sweep every row the subject owns — held ones included — to
  `"revocation"`, and a release then matches nothing. It is a release, not an
  unconditional restore, and the database is what enforces that rather than the
  row this module happened to read a moment earlier.

  (Sign-out revokes too — `clear_session/2` runs
  `AshAuthentication.Plug.Helpers.revoke_session_tokens/3` — but only the token
  carried in *that* session, and a browser waiting at the code prompt is not
  signed in and carries none. So it is the two sweeps above that can reach a
  held row.)

  A `nil` `jti` is a `:session` blob, whose single use is the deleted session
  key — so the claim half is `:ok` rather than an error, and a caller can claim
  what it resolved without asking which door it came through. The clause matches
  `nil` specifically: a `:encrypted` blob that somehow reached here *without* a
  jti is a bug, and answering `:ok` to it would report a claim that never
  happened. The release half is the same for both doors.
  """
  @spec claim(t()) :: :ok | :taken | :unavailable
  def claim(%__MODULE__{user: %Accounts.User{__metadata__: metadata}} = pending) do
    with :ok <- record_spend(pending) do
      release_first_factor(Map.get(metadata, :token))
    end
  end

  defp record_spend(%__MODULE__{jti: jti, user: %Accounts.User{} = user}) when is_binary(jti) do
    # `authorize?: false` because there is no actor to authorize: the whole
    # point of this step is that the caller has *not* finished signing in. The
    # action is `forbid_if always()` so nothing else can reach it.
    case Accounts.spend_pending_sign_in(
           %{jti: jti, subject: AshAuthentication.user_to_subject(user)},
           authorize?: false
         ) do
      {:ok, _row} ->
        :ok

      {:error, error} ->
        if already_claimed?(error) do
          :taken
        else
          # Anything that is not the primary-key conflict is a defect or an
          # outage, and silence here would render a total failure of the
          # headless second factor as ordinary replay traffic: every sign-in
          # answering "start again", nothing in the log to say why.
          Logger.error("could not record a spent pending sign-in: #{Exception.message(error)}")
          :unavailable
        end
    end
  end

  defp record_spend(%__MODULE__{jti: nil}), do: :ok

  # The conflict Postgres raises when the blob has already been claimed. Ash
  # surfaces the primary key's implicit unique constraint as an invalid-changes
  # error on the field; anything else is not "someone beat us to it".
  defp already_claimed?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%{field: :jti}, &1))

  defp already_claimed?(_other), do: false

  # #1171. The hold is a side effect a caller cannot opt out of, so the one call
  # it must never make is the one that would take *its own* session down: a
  # step-up prompt handing over the token that authenticates the request. Both
  # places a conn carries that token are checked — AshAuthentication's session
  # key (`"user_token"`, what `store_in_session/2` writes) and the bearer path,
  # which lands the token on `assigns.current_user.__metadata__.token`.
  # Compared by jti rather than by string, so a re-encoded copy of the same
  # credential does not slip past. Anything that is not a `Plug.Conn` (an
  # endpoint module, a socket) carries no request credential to compare against.
  defp refuse_own_credential!(%Plug.Conn{} = conn, token) do
    with jti when is_binary(jti) <- Accounts.Token.peeked_jti(token),
         true <- jti in conn_credential_jtis(conn) do
      raise ArgumentError,
            "PendingSignIn.mint_and_hold/4 was handed the token that authenticates " <>
              "this request; holding it would sign the caller out. A step-up prompt " <>
              "must mint a fresh first-factor token rather than re-use the session's."
    else
      _ -> :ok
    end
  end

  defp refuse_own_credential!(_context, _token), do: :ok

  defp conn_credential_jtis(%Plug.Conn{} = conn) do
    session_token =
      case conn.private do
        %{plug_session: %{} = session} -> Map.get(session, "user_token")
        _ -> nil
      end

    bearer_token =
      case conn.assigns do
        %{current_user: %Accounts.User{__metadata__: %{token: token}}} -> token
        _ -> nil
      end

    [session_token, bearer_token]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Accounts.Token.peeked_jti/1)
    |> Enum.filter(&is_binary/1)
  end

  # #742 / #1173. Park the first-factor token for the length of this step.
  #
  # One atomic UPDATE filtered by jti (purpose predicate lives on the action),
  # not a SELECT then UPDATE. Fail-soft, and that means catching **raises** as
  # well as a failed bulk result: the store is reached over a connection pool,
  # and a checkout failure arrives as an exception rather than a tuple. Left to
  # travel it would 500 a password step that had already succeeded — which is
  # the outcome the moduledoc's first asymmetry exists to rule out.
  @spec hold_first_factor(term()) :: :ok
  defp hold_first_factor(token) do
    case Accounts.Token.peeked_jti(token) do
      jti when is_binary(jti) -> hold_by_jti(jti)
      # Not a JWT at all — a fixture, a fabricated payload. There was never a
      # row, so this is silent rather than an anomaly.
      nil -> :ok
    end
  rescue
    error -> log_hold_failure(Exception.message(error))
  end

  defp hold_by_jti(jti) do
    Accounts.Token
    |> Ash.Query.filter(jti == ^jti)
    |> Ash.bulk_update(:hold_for_second_factor, %{},
      strategy: :atomic,
      authorize?: false,
      return_records?: true,
      return_errors?: true
    )
    |> interpret_hold_result()
  end

  defp interpret_hold_result(%Ash.BulkResult{status: status, records: [_ | _]})
       when status in [:success, :partial_success],
       do: :ok

  defp interpret_hold_result(%Ash.BulkResult{status: status})
       when status in [:success, :partial_success] do
    # A token we could read a jti out of was minted by the strategy and
    # therefore should have a row, so its absence is the defence quietly
    # not running and has to say so.
    log_hold_failure("no stored row for it")
  end

  defp interpret_hold_result(%Ash.BulkResult{errors: [error | _]}),
    do: log_hold_failure(Exception.message(error))

  defp interpret_hold_result(other), do: log_hold_failure(inspect(other))

  defp log_hold_failure(detail) do
    Logger.error("could not hold a first-factor token: #{detail}")
    :ok
  end

  # The other half, and the one that fails **closed**: everything short of "this
  # token is now usable" answers `:unavailable`, because the alternative is a 201
  # (or a session) carrying a credential that is still parked, whose only symptom
  # is a 401 on every subsequent request with nothing logged.
  #
  # One atomic UPDATE: the jti is the filter, the JWT's own `exp` is the argument
  # (#1173). Peeking once here collapses the three peeks the previous release
  # path did (caller, validate, StoreTokenChange).
  @spec release_first_factor(term()) :: :ok | :unavailable
  defp release_first_factor(token) do
    with jti when is_binary(jti) <- Accounts.Token.peeked_jti(token),
         %DateTime{} = expires_at <- Accounts.Token.peeked_expires_at(token) do
      release_by_jti(jti, expires_at, token)
    else
      # Not a JWT at all, so nothing was ever held and there is nothing to put
      # back. Symmetric with the hold, and silent for the same reason.
      nil -> :ok
    end
  rescue
    error -> log_release_failure(Exception.message(error))
  end

  defp release_by_jti(jti, expires_at, token) do
    Accounts.Token
    |> Ash.Query.filter(jti == ^jti)
    |> Ash.bulk_update(:release_second_factor_hold, %{expires_at: expires_at},
      strategy: :atomic,
      authorize?: false,
      return_records?: true,
      return_errors?: true
    )
    |> interpret_release_result(token)
  end

  defp interpret_release_result(%Ash.BulkResult{status: status, records: [_ | _]}, _token)
       when status in [:success, :partial_success],
       do: :ok

  defp interpret_release_result(%Ash.BulkResult{status: status}, token)
       when status in [:success, :partial_success] do
    # Nothing held under that purpose, and what to make of it turns on whether a
    # row exists at all — absence is not evidence. See the pre-#1173 comments: a
    # row that exists and is not held is evidence (revoked or lapsed); no row is
    # a deployment that never stored tokens.
    release_when_unheld(token)
  end

  defp interpret_release_result(%Ash.BulkResult{errors: [error | _]}, _token),
    do: log_release_failure(Exception.message(error))

  defp interpret_release_result(other, _token), do: log_release_failure(inspect(other))

  defp release_when_unheld(token) do
    if stored_row_exists?(token),
      do: log_release_failure("it is not held and not usable"),
      else: :ok
  end

  defp log_release_failure(detail) do
    Logger.error("could not release a held first-factor token: #{detail}")
    :unavailable
  end

  # Is there a row for this token under any purpose, expired or not? `:get_token`
  # cannot answer it — it filters `expires_at > now()`, and a lapsed hold is
  # exactly the case this has to see.
  defp stored_row_exists?(token) do
    case Accounts.Token.peeked_jti(token) do
      jti when is_binary(jti) ->
        match?(
          {:ok, %Accounts.Token{}},
          Accounts.get_stored_token_by_jti(jti, authorize?: false, not_found_error?: false)
        )

      nil ->
        false
    end
  end

  # ── Blob wrap / unwrap ──────────────────────────────────────────────────────

  defp wrap(:session, context, payload),
    do: Phoenix.Token.sign(context, salt(:session), payload, max_age: @max_age)

  defp wrap(:encrypted, context, payload),
    do: Phoenix.Token.encrypt(context, salt(:encrypted), payload, max_age: @max_age)

  defp unwrap(:session, context, blob),
    do: Phoenix.Token.verify(context, salt(:session), blob, max_age: @max_age)

  defp unwrap(:encrypted, context, blob),
    do: Phoenix.Token.decrypt(context, salt(:encrypted), blob, max_age: @max_age)

  defp salt(mode), do: @modes |> Map.fetch!(mode) |> Map.fetch!(:salt)

  # A mode that carries a `jti` must have one. A mode that does not carries
  # `nil` — and, importantly, is not allowed to *supply* one: a payload is only
  # ever built by `mint_and_hold/4`, but reading a jti the mode did not mint would let
  # `claim/1` record a value nothing ever checks against.
  defp minted_jti(true, payload) do
    case Map.get(payload, "jti") do
      jti when is_binary(jti) -> {:ok, jti}
      _ -> :error
    end
  end

  defp minted_jti(false, _payload), do: {:ok, nil}

  defp put_if(map, false, _key, _fun), do: map
  defp put_if(map, true, key, fun), do: Map.put(map, key, fun.())

  defp random_jti, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
