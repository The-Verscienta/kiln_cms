defmodule KilnCMS.Accounts.TotpSecrets do
  @moduledoc """
  The one place that reads a user's TOTP secrets.

  Each secret has two columns during the expand/contract window:

    * the encrypted one (`totp_secret_encrypted`,
      `totp_pending_secret_encrypted`), which the `User` attributes
      `totp_secret` and `totp_pending_secret` map to and hold decrypted
      (`KilnCMS.Keys.Vault.EncryptedBinary`);
    * the plaintext one from before (`totp_secret`, `totp_pending_secret`),
      mapped to `legacy_totp_secret` and `legacy_totp_pending_secret`.

  ## Why the plaintext column wins when both are set

  Every write this release makes to a secret also clears its plaintext
  column, so a plaintext value is never older than this release's ciphertext:
  it is either a row `KilnCMS.Accounts.TotpSecretBackfill` has not reached
  yet, or one a node of the previous release wrote during a rolling deploy or
  after a rollback. The previous release knows only the plaintext column, so
  when it re-enrols an account the encrypted column still holds the replaced
  secret. Reading the ciphertext first would check codes against that one.

  Clearing: a node of the previous release that disables the factor clears
  only the plaintext column. The read then falls back to the ciphertext, but
  `totp_confirmed_at` is cleared with it, so the factor is off; the backfill
  drops such an orphaned secret.
  """

  alias KilnCMS.Accounts.User
  alias KilnCMS.Keys.Vault

  @doc "The account's live TOTP secret, or `nil`."
  @spec live(User.t()) :: binary() | nil
  def live(%User{legacy_totp_secret: legacy}) when is_binary(legacy), do: legacy
  def live(%User{totp_secret: secret}), do: secret

  @doc "The secret staged by `:setup_totp` and not yet confirmed, or `nil`."
  @spec pending(User.t()) :: binary() | nil
  def pending(%User{legacy_totp_pending_secret: legacy}) when is_binary(legacy), do: legacy
  def pending(%User{totp_pending_secret: secret}), do: secret

  @doc """
  The same rule over raw column values, for a read that bypasses Ash (a
  `SELECT … FOR UPDATE` in `KilnCMS.Accounts.AccountLock`): the plaintext,
  else the ciphertext decrypted, else `nil`.
  """
  @spec from_columns(binary() | nil, binary() | nil) :: binary() | nil
  def from_columns(legacy, _encrypted) when is_binary(legacy), do: legacy

  def from_columns(nil, encrypted) when is_binary(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, plaintext} -> plaintext
      {:error, :decrypt_failed} -> nil
    end
  end

  def from_columns(nil, nil), do: nil
end
