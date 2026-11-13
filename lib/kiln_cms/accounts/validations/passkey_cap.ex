defmodule KilnCMS.Accounts.Validations.PasskeyCap do
  @moduledoc """
  Refuses a passkey registration once the account holds
  `KilnCMS.Accounts.Passkey.max_per_account/0` of them (#2247).

  Every passkey added mails the owner (`KilnCMS.Accounts.SecondFactorNotice`),
  and "an email for every factor added" has to stay literally true. The cap,
  with the per-hour budget (`KilnCMS.Accounts.Changes.ThrottlePasskeyRegistration`),
  is what keeps that promise from becoming a way for a stolen session to flood
  the owner's inbox and the instance's relay quota.

  A validation, so it runs on the ceremony's `authorize?: false` call too. The
  count is read when the changeset is built, so two registrations racing at
  the 20th could both pass; the hourly budget bounds that overshoot, and a
  passkey or two past the cap costs nothing worth a lock.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.PasskeyLimitReached
  alias KilnCMS.Accounts.Passkey

  @impl true
  def validate(changeset, _opts, _context) do
    max = Passkey.max_per_account()

    case Ash.Changeset.get_attribute(changeset, :user_id) do
      user_id when is_binary(user_id) ->
        if count(user_id) >= max,
          do: {:error, PasskeyLimitReached.exception(max: max)},
          else: :ok

      # No account named: `belongs_to :user` refuses it on its own.
      _missing ->
        :ok
    end
  end

  defp count(user_id) do
    # authorize?: false — counts the target account's own rows to enforce the
    # cap; the caller learns nothing but the refusal, and the ceremony that
    # registers runs without a policy-bearing actor
    user_id
    |> Accounts.list_passkeys!(authorize?: false, query: [select: [:id]])
    |> length()
  end
end
