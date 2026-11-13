defmodule KilnCMS.Accounts.Changes.ThrottlePasskeyRegistration do
  @moduledoc """
  Charges one attempt against the account's passkey-registration budget
  (#2247, `KilnCMS.Accounts.AccountThrottle.consume_passkey_registration/1`)
  on `KilnCMS.Accounts.Passkey`'s `:register`.

  Every passkey added mails the owner, so a stolen session that could add
  passkeys at socket speed could flood the owner's inbox and the instance's
  relay quota. This is the per-hour bound; `Validations.PasskeyCap` is the
  total one.

  ## Per account, in `ThrottleStore`

  Keyed on the account, not the client address: the flood is aimed at one
  owner's mailbox whichever address it comes from, and the ceremony already
  names the account. Counted in `KilnCMS.Accounts.ThrottleStore` like the
  other per-account budgets, so it holds across nodes and restarts, rather than
  in `KilnCMSWeb.RateLimit`'s node-local buckets, which are per-client flood
  ceilings. On the action rather than at the settings page, so any later
  caller of the ceremony inherits it (`ThrottleSecondFactor`'s argument).

  ## From `before_transaction`

  `ThrottleStore.hit/5` refuses to run inside a transaction: a registration
  that then fails (a credential id already registered) would roll the charge
  back with it. Not from the `change/3` body either: nothing builds this
  changeset per keystroke today, but a hook runs once per real attempt
  whatever the caller does.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.PasskeyRegistrationThrottled

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, &charge/1)
  end

  defp charge(changeset) do
    case Ash.Changeset.get_attribute(changeset, :user_id) do
      user_id when is_binary(user_id) ->
        case AccountThrottle.consume_passkey_registration(user_id) do
          :allow ->
            changeset

          {:deny, retry_after_ms} ->
            Ash.Changeset.add_error(
              changeset,
              PasskeyRegistrationThrottled.exception(
                retry_after_seconds: AccountThrottle.retry_after_seconds(retry_after_ms)
              )
            )
        end

      # No account named: `belongs_to :user` refuses it on its own.
      _missing ->
        changeset
    end
  end
end
