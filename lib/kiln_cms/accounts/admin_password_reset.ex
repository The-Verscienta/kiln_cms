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

  ## The per-address mail budget is bypassed, deliberately

  `KilnCMS.Accounts.AccountThrottle`'s five-per-hour budget exists because
  anyone can name anyone's address on the public form. Nobody can reach this
  action without already holding an admin session, and the amount of mail an
  admin can send through the console dwarfs one reset link. Charging it here
  would buy nothing and cost the thing this action exists for: on a spent budget
  the button would report success and send nothing, which is exactly the lie the
  public endpoint is *supposed* to tell and this one must not.

  It is logged instead, so an operator reading the mail log can tell an
  admin-initiated reset from a self-service one.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias AshAuthentication.Strategy.Password
  alias KilnCMS.Accounts.User

  @impl true
  def run(input, _opts, context) do
    user_id = Ash.ActionInput.get_argument(input, :user_id)

    with {:ok, user} <- fetch(user_id),
         :ok <- resettable(user),
         {:ok, token} <- reset_token(user) do
      {sender, opts} = sender()

      # The strategy's own sender opts come first, so this cannot silently drop a
      # future DSL option; `bypass_budget?: true` is read by
      # `KilnCMS.Accounts.User.Senders.SendPasswordResetEmail`.
      Logger.info("Admin-initiated password reset for user #{user.id}")

      sender.send(
        user,
        token,
        Keyword.merge(opts, tenant: context.tenant, bypass_budget?: true)
      )

      {:ok, :sent}
    end
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
