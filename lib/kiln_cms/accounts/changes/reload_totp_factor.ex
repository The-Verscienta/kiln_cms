defmodule KilnCMS.Accounts.Changes.ReloadTotpFactor do
  @moduledoc """
  Refreshes the account's authenticator-app columns (`totp_secret`,
  `totp_confirmed_at`, `totp_pending_secret`, `totp_recovery_hashes`, and the
  `legacy_` plaintext columns of both secrets) on the
  changeset's data from the database at build time, on `User`'s
  `:disable_totp` and `:regenerate_totp_recovery_codes`
  (GHSA-5g35-j8qr-j475).

  Both check a code against the live secret (`ValidTotpCode`, which reads it
  off `changeset.data`). The struct a settings page passes in is its
  `current_user` assign, which may predate a replacement of the authenticator
  in another tab or device. Checked against it, a code from the app the owner
  just replaced (a lost or stolen phone, say) would still turn 2FA off or mint
  a recovery-code set its holder knows; and a struct from before the first
  enrollment would hold nils that `:disable_totp`'s `set_attribute(..., nil)`
  then equals, so Ash would drop those writes and leave the factor on while
  reporting it off.

  Declared first on each action, above the validations that read the
  columns. Only these columns are refreshed: `hashed_password` is the one
  `GuardAccountTakeover` compares against the row, and must stay as loaded.
  `:confirm_totp` refreshes its pending secret with `ReloadPendingTotpSecret`
  and decides "is there a live factor?" under its row lock
  (`Validations.RequireCurrentFactorForReplacement`).

  A `get_user` miss leaves the changeset untouched; the update then fails.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts

  # Both columns of each secret: the encrypted one and the plaintext one a
  # row from before may still have, which `TotpSecrets` reads first.
  @fields [
    :totp_secret,
    :legacy_totp_secret,
    :totp_confirmed_at,
    :totp_pending_secret,
    :legacy_totp_pending_secret,
    :totp_recovery_hashes
  ]

  @impl true
  def change(changeset, _opts, _context) do
    # authorize?: false — a re-read of the very row this action is already
    # authorized to update, for private columns no read policy should be
    # widened to hand out. Nothing read here leaves the changeset.
    case Accounts.get_user(changeset.data.id, authorize?: false, not_found_error?: false) do
      {:ok, %Accounts.User{} = row} ->
        %{changeset | data: struct(changeset.data, Map.take(row, @fields))}

      _missing ->
        changeset
    end
  end
end
