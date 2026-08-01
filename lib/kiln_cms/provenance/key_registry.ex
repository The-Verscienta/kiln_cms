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

  Each `:retired_keys` entry is a `KilnCMS.Keys` provider tuple (`:env` /
  `:file`) or a raw PEM binary. On a released image, where editing the config
  above means a rebuild, set `KILN_PROVENANCE_RETIRED_KEY_FILES` instead — a
  comma-separated list of PEM paths, parsed by
  `KilnCMS.Provenance.parse_key_files/1` into `:retired_key_files`, which
  `retired/0` unions with `:retired_keys`.

  Registering the **public half alone** is enough — that is all verification
  needs — so a rotated-out private key can be destroyed, but only *after* the
  public half is registered: until then those signatures resolve to
  `{:error, {:unknown_key_id, …}}`, and a destroyed private key cannot be asked
  for its public one. A private key PEM is accepted too (its public half is
  derived), but publishing the public half is the better habit.

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
  Every configured retired key, in config order: `:retired_keys` first, then
  the paths in `:retired_key_files` (what `KILN_PROVENANCE_RETIRED_KEY_FILES`
  sets). The two are a **union** — the env route adds verification keys and
  can never remove one configured in source, because a rotation losing a key it
  used to hold is the failure this whole registry exists to prevent.

  Unresolvable entries are logged and omitted rather than raising.
  """
  @spec retired() :: [entry()]
  def retired do
    config = Application.get_env(:kiln_cms, KilnCMS.Provenance, [])

    tuples = Enum.map(Keyword.get(config, :retired_keys, []), &{:retired_keys, &1})

    files =
      config
      |> Keyword.get(:retired_key_files, [])
      |> Enum.map(&{:retired_key_files, {:file, %{"path" => &1}}})

    (tuples ++ files)
    |> Enum.map(fn {from, source} -> resolve(from, source) end)
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

  # A config entry is a provider tuple or the PEM itself. `from` names the
  # config key it came from, so the warning points at the thing to go fix —
  # a path from KILN_PROVENANCE_RETIRED_KEY_FILES is not in :retired_keys.
  defp resolve(from, source) do
    with {:ok, pem} <- fetch_source(source),
         {:ok, public_key} <- Keys.rsa_public_key_from_pem(pem) do
      describe(public_key)
    else
      {:error, reason} ->
        Logger.warning(
          "Skipping unreadable #{inspect(from)} entry #{inspect(source)}: " <>
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
