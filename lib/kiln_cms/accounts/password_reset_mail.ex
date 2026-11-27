defmodule KilnCMS.Accounts.PasswordResetMail do
  @moduledoc """
  Mints a password-reset token for a known account and queues the mail that
  carries it, charging the address's reset-mail budget once.

  Two callers know the account already and need to be told what happened,
  which the anonymous self-service form (`:request_password_reset_token`)
  deliberately never says:

    * `KilnCMS.Accounts.AdminPasswordReset`, an operator's "send a reset
      link" button (`:requested`, the ordinary reset mail);
    * `KilnCMS.Accounts.Preparations.CheckBreachedPasswordAtSignIn`, an
      administrator's sign-in refused for a breached password (#2407,
      `:breached_sign_in`, `KilnCMS.Accounts.User.Senders.SendBreachedPasswordReset`).

  Not through `:request_password_reset_token`: that action charges the
  per-IP `:auth` bucket as well, a second charge for one request. The budget
  here is `AccountThrottle.allow_mail?(:password_reset, email)` (five an
  hour), the one every reset mail to the address shares, charged before a
  token is minted so a refusal leaves no unused token behind. The person
  signing in with a breached password may be an attacker holding it, so the
  budget is never waived.
  """

  alias AshAuthentication.Strategy.Password
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.User.Senders.SendBreachedPasswordReset

  @type kind :: :requested | :breached_sign_in
  @type result :: :sent | :over_budget | {:error, :erased | :token | {:enqueue, term()}}

  @doc """
  Send `user` a reset link of `kind`, on behalf of `tenant` (an org id, an
  organization or `nil`, for the mail's branding). For `:breached_sign_in`
  the caller passes a site whose policy refused the sign-in (#3436).

    * `:sent` - a token was minted and the mail queued;
    * `:over_budget` - the address has had its reset mail for the hour;
    * `{:error, :erased}` - an erased account, which can never be reset;
    * `{:error, :token}` - no token could be minted;
    * `{:error, {:enqueue, error}}` - the mail could not be queued.
  """
  @spec send(User.t(), term(), kind()) :: result()
  def send(%User{anonymized_at: %DateTime{}}, _tenant, _kind), do: {:error, :erased}

  def send(%User{} = user, tenant, kind) when kind in [:requested, :breached_sign_in] do
    with :ok <- within_budget(user),
         {:ok, token} <- reset_token(user) do
      deliver(user, token, tenant, kind)
    end
  end

  # `allow_mail?/2` consumes a unit whether or not it allows.
  defp within_budget(user) do
    if AccountThrottle.allow_mail?(:password_reset, to_string(user.email)),
      do: :ok,
      else: :over_budget
  end

  defp reset_token(user) do
    case Password.reset_token_for(strategy(), user) do
      {:ok, token} -> {:ok, token}
      _error -> {:error, :token}
    end
  end

  defp deliver(user, token, tenant, :requested) do
    {sender, opts} = strategy().resettable.sender

    # The strategy's own sender opts come first, so this cannot silently drop
    # a future DSL option. `budget_checked?: true` tells the sender the budget
    # was charged above, so it is not charged twice.
    :ok = sender.send(user, token, Keyword.merge(opts, tenant: tenant, budget_checked?: true))
    :sent
  rescue
    # `Mail.enqueue!/1` raises on an insert failure; the caller reports it.
    error -> {:error, {:enqueue, error}}
  end

  defp deliver(user, token, tenant, :breached_sign_in) do
    :ok = SendBreachedPasswordReset.deliver(user, token, tenant)
    :sent
  rescue
    error -> {:error, {:enqueue, error}}
  end

  defp strategy, do: AshAuthentication.Info.strategy!(User, :password)
end
