defmodule KilnCMS.Accounts.Preparations.ThrottleSignIn do
  @moduledoc """
  Applies the per-account sign-in budget to `:sign_in_with_password` (#478).

  Lives on the action rather than in a plug, so every entry point is covered by
  one hook: the browser sign-in page, the LiveView (which submits over `/live`
  and so never passes the router's `:auth` pipeline at all), the headless
  `POST /api/auth/sign_in`, and anything reached through
  `AshAuthentication.Strategy.action/3`. A plug per route is a list to forget to
  add to.

  ## Charge the attempt, forgive the success

  `AccountThrottle.consume/1` is one atomic increment-and-compare, run before the
  read. A preparation can't observe *why* a read failed — `SignInPreparation`
  returns its `AuthenticationFailed` from an `after_action` hook, and a hook that
  errors ends the chain — so every attempt is charged and a genuine success
  refunds the whole counter.

  "Genuine" is checked rather than assumed: the record is forgiven only if it
  carries the sign-in token `SignInPreparation` mints once the password verifies.
  Ash appends `after_action` hooks only when `read_action_after_action_hooks_in_order?`
  is set (it is, in `config/config.exs`); reading the token means the wrong order
  degrades to "forgives nothing" rather than to "forgives a failed attempt".

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
  """
  use Ash.Resource.Preparation

  alias Ash.Query
  alias AshAuthentication.Errors.AuthenticationFailed
  alias AshAuthentication.Info
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.SignInAlert

  @impl true
  def prepare(query, opts, context) do
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

  defp forgive_on_success(query, identifier) do
    Query.after_action(query, fn _query, records ->
      if Enum.any?(records, &signed_in?/1), do: AccountThrottle.forgive(identifier)
      {:ok, records}
    end)
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
