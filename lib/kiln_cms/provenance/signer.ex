defmodule KilnCMS.Provenance.Signer do
  @moduledoc """
  RSA signing/verification for provenance manifests (#340).

  Reuses the DKIM signing infrastructure (`KilnCMS.Keys`): the same RSA key
  handling that signs outbound mail signs content manifests. The key source is
  config (`KilnCMS.Provenance.signing_key`, resolved by `KilnCMS.Keys.fetch(:provenance)`),
  so an operator can either reuse the DKIM key (`:dkim`) or point at a dedicated
  content-signing key.

  Signatures are RSASSA-PKCS1-v1_5 over SHA-256 — deterministic, so re-deriving
  a manifest for the same immutable artifact yields the same signature.
  """

  alias KilnCMS.Keys

  @doc """
  Sign a canonical payload binary. Returns `{:ok, base64_signature}` or an
  error describing why the key couldn't be resolved.
  """
  @spec sign(binary()) :: {:ok, String.t()} | {:error, term()}
  def sign(payload) when is_binary(payload) do
    with {:ok, pem} <- Keys.fetch(:provenance),
         {:ok, private_key} <- Keys.rsa_private_key(pem) do
      signature = :public_key.sign(payload, :sha256, private_key)
      {:ok, Base.encode64(signature)}
    end
  end

  @doc """
  Verify a base64 signature over `payload` against the configured public key.
  Returns a boolean; `{:error, reason}` only when the key can't be resolved.
  """
  @spec verify(binary(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def verify(payload, base64_signature) when is_binary(payload) do
    with {:ok, pem} <- Keys.fetch(:provenance),
         {:ok, private_key} <- Keys.rsa_private_key(pem),
         {:ok, signature} <- decode_b64(base64_signature) do
      public_key = Keys.rsa_public_key(private_key)
      {:ok, :public_key.verify(payload, :sha256, signature, public_key)}
    end
  end

  @doc """
  The configured signing key's public half, for consumers to verify manifests
  offline. Returns `{:ok, %{alg, key_id, public_key_pem, public_key_b64}}` where
  `key_id` is a stable fingerprint of the SubjectPublicKeyInfo DER.
  """
  @spec public_key_info() :: {:ok, map()} | {:error, term()}
  def public_key_info do
    with {:ok, pem} <- Keys.fetch(:provenance),
         {:ok, private_key} <- Keys.rsa_private_key(pem),
         {:ok, der_b64} <- Keys.rsa_public_key_b64(pem) do
      {:ok,
       %{
         "alg" => "rsa-sha256",
         "key_id" => key_id(der_b64),
         "public_key_pem" => Keys.rsa_public_key_pem(private_key),
         "public_key_b64" => der_b64
       }}
    end
  end

  @doc "Stable fingerprint of the signing key: `sha256:<hex>` over the SPKI DER."
  @spec key_id() :: {:ok, String.t()} | {:error, term()}
  def key_id do
    with {:ok, pem} <- Keys.fetch(:provenance),
         {:ok, der_b64} <- Keys.rsa_public_key_b64(pem) do
      {:ok, key_id(der_b64)}
    end
  end

  defp key_id(der_b64) do
    der = Base.decode64!(der_b64)
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, der), case: :lower)
  end

  defp decode_b64(str) do
    case Base.decode64(str) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_signature_encoding}
    end
  end
end
