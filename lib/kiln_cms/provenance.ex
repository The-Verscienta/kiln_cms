defmodule KilnCMS.Provenance do
  @moduledoc """
  Cryptographically signed, provenance-verified content (#340).

  Every fired `:web`/`:json`/`:json_ld` artifact can carry a **detached,
  signed manifest** — C2PA-*style* (adapted from C2PA's media-asset model to
  HTML/JSON *content* artifacts): a signed hash binding the exact bytes to a
  claim (signer identity, AI-generation disclosure, origin, version, timestamp).
  A consumer independently verifies "this exact content came from us, unaltered,
  at version N, disclosed as human/AI" against a published public key.

  Manifests are derived *statelessly* from the immutable artifact (no extra
  table, the firing hot path is untouched): re-deriving a manifest for the same
  artifact yields the same bytes, because the artifact is immutable per publish
  and the signature is deterministic. A later phase may persist manifests at
  fire-time to pin the signer/key as-of-publish (see docs/provenance.md).

  **On by default since 1.7** (#1929). `/setup` generates a signing key
  (`KilnCMS.Provenance.Settings`) unless one is mounted, and every fire stores
  the artifact's signed manifest beside it (`sign_fired/4`), so
  `GET /api/provenance/verify/:type/:slug` can tell `verified` from `tampered`.
  An install with no key keeps working: its artifacts are `unsigned`, never
  refused, and the console says which variable to set. `enabled: false`
  (`KILN_PROVENANCE_ENABLED=false`) still turns all of it off and 404s the
  endpoints.
  """

  alias KilnCMS.Firing.Engine
  alias KilnCMS.Provenance.Canonical
  alias KilnCMS.Provenance.Signer

  @manifest_version "1.0"
  @disclosures ~w(human ai_assisted ai_generated)

  @doc "Whether signed provenance is enabled (`config … KilnCMS.Provenance, enabled:`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc """
  The PEM of the key `/setup` generated, decrypted, or `{:error,
  :no_key_generated}`. Read as the system: signing has no actor of its own.

  Cached once found. The row has no update action, so the key it holds never
  changes; a miss is not cached, so a key generated later is picked up on the
  next fire.
  """
  @spec stored_key() :: {:ok, binary()} | {:error, term()}
  def stored_key do
    case :persistent_term.get({__MODULE__, :stored_key}, nil) do
      nil -> read_stored_key()
      pem -> {:ok, pem}
    end
  end

  defp read_stored_key do
    # authorize?: false — the signer reads key material as the system, the
    # way `KilnCMS.Billing.get_settings/0` reads its credentials; the row's
    # policy is for people (platform admins).
    with {:ok, %{private_key_encrypted: encrypted}} <-
           KilnCMS.Firing.get_provenance_settings(authorize?: false),
         {:ok, pem} <- KilnCMS.Keys.Vault.decrypt(encrypted) do
      :persistent_term.put({__MODULE__, :stored_key}, pem)
      {:ok, pem}
    else
      {:error, :decrypt_failed} = error -> error
      _none -> {:error, :no_key_generated}
    end
  rescue
    # No table yet (a release whose migration has not run): no key.
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :no_key_generated}
  end

  @doc false
  # Tests that generate and drop keys.
  def forget_stored_key, do: :persistent_term.erase({__MODULE__, :stored_key})

  @doc """
  Whether a signing key resolves right now: a mounted one, or the generated one.
  """
  @spec key_available?() :: boolean()
  def key_available?, do: match?({:ok, _}, KilnCMS.Provenance.KeyRegistry.current())

  @doc """
  Generate and store the instance's signing key, as `actor` (a platform
  admin), unless a key already resolves. `/setup` calls it for the admin it
  has just created. `{:ok, :exists}` when there was nothing to do.
  """
  @spec ensure_key(term()) :: {:ok, :exists | :generated} | {:error, term()}
  def ensure_key(actor) do
    if enabled?() and not key_available?() do
      case KilnCMS.Firing.generate_provenance_key(actor: actor) do
        {:ok, _settings} -> {:ok, :generated}
        {:error, error} -> {:error, error}
      end
    else
      {:ok, :exists}
    end
  end

  @doc """
  The manifest to store with an artifact as it is fired, or `nil` — provenance
  off, or no key (the artifact is then served `unsigned`). Never raises: a
  signing failure must not fail the fire.

  `body` is hashed as it will read back from the database (a JSON round trip),
  which is what every later verification hashes.
  """
  @spec sign_fired(struct(), atom(), map(), keyword()) :: map() | nil
  def sign_fired(document, surface, body, opts) do
    if enabled?() do
      artifact = %{
        surface: surface,
        body: body |> Jason.encode!() |> Jason.decode!(),
        fired_at: Keyword.fetch!(opts, :fired_at),
        source_version_id: Keyword.get(opts, :source_version_id)
      }

      case manifest_for(artifact, document) do
        {:ok, manifest} -> manifest
        {:error, _no_key} -> nil
      end
    end
  rescue
    error ->
      require Logger
      Logger.warning("Provenance: could not sign a fired artifact: #{Exception.message(error)}")
      nil
  end

  @doc """
  The verdict on a fired artifact against the manifest stored with it:

    * `:verified` — the body hashes to the manifest's hash and the signature
      verifies against the key it names;
    * `:tampered` — either check fails against a key we hold;
    * `:unsigned` — no manifest was stored (fired before 1.7, or with no key);
    * `:unverifiable` — signed with a key this instance no longer holds
      (`{:unknown_key_id, _}`). Not holding a key says nothing about the
      content, so it is never reported as tampering.
  """
  @spec verdict(%{manifest: map() | nil, body: map()}) ::
          {:verified | :tampered | :unsigned | :unverifiable, map() | nil}
  def verdict(%{manifest: nil}), do: {:unsigned, nil}

  def verdict(%{manifest: manifest, body: body}) do
    case verify(manifest, body) do
      {:ok, %{"verified" => true} = result} -> {:verified, result}
      {:ok, result} -> {:tampered, result}
      {:error, {:unknown_key_id, _}} -> {:unverifiable, nil}
      {:error, :malformed_manifest} -> {:tampered, nil}
      {:error, _other} -> {:unverifiable, nil}
    end
  end

  @doc """
  Parse a comma-separated list of PEM **file paths**, for
  `KILN_PROVENANCE_RETIRED_KEY_FILES` (#608). Returns the paths, which
  `KilnCMS.Provenance.KeyRegistry` reads as `:retired_key_files`.

  Retired keys could only be listed in `config/config.exs`, which a released
  image cannot edit — so an operator who rotated and followed the docs' advice
  to destroy the outgoing private half could permanently lose the ability to
  verify everything signed before the rotation. This is the runtime route.

  Paths only, deliberately: a key is a multi-line PEM and `.env` parsers do not
  carry embedded newlines, which is the same reason the signing key itself is
  better mounted than exported. Blank entries are dropped, so a trailing comma
  is harmless. Unreadable paths are logged and skipped at *use* time by
  `KeyRegistry` — one bad path must not blind the rest.

  Plain paths rather than the `{:file, %{"path" => …}}` provider tuples they
  become, because a list of those tuples *is* a keyword list, and `Config`
  deep-merges keyword lists: setting the env var would then `Keyword.merge`
  into a `:retired_keys` configured in source and silently delete every
  `:file` entry already there. A list of binaries is not a keyword list, so it
  replaces `:retired_key_files` cleanly, and `KeyRegistry` unions that with
  `:retired_keys` — so the env var cannot make a source-registered key stop
  verifying. That holds because `:retired_key_files` has exactly one writer;
  source config belongs in `:retired_keys`.
  """
  @spec parse_key_files(String.t()) :: [String.t()]
  def parse_key_files(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "The human-readable signer identity embedded in every manifest."
  @spec signer() :: String.t()
  def signer do
    config()[:signer] || Application.get_env(:kiln_cms, :site_name, "KilnCMS")
  end

  @doc "The origin URL recorded in the claim."
  @spec origin() :: String.t()
  def origin do
    config()[:origin] || Application.get_env(:kiln_cms, :public_base_url, "http://localhost:4000")
  end

  @doc "The default AI-disclosure when a document doesn't declare its own."
  @spec default_disclosure() :: String.t()
  def default_disclosure do
    (config()[:ai_disclosure] || :human) |> to_string() |> normalize_disclosure()
  end

  @doc "Valid AI-disclosure values: human | ai_assisted | ai_generated."
  @spec disclosures() :: [String.t()]
  def disclosures, do: @disclosures

  @doc """
  The AI-generation disclosure for a document: its own `custom_fields`
  `"ai_disclosure"` when set to a valid value, otherwise the configured default.
  This lets an editor declare disclosure per-document with no schema change.
  """
  @spec disclosure_for(struct()) :: String.t()
  def disclosure_for(document) do
    # A private `ai_disclosure` field (#2044) declares nothing: the manifest
    # is public, so it falls to the default like an absent one.
    document
    |> Map.get(:custom_fields)
    |> KilnCMS.CMS.PrivateFields.drop_for(document)
    |> case do
      %{"ai_disclosure" => value} -> normalize_disclosure(to_string(value))
      _ -> default_disclosure()
    end
  end

  @doc """
  Build a signed manifest for `artifact` (a `PublishedArtifact` row) belonging
  to `document`. Returns `{:ok, manifest_map}` or `{:error, reason}` when the
  signing key can't be resolved.
  """
  @spec manifest_for(struct(), struct()) :: {:ok, map()} | {:error, term()}
  def manifest_for(artifact, document) do
    surface = to_string(artifact.surface)
    fired_at = DateTime.to_iso8601(artifact.fired_at)

    unsigned = %{
      "kiln_provenance" => @manifest_version,
      "artifact" => %{
        "type" => Engine.public_type(document),
        "slug" => Map.get(document, :slug),
        "surface" => surface,
        "hash" => %{
          "alg" => "sha-256",
          "canonicalization" => Canonical.id(),
          "value" => Canonical.digest(artifact.body)
        }
      },
      "claim" => %{
        "signer" => signer(),
        "origin" => origin(),
        "version" => artifact.source_version_id,
        "ai_disclosure" => disclosure_for(document),
        # The artifact is immutable per publish, so "signed as of firing" is the
        # honest timestamp — not the wall-clock of this (re-)derivation.
        "fired_at" => fired_at,
        "signed_at" => fired_at
      }
    }

    with {:ok, key_id} <- Signer.key_id(),
         {:ok, signature} <- Signer.sign(Canonical.encode(unsigned)) do
      manifest =
        Map.put(unsigned, "signature", %{
          "alg" => "rsa-sha256",
          "key_id" => key_id,
          "value" => signature
        })

      {:ok, manifest}
    end
  end

  @doc """
  Verify a manifest against an artifact `body`: the hash must match the body's
  canonical digest (unaltered) and the signature must verify (authentic).
  Returns a verdict map; both checks must pass for `"verified" => true`.

  The signature is checked against the key the manifest **names**
  (`signature.key_id`), resolved through `KilnCMS.Provenance.KeyRegistry` — so
  a manifest published before a key rotation still verifies, provided the
  retired key's public half is registered. An unregistered `key_id` is an
  error, not a `false` verdict: we cannot check it, which is not the same as
  it being wrong.
  """
  @spec verify(map(), map()) :: {:ok, map()} | {:error, term()}
  def verify(%{"signature" => %{"value" => signature} = signed} = manifest, body) do
    unsigned = Map.delete(manifest, "signature")
    expected_hash = get_in(manifest, ["artifact", "hash", "value"])
    unaltered = expected_hash == Canonical.digest(body)

    with {:ok, authentic} <-
           Signer.verify(Canonical.encode(unsigned), signature, signed["key_id"]) do
      {:ok,
       %{
         "verified" => unaltered and authentic,
         "unaltered" => unaltered,
         "authentic" => authentic,
         "key_id" => signed["key_id"],
         "claim" => manifest["claim"]
       }}
    end
  end

  def verify(_manifest, _body), do: {:error, :malformed_manifest}

  @doc """
  The number 1.7 has to produce (#1929): the share of published artifacts
  carrying a verifiable manifest.

  Counted over the `:json` surface, one row per published document (every
  surface is fired and signed together). `verifiable` is a stored manifest
  whose `key_id` this instance can resolve — the active key or a registered
  retired one; a manifest naming a key we no longer hold is `signed` but not
  `verifiable`. `org_id` scopes it to one site; `nil` counts the instance.
  """
  @spec coverage(Ecto.UUID.t() | nil) :: %{
          total: non_neg_integer(),
          signed: non_neg_integer(),
          verifiable: non_neg_integer(),
          share: float()
        }
  # The only interpolation is a constant clause; the org id is a bound
  # parameter.
  # sobelow_skip ["SQL.Query"]
  def coverage(org_id \\ nil) do
    {scope, params} =
      if org_id, do: {"AND org_id = $1", [Ecto.UUID.dump!(org_id)]}, else: {"", []}

    %{rows: rows} =
      KilnCMS.Repo.query!(
        """
        SELECT manifest -> 'signature' ->> 'key_id', count(*)
        FROM published_artifacts
        WHERE surface = 'json' #{scope}
        GROUP BY 1
        """,
        params
      )

    known? = &match?({:ok, _}, KilnCMS.Provenance.KeyRegistry.verifier(&1))

    {total, signed, verifiable} =
      KilnCMS.Provenance.KeyRegistry.with_cache(fn ->
        Enum.reduce(rows, {0, 0, 0}, fn
          [nil, n], {t, s, v} -> {t + n, s, v}
          [key_id, n], {t, s, v} -> {t + n, s + n, if(known?.(key_id), do: v + n, else: v)}
        end)
      end)

    %{
      total: total,
      signed: signed,
      verifiable: verifiable,
      share: if(total == 0, do: 0.0, else: verifiable / total)
    }
  end

  @doc """
  `[:kiln_cms, :provenance, :coverage]` with `coverage/1`'s numbers for the
  instance, for the telemetry poller (`KilnCMSWeb.Telemetry`). Emits nothing
  when the count cannot be read (no database yet, or a test's sandbox).
  """
  @spec emit_coverage() :: :ok
  def emit_coverage do
    if enabled?() do
      :telemetry.execute([:kiln_cms, :provenance, :coverage], coverage(), %{})
    end

    :ok
  rescue
    _unavailable -> :ok
  end

  defp normalize_disclosure(value) when value in @disclosures, do: value
  defp normalize_disclosure(_), do: "human"

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
