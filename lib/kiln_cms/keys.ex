defmodule KilnCMS.Keys do
  @moduledoc """
  Named-secret resolution through pluggable providers (Drupal-Key-style —
  see `KilnCMS.Keys.Provider` and `docs/direct-email-delivery-plan.md`).

  Consumers call `fetch(:dkim)` and get the secret material from wherever the
  operator pointed the key: an env var, a file, or the encrypted database
  column. The registry is deliberately a single named key until a second
  consumer needs one.

  Also home to the RSA key-handling helpers shared by the DKIM settings
  actions (generation, PEM validation, public-key derivation for the DNS TXT
  record).
  """

  alias KilnCMS.Keys.Providers

  @providers %{
    database: Providers.Database,
    env: Providers.Env,
    file: Providers.File
  }

  @provider_names Map.keys(@providers)

  @doc "Provider names in UI order: preferred production tiers first."
  def provider_names, do: [:env, :file, :database]

  @doc "The implementing module for a provider name."
  @spec provider!(atom()) :: module()
  def provider!(name) when name in @provider_names, do: Map.fetch!(@providers, name)

  @doc """
  Resolve a named key's secret material via its configured provider.

  `:dkim` — the DKIM signing key; provider choice and config live on the
  `KilnCMS.Mail.Settings` singleton. `{:error, :not_configured}` when the
  settings row doesn't exist yet.

  `:provenance` — the content-signing key for C2PA-*style* signed artifacts
  (#340). Its source is config, not the DB singleton: `config :kiln_cms,
  KilnCMS.Provenance, signing_key: {:env, %{"var" => …}} | {:file, %{"path" =>
  …}} | :dkim`. `:dkim` reuses the mail signing key (the same "this org's RSA
  key" the issue points at); the tuple forms resolve through the env/file
  providers, letting an operator point at a dedicated content-signing key.
  """
  @spec fetch(:dkim | :provenance) :: {:ok, binary()} | {:error, term()}
  def fetch(:dkim) do
    case KilnCMS.Mail.get_settings() do
      nil -> {:error, :not_configured}
      settings -> fetch_for(settings)
    end
  end

  def fetch(:provenance) do
    case Application.get_env(:kiln_cms, KilnCMS.Provenance, [])[:signing_key] do
      :dkim -> fetch(:dkim)
      {provider, config} when provider in @provider_names -> provider!(provider).fetch(config)
      nil -> {:error, :not_configured}
      other -> {:error, {:invalid_key_source, other}}
    end
  end

  @doc """
  Resolve the DKIM key material from an already-loaded settings row — lets
  callers that have just read the singleton (e.g. `KilnCMS.Mail.dkim_config/0`)
  avoid a second read and keep the selector and key from one snapshot.
  """
  @spec fetch_for(KilnCMS.Mail.Settings.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_for(settings),
    do: provider!(settings.dkim_key_provider).fetch(provider_config(settings))

  @doc "Whether `provider` accepts a generated key (vs pointing at an external source)."
  @spec writable?(atom()) :: boolean()
  def writable?(provider), do: provider!(provider).writable?()

  # The database provider's material is a column, not part of the persisted
  # provider-config map; assemble its in-memory config here.
  defp provider_config(settings) do
    case settings.dkim_key_provider do
      :database -> %{"encrypted" => settings.dkim_private_key_encrypted}
      _env_or_file -> settings.dkim_key_provider_config || %{}
    end
  end

  ## RSA / PEM helpers

  @doc """
  Generate a fresh RSA-2048 private key as PKCS#1 PEM (`BEGIN RSA PRIVATE
  KEY`) — the format gen_smtp's DKIM signer consumes via `{:pem_plain, pem}`.
  """
  @spec generate_rsa_pem() :: binary()
  def generate_rsa_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  @doc """
  Validate that `pem` parses as an RSA private key. PKCS#8 (`BEGIN PRIVATE
  KEY`) is rejected with a distinct error so the settings UI can say
  "convert with `openssl rsa`" instead of a generic parse failure.
  """
  @spec validate_private_key_pem(binary()) :: :ok | {:error, term()}
  def validate_private_key_pem(pem) when is_binary(pem) do
    case decode_rsa_private_key(pem) do
      {:ok, _key} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Derive the DKIM TXT record's `p=` value — base64 of the SubjectPublicKeyInfo
  DER (RFC 6376) — from an RSA private key PEM.
  """
  @spec rsa_public_key_b64(binary()) :: {:ok, String.t()} | {:error, term()}
  def rsa_public_key_b64(pem) do
    with {:ok, key} <- decode_rsa_private_key(pem) do
      modulus = elem(key, 2)
      public_exponent = elem(key, 3)

      {:SubjectPublicKeyInfo, der, :not_encrypted} =
        :public_key.pem_entry_encode(
          :SubjectPublicKeyInfo,
          {:RSAPublicKey, modulus, public_exponent}
        )

      {:ok, Base.encode64(der)}
    end
  end

  @doc """
  Decode an RSA private key PEM to the `:public_key` record used by
  `:public_key.sign/3` (shared by the provenance signer, #340). Same PKCS#1
  requirement as DKIM — PKCS#8 is rejected with `:pkcs8_unsupported`.
  """
  @spec rsa_private_key(binary()) :: {:ok, tuple()} | {:error, term()}
  def rsa_private_key(pem) when is_binary(pem), do: decode_rsa_private_key(pem)

  @doc """
  Derive the `:RSAPublicKey` record (`{:RSAPublicKey, modulus, exponent}`) from
  an RSA private key record — the public half used to verify signatures.
  """
  @spec rsa_public_key(tuple()) :: tuple()
  def rsa_public_key(private_key) do
    {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}
  end

  @doc "Encode an RSA private key's public half as a SubjectPublicKeyInfo PEM."
  @spec rsa_public_key_pem(tuple()) :: binary()
  def rsa_public_key_pem(private_key) do
    entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, rsa_public_key(private_key))
    :public_key.pem_encode([entry])
  end

  @doc """
  A fresh DKIM selector, e.g. `kiln2026073f9ea1b2` — month-stamped for humans,
  random-suffixed so every rotation gets a distinct DNS name (the old TXT
  record can stay up while mail signed with the old key is in transit).
  """
  @spec new_selector() :: String.t()
  def new_selector do
    stamp = Calendar.strftime(Date.utc_today(), "%Y%m")
    suffix = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "kiln#{stamp}#{suffix}"
  end

  @doc "Operator-facing description of a provider/PEM error."
  @spec describe_error(term()) :: String.t()
  def describe_error({:env_var_unset, var}), do: "environment variable #{var} is not set"
  def describe_error(:no_path_configured), do: "no file path configured"

  def describe_error({:unreadable, path, posix}),
    do: "cannot read #{path} (#{posix})"

  def describe_error(:pkcs8_unsupported),
    do:
      "PKCS#8 (\"BEGIN PRIVATE KEY\") is not supported — convert with: " <>
        "openssl rsa -in key.pem -traditional -out key-pkcs1.pem"

  def describe_error(:invalid_pem), do: "not a valid PEM-encoded private key"
  def describe_error(:not_an_rsa_private_key), do: "not an RSA private key"
  def describe_error(:no_key_generated), do: "no key has been generated yet"

  def describe_error(:decrypt_failed),
    do:
      "stored key cannot be decrypted (was SECRET_KEY_BASE rotated?) — regenerate or switch provider"

  def describe_error(:not_configured), do: "mail settings have not been initialised"
  def describe_error(other), do: "key source error: #{inspect(other)}"

  defp decode_rsa_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:RSAPrivateKey, _der, :not_encrypted} = entry | _rest] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      [{:PrivateKeyInfo, _der, _} | _rest] ->
        {:error, :pkcs8_unsupported}

      [] ->
        {:error, :invalid_pem}

      _other ->
        {:error, :not_an_rsa_private_key}
    end
  rescue
    # pem_decode/pem_entry_decode throw on garbage that vaguely resembles PEM.
    _e -> {:error, :invalid_pem}
  end
end
