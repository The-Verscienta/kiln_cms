defmodule KilnCMS.Keys.Vault.EncryptedBinary do
  @moduledoc """
  A binary attribute stored as `KilnCMS.Keys.Vault` ciphertext and held as
  plaintext in memory.

  `KilnCMS.Keys.Vault.Ciphertext` is the other vault column type: there the
  struct holds the ciphertext and the resource decrypts it when it needs the
  value. This one encrypts on the way to the database (`dump_to_native/2`)
  and decrypts on the way back (`cast_stored/2`), so code that reads the
  attribute sees the secret itself, as it did when the column was plain
  `:binary`. It exists for the TOTP seeds on `KilnCMS.Accounts.User`, which
  dozens of call sites read as plaintext.

  The stored bytes are the vault's wire format, the same as a `Ciphertext`
  column's, so `KilnCMS.Keys.Vault.encrypted_attributes/0` lists both types
  and `mix kiln.vault.reencrypt` walks both across a `SECRET_KEY_BASE`
  rotation.

  ## A value that does not decrypt loads as `nil`

  Loading a user must not fail because one secret column opens under no
  secret this node knows (a rotation done without `PREVIOUS_SECRET_KEY_BASE`,
  or a clone restored without the production `SECRET_KEY_BASE`). Raising would
  break every read of that row, the sign-in included. A `nil` second-factor
  secret is a state the app already handles: `KilnCMS.Accounts.SecondFactor`
  falls through to the recovery codes. The failure is logged, and
  `mix kiln.vault.reencrypt` reports the row as unreadable. The stored bytes
  are never rewritten by the load.
  """
  use Ash.Type

  require Logger

  alias KilnCMS.Keys.Vault

  @impl true
  def storage_type(_constraints), do: :binary

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints) when is_binary(value), do: {:ok, value}
  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(ciphertext, _constraints) when is_binary(ciphertext) do
    case Vault.decrypt(ciphertext) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, :decrypt_failed} ->
        Logger.error(
          "an encrypted column did not decrypt under the current or any previous " <>
            "SECRET_KEY_BASE and was loaded as nil; run `mix kiln.vault.reencrypt --dry-run`"
        )

        {:ok, nil}
    end
  end

  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(plaintext, _constraints) when is_binary(plaintext),
    do: {:ok, Vault.encrypt(plaintext)}

  def dump_to_native(_value, _constraints), do: :error
end
