defmodule KilnCMS.Accounts.Changes.ConsumeRecoveryCode do
  @moduledoc """
  Validate-and-burn a 2FA recovery code (#331): the `:code` argument must match
  one of the stored hashes, and the matched hash is removed in the same update —
  so a code can never sign in twice. An unmatched code fails the action.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.RecoveryCodes

  @impl true
  def change(changeset, _opts, _context) do
    code = Ash.Changeset.get_argument(changeset, :code)

    case RecoveryCodes.consume(changeset.data.totp_recovery_hashes || [], code) do
      {:ok, remaining} ->
        Ash.Changeset.force_change_attribute(changeset, :totp_recovery_hashes, remaining)

      :error ->
        Ash.Changeset.add_error(changeset,
          field: :code,
          message: "is not a valid recovery code"
        )
    end
  end
end
