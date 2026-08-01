defmodule KilnCMS.Governance.Chain do
  @moduledoc """
  Tamper-evident history anchoring (#356): fold a document's PaperTrail
  version list into one canonical SHA-256 chain hash, anchor it (signed) at
  publish time, and verify it later against the live `*_versions` rows.

  The chain is per document: versions sorted ascending are folded as

      chain_n = digest(%{"prev" => chain_n-1, "item" => digest(version_n)})

  so changing, removing, or reordering **any** anchored version changes the
  final hash. Anchors are signed with the provenance signing key when
  configured (`KilnCMS.Provenance.Signer` / `KilnCMS.Keys`), so the anchor row
  itself can't be silently rewritten to match doctored history.

  ## Anchors chain to each other

  A new anchor is folded **incrementally, seeded from the previous anchor's
  recorded `chain_hash`** — never recomputed from scratch over the live
  version rows.

  This is a correctness property, not an optimization. Re-folding from genesis
  at each anchor would derive the new hash from whatever the version table
  says *now*, so an attacker who doctored history and then waited for the next
  publish would get a fresh, valid, correctly-signed anchor over the doctored
  rows — and since `verify/4` checks the latest anchor, the tampering would
  read as `:verified`. Seeding from the recorded hash means every anchor
  transitively commits to every earlier one.

  It is also O(new versions) rather than O(history), which is what makes
  per-write anchoring affordable.

  ## What the chain does and does not guarantee (#597)

  Each anchor also records its predecessor's **id and a digest of its contents**,
  both inside the signed payload. `chain_intact/1` walks that sequence, so an
  anchor that is deleted or rewritten *while something still points at it* leaves
  a hole — `{:tampered, "anchor chain broken: …"}` rather than silence.

  **This narrows the laundering route in #597; it does not close it.** Say what
  holds, precisely:

    * Deleting or rewriting a **middle** anchor is detected — its successor names
      it, and the digest covers the predecessor's hash, count, signature and its
      own link columns, so it cannot be repaired without the signing key.
    * Deleting the **newest** anchors is **not** detected. Nothing points at the
      newest anchor, so a shorter chain is indistinguishable from a younger one.
      Since it is exactly the newest anchors that commit to the most recent
      versions, an attacker who doctors version *k* deletes only the anchors with
      `version_count >= k`, leaves the rest intact, and the next write re-anchors
      from the surviving prefix over the doctored rows. Verdict: `:verified`.
      Confirmed empirically, and characterised in the test suite.
    * Wiping **every** anchor returns the document to `:unanchored` and the next
      write anchors it afresh — indistinguishable from a document anchored for
      the first time.
    * Without a signing key (the default — `KILN_PROVENANCE_PRIVATE_KEY` unset),
      none of this holds at all: the digest is computed from public columns, so
      an attacker recomputes any link they like, and the verdict is `:unsigned`
      either way. **The predecessor link is advisory on an unsigned deployment.**

  Closing the truncation case needs state the document's own anchor set cannot
  provide — a per-document monotonic sequence with an external witness, an
  append-only store, or `ON DELETE RESTRICT` plus a signed head pointer. Tracked
  in #666; #597 stays open until then. Revoking `DELETE` on `history_anchors`
  for the application role remains the cheap defence in depth, and is orthogonal
  to all of this.

  ## When anchors are minted

  Always at publish (`KilnCMS.CMS.Changes.RecordPublishedVersion`) — the
  moments that matter most for compliance. With `anchor_every_write: true`,
  also after **every** versioned write (`KilnCMS.CMS.Changes.AnchorVersion`),
  which closes the between-publish window #356 asks about. Off by default:
  it costs one signature and one row per save, which a regulated deployment
  wants and a blog does not. Either way the governance trail surfaces any
  still-uncovered tail via `unanchored_tail/2`.
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
  Whether every versioned write is anchored, not just publishes (#356).
  Default false — see the module docs on cost.
  """
  @spec every_write?() :: boolean()
  def every_write?, do: Application.get_env(:kiln_cms, :audit_anchor_every_write, false)

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
  def fold(versions), do: fold_from(@genesis, 0, versions)

  @doc """
  Fold `versions` onto an existing chain head — `seed` being the previous
  anchor's recorded `chain_hash` and `offset` the version count it covered.

  Folding all versions from genesis yields the same hash as folding the tail
  onto an honest prefix, so this is interchangeable with `fold/1` on intact
  history — and *not* interchangeable on doctored history, which is the point
  (see the module docs).
  """
  @spec fold_from(String.t(), non_neg_integer(), [struct()]) :: map()
  def fold_from(seed, offset, versions) do
    chain_hash =
      Enum.reduce(versions, seed, fn version, prev ->
        Canonical.digest(%{"prev" => prev, "item" => item_digest(version)})
      end)

    %{
      chain_hash: chain_hash,
      version_count: offset + length(versions),
      last_version_id: versions |> List.last() |> then(&(&1 && &1.id))
    }
  end

  @doc """
  Mint an anchor for `record` after a publish. Never raises — a chain problem
  must not break the publish that triggered it. Returns `:ok` always.
  """
  @spec anchor(struct(), keyword()) :: :ok
  def anchor(record, opts \\ []) do
    # allow_empty?: a publish anchor is recorded even when it covers no new
    # versions, because it also carries the `published_version_id` linkage.
    if enabled?(), do: mint(record, opts, true), else: :ok
  rescue
    error ->
      Logger.error("History anchoring failed (publish unaffected): #{inspect(error)}")
      :ok
  end

  @doc """
  Extend the chain after a *non-publish* versioned write, when
  `anchor_every_write` is on (#356). Same guarantees and the same never-raise
  contract as `anchor/2`; publishes go through `anchor/2` instead so the
  anchor also records `published_version_id`.
  """
  @spec extend(struct(), keyword()) :: :ok
  def extend(record, opts \\ []) do
    if enabled?() and every_write?(), do: mint(record, opts, false), else: :ok
  rescue
    error ->
      Logger.error("History anchoring failed (write unaffected): #{inspect(error)}")
      :ok
  end

  # Fold whatever is new since the latest anchor onto its recorded hash, and
  # record + sign the result. Seeding from the recorded hash (rather than
  # re-folding the live rows from genesis) is what stops a later write from
  # re-blessing doctored history — see the module docs.
  defp mint(record, opts, allow_empty?) do
    type = to_string(KilnCMS.Firing.Engine.document_type(record))
    previous = latest_anchor(type, record.id, record.org_id)
    {seed, offset} = seed(previous)
    fresh = versions(record.__struct__, record.id, :all, record.org_id, offset)

    # Nothing new to cover: a second anchor over the identical prefix would say
    # nothing. Publishes opt out — theirs carries `published_version_id`.
    if fresh == [] and not is_nil(previous) and not allow_empty? do
      :ok
    else
      computed = fold_from(seed, offset, fresh)
      prev_digest = anchor_digest(previous)

      {signature, key_id} = sign(anchor_payload(type, record.id, computed, previous, prev_digest))

      CMS.create_history_anchor!(
        %{
          resource_type: type,
          source_id: record.id,
          chain_hash: computed.chain_hash,
          version_count: computed.version_count,
          last_version_id: computed.last_version_id || previous_last_version_id(previous),
          published_version_id: Map.get(record, :published_version_id),
          signature: signature,
          key_id: key_id,
          actor_id: opts[:actor_id],
          prev_anchor_id: previous && previous.id,
          prev_anchor_digest: prev_digest
        },
        authorize?: false,
        tenant: record.org_id
      )

      :ok
    end
  end

  defp seed(nil), do: {@genesis, 0}
  defp seed(anchor), do: {anchor.chain_hash, anchor.version_count}

  defp previous_last_version_id(nil), do: nil
  defp previous_last_version_id(anchor), do: anchor.last_version_id

  @doc """
  Verify a document's history against its **latest** anchor:

    * `:verified` — the anchored prefix recomputes to the anchored hash and
      the anchor's signature checks out against the key it names (the active
      signing key, or a registered retired one).
    * `:unsigned` — prefix intact, but the anchor carries no signature (no
      signing key was configured when it was minted).
    * `:unverifiable` — prefix intact and the anchor IS signed, but no key
      matching the anchor's `key_id` is available: it was rotated out and
      never registered in `retired_keys`, or no key is configured at all.
      Deliberately distinct from tampering — we cannot attest this anchor, but
      nothing says it is bad. Registering the retired key's public half
      (`KilnCMS.Provenance.KeyRegistry`) turns these back into `:verified`.
    * `:unanchored` — the document has no anchors yet (never published since
      anchoring was enabled).
    * `{:tampered, reason}` — the anchored history no longer reproduces the
      hash (altered/deleted/reordered versions), or the signature fails
      against a key we DO hold. Not holding the key is `:unverifiable`, above.

  Only the anchored prefix is covered — edits since the last publish anchor
  at the next publish. Callers that need to show that window use
  `unanchored_tail/2` (the governance trail displays it).
  """
  @spec verify(module(), String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: verdict()
  def verify(resource, type, source_id, org_id) do
    case anchors(type, source_id, org_id) do
      [] ->
        :unanchored

      [anchor | _] = all ->
        with :ok <- chain_intact(all) do
          verdict(
            anchor,
            compute(resource, source_id, org_id, anchor.version_count),
            type,
            source_id
          )
        end
    end
  end

  @doc """
  Whether a document's anchor sequence is unbroken (#597).

  Takes the anchors newest-first. Every anchor but a document's first names its
  predecessor and carries a digest of it, both inside the signed payload — so a
  named predecessor that is **absent**, or present but digesting differently, is
  a hole. That is exactly what deleting or rewriting an anchor row leaves behind.

  Returns `:ok`, or `{:tampered, reason}` naming the break.
  """
  @spec chain_intact([struct()]) :: :ok | {:tampered, String.t()}
  def chain_intact(anchors) do
    by_id = Map.new(anchors, &{&1.id, &1})

    anchors
    |> Enum.reject(&is_nil(&1.prev_anchor_id))
    |> Enum.reduce_while(:ok, fn anchor, :ok ->
      case link_intact(anchor, by_id) do
        :ok -> {:cont, :ok}
        broken -> {:halt, broken}
      end
    end)
  end

  defp link_intact(anchor, by_id) do
    case Map.fetch(by_id, anchor.prev_anchor_id) do
      :error ->
        {:tampered,
         "anchor chain broken: anchor #{anchor.id} names predecessor " <>
           "#{anchor.prev_anchor_id}, which no longer exists"}

      {:ok, prev} ->
        digest_intact(anchor, prev)
    end
  end

  defp digest_intact(anchor, prev) do
    if anchor_digest(prev) == anchor.prev_anchor_digest do
      :ok
    else
      {:tampered,
       "anchor chain broken: anchor #{anchor.id} does not match the " <>
         "predecessor #{prev.id} it names"}
    end
  end

  @doc """
  Like `verify/4` but folding over an already-loaded ASCENDING version list
  (the governance trail reads versions once and shares them).
  """
  @spec verify_loaded([struct()], String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: verdict()
  def verify_loaded(versions, type, source_id, org_id) do
    case anchors(type, source_id, org_id) do
      [] ->
        :unanchored

      [anchor | _] = all ->
        with :ok <- chain_intact(all) do
          verdict(anchor, fold(Enum.take(versions, anchor.version_count)), type, source_id)
        end
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

      true ->
        signature_verdict(anchor, type, source_id)
    end
  end

  # Resolve the key the anchor says signed it (active or retired) and check
  # against *that*. A failure under a key we hold is tampering; not holding the
  # key at all is unverifiable — never red. See `Provenance.KeyRegistry`.
  defp signature_verdict(anchor, type, source_id) do
    # Anchors minted before #597 were signed over a payload with no predecessor
    # keys, so both shapes are tried. A format migration, not a weakening: every
    # candidate is checked against the SAME key, so an attacker without it cannot
    # produce a signature matching either shape.
    anchor
    |> payload_candidates(type, source_id)
    |> Enum.reduce_while({:tampered, "anchor signature does not verify"}, fn payload, acc ->
      case Signer.verify(payload, anchor.signature, anchor.key_id) do
        {:ok, true} -> {:halt, :verified}
        {:ok, false} -> {:cont, acc}
        # Not holding the key is never red — and it is the same answer for every
        # candidate, so stop rather than retrying the identical failure.
        {:error, _reason} -> {:halt, :unverifiable}
      end
    end)
  end

  defp payload_candidates(anchor, type, source_id) do
    computed = %{chain_hash: anchor.chain_hash, version_count: anchor.version_count}

    v2 =
      anchor_payload(
        type,
        source_id,
        computed,
        anchor.prev_anchor_id && %{id: anchor.prev_anchor_id},
        anchor.prev_anchor_digest
      )

    # The v1 candidate is offered ONLY when both link columns are null, i.e. the
    # anchor really could be pre-#597. Otherwise a v1 anchor — whose signature
    # never covered those columns — could have a predecessor link written into it
    # after the fact and still verify, letting an attacker manufacture a
    # chain-broken verdict on an untouched document, or blank a link that a later
    # anchor depends on.
    if is_nil(anchor.prev_anchor_id) and is_nil(anchor.prev_anchor_digest) do
      [v2, legacy_anchor_payload(type, source_id, computed)]
    else
      [v2]
    end
  end

  @doc """
  The latest anchor for a document, or nil. Honors the kill switch (and so
  keeps the whole read path quiet — no `history_anchors` query — when the
  feature is off or its migration hasn't run yet).
  """
  def latest_anchor(type, source_id, org_id) do
    type |> anchors(source_id, org_id, 1) |> List.first()
  end

  @doc """
  Every anchor for a document, newest first — the input to `chain_intact/1`.

  One query, then an in-memory walk: the sequence is bounded by how often the
  document has been anchored, not by how many versions it has, so this is not
  the per-version fold.
  """
  @spec anchors(String.t(), Ash.UUID.t(), Ash.UUID.t() | nil, pos_integer() | nil) :: [struct()]
  def anchors(type, source_id, org_id, limit \\ nil) do
    if enabled?() do
      # Newest first with an id tiebreak (same-microsecond anchors).
      query = [sort: [inserted_at: :desc, id: :desc]]
      query = if limit, do: Keyword.put(query, :limit, limit), else: query

      CMS.list_history_anchors_for!(type, source_id,
        authorize?: false,
        tenant: org_id,
        query: query
      )
    else
      []
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Version twins are tenant-strict (#419) — the chain reads under the org.
  # `offset` skips the prefix an earlier anchor already covered, so an
  # incremental fold reads only what is new.
  defp versions(resource, source_id, count, org_id, offset \\ 0) do
    query =
      Module.concat(resource, Version)
      |> Ash.Query.filter(version_source_id == ^source_id)
      |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)

    query = if count == :all, do: query, else: Ash.Query.limit(query, count)
    query = if offset > 0, do: Ash.Query.offset(query, offset), else: query

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

  # `prev` and `prev_digest` are inside the SIGNED payload, which is what makes
  # the link unforgeable: an attacker who deletes an anchor cannot mint a
  # replacement whose successor still verifies, not without the signing key.
  #
  # `v: 2` because the shape changed (#597); `legacy_anchor_payload/3` keeps
  # anchors minted at v1 verifying.
  defp anchor_payload(type, source_id, computed, prev, prev_digest) do
    Canonical.encode(%{
      "v" => 2,
      "type" => type,
      "source_id" => source_id,
      "chain_hash" => computed.chain_hash,
      "version_count" => computed.version_count,
      "prev_anchor_id" => prev && prev.id,
      "prev_anchor_digest" => prev_digest
    })
  end

  # The pre-#597 signed shape, so anchors minted by an earlier release keep
  # verifying rather than turning red on deploy.
  defp legacy_anchor_payload(type, source_id, computed) do
    Canonical.encode(%{
      "v" => 1,
      "type" => type,
      "source_id" => source_id,
      "chain_hash" => computed.chain_hash,
      "version_count" => computed.version_count
    })
  end

  @doc """
  A digest over an anchor's identity **and** contents, recorded by its successor.

  Binding the hash, count and signature — not just the id — means a deleted
  predecessor cannot be replaced by a forged row reusing its id.
  """
  @spec anchor_digest(struct() | nil) :: String.t() | nil
  def anchor_digest(nil), do: nil

  def anchor_digest(anchor) do
    :sha256
    |> :crypto.hash(
      Canonical.encode(%{
        "id" => anchor.id,
        "chain_hash" => anchor.chain_hash,
        "version_count" => anchor.version_count,
        "signature" => anchor.signature,
        # The predecessor's OWN link columns are included, or a middle anchor
        # could be spliced out by re-pointing its successor at its predecessor:
        # the digest would be unchanged, and a non-newest anchor's signature is
        # the only other thing that would have caught it.
        "prev_anchor_id" => Map.get(anchor, :prev_anchor_id),
        "prev_anchor_digest" => Map.get(anchor, :prev_anchor_digest)
      })
    )
    |> Base.encode16(case: :lower)
  end

  # Sign with the provenance signing key when one is configured; otherwise the
  # anchor is stored unsigned (still a useful integrity checksum).
  #
  # An unresolvable key is LOGGED, not swallowed. Silently degrading to unsigned
  # anchors is the failure an operator is least likely to notice and most likely
  # to care about: the row still lands, the dashboard still shows a chain, and
  # only the verdict (`:unsigned` rather than `:verified`) betrays that nothing
  # is actually attested. A misconfigured key must be loud — this is per anchor
  # on purpose, since it means the deployment is misconfigured right now.
  defp sign(payload) do
    with {:ok, signature} <- Signer.sign(payload),
         {:ok, key_id} <- Signer.key_id() do
      {signature, key_id}
    else
      # Both Signer.sign/1 and Signer.key_id/0 spec {:ok, _} | {:error, term()},
      # so this is the only reachable shape — a catch-all here is dead code that
      # dialyzer rejects (pattern_match_cov).
      #
      # ASCII only: Logger escapes non-ASCII to \x{...}, which turns an em dash
      # into noise in exactly the message an operator needs to read.
      {:error, reason} ->
        Logger.warning(
          "History anchor stored UNSIGNED - provenance signing key unavailable: " <>
            KilnCMS.Keys.describe_error(reason)
        )

        {nil, nil}
    end
  end
end
