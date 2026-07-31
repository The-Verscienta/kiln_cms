defmodule KilnCMS.Provenance.KeyRegistry do
  @moduledoc """
  Which key verifies which signature (#340 phase 2, #356).

  Everything Kiln signs — provenance manifests (#340) and tamper-evident
  history anchors (#356) — records the `key_id` of the key that made the
  signature. Rotating the signing key must not blind what was signed before
  the rotation: an audit trail that goes dark the moment you rotate is not an
  audit trail, and a consumer holding a manifest we published last year must
  still be able to check it.

  So verification resolves a key **by `key_id`** rather than assuming the
  active one: the current signing key, or any key listed in `retired_keys`.

      config :kiln_cms, KilnCMS.Provenance,
        signing_key: {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}},
        retired_keys: [
          {:file, %{"path" => "/etc/kiln/keys/2025-provenance.pub.pem"}},
          {:env, %{"var" => "KILN_PROVENANCE_RETIRED_2024"}}
        ]

  Each entry is a `KilnCMS.Keys` provider tuple (`:env` / `:file`) or a raw PEM
  binary. Registering the **public half alone** is enough — that is all
  verification needs — so a rotated-out private key can be destroyed and the
  historical trail still verifies. A private key PEM is accepted too (its
  public half is derived), but publishing the public half is the better habit.

  Entries that can't be resolved are logged and skipped: one unreadable path
  must not take down verification for the keys that *are* readable.

  Resolution is not memoized. Verification is a cold path (the governance
  dashboard, the public verify endpoint, `mix kiln.audit.verify`), and a cache
  keyed on the config would go stale exactly when an operator rotates a key's
  *contents* without editing the config that points at it.
  """
  require Logger

  alias KilnCMS.Keys

  @typedoc "A key that can verify signatures, and the fingerprint naming it."
  @type entry :: %{
          key_id: String.t(),
          public_key: tuple(),
          pem: binary(),
          der_b64: String.t()
        }

  @doc """
  The active signing key's public half, or the error that stopped it from
  resolving.
  """
  @spec current() :: {:ok, entry()} | {:error, term()}
  def current do
    with {:ok, pem} <- Keys.fetch(:provenance),
         {:ok, private_key} <- Keys.rsa_private_key(pem) do
      {:ok, describe(Keys.rsa_public_key(private_key))}
    end
  end

  @doc """
  Every configured retired key, in config order. Unresolvable entries are
  logged and omitted rather than raising.
  """
  @spec retired() :: [entry()]
  def retired do
    :kiln_cms
    |> Application.get_env(KilnCMS.Provenance, [])
    |> Keyword.get(:retired_keys, [])
    |> Enum.map(&resolve/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The public key that should verify a signature bearing `key_id`.

  `nil` means "whatever is signing today" (used when signing, and by callers
  with no recorded key_id). A `key_id` that matches neither the active key nor
  a retired one is `{:error, {:unknown_key_id, key_id}}` — deliberately
  distinct from a signature that fails against a key we *do* hold, which is
  evidence of tampering.
  """
  @spec verifier(String.t() | nil) :: {:ok, tuple()} | {:error, term()}
  def verifier(nil) do
    with {:ok, entry} <- current(), do: {:ok, entry.public_key}
  end

  def verifier(key_id) when is_binary(key_id) do
    case current() do
      {:ok, %{key_id: ^key_id, public_key: public_key}} ->
        {:ok, public_key}

      # Either the active key is a different one (a rotation) or it can't be
      # resolved at all; both fall through to the retired registry.
      _current ->
        case Enum.find(retired(), &(&1.key_id == key_id)) do
          %{public_key: public_key} -> {:ok, public_key}
          nil -> {:error, {:unknown_key_id, key_id}}
        end
    end
  end

  @doc """
  The stable fingerprint naming a key: `sha256:<hex>` over its
  SubjectPublicKeyInfo DER. Two deployments holding the same key agree on it.
  """
  @spec key_id(String.t()) :: String.t()
  def key_id(der_b64) when is_binary(der_b64) do
    digest = der_b64 |> Base.decode64!() |> then(&:crypto.hash(:sha256, &1))
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp describe(public_key) do
    der_b64 = Keys.rsa_public_key_der_b64(public_key)

    %{
      key_id: key_id(der_b64),
      public_key: public_key,
      pem: Keys.rsa_public_key_pem(public_key),
      der_b64: der_b64
    }
  end

  # A config entry is a provider tuple or the PEM itself.
  defp resolve(source) do
    with {:ok, pem} <- fetch_source(source),
         {:ok, public_key} <- Keys.rsa_public_key_from_pem(pem) do
      describe(public_key)
    else
      {:error, reason} ->
        Logger.warning(
          "Skipping unreadable :retired_keys entry #{inspect(source)}: " <>
            Keys.describe_error(reason)
        )

        nil
    end
  end

  defp fetch_source(pem) when is_binary(pem), do: {:ok, pem}

  defp fetch_source({provider, config}) do
    if provider in Keys.provider_names() do
      Keys.provider!(provider).fetch(config)
    else
      {:error, {:invalid_key_source, provider}}
    end
  end

  defp fetch_source(other), do: {:error, {:invalid_key_source, other}}
end
