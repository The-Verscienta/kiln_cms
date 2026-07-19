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
  governance trail surfaces that window via `unanchored_tail/2`.

  Anchoring recomputes the full chain at each publish — O(version count).
  Fine for editorial documents (tens to hundreds of versions); an incremental
  fold seeded from the previous anchor is the follow-on if very hot documents
  ever make publishes noticeably slower.
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
          | :unverifiable
          | :unanchored
          | {:tampered, String.t()}

  @doc "Whether anchoring is enabled (default true; kill switch in config)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :audit_anchors_enabled, true)

  @doc """
  Fold the document's versions (ascending) into the chain — all of them, or
  only the first `count` (the prefix an earlier anchor covered). Returns
  `%{chain_hash, version_count, last_version_id}`.
  """
  @spec compute(module(), Ash.UUID.t(), Ash.UUID.t(), :all | non_neg_integer()) :: %{
          chain_hash: String.t(),
          version_count: non_neg_integer(),
          last_version_id: Ash.UUID.t() | nil
        }
  def compute(resource, source_id, org_id, count \\ :all) do
    resource |> versions(source_id, count, org_id) |> fold()
  end

  @doc "Fold an already-loaded ascending version list into the chain shape."
  @spec fold([struct()]) :: map()
  def fold(versions) do
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
      computed = compute(record.__struct__, record.id, record.org_id)
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
      the anchor's signature checks out against the current signing key.
    * `:unsigned` — prefix intact, but the anchor carries no signature (no
      signing key was configured when it was minted).
    * `:unverifiable` — prefix intact and the anchor IS signed, but the
      signature was made under a different key than the one currently
      configured (`key_id` mismatch — e.g. after a key rotation) or no key is
      configured now, so it cannot be checked. Deliberately distinct from
      tampering: a rotation must not turn the whole corpus red.
    * `:unanchored` — the document has no anchors yet (never published since
      anchoring was enabled).
    * `{:tampered, reason}` — the anchored history no longer reproduces the
      hash (altered/deleted/reordered versions), or a signature made under
      the CURRENT key fails.

  Only the anchored prefix is covered — edits since the last publish anchor
  at the next publish. Callers that need to show that window use
  `unanchored_tail/2` (the governance trail displays it).
  """
  @spec verify(module(), String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: verdict()
  def verify(resource, type, source_id, org_id) do
    case latest_anchor(type, source_id, org_id) do
      nil ->
        :unanchored

      anchor ->
        verdict(
          anchor,
          compute(resource, source_id, org_id, anchor.version_count),
          type,
          source_id
        )
    end
  end

  @doc """
  Like `verify/4` but folding over an already-loaded ASCENDING version list
  (the governance trail reads versions once and shares them).
  """
  @spec verify_loaded([struct()], String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: verdict()
  def verify_loaded(versions, type, source_id, org_id) do
    case latest_anchor(type, source_id, org_id) do
      nil -> :unanchored
      anchor -> verdict(anchor, fold(Enum.take(versions, anchor.version_count)), type, source_id)
    end
  end

  @doc "How many versions follow the latest anchor (0 when unanchored/none)."
  @spec unanchored_tail([struct()], struct() | nil) :: non_neg_integer()
  def unanchored_tail(_versions, nil), do: 0
  def unanchored_tail(versions, anchor), do: max(length(versions) - anchor.version_count, 0)

  defp verdict(anchor, computed, type, source_id) do
    cond do
      computed.version_count < anchor.version_count ->
        {:tampered, "anchored versions are missing"}

      computed.chain_hash != anchor.chain_hash ->
        {:tampered, "anchored history does not reproduce the recorded chain hash"}

      is_nil(anchor.signature) ->
        :unsigned

      not current_key?(anchor) ->
        :unverifiable

      signature_ok?(anchor, type, source_id) ->
        :verified

      true ->
        {:tampered, "anchor signature does not verify"}
    end
  end

  # The anchor was signed by the key currently configured; only then is a
  # failing signature evidence of tampering rather than rotation.
  defp current_key?(anchor) do
    match?({:ok, key_id} when key_id == anchor.key_id, Signer.key_id())
  end

  @doc """
  The latest anchor for a document, or nil. Honors the kill switch (and so
  keeps the whole read path quiet — no `history_anchors` query — when the
  feature is off or its migration hasn't run yet).
  """
  def latest_anchor(type, source_id, org_id) do
    if enabled?() do
      # Newest first with an id tiebreak (same-microsecond anchors), one row only.
      CMS.list_history_anchors_for!(type, source_id,
        authorize?: false,
        tenant: org_id,
        query: [sort: [inserted_at: :desc, id: :desc], limit: 1]
      )
      |> List.first()
    else
      nil
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Version twins are tenant-strict (#419) — the chain reads under the org.
  defp versions(resource, source_id, count, org_id) do
    query =
      Module.concat(resource, Version)
      |> Ash.Query.filter(version_source_id == ^source_id)
      |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)

    query = if count == :all, do: query, else: Ash.Query.limit(query, count)

    Ash.read!(query, authorize?: false, tenant: org_id)
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
