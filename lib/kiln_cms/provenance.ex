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
  canonical digest (unaltered) and the signature must verify against the
  configured public key (authentic). Returns a verdict map; both checks must
  pass for `"verified" => true`.
  """
  @spec verify(map(), map()) :: {:ok, map()} | {:error, term()}
  def verify(%{"signature" => %{"value" => signature}} = manifest, body) do
    unsigned = Map.delete(manifest, "signature")
    expected_hash = get_in(manifest, ["artifact", "hash", "value"])
    unaltered = expected_hash == Canonical.digest(body)

    with {:ok, authentic} <- Signer.verify(Canonical.encode(unsigned), signature) do
      {:ok,
       %{
         "verified" => unaltered and authentic,
         "unaltered" => unaltered,
         "authentic" => authentic,
         "claim" => manifest["claim"]
       }}
    end
  end

  def verify(_manifest, _body), do: {:error, :malformed_manifest}

  defp normalize_disclosure(value) when value in @disclosures, do: value
  defp normalize_disclosure(_), do: "human"

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
