defmodule KilnCMS.Keys.Vault do
  @moduledoc """
  At-rest encryption for the database key provider: AES-256-GCM with a key
  derived from the Phoenix `secret_key_base` (`Plug.Crypto.KeyGenerator`, so
  no extra secret to manage — the trade-off, documented in the mail settings
  UI, is that rotating `secret_key_base` orphans database-stored keys; env and
  file providers are immune).

  Wire format: `iv (12 bytes) <> tag (16 bytes) <> ciphertext`.
  """

  @aad "KilnCMS.Keys.Vault"
  @salt "kiln keys aes-256-gcm"

  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def decrypt(<<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :decrypt_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_malformed), do: {:error, :decrypt_failed}

  defp key do
    secret_key_base =
      :kiln_cms
      |> Application.fetch_env!(KilnCMSWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    Plug.Crypto.KeyGenerator.generate(secret_key_base, @salt,
      length: 32,
      cache: Plug.Crypto.Keys
    )
  end
end
