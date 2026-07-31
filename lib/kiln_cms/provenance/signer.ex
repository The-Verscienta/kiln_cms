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

  Signing always uses the *active* key; verification resolves the key named by
  the signature's `key_id` through `KilnCMS.Provenance.KeyRegistry`, so a
  rotation doesn't invalidate what was signed before it.
  """

  alias KilnCMS.Keys
  alias KilnCMS.Provenance.KeyRegistry

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
  Verify a base64 signature over `payload` using the key named by `key_id`.

  `nil` (the default) means the active signing key. A `key_id` naming a
  rotated-out key resolves through the retired registry, so historical
  signatures keep verifying across rotations.

  `{:ok, false}` is a signature that failed against a key we **do** hold —
  evidence of tampering. `{:error, {:unknown_key_id, _}}` is a key we don't
  hold at all, which says nothing either way; callers must not conflate them.
  """
  @spec verify(binary(), String.t(), String.t() | nil) :: {:ok, boolean()} | {:error, term()}
  def verify(payload, base64_signature, key_id \\ nil)

  def verify(payload, base64_signature, key_id) when is_binary(payload) do
    with {:ok, signature} <- decode_b64(base64_signature),
         {:ok, public_key} <- KeyRegistry.verifier(key_id) do
      {:ok, :public_key.verify(payload, :sha256, signature, public_key)}
    end
  end

  @doc """
  The public key material consumers need to verify manifests offline.

  Returns `{:ok, %{alg, key_id, public_key_pem, public_key_b64, keys}}`. The
  top-level fields describe the **active** key; `keys` lists every key that can
  still verify something we published — the active one plus each registered
  retired key — so a consumer holding a manifest signed before a rotation
  looks its `signature.key_id` up here instead of failing.
  """
  @spec public_key_info() :: {:ok, map()} | {:error, term()}
  def public_key_info do
    with {:ok, current} <- KeyRegistry.current() do
      {:ok,
       %{
         "alg" => "rsa-sha256",
         "key_id" => current.key_id,
         "public_key_pem" => current.pem,
         "public_key_b64" => current.der_b64,
         "keys" => [
           describe(current, "active") | Enum.map(KeyRegistry.retired(), &describe(&1, "retired"))
         ]
       }}
    end
  end

  @doc "Stable fingerprint of the active signing key: `sha256:<hex>` over the SPKI DER."
  @spec key_id() :: {:ok, String.t()} | {:error, term()}
  def key_id do
    with {:ok, current} <- KeyRegistry.current(), do: {:ok, current.key_id}
  end

  defp describe(entry, status) do
    %{
      "key_id" => entry.key_id,
      "alg" => "rsa-sha256",
      "status" => status,
      "public_key_pem" => entry.pem,
      "public_key_b64" => entry.der_b64
    }
  end

  defp decode_b64(str) do
    case Base.decode64(str) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_signature_encoding}
    end
  end
end
