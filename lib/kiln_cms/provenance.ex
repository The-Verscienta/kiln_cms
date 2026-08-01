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

  **Off by default.** With `enabled: false` no manifest is produced and the
  verification endpoints 404 — the lean install pays nothing.
  """

  alias KilnCMS.Firing.Engine
  alias KilnCMS.Provenance.Canonical
  alias KilnCMS.Provenance.Signer

  @manifest_version "1.0"
  @disclosures ~w(human ai_assisted ai_generated)

  @doc "Whether signed provenance is enabled (`config … KilnCMS.Provenance, enabled:`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false)

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
    document
    |> Map.get(:custom_fields)
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

  defp normalize_disclosure(value) when value in @disclosures, do: value
  defp normalize_disclosure(_), do: "human"

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
