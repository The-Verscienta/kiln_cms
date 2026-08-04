defmodule KilnCMS.Accounts.Preparations.ThrottleSignIn do
  @moduledoc """
  Applies the per-account sign-in budget to `:sign_in_with_password` (#478).

  Lives on the action rather than in a plug, so every entry point is covered by
  one hook: the browser sign-in page, the LiveView (which submits over `/live`
  and so never passes the router's `:auth` pipeline at all), the headless
  `POST /api/auth/sign_in`, and anything reached through
  `AshAuthentication.Strategy.action/3`. A plug per route is a list to forget to
  add to.

  ## An attempt is an execution, not a build

  Everything here is charged from a `before_action` hook, never from `prepare/3`
  directly, and that is load-bearing rather than stylistic. A preparation runs
  when the query is **built**, and `AshPhoenix.Form` builds one on every
  `validate/2` — the sign-in form is `phx-change="change"`, so a charge in
  `prepare/3` costs one unit *per keystroke*, plus one for each page load that
  builds the form at all. A user typing a twenty-character password would spend
  their own budget and be refused before they could submit it. `before_action`
  runs once, when the read actually executes, which is the only thing that is an
  attempt.

  ## Charge the attempt, forgive the *completed* sign-in

  `AccountThrottle.consume/1` is one atomic increment-and-compare, run before the
  read. A preparation can't observe *why* a read failed — `SignInPreparation`
  returns its `AuthenticationFailed` from an `after_action` hook, and a hook that
  errors ends the chain — so every attempt is charged and a completed sign-in
  refunds the whole counter.

  Two things are checked rather than assumed. The record must carry the sign-in
  token `SignInPreparation` mints once the password verifies — Ash appends
  `after_action` hooks only when `read_action_after_action_hooks_in_order?` is
  set (it is, in `config/config.exs`), so reading the token means the wrong
  order degrades to "forgives nothing" rather than to "forgives a failed
  attempt". And the account must not owe a **second factor** (#742): for a 2FA
  account the password succeeding is not the sign-in succeeding, and forgiving
  there handed an attacker who holds a stuffed password an unlimited supply of
  first-factor steps. `KilnCMS.Accounts.SecondFactor.check/2` forgives it at the
  step that actually completes.

  ## The refusal costs an attacker the same as a wrong guess

  Same `AuthenticationFailed` a wrong password produces, so the caller renders
  the same generic 401. And the same *time*: `SignInPreparation` calls
  `hash_provider.simulate/0` on a miss precisely so a missing account and a wrong
  password both cost a full bcrypt verify, and a refusal that skipped it would
  answer in a millisecond — telling an attacker "this address is throttled right
  now", which is both an enumeration oracle and a free poll for when the window
  rolls. So a refusal burns the same bcrypt.

  ## The owner is told once

  Crossing the budget is what triggers `KilnCMS.Accounts.SignInAlert` — not the
  attempt that reaches it. A user who mistypes their password nine times and then
  gets it right must not be mailed "someone is guessing at your password", and
  the alert's own once-per-window budget must not be spent on them.

  ## The other axis, for the one caller that has no plug (#715)

  The per-account budget bounds guesses at *one* account. It does not bound
  volume: one address can spend a thousand accounts' budgets, and every attempt
  costs a bcrypt verify and an ETS row. Every HTTP entry point already pays the
  router's per-IP `:auth` bucket for that, but the browser sign-in submits its
  credentials as a LiveView event over `/live`, which passes no pipeline at all.

  So when the action's context carries a `:kiln_client_ip` — which only
  `KilnCMSWeb.SignInLive` sets, from the socket's own handshake — this
  charges the same `:auth` bucket the plug would have. Deliberately the *same*
  bucket, so the socket and the HTTP form share one window per address rather
  than handing an attacker a second budget by switching transport. And
  deliberately keyed on the context rather than charged unconditionally: a path
  that already passed the plug would otherwise be charged twice, halving a limit
  the threat model states as one number.

  The IP is charged **before** the account budget, and a refusal spends no
  account budget. The other order would let a flood from one address burn a
  thousand victims' budgets on its way to being refused — turning the control
  that exists to protect accounts into the lever for locking them out.

  A success forgives the account counter and never the IP one. Volume is volume;
  an attacker holding one valid credential must not be able to reset their
  address's budget by spending it.

  The per-IP refusal is also the one refusal here that does *not* burn a
  simulated bcrypt — see `refuse_address/1` for why the timing argument that
  governs the account refusal does not apply to it, and why paying it anyway
  would forfeit most of what this control is for.
  """
  use Ash.Resource.Preparation

  alias Ash.Query
  alias AshAuthentication.Errors.AuthenticationFailed
  alias AshAuthentication.Info
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.SignInAlert

  # Named here rather than at the caller so the two ends cannot drift into
  # writing and reading different keys — which would fail silently, as "no IP in
  # context" is a legitimate state meaning "a plug already charged this".
  @context_key :kiln_client_ip

  @doc """
  The action context that asks this preparation to charge the `:auth` bucket for
  `client_ip` as well.

  `KilnCMSWeb.SignInLive` merges this into the sign-in form's context; nothing
  that reaches the action through a plug should, because the plug charged it.
  """
  @spec client_ip_context(String.t()) :: map()
  def client_ip_context(client_ip) when is_binary(client_ip), do: %{@context_key => client_ip}

  @impl true
  def prepare(query, opts, context) do
    Query.before_action(query, &charge(&1, opts, context))
  end

  # Everything is charged from a `before_action` hook rather than from
  # `prepare/3` itself, because a preparation runs when the query is **built**
  # and a build is not an attempt. `AshPhoenix.Form.validate/2` builds one, and
  # the sign-in form is `phx-change="change"` — so charging in `prepare/3` spends
  # a budget per *keystroke*, and a user typing their password locks themselves
  # out before they can submit it. (It also charged once per page load, since
  # building the form builds a query too.) A `before_action` hook runs once, when
  # the read actually executes, which is the thing worth counting.
  defp charge(query, opts, context) do
    case charge_client_ip(query) do
      {:deny, _retry_after} -> refuse_address(query)
      :allow -> throttle_account(query, opts, context)
    end
  end

  defp throttle_account(query, opts, context) do
    case identifier(query) do
      nil ->
        query

      identifier ->
        case AccountThrottle.consume(identifier) do
          :allow -> forgive_on_success(query, identifier)
          {:deny, _retry_after} -> refuse(query, identifier, opts, context)
        end
    end
  end

  # `:allow` also covers "no IP in the context", which is every caller that
  # reached the action through a pipeline carrying `Plugs.RateLimit, :auth`.
  defp charge_client_ip(query) do
    case Map.get(query.context, @context_key) do
      ip when is_binary(ip) -> KilnCMSWeb.RateLimit.check(:auth, ip)
      _absent -> :allow
    end
  end

  defp forgive_on_success(query, identifier) do
    Query.after_action(query, fn _query, records ->
      if Enum.any?(records, &completed_sign_in?/1), do: AccountThrottle.forgive(identifier)
      {:ok, records}
    end)
  end

  # A password that is not the whole sign-in does not clear the counter (#742).
  #
  # For a 2FA account the first factor succeeding proves nothing about whoever
  # sent it finishing — and forgiving there left this budget with no grip on the
  # one attacker it most needs it for. Someone holding a stuffed password for an
  # account they cannot pass could loop `POST /api/auth/sign_in`: the password
  # *succeeds*, so the counter reset every time, and the only remaining bound
  # was the per-IP `:auth` bucket — the axis #478 exists precisely because
  # attackers rotate. Each of those calls also mints and stores a token row
  # nobody will ever hold, because `store_all_tokens?` writes it before this
  # controller learns the account owes a code.
  #
  # So the counter is held, and `KilnCMS.Accounts.SecondFactor.check/2` forgives
  # it when the second factor actually lands. A user who abandons the code
  # prompt ten times in a window is refused for its tail, which is the same
  # bargain every other account here makes.
  defp completed_sign_in?(record) do
    signed_in?(record) and not KilnCMS.Accounts.totp_enabled?(record)
  end

  # The per-IP refusal, which is deliberately *not* the per-account one.
  #
  # It mails nobody: the address being refused says nothing about whose account
  # was aimed at, and an attacker who has spent their budget must not also get
  # to pick whose inbox rings.
  #
  # And it does not burn a simulated bcrypt. The account refusal must (see
  # below) because a fast answer would tell an attacker *which addresses* are
  # currently throttled, which is an enumeration oracle. Here the only thing a
  # fast answer reveals is that the caller's own address is out of budget, which
  # the caller already knows — they sent the traffic. Paying bcrypt anyway would
  # give up the thing this control exists for: past the limit, a flood over
  # `/live` would still cost a full password hash per request, which is most of
  # the CPU an unthrottled flood costs in the first place.
  defp refuse_address(query) do
    Query.add_error(
      query,
      AuthenticationFailed.exception(
        query: query,
        caused_by: %{
          module: __MODULE__,
          action: :sign_in_with_password,
          message: "Too many sign-in attempts from this address"
        }
      )
    )
  end

  defp refuse(query, identifier, opts, context) do
    simulate_hashing(query, opts, context)
    SignInAlert.account_locked(identifier)

    Query.add_error(
      query,
      AuthenticationFailed.exception(
        query: query,
        caused_by: %{
          module: __MODULE__,
          action: :sign_in_with_password,
          message: "Too many failed sign-in attempts for this account"
        }
      )
    )
  end

  # Equalizes the refusal against the wrong-password path — see the moduledoc.
  # Best-effort: if the strategy can't be resolved there is nothing to simulate
  # with, and failing the sign-in over it would be worse than the timing signal.
  defp simulate_hashing(query, opts, context) do
    case Info.find_strategy(query, context, opts) do
      {:ok, strategy} -> strategy.hash_provider.simulate()
      _other -> :ok
    end
  rescue
    _error -> :ok
  end

  # `Ash.Resource.put_metadata(record, :token, …)` is the last thing
  # `SignInPreparation` does once the password verifies.
  defp signed_in?(record) do
    is_binary(Map.get(record.__metadata__ || %{}, :token))
  end

  defp identifier(query) do
    case Query.get_argument(query, :email) do
      nil -> nil
      email -> to_string(email)
    end
  end
end
