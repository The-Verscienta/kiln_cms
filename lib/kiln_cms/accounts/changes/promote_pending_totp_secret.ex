defmodule KilnCMS.Accounts.Changes.PromotePendingTotpSecret do
  @moduledoc """
  Copies `totp_pending_secret` into `totp_secret` and clears the pending slot
  (#754). Runs on `:confirm_totp`, after `ValidTotpCode` has already proven the
  caller holds the pending secret — this only ever promotes a secret that has
  just been demonstrated, never a bare `setup_totp` write.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.TotpSecrets

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:totp_secret, TotpSecrets.pending(changeset.data))
    |> Ash.Changeset.force_change_attribute(:totp_pending_secret, nil)
    # Both written encrypted now: a plaintext copy of
    # either, left from before, would outlive the promotion and win the read.
    |> Ash.Changeset.force_change_attribute(:legacy_totp_secret, nil)
    |> Ash.Changeset.force_change_attribute(:legacy_totp_pending_secret, nil)
  end
end
