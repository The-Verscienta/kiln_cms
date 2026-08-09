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
  reader that supplies its own `max_age` wins, so `mint/4` cannot stop a future
  caller reading a stale blob. What it sets is the *default* for a reader that
  passes none: `Plug.Crypto` embeds `Keyword.get(opts, :max_age, 86400)` into
  the term, so without it the blob's own lifetime would be a day. The five
  minutes is enforced by `resolve/3`; the mint-time value is what a reader that
  forgets falls back to.

  ## Single use

  `:encrypted` blobs are burned on redemption, so a captured verify request
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
  the `jti` is for, and why paying a cache write per browser sign-in for it
  would be paying for the wrong threat.

  The record is a row on `KilnCMS.Accounts.Token` (#743), and single use is
  **exact** — on one node and on a cluster.

  It used to be a node-local `Cachex` entry, which made it fail *open* across
  nodes: a replay landing on a node that never saw the redemption was accepted.
  That is now a Postgres INSERT whose primary key is the `jti`, so the write
  **is** the check. Two redemptions of the same blob race at the database, and
  exactly one wins, wherever each request landed.

  The ordering that matters: the row is written after the code verifies, not on
  resolve — see `spend/1`. The cheap `spent?` read in `resolve/3` stays, because
  rejecting a replayed blob before spending a TOTP check against it is the
  friendlier answer, but it is not what makes this exact. The INSERT is.

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

  Burning is deliberately **not** done on a wrong code or a spent budget. The
  caller has not failed authentication there, and destroying their pending state
  would turn "that code isn't valid" into "start over".
  """

  alias KilnCMS.Accounts

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
  Mint the blob for `user`, who has just passed the first factor.

  Options:

    * `:token` — the first-factor JWT to carry. Defaults to
      `user.__metadata__.token`, which is where it lands for a headless
      sign-in; the browser callback is handed it separately and passes it in.
    * `:remember_me?` — the ticked checkbox, carried across the code prompt as
      *intent* only. The cookie itself is withheld at the first factor and
      issued once the code verifies (#699). Ignored by `:encrypted`.
  """
  @spec mint(mode(), context(), Accounts.User.t(), keyword()) :: String.t()
  def mint(mode, context, user, opts \\ []) when is_map_key(@modes, mode) do
    %{jti?: jti?, remember_me?: carries_remember_me?} = Map.fetch!(@modes, mode)

    %{
      "user_id" => user.id,
      "token" => Keyword.get_lazy(opts, :token, fn -> user.__metadata__.token end)
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
         {:ok, jti} <- claim(jti?, payload),
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
  # `mint/4` raises on one too and the pair has to fail the same way: a silent
  # `:error` from a typo would resolve forever, and both gates render that as a
  # redirect back to `/sign-in` — an unbreakable loop with no exception, no log
  # line, and nothing in the suite to catch it.
  def resolve(mode, _context, _blob) when is_map_key(@modes, mode), do: :error

  @doc """
  Claim this attempt, so the blob cannot be redeemed again — `:ok` if this
  caller got it, `:error` if it was already spent.

  **The return value is the single-use guarantee, and a caller that ignores it
  has none.** The row's primary key is the `jti`, so two concurrent redemptions
  of one blob both reach here and exactly one INSERT succeeds; the loser gets
  `:error` and must refuse the sign-in rather than issue a token. That is the
  whole difference from the node-local cache this replaced, where both would
  have been told they were first.

  Called once the code has verified, never on resolve: a wrong code or a spent
  budget is not a failed authentication, and spending the blob there would turn
  "that code isn't valid" into "start over".

  Fails **closed**. A database error is indistinguishable here from "someone
  else already has it", and for a single-use check the safe reading of "I don't
  know" is "no".

  The row outlives the blob by a second, so there is no window in which the blob
  is still inside its `max_age` but the record of its use has expired. It is
  swept by the nightly `:expunge_expired` trigger the resource already runs.

  A `nil` `jti` is a `:session` blob, whose single use is the deleted session
  key — so this is `:ok` rather than an error, and a caller can spend what it
  resolved without asking which door it came through.
  """
  @spec spend(t() | nil) :: :ok | :error
  def spend(%__MODULE__{jti: jti, user: user}) when is_binary(jti) do
    expires_at = DateTime.add(DateTime.utc_now(), @max_age + 1, :second)

    # `authorize?: false` because there is no actor to authorize: the whole
    # point of this step is that the caller has *not* finished signing in.
    case Accounts.spend_pending_sign_in(
           %{
             jti: jti,
             subject: AshAuthentication.user_to_subject(user),
             expires_at: expires_at
           },
           authorize?: false
         ) do
      {:ok, _row} -> :ok
      {:error, _already_spent_or_unavailable} -> :error
    end
  end

  def spend(%__MODULE__{}), do: :ok
  def spend(nil), do: :ok

  defp wrap(:session, context, payload),
    do: Phoenix.Token.sign(context, salt(:session), payload, max_age: @max_age)

  defp wrap(:encrypted, context, payload),
    do: Phoenix.Token.encrypt(context, salt(:encrypted), payload, max_age: @max_age)

  defp unwrap(:session, context, blob),
    do: Phoenix.Token.verify(context, salt(:session), blob, max_age: @max_age)

  defp unwrap(:encrypted, context, blob),
    do: Phoenix.Token.decrypt(context, salt(:encrypted), blob, max_age: @max_age)

  defp salt(mode), do: @modes |> Map.fetch!(mode) |> Map.fetch!(:salt)

  # A mode that carries a `jti` must have one, and it must be unspent. A mode
  # that does not carries `nil` — and, importantly, is not allowed to *supply*
  # one: a payload is only ever built by `mint/4`, but reading a jti the mode
  # did not mint would let a future single-use check pass on a value nothing
  # ever burns.
  defp claim(true, payload) do
    case Map.get(payload, "jti") do
      jti when is_binary(jti) -> if spent?(jti), do: :error, else: {:ok, jti}
      _ -> :error
    end
  end

  defp claim(false, _payload), do: {:ok, nil}

  defp put_if(map, false, _key, _fun), do: map
  defp put_if(map, true, key, fun), do: Map.put(map, key, fun.())

  defp random_jti, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # A cheap pre-check, not the guarantee — `spend/1` is. Rejecting a replayed
  # blob here saves spending a TOTP check (and a slice of the second-factor
  # budget) against an exchange that is already over.
  #
  # Unknown reads as *unspent*, deliberately: this is an optimisation, and
  # failing closed on a transient read error would break sign-ins that `spend/1`
  # would have allowed. The write below is where "I don't know" means "no".
  defp spent?(jti) do
    case Accounts.get_token(jti, authorize?: false, not_found_error?: false) do
      {:ok, %{purpose: "pending_sign_in"}} -> true
      _other -> false
    end
  end
end
