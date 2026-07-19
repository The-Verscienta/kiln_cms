defmodule KilnCMS.Accounts.Changes.GenerateRecoveryCodes do
  @moduledoc """
  Mint a fresh 2FA recovery-code set (#331): store only the hashes, and expose
  the plaintext codes exactly once as `:recovery_codes` metadata on the returned
  record — the same show-once pattern as API-key minting. Any previous set is
  replaced (regeneration invalidates unused codes).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.RecoveryCodes

  @impl true
  def change(changeset, _opts, _context) do
    codes = RecoveryCodes.generate()

    changeset
    |> Ash.Changeset.force_change_attribute(
      :totp_recovery_hashes,
      Enum.map(codes, &RecoveryCodes.hash/1)
    )
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :recovery_codes, codes)}
    end)
  end
end
