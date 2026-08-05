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

  Source config belongs in `:retired_keys`; `:retired_key_files` is the runtime
  channel and `config/runtime.exs` is its only writer, which replaces it
  wholesale. Setting it in source too would be silently overwritten the first
  time the env var is used — the union holds *between* the two keys, not within
  either one.

  Registering the **public half alone** is enough — that is all verification
  needs — so a rotated-out private key can be destroyed, but only *after* the
  public half is registered: until then those signatures resolve to
  `{:error, {:unknown_key_id, …}}`, and a destroyed private key cannot be asked
  for its public one. A private key PEM is accepted too (its public half is
  derived), but publishing the public half is the better habit.

  Entries that can't be resolved are logged and skipped: one unreadable path
  must not take down verification for the keys that *are* readable.

  ## Resolution is not cached across time, only within a scope

  A resolution reads and PEM-decodes every configured key. A standing cache
  keyed on the config would go stale exactly when an operator rotates a key's
  *contents* at a path the config already points at — the one moment the audit
  trail must not silently keep trusting the old key. So there is no such cache.

  What there is, is `with_cache/1`: a caller that resolves the registry many
  times in a tight loop over one consistent view of the config wraps that loop,
  and `current/0` / `retired/0` resolve **once** inside it, reusing the result
  for the rest of the block. The cache lives in the process dictionary and dies
  with the block (`try/after`), so it cannot outlast the work it was scoped to —
  a fresh `mix kiln.audit.verify` run, or a single governance request, each
  re-reads from disk. Content rotated between runs is picked up on the next one,
  no restart needed; content rotated *mid-run* is not, which is the correct
  granularity for a sweep that is meant to judge one snapshot.

  Without `with_cache/1`, resolution is uncached exactly as before — every
  `verify/2` re-reads, which is what keeps a long-lived server fresh. The two
  loops where the per-document cost and the per-document warning actually bit
  (#643) opt in; nothing else changes.
  """
  require Logger

  alias KilnCMS.Keys

  @cache_key __MODULE__.Cache

  @doc """
  Resolve `current/0` and `retired/0` at most once each for the duration of
  `fun`, reusing the result within it (#643).

  For a batch that verifies many signatures against one config snapshot — the
  `mix kiln.audit.verify` sweep, a governance trail render — this collapses N
  file reads and PEM parses (and N repeats of any unreadable-entry warning) to
  one. Outside such a batch, leave resolution uncached so a running server
  always reflects the current key material.

  Nesting reuses the outer scope's cache rather than starting a new one, so it
  is safe to wrap a batch whose callees also wrap.
  """
  @spec with_cache((-> result)) :: result when result: var
  def with_cache(fun) when is_function(fun, 0) do
    if Process.get(@cache_key) do
      # Already inside a scope — do not start a nested one, or the inner
      # `after` would tear down the outer scope's cache early.
      fun.()
    else
      Process.put(@cache_key, %{})

      try do
        fun.()
      after
        Process.delete(@cache_key)
      end
    end
  end

  # Memoize `key`'s resolution for the lifetime of the enclosing `with_cache/1`
  # block. With no such block the value is computed every call, unchanged from
  # before #643. `store?` decides whether a computed value is worth caching —
  # `current/0` caches only successes, so a transient read glitch on the first
  # document of a sweep is retried rather than relabelling every current-key
  # signature `:unverifiable` for the whole run.
  #
  # `compute.()` must NOT itself resolve the sibling cached function: this is a
  # plain read-modify-write against the map snapshot taken before the compute,
  # so a nested resolution's write would be clobbered here. Today neither
  # `current/0` nor `retired/0` calls the other; keep it that way.
  defp cached(key, compute, store? \\ fn _ -> true end) do
    case Process.get(@cache_key) do
      nil ->
        compute.()

      %{^key => value} ->
        value

      cache ->
        value = compute.()
        if store?.(value), do: Process.put(@cache_key, Map.put(cache, key, value))
        value
    end
  end

  defp ok?({:ok, _}), do: true
  defp ok?(_), do: false

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
    cached(
      :current,
      fn ->
        with {:ok, pem} <- Keys.fetch(:provenance),
             {:ok, private_key} <- Keys.rsa_private_key(pem) do
          {:ok, describe(Keys.rsa_public_key(private_key))}
        end
      end,
      &ok?/1
    )
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
    cached(:retired, fn ->
      config = Application.get_env(:kiln_cms, KilnCMS.Provenance, [])

      from(config, :retired_keys)
      |> Kernel.++(from(config, :retired_key_files))
      |> Enum.map(fn {from, source} -> resolve(from, source) end)
      |> Enum.reject(&is_nil/1)
      # The same key can legitimately be registered both ways for a deploy or two
      # while an operator moves a retired key out of source config and into the
      # env var. Publishing it twice on /api/provenance/public-key would just tell
      # consumers we hold a key we don't.
      |> Enum.uniq_by(& &1.key_id)
    end)
  end

  defp from(config, key), do: Enum.map(Keyword.get(config, key, []), &{key, &1})

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

  # A `:retired_key_files` entry is a bare path. Widening it to the provider
  # tuple here rather than at the call site keeps anything that ISN'T a path
  # flowing through `fetch_source/1`'s catch-all — wrapping unconditionally
  # made a non-binary entry raise out of `retired/0` (File.read on a tuple),
  # taking down verification for every key, which is the opposite of the
  # log-and-skip contract above.
  defp resolve(:retired_key_files, path) when is_binary(path),
    do: resolve(:retired_key_files, {:file, %{"path" => path}})

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
