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

  ## Resuming by position, not by count (#598)

  "What is new since the previous anchor" is asked as *"the rows sorting after
  the boundary the previous anchor ended on"* — the `(last_version_at,
  last_version_id)` sort key it recorded — never as a SQL `OFFSET
  version_count`.

  `OFFSET n` means "skip the first n rows **of the current result set**", which
  equals "skip the rows the previous anchor covered" only while no row ever
  becomes visible *below* the boundary afterwards. Two ordinary ways that
  breaks: concurrent writes whose version rows commit out of stamp order, and
  wall-clock skew between app nodes, since `version_inserted_at` is stamped by
  whichever node performs the write. Either one made the offset skip the row it
  was meant to fold and fold the boundary row a second time, minting a
  correctly-signed anchor whose hash covers a sequence that never existed and
  whose `version_count` is one too high.

  **Be exact about what this does and does not fix.** It removes the fabricated
  chain state. It does **not** clear the verdict: an earlier anchor committed to
  an ordering the version table no longer holds, so it can never reproduce, and
  `verify/4` recomputes the prefix from genesis. A document that took a
  below-boundary row reads `{:tampered, …}` before this change and after it.
  What changes is that the anchor is now honest about what it covered, the
  condition is logged when it happens instead of surfacing months later, and
  the verdict names it rather than reporting a bare hash mismatch that reads
  identically to doctored content.

  Actually closing it needs a fold order **assigned** at write time rather than
  inferred from a wall-clock timestamp, so that a late row appends instead of
  landing mid-sequence. That is a compliance-visible policy change — it decides
  whether a version row appearing inside an anchored range is tampering or a
  latecomer — so it is tracked separately rather than settled here.

  The boundary is signed. `last_version_at` is inside the anchor payload and
  its presence is what selects the v3 payload shape, so an attacker with
  `UPDATE` on `history_anchors` cannot repoint the resume position to freeze
  anchoring — the column steers the fold, so it has to be attested, exactly
  like `version_count` was when the fold resumed by count. It is stored rather
  than looked up from `last_version_id`, because version rows are deleted in
  ordinary operation (`KilnCMS.CMS.Changes.CoalesceAutosaveVersions` destroys
  superseded autosave rows on every debounced save) and a boundary that
  evaporated with its row would silently fall back to the count resume.

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
  `%{chain_hash, version_count, last_version_id, last_version_at}`.
  """
  @spec compute(module(), Ash.UUID.t(), Ash.UUID.t(), :all | non_neg_integer()) :: %{
          chain_hash: String.t(),
          version_count: non_neg_integer(),
          last_version_id: Ash.UUID.t() | nil,
          last_version_at: DateTime.t() | nil
        }
  def compute(resource, source_id, org_id, count \\ :all) do
    resource |> versions(source_id, count, org_id) |> fold()
  end

  @doc "Fold an already-loaded ascending version list into the chain shape."
  @spec fold([struct()]) :: map()
  def fold(versions), do: fold_from(@genesis, 0, versions)

  @doc """
  Fold `versions` onto an existing chain head — `seed` being the previous
  anchor's recorded `chain_hash` and `base_count` the number of versions that
  hash already covers.

  `base_count` is a cardinality carried forward for bookkeeping only; where the
  fold *starts* is a position, and the two are deliberately separate (#598).

  Folding all versions from genesis yields the same hash as folding the tail
  onto an honest prefix, so this is interchangeable with `fold/1` on intact
  history — and *not* interchangeable on doctored history, which is the point
  (see the module docs).
  """
  @spec fold_from(String.t(), non_neg_integer(), [struct()]) :: map()
  def fold_from(seed, base_count, versions) do
    chain_hash =
      Enum.reduce(versions, seed, fn version, prev ->
        Canonical.digest(%{"prev" => prev, "item" => item_digest(version)})
      end)

    last = List.last(versions)

    %{
      chain_hash: chain_hash,
      version_count: base_count + length(versions),
      last_version_id: last && last.id,
      last_version_at: last && last.version_inserted_at
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
    scope = %{resource: record.__struct__, source_id: record.id, org_id: record.org_id}
    previous = latest_anchor(type, record.id, record.org_id)
    {seed, base_count} = seed(previous)
    fresh = versions(scope.resource, scope.source_id, :all, scope.org_id, resume_at(previous))

    # Nothing new to cover: a second anchor over the identical prefix would say
    # nothing. Publishes opt out — theirs carries `published_version_id`.
    #
    # After a versioned write, though, "nothing after the boundary" means the
    # row this hook exists to fold landed BELOW it — the #598 skew. That costs
    # nothing to notice here, and it is the only place the hot path pays for
    # the check at all.
    if fresh == [] and not is_nil(previous) and not allow_empty? do
      warn_on_skew(scope, type, previous, base_count)
      :ok
    else
      computed = fold_from(seed, base_count, fresh)
      boundary = boundary(computed, previous)
      prev_digest = anchor_digest(previous)

      # Publishes are the compliance-critical anchors and are rare, so they pay
      # one count to check the same invariant even when they did fold something.
      if allow_empty?, do: warn_on_skew(scope, type, previous, computed.version_count)

      {signature, key_id} =
        sign(anchor_payload(type, record.id, computed, previous, prev_digest, boundary))

      CMS.create_history_anchor!(
        %{
          resource_type: type,
          source_id: record.id,
          chain_hash: computed.chain_hash,
          version_count: computed.version_count,
          last_version_id: boundary.id,
          last_version_at: boundary.at,
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

  # The sort key this anchor ends on: the last row it folded, or — when it
  # folded nothing — the one its predecessor ended on, carried forward so the
  # boundary never moves backwards.
  defp boundary(%{last_version_id: nil}, previous),
    do: %{id: previous && previous.last_version_id, at: previous && previous.last_version_at}

  defp boundary(computed, _previous),
    do: %{id: computed.last_version_id, at: computed.last_version_at}

  # Where the incremental fold picks up (#598) — a pure function of the previous
  # anchor, so nothing about it depends on a version row still existing.
  #
  # `{:offset, n}` is the pre-#598 count resume, reachable only for anchors
  # minted before `last_version_at` existed. It is wrong in exactly the way this
  # module documents, and it survives only until each document's next anchor
  # records a boundary — folding the whole history onto a seed that already
  # covers it would be worse.
  defp resume_at(nil), do: :genesis
  defp resume_at(%{last_version_at: nil, version_count: 0}), do: :genesis
  defp resume_at(%{last_version_at: nil} = previous), do: {:offset, previous.version_count}
  defp resume_at(%{last_version_at: at, last_version_id: id}), do: {:after, {at, id}}

  # A version row this anchor did not cover is history rearranging itself under
  # an anchor that already committed to the old order: that anchor can never
  # reproduce, and no later anchor repairs it (see the module docs). Otherwise
  # invisible until someone audits the document, which may be months later.
  #
  # Says what is true and stops — deliberately not "the document will verify as
  # tampered", which is a consequence this function has not established.
  defp warn_on_skew(scope, type, previous, covered) do
    total = count_versions(scope)

    if total > covered do
      Logger.error(
        "History chain skew on #{type} #{scope.source_id}: #{total - covered} version " <>
          "row(s) are not covered by the chain that anchor #{previous.id} continues, " <>
          "and no later anchor will cover them. See #598."
      )
    end
  end

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
            source_id,
            covered_by_query(
              %{resource: resource, source_id: source_id, org_id: org_id},
              anchor
            )
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
          verdict(
            anchor,
            fold(Enum.take(versions, anchor.version_count)),
            type,
            source_id,
            covered_loaded(versions, anchor)
          )
        end
    end
  end

  @doc "How many versions follow the latest anchor (0 when unanchored/none)."
  @spec unanchored_tail([struct()], struct() | nil) :: non_neg_integer()
  def unanchored_tail(_versions, nil), do: 0
  def unanchored_tail(versions, anchor), do: max(length(versions) - anchor.version_count, 0)

  defp verdict(anchor, computed, type, source_id, covered) do
    cond do
      computed.version_count < anchor.version_count ->
        {:tampered, "anchored versions are missing"}

      computed.chain_hash != anchor.chain_hash ->
        {:tampered, mismatch_reason(anchor, covered)}

      is_nil(anchor.signature) ->
        :unsigned

      true ->
        signature_verdict(anchor, type, source_id)
    end
  end

  # Tampering either way — a row spliced into the anchored range is exactly what
  # fabricated history looks like, so the verdict must not soften, and this says
  # only what it counted. But "N rows sort inside the anchored range that the
  # anchor never covered" is a fact an operator can go and check, where a bare
  # hash mismatch is not: rearranged history and rewritten content produce the
  # same permanent red, and nothing else distinguishes them.
  @mismatch "anchored history does not reproduce the recorded chain hash"

  defp mismatch_reason(anchor, covered) do
    case covered.() do
      n when is_integer(n) and n > anchor.version_count ->
        "#{@mismatch}: #{n - anchor.version_count} version row(s) sort inside the " <>
          "anchored range of #{anchor.version_count} but were never covered by it"

      _ ->
        @mismatch
    end
  end

  # How many version rows now sit in the anchored range — everything at or
  # before the anchor's recorded boundary. Deferred behind a closure because it
  # costs two queries and only the mismatch branch of `verdict/5` ever asks, and
  # rescued because unlike `anchor/2` and `extend/2` the read path has no
  # blanket rescue: `mix kiln.audit.verify` walks every document in every org,
  # and one unreadable count must not abort the run on the one verdict that
  # matters most.
  defp covered_by_query(scope, anchor) do
    fn ->
      case boundary_of(anchor) do
        nil -> nil
        key -> count_versions(scope) - count_after(scope, key)
      end
    end
  rescue
    error ->
      Logger.warning(
        "History chain range count failed, reporting a bare mismatch: #{inspect(error)}"
      )

      fn -> nil end
  end

  # Same question against an already-loaded ASCENDING list — free, no query.
  # The list must be the document's COMPLETE version set in the fold's order,
  # which is what `KilnCMS.Governance.versions_asc/3` hands `verify_loaded/4`;
  # a filtered or paginated list would silently answer a different question.
  defp covered_loaded(versions, anchor) do
    fn ->
      case boundary_of(anchor) do
        nil -> nil
        {at, id} -> Enum.count(versions, &at_or_before?(&1, at, id))
      end
    end
  end

  defp boundary_of(%{last_version_at: at, last_version_id: id}) when not is_nil(at),
    do: {at, id}

  defp boundary_of(_anchor), do: nil

  # The in-memory twin of `count_after/2`'s SQL predicate, negated. Comparing
  # ids with `<=` matches Postgres because Ash renders uuids as canonical
  # lowercase hex: hex digits order the same as their nibble values in ASCII and
  # the dashes sit at fixed offsets, so the string order is the byte order.
  defp at_or_before?(version, at, id) do
    case DateTime.compare(version.version_inserted_at, at) do
      :lt -> true
      :eq -> version.id <= id
      :gt -> false
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
    prev = anchor.prev_anchor_id && %{id: anchor.prev_anchor_id}
    boundary = %{id: anchor.last_version_id, at: anchor.last_version_at}

    v3 = anchor_payload(type, source_id, computed, prev, anchor.prev_anchor_digest, boundary)

    # An older-shape candidate is offered only when the columns it does NOT
    # cover are null — otherwise an anchor signed at that shape could have those
    # columns written into it after the fact and still verify. A newer-shape
    # anchor is never at risk from the older candidates: the encoded payloads
    # differ byte for byte, so its signature can only ever match its own shape.
    #
    # v2 is gated on `last_version_at` rather than on `last_version_id`, because
    # `last_version_at` is what steers the fold (`resume_at/1`) and every v2
    # anchor already carries a non-null `last_version_id`. So a v2 anchor's id
    # can still be rewritten unnoticed — and does nothing, since without the
    # timestamp the resume falls back to the count.
    v2 = anchor_payload(type, source_id, computed, prev, anchor.prev_anchor_digest)
    v1 = legacy_anchor_payload(type, source_id, computed)

    cond do
      not is_nil(anchor.last_version_at) -> [v3]
      is_nil(anchor.prev_anchor_id) and is_nil(anchor.prev_anchor_digest) -> [v3, v2, v1]
      true -> [v3, v2]
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

  @typedoc """
  How much of a document's version history is inside an anchor's fold.

  `:none` — nothing is anchored. `{at, id}` — every row at or before that
  `(version_inserted_at, id)` key is. `:unknown` — the question could not be
  answered, which callers must treat as "all of it": see `anchored_boundary/1`.
  """
  @type anchored :: {DateTime.t(), Ash.UUID.t()} | :none | :unknown

  @doc """
  How much of `record`'s version history an anchor has already committed to.

  A version row inside the fold is immutable. Destroying or rewriting one is
  unrecoverable: that anchor can never reproduce, no later anchor repairs it,
  and the verdict is `{:tampered, …}` — indistinguishable from real tampering,
  permanently.

  This is not hypothetical bookkeeping. `KilnCMS.CMS.Changes.CoalesceAutosaveVersions`
  destroys superseded autosave rows and rewrites the survivor's `changes` on
  every debounced save, and with `anchor_every_write` on those same rows have
  just been anchored — so the two features, each correct alone, produced a
  permanent false tamper verdict on the one configuration that exists to make
  the audit surface stronger (#671). Anything that mutates version rows asks
  this first.

  Three things make it answer conservatively, because every wrong answer here
  destroys history that cannot be reconstructed:

    * **It ignores the `audit_anchors_enabled` kill switch**, unlike every other
      read here. Turning the switch off stops anchoring; it does not delete the
      anchors already minted, and those rows still commit to what they commit
      to. Reading `[]` because the feature is "off" would let coalescing eat
      them and red the document the moment the switch came back on.
    * **It never raises.** It runs in `after_transaction`, after the editor's
      save has already committed, where a raise reaches the LiveView rather than
      the changeset — the same reason `anchor/2` and `extend/2` are wrapped. An
      unreadable `history_anchors` (the migration not yet applied, a transient
      fault) answers `:unknown`.
    * **`:unknown` means "assume everything".** A pre-#598 anchor recorded only
      a `version_count`, so the position is resolved by reading the
      `version_count`-th surviving row; when fewer rows survive than the anchor
      counted — which is the state a document damaged by #671 is already in —
      there is no row to resolve to, and the honest answer is that we cannot
      tell rather than that nothing is anchored.
  """
  @spec anchored_boundary(struct()) :: anchored()
  def anchored_boundary(record) do
    type = to_string(KilnCMS.Firing.Engine.document_type(record))
    scope = %{resource: record.__struct__, source_id: record.id, org_id: record.org_id}

    type
    |> read_anchors(record.id, record.org_id, 1)
    |> List.first()
    |> resolved_boundary(scope)
  rescue
    error ->
      Logger.error("Anchor boundary unreadable, skipping version coalescing: #{inspect(error)}")
      :unknown
  end

  defp resolved_boundary(nil, _scope), do: :none

  defp resolved_boundary(%{last_version_at: at, last_version_id: id}, _scope)
       when not is_nil(at),
       do: {at, id}

  # Pre-#598 anchors recorded a count and no position (`resume_at/1`'s
  # `{:offset, n}` case). Resolve it to the same sort key by reading the row at
  # that position, so callers have one shape to reason about rather than two.
  #
  # Deleted rows push the n-th survivor later, which is conservative. Deleting
  # enough of them that there is no n-th row at all is not — so that answers
  # `:unknown` rather than `:none`.
  defp resolved_boundary(%{version_count: n}, scope) when n > 0 do
    scope.resource
    |> version_scope(scope.source_id)
    |> Ash.Query.offset(n - 1)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: scope.org_id)
    |> case do
      nil -> :unknown
      version -> {version.version_inserted_at, version.id}
    end
  end

  defp resolved_boundary(_anchor, _scope), do: :none

  @doc """
  Narrow `query` over a version resource to the rows no anchor has committed to.

  The same predicate the incremental fold resumes on, exposed so a caller that
  mutates version rows can exclude the anchored prefix in SQL rather than
  filtering in memory. `:none` is the identity; `:unknown` is not accepted,
  because "narrow to nothing" and "read nothing" are different enough that the
  caller should say which it means.
  """
  @spec after_anchored(Ash.Query.t(), {DateTime.t(), Ash.UUID.t()} | :none) :: Ash.Query.t()
  def after_anchored(query, :none), do: query

  def after_anchored(query, {at, boundary_id}),
    do: resume_after(query, {:after, {at, boundary_id}})

  @doc """
  Every anchor for a document, newest first — the input to `chain_intact/1`.

  One query, then an in-memory walk: the sequence is bounded by how often the
  document has been anchored, not by how many versions it has, so this is not
  the per-version fold.
  """
  @spec anchors(String.t(), Ash.UUID.t(), Ash.UUID.t() | nil, pos_integer() | nil) :: [struct()]
  def anchors(type, source_id, org_id, limit \\ nil) do
    if enabled?(), do: read_anchors(type, source_id, org_id, limit), else: []
  end

  # The read itself, with no kill-switch gate. `anchors/4` applies the gate;
  # `anchored_boundary/1` deliberately does not — see its docs.
  defp read_anchors(type, source_id, org_id, limit) do
    # Newest first with an id tiebreak (same-microsecond anchors).
    query = [sort: [inserted_at: :desc, id: :desc]]
    query = if limit, do: Keyword.put(query, :limit, limit), else: query

    CMS.list_history_anchors_for!(type, source_id,
      authorize?: false,
      tenant: org_id,
      query: query
    )
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Version twins are tenant-strict (#419) — the chain reads under the org.
  # `resume` skips the prefix an earlier anchor already covered, so an
  # incremental fold reads only what is new. See `resume_at/1` for why the
  # boundary is a position rather than a count (#598).
  defp versions(resource, source_id, count, org_id, resume \\ :genesis) do
    resource
    |> version_scope(source_id)
    |> resume_after(resume)
    |> then(&if count == :all, do: &1, else: Ash.Query.limit(&1, count))
    |> Ash.read!(authorize?: false, tenant: org_id)
  end

  @doc """
  A document's versions in the order the chain folds them — ascending
  `(version_inserted_at, id)`.

  Public because `KilnCMS.Governance.trail/3` reads the same list once and hands
  it to `verify_loaded/4`: the fold order has to be defined in one place, or the
  trail and `verify/4` can reach different verdicts for the same document.
  """
  @spec versions_asc(module(), Ash.UUID.t(), Ash.UUID.t() | nil) :: [struct()]
  def versions_asc(resource, source_id, org_id) do
    versions(resource, source_id, :all, org_id)
  end

  defp version_scope(resource, source_id) do
    Module.concat(resource, Version)
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)
  end

  defp resume_after(query, :genesis), do: query
  defp resume_after(query, {:offset, n}), do: Ash.Query.offset(query, n)

  # Strictly after the boundary in the `(version_inserted_at, id)` sort order the
  # fold uses — the row-valued comparison, spelled out because the expression
  # language has no tuple form. `boundary_id` rather than `id`: the bare `id` on
  # the left is a reference to the column, and giving the pinned value the same
  # name reads as though one shadows the other.
  defp resume_after(query, {:after, {at, boundary_id}}) do
    Ash.Query.filter(
      query,
      version_inserted_at > ^at or (version_inserted_at == ^at and id > ^boundary_id)
    )
  end

  defp count_versions(scope) do
    scope.resource
    |> version_scope(scope.source_id)
    |> Ash.count!(authorize?: false, tenant: scope.org_id)
  end

  # Rows strictly after `key` — the same predicate the fold resumes with, so
  # "how many rows are at or before the boundary" is `count_versions - this`
  # rather than a second, independently-maintained comparison that could drift
  # out of complement with it.
  defp count_after(scope, key) do
    scope.resource
    |> version_scope(scope.source_id)
    |> resume_after({:after, key})
    |> Ash.count!(authorize?: false, tenant: scope.org_id)
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
  # So is the boundary (#598). Once the fold resumes from a position rather than
  # from the signed `version_count`, that position is control flow: repoint it
  # and the next anchor covers whatever rows the attacker chose. Anything that
  # steers the fold has to be attested.
  #
  # `v: 3` because the shape changed again; `anchor_payload/5` and
  # `legacy_anchor_payload/3` keep anchors minted at v2 and v1 verifying.
  defp anchor_payload(type, source_id, computed, prev, prev_digest, boundary) do
    Canonical.encode(%{
      "v" => 3,
      "type" => type,
      "source_id" => source_id,
      "chain_hash" => computed.chain_hash,
      "version_count" => computed.version_count,
      "prev_anchor_id" => prev && prev.id,
      "prev_anchor_digest" => prev_digest,
      "last_version_id" => boundary.id,
      "last_version_at" => boundary.at && DateTime.to_iso8601(boundary.at)
    })
  end

  # The pre-#598 signed shape.
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
