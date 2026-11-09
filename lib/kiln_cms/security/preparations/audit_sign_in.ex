defmodule KilnCMS.Security.Preparations.AuditSignIn do
  @moduledoc """
  Records the refusals of `:sign_in_with_password` in the security audit log
  (#2241): a wrong password or unknown address (`:sign_in_failed`, sampled per
  IP), a human-verification token that did not pass or could not be checked
  (`:sign_in_failed`, reason `challenge_failed` / `challenge_unavailable`,
  #2249) and the two throttle lockouts (`:sign_in_locked`, scope `"account"` or
  `"address"`).

  It sits on the action rather than at a controller because the browser form
  submits over `/live` and never reaches `AuthController.failure/3`; the action
  is the one place every door passes. The request context and org arrive in the
  action's context (`KilnCMS.Security.AuthEvents.context/2`); with none, nothing
  is recorded.

  An `after_transaction` hook, so it runs for a refusal that a `before_action`
  hook added (the throttle) as well as for the one `SignInPreparation` returns.
  It only observes: the result is handed back untouched, so the response, its
  error and its timing are the ones the action produced.

  Whatever the account's existence, the same path runs, and the lockout cases
  are told apart from a wrong password by the error `ThrottleSignIn` raised,
  not by reading the account.
  """
  use Ash.Resource.Preparation

  alias AshAuthentication.Errors.AuthenticationFailed
  alias KilnCMS.Accounts.Errors.ChallengeRequired
  alias KilnCMS.Accounts.Preparations.ThrottleSignIn
  alias KilnCMS.Security.AuthEvents
  alias KilnCMS.Security.Recorder

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_transaction(query, fn query, result ->
      with {:error, error} <- result, do: audit(query, error)
      result
    end)
  end

  defp audit(query, error) do
    context = query.context || %{}

    if is_map(context[Recorder.context_key()]) do
      email = Ash.Query.get_argument(query, :email)
      record(refusal(error), context, email)
    end
  end

  defp record(:account_locked, context, email),
    do: AuthEvents.password_locked(context, email && to_string(email), "account")

  defp record(:address_locked, context, email),
    do: AuthEvents.password_locked(context, email && to_string(email), "address")

  defp record(:invalid, context, email),
    do: AuthEvents.sign_in_failed(context, email, "password", "invalid_credentials")

  # Human verification (#2249). A token the provider refused is a failed
  # attempt like a wrong password; a refusal because the provider could not be
  # asked is recorded so an outage shows in the site's log. A challenge merely
  # being asked for (`:required`) is not a failure and records nothing.
  defp record({:challenge, :failed}, context, email),
    do: AuthEvents.sign_in_failed(context, email, "password", "challenge_failed")

  defp record({:challenge, :unavailable}, context, email),
    do: AuthEvents.sign_in_failed(context, email, "password", "challenge_unavailable")

  defp record(_required_or_other, _context, _email), do: :ok

  # What `error` is: the account lock, the per-address lock, any other refused
  # sign-in, or a failure that is not one (bad input, a crash).
  defp refusal(error) do
    error
    |> flatten()
    |> Enum.find_value(:other, fn
      %AuthenticationFailed{caused_by: %{module: ThrottleSignIn, message: message}} ->
        if String.contains?(to_string(message), "from this address"),
          do: :address_locked,
          else: :account_locked

      %AuthenticationFailed{} ->
        :invalid

      %ChallengeRequired{reason: reason} ->
        {:challenge, reason}

      _other ->
        nil
    end)
  end

  defp flatten(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)
  defp flatten(error), do: [error]
end
