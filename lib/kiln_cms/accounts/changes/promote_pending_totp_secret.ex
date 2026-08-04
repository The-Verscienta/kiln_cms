defmodule KilnCMS.Accounts.Changes.PromotePendingTotpSecret do
  @moduledoc """
  Copies `totp_pending_secret` into `totp_secret` and clears the pending slot
  (#754). Runs on `:confirm_totp`, after `ValidTotpCode` has already proven the
  caller holds the pending secret — this only ever promotes a secret that has
  just been demonstrated, never a bare `setup_totp` write.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:totp_secret, changeset.data.totp_pending_secret)
    |> Ash.Changeset.force_change_attribute(:totp_pending_secret, nil)
  end
end
