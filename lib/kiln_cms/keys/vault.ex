defmodule KilnCMS.Keys.Vault do
  @moduledoc """
  At-rest encryption for the database key provider: AES-256-GCM with a key
  derived from the Phoenix `secret_key_base` (`Plug.Crypto.KeyGenerator`, so
  no extra secret to manage — the trade-off is that the ciphertext is bound to
  that secret; env and file providers are immune).

  Wire format: `iv (12 bytes) <> tag (16 bytes) <> ciphertext`.

  ## Rotating `secret_key_base` (#1487)

  A read-only dual-key window. `encrypt/1` only ever writes under the
  **current** secret; `decrypt/1` tries the current secret and then each
  **previous** one (`PREVIOUS_SECRET_KEY_BASE`, read into this module's config
  by `runtime.exs`). So a deployment restarted with a new `SECRET_KEY_BASE` and
  the old one as `PREVIOUS_SECRET_KEY_BASE` keeps opening everything it stored,
  while every new write lands under the new key — and `KilnCMS.Keys.Reencrypt`
  moves the rest across so the old secret can be retired.

  The window covers this module only. The session cookie, `Phoenix.Token` and
  the AshAuthentication JWTs each derive one key from one secret and remain
  hard cutovers — see `docs/secrets-rotation.md`.

  ## Which columns hold vault ciphertext

  Every attribute of type `KilnCMS.Keys.Vault.Ciphertext`, discovered by
  `encrypted_attributes/0` rather than listed, so the re-encryption walk cannot
  miss a column somebody adds later.
  """

  @aad "KilnCMS.Keys.Vault"
  @salt "kiln keys aes-256-gcm"

  @doc "Encrypt under the current `secret_key_base`."
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext), do: encrypt(plaintext, secret_key_base())

  @doc """
  Encrypt under an explicit `secret_key_base`. The re-encryption walk's
  primitive; everything else writes through `encrypt/1`.
  """
  @spec encrypt(binary(), String.t()) :: binary()
  def encrypt(plaintext, secret_key_base)
      when is_binary(plaintext) and is_binary(secret_key_base) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key(secret_key_base),
        iv,
        plaintext,
        @aad,
        true
      )

    iv <> tag <> ciphertext
  end

  @doc """
  Decrypt with the current `secret_key_base`, falling back to each previous one
  (`previous_secret_key_bases/0`) — the read half of a rotation window.
  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def decrypt(ciphertext) do
    Enum.reduce_while(secret_key_bases(), {:error, :decrypt_failed}, fn secret, acc ->
      case decrypt(ciphertext, secret) do
        {:ok, plaintext} -> {:halt, {:ok, plaintext}}
        {:error, :decrypt_failed} -> {:cont, acc}
      end
    end)
  end

  @doc "Decrypt with exactly one explicit `secret_key_base`, no fallback."
  @spec decrypt(binary(), String.t()) :: {:ok, binary()} | {:error, :decrypt_failed}
  def decrypt(
        <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>,
        secret_key_base
      )
      when is_binary(secret_key_base) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key(secret_key_base),
           iv,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      :error -> {:error, :decrypt_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_malformed, _secret_key_base), do: {:error, :decrypt_failed}

  @doc "The `secret_key_base` every write uses — the endpoint's."
  @spec secret_key_base() :: String.t()
  def secret_key_base do
    :kiln_cms
    |> Application.fetch_env!(KilnCMSWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  @doc """
  Secrets `decrypt/1` still accepts after the current one: the rotation window.

  Blank entries and a copy of the current secret are dropped, so a
  `PREVIOUS_SECRET_KEY_BASE=` left behind in an env file is the same as unset.
  """
  @spec previous_secret_key_bases() :: [String.t()]
  def previous_secret_key_bases do
    current = secret_key_base()

    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:previous_secret_key_bases, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != "" and &1 != current))
    |> Enum.uniq()
  end

  @doc """
  Every `{resource, attribute}` stored as vault ciphertext — each attribute of
  type `KilnCMS.Keys.Vault.Ciphertext`, across every domain in `:ash_domains`.
  """
  @spec encrypted_attributes() :: [{module(), atom()}]
  def encrypted_attributes do
    :kiln_cms
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn resource ->
      for %{type: KilnCMS.Keys.Vault.Ciphertext, name: name} <-
            Ash.Resource.Info.attributes(resource),
          do: {resource, name}
    end)
    |> Enum.sort()
  end

  defp secret_key_bases, do: [secret_key_base() | previous_secret_key_bases()]

  defp key(secret_key_base) do
    Plug.Crypto.KeyGenerator.generate(secret_key_base, @salt,
      length: 32,
      cache: Plug.Crypto.Keys
    )
  end
end
