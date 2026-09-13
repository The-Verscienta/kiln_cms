defmodule KilnCMS.Accounts.AdminPasswordReset do
  @moduledoc """
  Sends a password-reset link to a named account, on an operator's behalf.

  The self-service form (`:request_password_reset_token`) cannot serve this. It
  is built to be *indistinguishable*: it takes an address rather than an account,
  answers `:ok` whether or not that address exists, and its sender drops the mail
  silently when the per-address budget is spent — all correct for an anonymous
  endpoint that must not become an account oracle or a mailbomb, and all wrong
  for a button in the admin console, where the operator already knows the account
  exists and needs to be told whether the mail went.

  So this takes a `user_id`, is admin-only by policy, and reports what happened:

    * `{:ok, :sent}` — a reset token was minted and the mail enqueued;
    * `{:error, %Ash.Error.Invalid{}}` — the account cannot be reset this way
      (an erased account, or one with no password identity), named as such.

  ## The per-address mail budget still applies

  `KilnCMS.Accounts.AccountThrottle`'s budget bounds how much reset mail one
  address can be sent in an hour, whoever asks. An earlier version bypassed it
  here on the grounds that an admin is trusted — but a *temporary* admin is a
  grantee, not necessarily an operator, and the bypass also skipped the budget's
  consumption, so the admin path and the owner's own requests became two
  independent allowances. The budget is charged here, once, before a token is
  minted; a refusal is reported to the operator by name instead of being dropped
  silently the way the anonymous form must.

  ## "Sent" means enqueued

  `{:ok, :sent}` is returned only after the mail was handed to the queue.
  `KilnCMS.Mail.enqueue!/1` raises on an insert failure; that is caught and
  reported as an error, so the console flashes it rather than crashing.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias AshAuthentication.Strategy.Password
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User

  @impl true
  def run(input, _opts, context) do
    user_id = Ash.ActionInput.get_argument(input, :user_id)

    with {:ok, user} <- fetch(user_id),
         :ok <- resettable(user),
         :ok <- within_budget(user),
         {:ok, token} <- reset_token(user) do
      deliver(user, token, context)
    end
  end

  # Charged before the token is minted, so a refused request leaves no unused
  # reset token behind. `allow_mail?/2` consumes a unit whether or not it allows.
  defp within_budget(user) do
    if AccountThrottle.allow_mail?(:password_reset, to_string(user.email)) do
      :ok
    else
      invalid(
        :user_id,
        "this address has been sent too many reset links in the last hour — try again later"
      )
    end
  end

  defp deliver(user, token, context) do
    {sender, opts} = sender()
    Logger.info("Admin-initiated password reset for user #{user.id}")

    # The strategy's own sender opts come first, so this cannot silently drop a
    # future DSL option. `budget_checked?: true` tells the sender the budget was
    # charged above, so it is not charged twice.
    :ok =
      sender.send(user, token, Keyword.merge(opts, tenant: context.tenant, budget_checked?: true))

    {:ok, :sent}
  rescue
    error ->
      Logger.error("Admin-initiated password reset could not be enqueued: #{inspect(error)}")
      invalid(:user_id, "the reset email could not be queued — check the mail settings")
  end

  # Read with `authorize?: false` after the action's own admin-only policy has
  # run: `User`'s read policy is self-only for non-admins, and the actor here is
  # by definition someone else's administrator.
  defp fetch(user_id) do
    case KilnCMS.Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %User{} = user} -> {:ok, user}
      _ -> invalid(:user_id, "no account with that id")
    end
  end

  # An erased account's password hash is random bytes with no matching plaintext
  # (`KilnCMS.Accounts.Changes.AnonymizeUser`) and its email is a non-routable
  # tombstone, so a reset link would be mail to `@deleted.invalid` offering to set
  # credentials on an account that must never sign in again.
  defp resettable(%User{anonymized_at: nil}), do: :ok

  defp resettable(%User{}),
    do: invalid(:user_id, "this account has been erased and cannot be reset")

  defp reset_token(user) do
    case Password.reset_token_for(strategy(), user) do
      {:ok, token} -> {:ok, token}
      _ -> invalid(:user_id, "couldn't mint a reset token for this account")
    end
  end

  defp sender, do: strategy().resettable.sender

  defp strategy, do: AshAuthentication.Info.strategy!(User, :password)

  defp invalid(field, message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)]
     )}
  end
end
