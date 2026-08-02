defmodule KilnCMS.Accounts.AccountThrottle do
  @moduledoc """
  Per-account budgets for the credential and mail-triggering auth flows (#478).

  `KilnCMSWeb.RateLimit`'s `:auth` bucket keys strictly on the client IP, so an
  attacker rotating addresses gets a fresh window per address against the same
  account. TOTP and passkeys mitigate that, but neither is mandatory. This is the
  other axis: a budget that follows the **account**, wherever the attempts come
  from.

  ## Flat and bounded, deliberately

  `@budget` attempts per `@window`, and that is the whole policy. No escalating
  tiers, no strike history: the issue that asked for this named the reason —
  *hard lockout is a trivial denial-of-service against any known email address*.
  A lockout that lengthens each time an attacker burns a window is a hard lockout
  wearing a costume; ten wrong guesses would let anyone keep a named editor out
  of the console indefinitely for the price of a few requests an hour.

  What a flat window buys is still most of the value: an attacker goes from
  unlimited guesses per account to `@budget` per `@window`, and the worst a
  victim suffers is the tail of one window. A successful sign-in clears the
  counter outright, so a user who mistypes twice and then gets it right starts
  from zero rather than carrying failures into their next session.

  Sign-in isn't the only way to prove you own the account, so a completed
  password reset and a passkey sign-in call `forgive/1` too — otherwise the one
  remedy a locked-out owner has would be the one thing the lock forbids.

  ## One atomic operation, not check-then-count

  `hit/3` is a single `:ets.update_counter` that increments *and* compares. A
  read followed by a later increment is not the same thing: a burst of
  simultaneous requests would all read "under budget", all proceed, and all get
  a full password verification — which is precisely the shape of the attack this
  exists to bound. So `consume/1` is the only gate, it runs once per attempt,
  and nothing reads the counter to decide.

  ## It never reveals whether an account exists

  Every bucket keys on the **submitted identifier**, normalized and hashed —
  never on a resolved user id. An address with no account throttles exactly like
  one with an account, the caller renders the refusal as the same generic
  failure a wrong password produces, and
  `KilnCMS.Accounts.Preparations.ThrottleSignIn` spends the same bcrypt time on
  a refusal that AshAuthentication spends on a miss, so the refusal is not a
  timing oracle either.

  The hash is not decoration: this table is a security control keyed on user
  identifiers, and it survives into crash dumps and `:observer`.

  ## Mail-triggering requests get their own budget

  Password-reset and magic-link requests aren't a credential-stuffing vector —
  they're a mailbomb. A flat per-address budget, enforced at the senders, which
  are the outbound boundary every entry point passes through.

  This one cuts both ways and the trade is deliberate: an attacker who spends a
  victim's mail budget delays that victim's own reset mail until the window
  rolls. The budget is therefore generous, per-hour rather than per-day, and
  every refusal is logged so an operator can see recovery being suppressed
  rather than guess at it.

  ## Scope

  Per node, in ETS, and reset by a restart — the same trade `KilnCMSWeb.RateLimit`
  makes. The alternative (counters on the user row) turns every guess into a
  write to a row the attacker chooses, and leaves an unknown address with nowhere
  to count, which is what reopens account enumeration.

  Every limit is config-overridable so the test suite can pin them:

      config :kiln_cms, KilnCMS.Accounts.AccountThrottle,
        budget: 3, window: :timer.seconds(1), mail_budget: 2
  """
  use Hammer, backend: :ets

  require Logger

  @budget 10
  @window :timer.minutes(15)

  @mail_budget 5
  @mail_window :timer.hours(1)

  # One "someone is guessing at your password" mail per address per window,
  # however long the attack runs.
  @alert_window :timer.hours(6)

  @type purpose :: :password_reset | :magic_link

  @doc """
  Charges one sign-in attempt against this identifier.

  `{:deny, retry_after_ms}` once the window's budget is spent. This is the gate
  *and* the counter — a single atomic increment-and-compare, so a simultaneous
  burst can't all pass a check that a later increment would have failed.
  """
  @spec consume(String.t()) :: :allow | {:deny, non_neg_integer()}
  def consume(identifier) do
    case hit(key("signin", identifier), window(), budget()) do
      {:allow, _count} -> :allow
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  @doc """
  Clears the sign-in counter for this identifier.

  Called on any proof of ownership — a successful password sign-in, a completed
  password reset, a passkey sign-in. A locked-out owner whose only remedy was
  the thing being blocked would have no remedy at all.
  """
  @spec forgive(String.t()) :: :ok
  def forgive(identifier), do: drop(key("signin", identifier), window())

  @doc """
  Whether the owner of this identifier should be told their account is being
  guessed at, consuming that budget if so.

  Separate from `consume/1` so an attack that runs for a day produces one mail
  rather than one per burned window.
  """
  @spec alert_allowed?(String.t()) :: boolean()
  def alert_allowed?(identifier) do
    match?({:allow, _count}, hit(key("signin:alert", identifier), @alert_window, 1))
  end

  @doc """
  Whether another `purpose` mail may be sent to this address.

  Consumes budget on every call, including refused ones — a caller asking is a
  caller who was about to send. A refusal is logged: this is the one budget here
  that can withhold something a legitimate user asked for, so it must not be
  silent to the operator (it stays silent to the *requester*, who may be an
  attacker probing for accounts).
  """
  @spec allow_mail?(purpose(), String.t()) :: boolean()
  def allow_mail?(purpose, identifier) when purpose in [:password_reset, :magic_link] do
    case hit(key("mail:#{purpose}", identifier), mail_window(), mail_budget()) do
      {:allow, _count} ->
        true

      {:deny, retry_after_ms} ->
        Logger.warning(
          "Suppressed a #{purpose} mail: per-address budget spent, " <>
            "#{div(retry_after_ms, 1000)}s remaining. If this repeats for one " <>
            "address, someone may be denying that account's recovery."
        )

        false
    end
  end

  @doc """
  The digest this module keys buckets on.

  Exported so anything else keying per-address state agrees byte-for-byte: two
  copies of "trim, downcase, hash" that drift produce two different buckets for
  one address, and the guarantees stated above quietly stop holding.
  """
  @spec digest(String.t()) :: String.t()
  def digest(identifier) do
    identifier
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  # Test seam: forget everything about an identifier, so a suite can assert on a
  # deterministic budget without waiting out a real window.
  @spec reset(String.t()) :: :ok
  def reset(identifier) do
    forgive(identifier)
    drop(key("signin:alert", identifier), @alert_window)
    Enum.each([:password_reset, :magic_link], &drop(key("mail:#{&1}", identifier), mail_window()))
  end

  # Hammer's `set/3` is spec'd `count :: pos_integer()`, so zeroing a bucket is a
  # type violation — drop the row instead (the same seam `Mail.RelayAlert` uses).
  # Hammer names the ETS table after the module and keys rows `{key, window}`.
  defp drop(key, scale) do
    :ets.delete(__MODULE__, {key, div(System.system_time(:millisecond), scale)})
    :ok
  end

  defp key(prefix, identifier), do: prefix <> ":" <> digest(identifier)

  defp budget, do: config(:budget, @budget)
  defp window, do: config(:window, @window)
  defp mail_budget, do: config(:mail_budget, @mail_budget)
  defp mail_window, do: config(:mail_window, @mail_window)

  defp config(key, default) do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
