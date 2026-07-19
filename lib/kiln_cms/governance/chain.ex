defmodule KilnCMS.Governance.Chain do
  @moduledoc """
  Tamper-evident history anchoring (#356): fold a document's PaperTrail
  version list into one canonical SHA-256 chain hash, anchor it (signed) at
  publish time, and verify it later against the live `*_versions` rows.

  The chain is per document: versions sorted ascending are folded as

      chain_n = digest(%{"prev" => chain_n-1, "item" => digest(version_n)})

  so changing, removing, or reordering **any** anchored version changes the
  final hash. Anchors are minted on publish (see
  `KilnCMS.CMS.Changes.RecordPublishedVersion`) — the moments that matter for
  compliance — and signed with the provenance signing key when configured
  (`KilnCMS.Provenance.Signer` / `KilnCMS.Keys`), so the anchor row itself
  can't be silently rewritten to match doctored history. Edits made after the
  latest anchor are not yet covered (they anchor at the next publish); the
  verifier reports them as `:unanchored_tail`, not tampering.
  """
  require Ash.Query
  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Provenance.Canonical
  alias KilnCMS.Provenance.Signer

  @genesis "kiln-audit-chain-v1"

  @typedoc "The verification outcome for one document."
  @type verdict ::
          :verified
          | :unsigned
          | :unanchored
          | {:tampered, String.t()}

  @doc "Whether anchoring is enabled (default true; kill switch in config)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :audit_anchors_enabled, true)

  @doc """
  Fold the document's versions (ascending) into the chain. Returns
  `%{chain_hash, version_count, last_version_id}`.
  """
  @spec compute(module(), Ash.UUID.t()) :: %{
          chain_hash: String.t(),
          version_count: non_neg_integer(),
          last_version_id: Ash.UUID.t() | nil
        }
  def compute(resource, source_id), do: compute(resource, source_id, :all)

  @doc """
  Like `compute/2` but folding only the first `count` versions — the prefix an
  earlier anchor covered.
  """
  @spec compute(module(), Ash.UUID.t(), :all | non_neg_integer()) :: map()
  def compute(resource, source_id, count) do
    versions = versions(resource, source_id, count)

    chain_hash =
      Enum.reduce(versions, @genesis, fn version, prev ->
        Canonical.digest(%{"prev" => prev, "item" => item_digest(version)})
      end)

    %{
      chain_hash: chain_hash,
      version_count: length(versions),
      last_version_id: versions |> List.last() |> then(&(&1 && &1.id))
    }
  end

  @doc """
  Mint an anchor for `record` after a publish. Never raises — a chain problem
  must not break the publish that triggered it. Returns `:ok` always.
  """
  @spec anchor(struct(), keyword()) :: :ok
  def anchor(record, opts \\ []) do
    if enabled?() do
      type = to_string(KilnCMS.Firing.Engine.document_type(record))
      computed = compute(record.__struct__, record.id)
      {signature, key_id} = sign(anchor_payload(type, record.id, computed))

      CMS.create_history_anchor!(
        %{
          resource_type: type,
          source_id: record.id,
          chain_hash: computed.chain_hash,
          version_count: computed.version_count,
          last_version_id: computed.last_version_id,
          published_version_id: Map.get(record, :published_version_id),
          signature: signature,
          key_id: key_id,
          actor_id: opts[:actor_id]
        },
        authorize?: false,
        tenant: record.org_id
      )

      :ok
    else
      :ok
    end
  rescue
    error ->
      Logger.error("History anchoring failed (publish unaffected): #{inspect(error)}")
      :ok
  end

  @doc """
  Verify a document's history against its **latest** anchor:

    * `:verified` — the anchored prefix recomputes to the anchored hash and
      the anchor's signature checks out.
    * `:unsigned` — prefix intact, but the anchor carries no signature (no
      signing key was configured when it was minted).
    * `:unanchored` — the document has no anchors yet (never published since
      anchoring was enabled).
    * `{:tampered, reason}` — the anchored history no longer reproduces the
      hash (altered/deleted/reordered versions) or the signature fails.
  """
  @spec verify(module(), String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: verdict()
  def verify(resource, type, source_id, org_id) do
    case latest_anchor(type, source_id, org_id) do
      nil ->
        :unanchored

      anchor ->
        computed = compute(resource, source_id, anchor.version_count)

        cond do
          computed.version_count < anchor.version_count ->
            {:tampered, "anchored versions are missing"}

          computed.chain_hash != anchor.chain_hash ->
            {:tampered, "anchored history does not reproduce the recorded chain hash"}

          is_nil(anchor.signature) ->
            :unsigned

          signature_ok?(anchor, type, source_id) ->
            :verified

          true ->
            {:tampered, "anchor signature does not verify"}
        end
    end
  end

  @doc "The latest anchor for a document, or nil."
  def latest_anchor(type, source_id, org_id) do
    CMS.list_history_anchors_for!(type, source_id, authorize?: false, tenant: org_id)
    |> List.first()
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp versions(resource, source_id, count) do
    query =
      Module.concat(resource, Version)
      |> Ash.Query.filter(version_source_id == ^source_id)
      |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)

    query = if count == :all, do: query, else: Ash.Query.limit(query, count)

    Ash.read!(query, authorize?: false)
  end

  # A version's canonical item digest: identity, action, and the tracked diff.
  # `changes` is the `:changes_only` map PaperTrail stored for the write.
  defp item_digest(version) do
    Canonical.digest(%{
      "version_id" => version.id,
      "source_id" => version.version_source_id,
      "action" => to_string(version.version_action_name),
      "at" => DateTime.to_iso8601(version.version_inserted_at),
      "changes" => version.changes
    })
  end

  defp anchor_payload(type, source_id, computed) do
    Canonical.encode(%{
      "v" => 1,
      "type" => type,
      "source_id" => source_id,
      "chain_hash" => computed.chain_hash,
      "version_count" => computed.version_count
    })
  end

  # Sign with the provenance signing key when one is configured; otherwise the
  # anchor is stored unsigned (still a useful integrity checksum).
  defp sign(payload) do
    with {:ok, signature} <- Signer.sign(payload),
         {:ok, key_id} <- Signer.key_id() do
      {signature, key_id}
    else
      _ -> {nil, nil}
    end
  end

  defp signature_ok?(anchor, type, source_id) do
    payload =
      anchor_payload(type, source_id, %{
        chain_hash: anchor.chain_hash,
        version_count: anchor.version_count
      })

    match?({:ok, true}, Signer.verify(payload, anchor.signature))
  end
end
