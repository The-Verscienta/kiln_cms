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

    * **Every anchor's signature is verified**, not only the head's, and an
      anchor that cannot be judged **floors the whole chain**. That is the
      foundation the rest stands on. While only the baseline was checked, every
      other anchor's attested columns were rewritable, and any invariant
      computed over them was satisfiable. And merely *skipping* an unjudgeable
      anchor was the same hole one column over: `anchor_digest/1` covers neither
      `key_id` nor `sequence`, so nulling a non-head signature made that anchor
      invisible to the sweep, after which it could be renumbered into the
      baseline position with nothing objecting. So a chain containing an anchor
      nobody can vouch for reads `:unsigned` or `:unverifiable` — never
      `:verified`. That is also the honest answer for the benign cases it
      covers: no key configured, or a rotation whose outgoing key was never
      registered.

      The floor never *softens* a verdict. The hash comparison needs no key at
      all, so real tampering is still reported as `{:tampered, …}` on a keyless
      deployment.
    * Deleting or rewriting a **middle** anchor is detected — its successor names
      it, and the digest covers the predecessor's hash, count, signature and its
      own link columns, so it cannot be repaired without the signing key.
    * Deleting a middle anchor **together with its successor** is detected. On a
      signed deployment the attacker must null the survivor's link columns to
      make the remaining links resolve, and those are inside its signed payload.
      On an **unsigned** one, where that is free, the per-document `sequence`
      is what is left: the run reads `[4, 1]` and the hole is visible.

      `prev_anchor_id` also carries `ON DELETE RESTRICT`, which is what forces
      the attacker into that shape: a middle anchor cannot be removed on its own
      while its successor survives. Be precise about what that does **not** buy —
      Postgres checks the constraint after the statement's rows are gone, so a
      `DELETE … WHERE source_id = …` that removes referrer and referent together
      still succeeds. RESTRICT narrows the attack; it does not stop a wipe. Both
      are characterised in the test suite.
    * **Reordering** is detected. Anchors are read in `sequence` order, which is
      `NOT NULL`, unique per document, and inside the signed payload from v4 on.
      Before it, ordering was by `inserted_at` — written by the database,
      attested by nothing — so `UPDATE … SET inserted_at = now()` on an older,
      shorter anchor made it the verification baseline, putting the doctored
      versions outside the anchored prefix with nothing deleted at all.

      A nullable position would have been the same hole one column over, since
      nothing attests an absent value; hence `NOT NULL`, backfilled. Anchors
      backfilled by that migration were signed before the column existed, so
      their position is *not* covered by their own signature — what holds them
      in place is that `version_count` must rise with position — on columns the
      signature sweep has established are attested, which is why that sweep has
      to floor rather than skip. A short anchor cannot be promoted to the
      baseline without violating it.
    * Deleting the **newest** anchors is detected, and so is *hiding* them —
      `UPDATE … SET resource_type = 'page_x'` or a rewritten `source_id` takes
      them out of the set the query returns, which is the same attack reached
      with `UPDATE` instead of `DELETE`, and reads the same way here. Both are
      caught by the **checkpoint witness** rather than by anything in the
      document's own anchor set, for the reason the next section gives.
    * Wiping **every** anchor is detected on a witnessed document: it reads
      `{:tampered, …}` rather than the `:unanchored` it used to, which was
      indistinguishable from a document anchored for the first time.
    * One variant only *weakens* a verdict rather than faking one, and is worth
      knowing because an operator reads it as benign: `key_id` is in neither the
      signed payload nor the digest — it cannot be, since the key it names is
      what would check the signature covering it — so one `UPDATE` on any anchor
      makes a corpus read `:unverifiable`, which looks exactly like a rotation
      whose outgoing key was never registered.
    * Without a signing key (the default — `KILN_PROVENANCE_PRIVATE_KEY` unset)
      the digest and the position are ordinary columns an attacker can recompute
      and renumber, and the verdict is `:unsigned` regardless. The structural
      checks still run and still report — `chain_intact/1` precedes the
      `:unsigned` short-circuit — so a hole or an out-of-order run is named
      rather than swallowed. But **treat them as advisory there**: they raise the
      cost of a forgery, they do not attest anything.

  ## The witness (#666)

  Nothing points at the newest anchor, so a shorter chain is indistinguishable
  from a younger one, and **no amount of state inside the document's own anchor
  set can tell them apart**. An attacker who doctors version *k* deletes only
  the anchors with `version_count >= k` — newest-first, past the `RESTRICT` —
  leaves the rest intact, and the next write re-anchors from the surviving
  prefix over the doctored rows.

  What closes it is a statement made from outside the document:
  `KilnCMS.Governance.Checkpoint` mints a signed, org-wide Merkle commitment to
  every document's head anchor on a schedule and publishes it through
  `KilnCMS.Governance.Witness`. `verify/4` compares the live head against the
  newest checkpoint entry, so a document witnessed at position 7 that now heads
  at 5 is `{:tampered, …}`.

  The comparison is against the anchor **at the witnessed position**, not against
  the head. Comparing heads was a one-extra-publish hole: positions are refilled
  by `next_sequence/1`, so two ordinary writes after a truncation put the head
  *past* what was witnessed with a contiguous chain underneath, and a
  head-versus-head check reads that as ordinary growth.

  Three limits, stated rather than glossed:

    * **Anchors above the witnessed position are not witnessed.** Truncating
      back to the last witnessed position is still invisible, so the exposure
      window is exactly one checkpoint interval — which is what makes the
      cadence (`KILN_GOVERNANCE_CHECKPOINT_CRON`) a security parameter and not a
      performance one.
    * **With the default `None` witness the commitment stays in the database.**
      That still catches the attack in its ordinary form, because
      `chain_checkpoints` is a second table the attacker has to remember. It does
      not survive one who does — deleting a document's entry rows removes the
      witness, and nothing here can tell that from a document no checkpoint ever
      covered. Configure a real sink for the property.
    * **Publication is only half of it.** A checkpoint nobody reads back is a
      file. `mix kiln.audit.checkpoint --audit` compares the sink to the database
      in *both* directions — including listing what was published and looking for
      what the database no longer has, which is the direction that sees a deleted
      checkpoint at all — and it wants to run somewhere the application host does
      not control.

  Revoking `DELETE` on `history_anchors` for the application role remains
  worthwhile on top of the `RESTRICT`, and is orthogonal to all of this.

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
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Provenance.Canonical
  alias KilnCMS.Provenance.Signer
  alias KilnCMS.Repo

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
  `%{chain_hash, attribution_hash, version_count, last_version_id, last_version_at}`.
  """
  @spec compute(module(), Ash.UUID.t(), Ash.UUID.t(), :all | non_neg_integer()) :: %{
          chain_hash: String.t(),
          attribution_hash: String.t(),
          version_count: non_neg_integer(),
          last_version_id: Ash.UUID.t() | nil,
          last_version_at: DateTime.t() | nil
        }
  def compute(resource, source_id, org_id, count \\ :all) do
    versions = versions(resource, source_id, count, org_id)
    with_attribution(fold(versions), versions)
  end

  # `chain_hash` is folded incrementally from a seed in `mint`, but
  # `attribution_hash` is always over the whole covered set from genesis — so it
  # is computed alongside `fold/1`'s from-genesis result and from `mint`'s full
  # read, never from the incremental `fold_from/3`.
  defp with_attribution(folded, versions),
    do: Map.put(folded, :attribution_hash, attribution_hash(versions))

  # The loaded-list twin of `compute/4` for `verify_loaded/4`: fold the first
  # `count` versions and carry the attribution over that same prefix.
  defp fold_loaded(versions, count) do
    prefix = Enum.take(versions, count)
    with_attribution(fold(prefix), prefix)
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

  @doc """
  Re-attest a promoted document's anchor chain under its new compiled type
  (#704). Returns the number of anchors re-signed.

  `mix kiln.promote_data` graduates a dynamic type into a compiled one, moving
  the documents and their version twins (ids and timestamps preserved) into the
  compiled type's tables. A document's anchors key on `resource_type`, which is
  `"entry"` while it is a generic dynamic document (`Firing.Engine.document_type/1`)
  and the compiled type's own atom afterwards. So without this, promotion
  orphans every anchor: `verify/4` reads nothing under the new type and returns
  `:unanchored`, and the next publish re-anchors from genesis over whatever the
  rows now say — the very laundering shape this module documents, reached here
  from a supported task rather than from database access.

  It cannot be fixed with a bare `UPDATE resource_type`: `resource_type` is
  inside the SIGNED payload (every shape, `anchor_payload_v5/8` down), so a
  repoint stops every signature verifying — that `UPDATE` *is* one of the hiding
  attacks the module docs enumerate. Instead each anchor is re-signed under the
  new type with the current key, oldest-first, so the `prev_anchor_digest` links
  re-propagate (the digest binds the predecessor's signature). Every other field
  — `chain_hash`, `version_count`, `sequence`, boundary, `attribution_hash` — is
  unchanged, because the version rows kept their ids and timestamps, so the
  result is byte-for-byte the chain an intact document would carry had it always
  been the compiled type.

  **A doctored chain is refused, not laundered.** Not recomputing `chain_hash`
  is necessary but not sufficient: re-signing over stored columns would mint a
  valid *current-key* signature over a `chain_hash` a DB-write attacker could
  have doctored to match doctored version rows — the signature was the ONLY
  thing catching that (`verify/4` read `:tampered`), and this would flip it to
  `:verified`. So before signing anything, every anchor is required to reproduce
  from the moved version rows (the same evidence `verdict/5` checks: hash, count,
  and attribution). Any anchor that does not reproduce raises, and the caller's
  transaction rolls the whole move back — promotion refuses to graduate a type
  whose history is already tampered. `mint`-parity: re-attestation signs
  *recomputed* evidence, never stored column values it did not re-derive.

  Likewise an anchor minted UNSIGNED (a keyless era, or a transient signing
  failure) stays unsigned — re-signing it with the current key would upgrade an
  advisory anchor to attested, an upgrade a natively-compiled document would not
  have. Only anchors that already carry a signature are re-signed.

  The anchor resource is append-only by design (no update/destroy action); this
  is the one authorized re-attestation, reached only from the dev-run promotion
  task with the signing key in hand, and it runs inside that task's transaction.
  A signed chain with no key available to re-sign it raises rather than silently
  breaking its signatures — the transaction then rolls the move back.

  One thing it does NOT carry over is the checkpoint witness (#666): the old
  witnessed entries key on `"entry"`, so the promoted document is uncovered by
  the witness until the next checkpoint runs under the new type — one interval,
  the documented exposure window. Tracked for a follow-up.
  """
  @spec repoint_after_promotion(
          module(),
          [Ash.UUID.t()],
          String.t(),
          String.t(),
          Ash.UUID.t() | nil
        ) ::
          non_neg_integer()
  def repoint_after_promotion(resource, source_ids, old_type, new_type, org_id) do
    signing? = match?({:ok, _}, Signer.key_id())

    Enum.reduce(source_ids, 0, fn source_id, total ->
      total + reattest_document(resource, source_id, old_type, new_type, org_id, signing?)
    end)
  end

  defp reattest_document(resource, source_id, old_type, new_type, org_id, signing?) do
    # An ungated, ASCENDING read: the rows exist regardless of the runtime kill
    # switch, and the `prev_anchor_digest` links must re-propagate oldest-first.
    anchors =
      CMS.list_history_anchors_for!(old_type, source_id,
        authorize?: false,
        tenant: org_id,
        query: [sort: [sequence: :asc]]
      )

    # The moved version rows, read once (ascending) so each anchor's stored hash
    # can be re-derived and checked before it is re-signed — never trust the
    # stored `chain_hash` we are about to bless with a fresh signature.
    versions = versions(resource, source_id, :all, org_id)

    {count, _prev_digest} =
      Enum.reduce(anchors, {0, nil}, fn anchor, {n, prev_digest} ->
        ensure_reproduces!(
          anchor,
          fold_loaded(versions, anchor.version_count),
          old_type,
          source_id
        )

        updated = reattest_anchor(anchor, new_type, prev_digest, source_id, signing?)
        {n + 1, anchor_digest(updated)}
      end)

    count
  end

  # The whole tamper half of `verdict/5`, applied UNGATED before re-signing (the
  # kill switch must not be a way to skip it). Two independent doctorings have to
  # be refused, and it takes both a hash check and a signature check to catch
  # them:
  #
  #   * a version row rewritten with the anchor's `chain_hash` left alone — the
  #     fold no longer reproduces the recorded hash (`computed.chain_hash !=`);
  #   * a version row rewritten AND `chain_hash` updated to match it — the fold
  #     now reproduces, so only the anchor's EXISTING signature (over the
  #     original hash, unforgeable without the key) still catches it.
  #
  # Either way the chain was already `:tampered`; re-signing it would mint a
  # valid current-key signature over doctored history — exactly the laundering
  # the module fights. So any anchor that does not reproduce raises, aborting the
  # promotion (the caller's transaction rolls the move back). `:unverifiable`
  # (signed under a key we do not hold) is NOT tampering — the hashes reproduce
  # and the operator is re-attesting with the current key — so it is allowed.
  defp ensure_reproduces!(anchor, computed, old_type, source_id) do
    cond do
      computed.version_count < anchor.version_count ->
        raise reattest_tamper(anchor, source_id, "anchored versions are missing")

      computed.chain_hash != anchor.chain_hash ->
        raise reattest_tamper(
                anchor,
                source_id,
                "anchored history does not reproduce its chain hash"
              )

      attribution_rewritten?(anchor, computed) ->
        raise reattest_tamper(anchor, source_id, "recorded author attribution does not reproduce")

      signature_broken?(anchor, old_type, source_id) ->
        raise reattest_tamper(anchor, source_id, "its existing signature does not verify")

      true ->
        :ok
    end
  end

  # An unsigned anchor has no signature to break (it is not re-signed anyway). A
  # signed anchor whose signature does not verify under a key we HOLD is
  # tampered; one we cannot check (`:unverifiable`, rotated/unregistered key) is
  # not — its hashes reproduced above, and the re-sign is a legitimate operator
  # re-attestation.
  defp signature_broken?(%{signature: nil}, _old_type, _source_id), do: false

  defp signature_broken?(anchor, old_type, source_id),
    do: match?({:tampered, _}, signature_verdict(anchor, old_type, source_id))

  defp reattest_tamper(anchor, source_id, reason) do
    "refusing to promote: history anchor #{anchor.id} for document #{source_id} " <>
      "cannot be re-attested because #{reason}. Its chain is already tampered — " <>
      "re-signing it would launder that. Investigate before promoting this type."
  end

  defp reattest_anchor(anchor, new_type, prev_digest, source_id, signing?) do
    if not signing? and not is_nil(anchor.signature) do
      raise """
      cannot re-attest signed history anchor #{anchor.id} without the provenance \
      signing key. Re-pointing its resource_type would break the signature it \
      already carries. Configure KILN_PROVENANCE_PRIVATE_KEY (the key that signed \
      it, or a current one registered as a retired key) and re-run the promotion.
      """
    end

    staged = %{anchor | resource_type: new_type, prev_anchor_digest: prev_digest}

    # Re-sign iff the anchor was ALREADY signed — the decision keys on the
    # anchor's own state, never on whether the deployment now holds a key. An
    # anchor minted unsigned (a keyless era, or a transient signing failure that
    # stored `{nil, nil}` loudly) stays unsigned: re-signing it with the current
    # key would upgrade an advisory anchor to attested, which is NOT the chain a
    # natively-compiled document would carry, and on a keyless-then-keyed
    # deployment would bless a `chain_hash` an attacker could have recomputed —
    # the exact laundering the module fights. It still gets its `resource_type`
    # and (cascaded) `prev_anchor_digest` repointed; there is no signature to
    # invalidate. A signed anchor is re-signed under the new type on the shape
    # `payload_candidates/3` offers first — the one `verify/4` matches — and the
    # guard above has already ensured a key is available to do it.
    {signature, key_id} =
      if is_nil(anchor.signature) do
        {nil, nil}
      else
        [payload | _] = payload_candidates(staged, new_type, source_id)
        sign(payload)
      end

    Repo.query!(
      "UPDATE history_anchors " <>
        "SET resource_type = $1, prev_anchor_digest = $2, signature = $3, key_id = $4 " <>
        "WHERE id = $5",
      [new_type, prev_digest, signature, key_id, Ecto.UUID.dump!(anchor.id)]
    )

    %{staged | signature: signature, key_id: key_id}
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

      # Attribution (#713), extended over the fresh tail exactly as `chain_hash`
      # is — O(new), which is what keeps `anchor_every_write` affordable. The
      # seed is the predecessor's `attribution_hash` when it has one; the first
      # v5 anchor (its predecessor is pre-#713, or there is none) has nothing to
      # extend, so it folds the whole covered set from genesis this once, the
      # same one-off `chain_hash` pays on a fresh chain.
      attribution = mint_attribution(scope, previous, fresh, computed.version_count)

      # Publishes are the compliance-critical anchors and are rare, so they pay
      # one count to check the same invariant even when they did fold something.
      if allow_empty?, do: warn_on_skew(scope, type, previous, computed.version_count)

      sequence = next_sequence(previous)

      {signature, key_id} =
        sign(
          anchor_payload_v5(
            type,
            record.id,
            computed,
            previous,
            prev_digest,
            boundary,
            sequence,
            attribution
          )
        )

      CMS.create_history_anchor!(
        %{
          resource_type: type,
          source_id: record.id,
          chain_hash: computed.chain_hash,
          attribution_hash: attribution,
          version_count: computed.version_count,
          last_version_id: boundary.id,
          last_version_at: boundary.at,
          published_version_id: Map.get(record, :published_version_id),
          signature: signature,
          key_id: key_id,
          actor_id: opts[:actor_id],
          prev_anchor_id: previous && previous.id,
          prev_anchor_digest: prev_digest,
          sequence: sequence
        },
        authorize?: false,
        tenant: record.org_id
      )

      :ok
    end
  end

  defp seed(nil), do: {@genesis, 0}
  defp seed(anchor), do: {anchor.chain_hash, anchor.version_count}

  # Attribution for a new anchor (#713). A v5 predecessor's `attribution_hash`
  # seeds the fold over the fresh tail — O(new), the same shape as `chain_hash`.
  # A predecessor that is pre-#713 (nil) or absent has nothing to extend, so the
  # first v5 anchor of a document folds its whole covered set from genesis once,
  # reading it here; every anchor after it stays incremental.
  defp mint_attribution(_scope, %{attribution_hash: seed}, fresh, _count) when is_binary(seed),
    do: attribution_fold(seed, fresh)

  defp mint_attribution(scope, _previous, _fresh, count) do
    scope.resource
    |> versions(scope.source_id, count, scope.org_id)
    |> attribution_hash()
  end

  # 1-based, assigned at write time (#666).
  #
  # A read-then-write, and `mint/3` runs in `after_transaction` — outside the
  # document's own transaction — so two concurrent mints read the same
  # predecessor and pick the same number. The UNIQUE index on
  # `(org_id, resource_type, source_id, sequence)` is what makes that safe: the
  # loser's insert fails and lands in `anchor/2`/`extend/2`'s rescue as a logged
  # skip. Without it both rows land, the run reads `[2, 2, 1]`, and the document
  # is permanently and falsely `{:tampered, …}` — anchors have no destroy
  # action, so there is no repair.
  defp next_sequence(nil), do: 1
  defp next_sequence(%{sequence: n}), do: n + 1

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
      signing key was configured when it was minted, or the key failed to
      resolve at mint time). When any anchor below the head IS attested, this
      verdict is only reachable after the fold has also reproduced that
      anchor — an unattested head never softens a verdict the attested
      history contradicts (#708).
    * `:unverifiable` — prefix intact and the anchor IS signed, but no key
      matching the anchor's `key_id` is available: it was rotated out and
      never registered in `retired_keys`, or no key is configured at all.
      Deliberately distinct from tampering — we cannot attest this anchor, but
      nothing says it is bad. Registering the retired key's public half
      (`KilnCMS.Provenance.KeyRegistry`) turns these back into `:verified`.
    * `:unanchored` — the document has no anchors yet (never published since
      anchoring was enabled) **and** no checkpoint ever saw it anchored.
    * `{:tampered, reason}` — the anchored history no longer reproduces the
      hash (altered/deleted/reordered versions), the signature fails against a
      key we DO hold, the chain is shorter than the last checkpoint witnessed,
      or an unattested head sits over an attested anchor whose prefix no
      longer reproduces (#708 — what an INSERTed forged head looks like).
      Not holding the key is `:unverifiable`, above.

  Only the anchored prefix is covered — edits since the last publish anchor
  at the next publish. Callers that need to show that window use
  `unanchored_tail/2` (the governance trail displays it).
  """
  @spec verify(module(), String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: verdict()
  def verify(resource, type, source_id, org_id) do
    all = anchors(type, source_id, org_id)
    scope = %{resource: resource, source_id: source_id, org_id: org_id}

    with witnessed when is_atom(witnessed) <- witness_intact(all, type, source_id, org_id),
         [anchor | _] <- all,
         {:judged, attested, newest_attested} <- judged_chain(all),
         :ok <-
           attested_baseline(
             anchor,
             newest_attested,
             &compute(resource, source_id, org_id, &1),
             &covered_by_query(scope, &1),
             type,
             source_id
           ) do
      verdict(
        anchor,
        compute(resource, source_id, org_id, anchor.version_count),
        type,
        source_id,
        covered_by_query(scope, anchor)
      )
      # ONE floor over both, not two chained calls. `floor_to/2` sets the verdict
      # rather than lowering it, so `|> floor_to(attested) |> floor_to(witnessed)`
      # let the second overwrite the first: an `:unverifiable` chain plus an
      # `:unsigned` witness came out `:unsigned`, which reads as the benign
      # "no key configured" rather than the weaker "signed by a key we do not
      # hold". `weaker/2` is this module's own ordering of exactly that.
      |> floor_to(weaker(attested, witnessed))
    else
      # No anchors, and no checkpoint says there should be — a document that has
      # never been published since anchoring was enabled.
      [] -> :unanchored
      {:tampered, _} = tampered -> tampered
    end
  end

  # The witness comparison (#666): what an external checkpoint last recorded for
  # this document, against what it heads at now.
  #
  # This is the only check here that can see a chain that is *shorter* than it
  # was. Everything else `verify/4` does is computed from rows the attacker also
  # controls, so a truncated chain is internally consistent by construction —
  # see `KilnCMS.Governance.Checkpoint`.
  #
  # `:ok` when no checkpoint covers the document, which is the honest answer for
  # one created since the last run, and for a deployment that has not minted one
  # yet. A checkpoint that cannot be judged floors the verdict rather than being
  # skipped, for the same reason an unjudgeable anchor does.
  #
  # `:unreadable` is that rule applied to the witness itself. An entry whose
  # columns will not load is not an absent entry, and treating it as one was a
  # one-statement kill: `proof` is a `jsonb[]` Postgres accepts any JSON into and
  # Ecto raises on, so `UPDATE … SET proof = ARRAY['"x"'::jsonb]` on a single row
  # turned the witness off for that document with nothing but a log line.
  # The anchoring kill switch gates this too. `anchors/4` returns `[]` when
  # `:audit_anchors_enabled` is off, and the checkpoint switch is a separate
  # flag — so without this gate, an operator turning anchoring off on a
  # deployment that had already minted checkpoints turned every witnessed
  # document `{:tampered, "…it now has no anchors at all"}`, failing the whole
  # corpus in `mix kiln.audit.verify`. The switch stops anchoring; it is not a
  # claim that history was rewritten.
  defp witness_intact(anchors, type, source_id, org_id) do
    if enabled?() do
      case Checkpoint.witnessed_head(type, source_id, org_id) do
        :none -> :ok
        :unreadable -> :unverifiable
        {:tampered, _} = tampered -> tampered
        {:ok, entry, attestation} -> against_witness(anchors, entry, attestation)
      end
    else
      :ok
    end
  end

  # Every anchor gone, on a document a checkpoint saw anchored. Before the
  # witness this was `:unanchored` — indistinguishable from a document anchored
  # for the first time, which is what made wiping the set a laundering route
  # rather than an alarm.
  defp against_witness([], entry, _attestation) do
    {:tampered,
     "checkpoint #{entry.checkpoint_sequence} witnessed this document at anchor " <>
       "position #{entry.head_sequence}, and it now has no anchors at all"}
  end

  # The comparison is against the anchor **at the witnessed position**, not
  # against the head.
  #
  # Comparing heads was a one-extra-publish hole, and an easy one to write: with
  # `head.sequence > entry.head_sequence` read as ordinary growth, an attacker
  # deletes the witnessed anchor, doctors the versions, and lets two ordinary
  # publishes refill positions N and N+1. `next_sequence/1` closes the gap,
  # `chain_intact/1` sees a contiguous run with `version_count` rising, the head
  # is now *past* the witnessed position — and the verdict is `:verified` over
  # history the checkpoint committed to differently. Anchors are immutable, so
  # the anchor at a witnessed position must be *that* anchor forever, whatever
  # has been minted above it.
  defp against_witness(anchors, entry, attestation) do
    witnessed = Enum.find(anchors, &(&1.sequence == entry.head_sequence))

    cond do
      is_nil(witnessed) ->
        {:tampered,
         "anchor chain truncated: checkpoint #{entry.checkpoint_sequence} witnessed " <>
           "position #{entry.head_sequence}, which no surviving anchor occupies " <>
           "(the newest is at #{List.first(anchors).sequence})"}

      witnessed.id != entry.head_anchor_id or witnessed.chain_hash != entry.chain_hash ->
        {:tampered,
         "the anchor at position #{entry.head_sequence} is not the one checkpoint " <>
           "#{entry.checkpoint_sequence} witnessed there"}

      true ->
        # Anchors above the witnessed position are not yet covered, so truncating
        # back to it stays invisible. That window is one checkpoint interval
        # wide, which is why the cadence is a security parameter.
        attestation
    end
  end

  @doc """
  Whether a document's anchor chain is unbroken (#597, #666).

  Takes the document's **complete** anchor set, newest first. Complete is not a
  nicety: the position check below requires the run to reach 1, so a truncated
  or paginated list reads as a gap on a healthy chain. `anchors/4` takes a
  `limit` for callers that only want the head — do not feed one of those here.

  Four things must hold, and they are load-bearing in this order:

    * **Links resolve.** Every anchor but the first names its predecessor, and a
      named predecessor that is absent is a hole.
    * **Digests match.** The predecessor is also digested, so one that is present
      but rewritten is a hole too.
    * **Every anchor's signature verifies** — not just the head's. This is what
      makes the two checks below mean anything: without it, an attacker rewrites
      the attested columns of any anchor that is not currently the head, and
      every invariant computed over them is satisfiable. Not holding the key
      (rotation without registering the outgoing one) is never red, and an
      unsigned anchor is skipped rather than judged — `verdict/5` reports
      `:unsigned` for the deployment.
    * **Positions are sane.** Contiguous down to 1, and `version_count`
      non-decreasing along them.

  Returns `{:tampered, reason}` naming the break, or the strongest thing that
  can honestly be said about the chain's attestation: `:ok` when every anchor
  verified, `:unsigned` when any carries no signature, `:unverifiable` when any
  is signed with a key this deployment does not hold. `verify/4` uses that as a
  **floor** — a chain containing an anchor nobody can vouch for never reads
  `:verified`, whatever the hashes say.

  The floor is deliberately not a short-circuit. The hash comparison is the one
  check that needs no key at all, so it still runs and is still reported: real
  tampering reads `{:tampered, …}` even on a keyless deployment.

  Cost is one signature verification per anchor. On the publish-only default a
  document has a handful; with `anchor_every_write` it has one per save, and
  this runs on the governance page and in `mix kiln.audit.verify`. That is the
  price of the property, and it is paid on audit paths only — nothing on the
  delivery path verifies a chain.
  """
  @spec chain_intact([struct()]) :: :ok | :unsigned | :unverifiable | {:tampered, String.t()}
  def chain_intact(anchors) do
    case judged_chain(anchors) do
      {:judged, attested, _newest_attested} -> attested
      {:tampered, _} = tampered -> tampered
    end
  end

  # `chain_intact/1` plus the anchor that earned the judgement: the newest one
  # whose signature verifies under a held key, or nil when none does. The
  # verify functions need that anchor — not just the floor — to hold the
  # verdict's baseline to attested evidence (#708).
  defp judged_chain(anchors) do
    by_id = Map.new(anchors, &{&1.id, &1})

    with :ok <- links_intact(anchors, by_id),
         {:judged, _attested, _newest} = judged <- signatures_intact(anchors),
         :ok <- sequence_intact(anchors) do
      judged
    end
  end

  # `:verified` only survives a chain every anchor of which could be judged.
  # A tamper verdict is never softened — it was reached on the hashes, which
  # need no key.
  defp floor_to({:tampered, _} = tampered, _attestation), do: tampered
  defp floor_to(_verdict, :unsigned), do: :unsigned
  defp floor_to(_verdict, :unverifiable), do: :unverifiable
  defp floor_to(verdict, :ok), do: verdict

  # Every anchor, not only the head (#666).
  #
  # `verify/4` only ever signature-checked the baseline, which left every other
  # anchor's attested columns rewritable — and those columns are exactly what
  # the position checks are computed from. An attacker who could renumber a
  # non-head anchor, or lower its `version_count`, could satisfy contiguity and
  # monotonicity while promoting a short, early anchor to the head, putting the
  # doctored versions outside the anchored prefix.
  #
  # **An anchor that cannot be judged is not a pass.** Silently continuing past
  # one was a hole in its own right, and a one-column one: `anchor_digest/1`
  # covers neither `key_id` nor `sequence`, so `UPDATE … SET signature = NULL`
  # (or a bogus `key_id`) on a non-head anchor made it unjudgeable, after which
  # it could be renumbered into the baseline position with nothing objecting.
  # So the weakest outcome across the chain wins, and it is the verdict the
  # caller gets: a chain containing an anchor we cannot vouch for reads
  # `:unsigned` or `:unverifiable`, never `:verified`.
  #
  # That is also the honest answer for the benign cases it covers — a deployment
  # with no key, or one mid-rotation without the outgoing key registered. Both
  # already read that way from the head; now the whole chain has to earn it.
  # Returns the weakest judgement across the chain plus the newest anchor that
  # VERIFIED (anchors arrive newest-first, so the first hit is the newest —
  # what `attested_baseline/6` compares against, #708), or halts on the first
  # tampered one. All of it comes out of a single sweep: the RSA verification
  # is the expensive part of `chain_intact/1`, and walking twice to compute the
  # floor separately would have doubled it.
  defp signatures_intact(anchors) do
    Enum.reduce_while(anchors, {:judged, :ok, nil}, fn anchor, {:judged, weakest, attested} ->
      case anchor_signature(anchor) do
        {:tampered, _} = broken -> {:halt, broken}
        :verified -> {:cont, {:judged, weaker(weakest, :verified), attested || anchor}}
        judged -> {:cont, {:judged, weaker(weakest, judged), attested}}
      end
    end)
  end

  # The verdict's baseline is the head anchor, but `INSERT` on `history_anchors`
  # is enough to supply the head (#708): mint a row whose `chain_hash` is the
  # fold recomputed over doctored versions (needs no key), whose link columns
  # are recomputed from the predecessor's public columns (needs no key either),
  # and which either carries no signature or one under a key nobody holds.
  # `verdict/5` then reads `:unsigned`/`:unverifiable` — which the fleet sweep
  # passes — instead of the tamper verdict the signed history would earn.
  #
  # So when the head is not itself the newest attested anchor, the fold must
  # ALSO reproduce that anchor. Evidence decides, not configuration: an honest
  # chain whose head was minted unsigned (pre-key history, or a signing-key
  # hiccup — `sign/1` stores the anchor unsigned, loudly, rather than failing
  # the publish) still reproduces its attested prefix and keeps reading
  # `:unsigned`; a forged head over doctored attested history cannot.
  #
  # When nothing in the chain verifies there is no evidence to hold the verdict
  # to, and the floor (`:unsigned`/`:unverifiable`) already says exactly that.
  defp attested_baseline(_head, nil, _compute_at, _covered_for, _type, _source_id), do: :ok

  defp attested_baseline(%{id: id}, %{id: id}, _compute_at, _covered_for, _type, _source_id),
    do: :ok

  defp attested_baseline(_head, attested, compute_at, covered_for, type, source_id) do
    case verdict(
           attested,
           compute_at.(attested.version_count),
           type,
           source_id,
           covered_for.(attested)
         ) do
      {:tampered, reason} ->
        {:tampered,
         "the newest attested anchor (position #{attested.sequence}) is not reproduced: " <>
           reason}

      _judged ->
        :ok
    end
  end

  @typedoc """
  How far a chain's *attested* prefix reaches, relative to its head (#811).

    * `:none` — the newest anchor that verifies IS the head (or there are no
      anchors). Nothing is outside the attested prefix.
    * `:unattested` — no anchor in the chain verifies under a held key. There is
      no attested prefix at all. On a deployment that *holds* a key this is a
      stronger statement than a gap, not a weaker one, and callers should treat
      it as such: `anchor_digest/1` covers neither `key_id` nor `sequence`, so
      one `UPDATE … SET key_id = '<unknown>'` over a document's anchors makes
      every one of them unjudgeable while leaving every link intact.
    * `:disabled` — anchoring is switched off, so there are no rows to reason
      from and nothing is claimed.
    * `{:gap, attested_versions, head_versions}` — some anchor verifies, but a
      NEWER one does not. Versions past `attested_versions` are anchored and
      unattested.
  """
  @type attested_gap ::
          :none | :unattested | :disabled | {:gap, non_neg_integer(), non_neg_integer()}

  @doc """
  Whether this chain's attested prefix reaches its head (#811).

  `verify/4` holds a doctored head to the newest anchor that still verifies
  (#708) — but it can only constrain versions *within* that anchor's prefix. An
  attacker with INSERT **and** DELETE on `history_anchors` moves the doctoring
  past it: delete the verified head, doctor only the versions it covered,
  re-insert an unsigned anchor at the same position whose `chain_hash` is
  refolded over the doctored rows. The surviving attested prefix still
  reproduces, so `attested_baseline/6` is satisfied, and the head reads
  `:unsigned` — which is not a failure.

  Nothing inside `history_anchors` can tell that from an honest deployment whose
  signing key went away between publishes, because the two produce byte-identical
  tables. So this deliberately does **not** return a tamper verdict. It returns
  the fact both cases share — the attested prefix stops short of the head, and
  everything past it is attested by nothing — and leaves the judgement to a
  caller that knows more: `mix kiln.audit.verify` weighs it against whether a
  signing key is configured at all, and the checkpoint witness settles it
  outright when one is running (`witness_intact/4`).

  Separate from `verify/4` rather than folded into its verdict so the verdict
  ladder (and every dashboard, JSON and CSV consumer of it) is untouched. Callers
  should ask only about chains that came back `:unsigned`/`:unverifiable`: a
  `:verified` chain has an attested head by definition, and a tampered one has
  already failed.
  """
  @spec attested_gap(String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: attested_gap()
  def attested_gap(type, source_id, org_id) do
    # `:disabled` rather than `:none` when the kill switch is off, for the reason
    # `witness_intact/4` special-cases the same switch: `anchors/4` returns `[]`,
    # and answering "the attested prefix reaches the head" from zero rows is a
    # verdict manufactured out of configuration.
    if enabled?() do
      type |> anchors(source_id, org_id) |> gap_from()
    else
      :disabled
    end
  end

  @doc """
  As `attested_gap/3`, over an already-loaded **newest-first** anchor list.

  For a caller that has the anchors in hand — `KilnCMS.Governance.trail/3` loads
  them for the timeline — so the gap costs no second query. The order is the
  caller's responsibility: this reads `hd/1` as the head, and an ascending list
  would silently compare against the oldest anchor.
  """
  @spec attested_gap([struct()]) :: attested_gap()
  def attested_gap(anchors) when is_list(anchors), do: gap_from(anchors)

  defp gap_from([]), do: :none

  defp gap_from([head | _] = anchors) do
    case newest_verified(anchors) do
      nil ->
        :unattested

      %{id: attested_id} when attested_id == head.id ->
        :none

      attested ->
        # Only a STRICTLY shorter attested prefix leaves versions outside it.
        # `coverage_rises_with_position/1` rejects a decrease but permits equal
        # counts, so a head covering no more than its predecessor is reachable —
        # and reporting `{:gap, n, n}` there would print an empty, inverted
        # version range for a chain that has nothing beyond the attested prefix.
        if attested.version_count < head.version_count do
          {:gap, attested.version_count, head.version_count}
        else
          :none
        end
    end
  end

  # The newest anchor that verifies, halting on a tampered signature exactly as
  # `signatures_intact/1` does — an `Enum.find` would walk straight past one to
  # an older verified anchor and disagree with the baseline `verify/4` used.
  #
  # Cheap where it matters: an unsigned anchor short-circuits in
  # `anchor_signature/1` with no RSA work, so a keyless deployment pays nothing.
  defp newest_verified(anchors) do
    Enum.reduce_while(anchors, nil, fn anchor, none ->
      case anchor_signature(anchor) do
        :verified -> {:halt, anchor}
        {:tampered, _} -> {:halt, none}
        _unjudgeable -> {:cont, none}
      end
    end)
  end

  # `:ok`/`:verified` is the strongest, then `:unsigned`, then `:unverifiable` —
  # "signed with a key we do not hold" says less than "not signed at all",
  # because the former is also what a tampered `key_id` looks like.
  defp weaker(:unverifiable, _), do: :unverifiable
  defp weaker(_, :unverifiable), do: :unverifiable
  defp weaker(:unsigned, _), do: :unsigned
  defp weaker(_, :unsigned), do: :unsigned
  defp weaker(_, _), do: :ok

  defp anchor_signature(%{signature: nil}), do: :unsigned

  defp anchor_signature(anchor),
    do: signature_verdict(anchor, anchor.resource_type, anchor.source_id)

  defp links_intact(anchors, by_id) do
    anchors
    |> Enum.reject(&is_nil(&1.prev_anchor_id))
    |> Enum.reduce_while(:ok, fn anchor, :ok ->
      case link_intact(anchor, by_id) do
        :ok -> {:cont, :ok}
        broken -> {:halt, broken}
      end
    end)
  end

  # Two invariants over the signed positions (#666). Both are only meaningful
  # because `signatures_intact/1` above has already established that the columns
  # they read are attested.
  #
  # **Contiguous down to 1.** The predecessor links catch a middle anchor removed
  # while its successor survives. This catches the same removal when the
  # successor is removed too: the run is `[7, 6, 3, 2, 1]` and the hole is
  # visible even though every surviving link resolves.
  #
  # **`version_count` non-decreasing along them.** Contiguity alone is satisfied
  # by any permutation, and a permutation is exactly what would promote a short,
  # early anchor to the head — putting the doctored versions outside the anchored
  # prefix, which is the whole object of the attack. Anchors only ever fold
  # forward, so coverage rises with position by construction.
  #
  # Neither catches a clean truncation of the newest anchors: `[3, 2, 1]` after
  # deleting 5 and 4 is indistinguishable from a document anchored only three
  # times. Nothing inside the document's own anchor set can tell those apart —
  # see the module docs and #666.
  defp sequence_intact(anchors) do
    with :ok <- contiguous(anchors), do: coverage_rises_with_position(anchors)
  end

  defp contiguous(anchors) do
    sequenced = anchors |> Enum.map(& &1.sequence) |> Enum.sort(:desc)

    if sequenced == Enum.to_list(length(sequenced)..1//-1) do
      :ok
    else
      # Says what is true and stops. A run that is not contiguous has several
      # causes — a removed anchor, a renumbering, two minted at one position —
      # and naming only the first would send an operator looking for a deletion
      # that may not have happened.
      {:tampered,
       "anchor sequence is not contiguous down to 1: #{inspect(sequenced)}. " <>
         "An anchor was removed, renumbered, or duplicated."}
    end
  end

  defp coverage_rises_with_position(anchors) do
    anchors
    |> Enum.sort_by(& &1.sequence)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [earlier, later] -> later.version_count < earlier.version_count end)
    |> case do
      nil ->
        :ok

      [earlier, later] ->
        {:tampered,
         "anchor sequence is out of order: position #{later.sequence} covers " <>
           "#{later.version_count} versions but position #{earlier.sequence} " <>
           "covers #{earlier.version_count}, and anchors only fold forward"}
    end
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
    all = anchors(type, source_id, org_id)

    with witnessed when is_atom(witnessed) <- witness_intact(all, type, source_id, org_id),
         [anchor | _] <- all,
         {:judged, attested, newest_attested} <- judged_chain(all),
         :ok <-
           attested_baseline(
             anchor,
             newest_attested,
             &fold_loaded(versions, &1),
             &covered_loaded(versions, &1),
             type,
             source_id
           ) do
      verdict(
        anchor,
        fold_loaded(versions, anchor.version_count),
        type,
        source_id,
        covered_loaded(versions, anchor)
      )
      # ONE floor over both, not two chained calls. `floor_to/2` sets the verdict
      # rather than lowering it, so `|> floor_to(attested) |> floor_to(witnessed)`
      # let the second overwrite the first: an `:unverifiable` chain plus an
      # `:unsigned` witness came out `:unsigned`, which reads as the benign
      # "no key configured" rather than the weaker "signed by a key we do not
      # hold". `weaker/2` is this module's own ordering of exactly that.
      |> floor_to(weaker(attested, witnessed))
    else
      [] -> :unanchored
      {:tampered, _} = tampered -> tampered
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

      # Attribution (#713). A v5 anchor records a fold over the covered versions'
      # author and action type; when it no longer reproduces, a `user_id` was
      # rewritten while the chain hash — which never covered it — still checks
      # out. Only for anchors that recorded one (v5+); a pre-#713 anchor carries
      # nil and is not attested for attribution. On a keyed deployment the
      # `attribution_hash` is inside the signed payload, so an attacker who also
      # rewrites the column to match is caught below by `signature_verdict/3`.
      #
      # Attribution inherits the same truncation exposure as everything else in
      # `verify/4`: on a document with pre-#713 (v4, nil-attribution) anchors
      # underneath its v5 ones, deleting the v5 anchors back to a v4 head makes
      # the head un-attested for attribution, and nothing INSIDE the anchor set
      # distinguishes that from a younger chain — the Checkpoint witness (#666)
      # is the mitigation, exactly as for a truncated `chain_hash`.
      attribution_rewritten?(anchor, computed) ->
        {:tampered, "recorded author attribution does not reproduce"}

      is_nil(anchor.signature) ->
        :unsigned

      true ->
        signature_verdict(anchor, type, source_id)
    end
  end

  defp attribution_rewritten?(%{attribution_hash: nil}, _computed), do: false

  defp attribution_rewritten?(anchor, computed),
    do: anchor.attribution_hash != Map.get(computed, :attribution_hash)

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
  # matters most. The rescue must sit INSIDE the closure — the queries run when
  # `mismatch_reason/2` invokes it, not while this function builds it (#705).
  defp covered_by_query(scope, anchor) do
    fn ->
      try do
        case boundary_of(anchor) do
          nil -> nil
          key -> count_versions(scope) - count_after(scope, key)
        end
      rescue
        error ->
          Logger.warning(
            "History chain range count failed, reporting a bare mismatch: #{inspect(error)}"
          )

          nil
      end
    end
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

    v5 =
      anchor_payload_v5(
        type,
        source_id,
        computed,
        prev,
        anchor.prev_anchor_digest,
        boundary,
        anchor.sequence,
        anchor.attribution_hash
      )

    v4 =
      anchor_payload(
        type,
        source_id,
        computed,
        prev,
        anchor.prev_anchor_digest,
        boundary,
        anchor.sequence
      )

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
      # A recorded `attribution_hash` is the mark of a v5 anchor (#713) — `mint`
      # is now the only writer and always signs v5 with one. The v5 payload
      # differs byte for byte from every older shape, so this anchor can satisfy
      # only the v5 candidate; there is nothing to fall back to, and offering an
      # older shape as well would let its signature be re-used against a payload
      # that omits the attribution it was minted to attest.
      not is_nil(anchor.attribution_hash) ->
        [v5]

      # v4 is offered on every branch, including the ones that predate the
      # boundary column. `mint/3` signed v4 unconditionally before #713, and it
      # carries a nil boundary forward when its predecessor had one — so gating
      # v4 on `last_version_at` made a freshly minted anchor unverifiable against
      # its own signature, and since every anchor is now swept that would have
      # been permanent, with no destroy action to repair it. An older shape can
      # never match a v4 anchor anyway: the payloads differ byte for byte.
      #
      # Every anchor carries a `sequence`, but only those minted since #666 were
      # SIGNED with one — the rest were backfilled by the migration that added
      # the column. Nothing distinguishes the two by inspection, so both shapes
      # are offered and each anchor matches exactly one: the payloads differ byte
      # for byte, so a v4 anchor can only satisfy v4 and a v3 anchor only v3.
      #
      # The consequence, stated rather than glossed: a backfilled anchor's
      # position is not covered by its own signature. What holds it in place is
      # `chain_intact/1` — `version_count` rising with position, on columns that
      # ARE covered, so a short early anchor cannot be promoted to the head.
      not is_nil(anchor.last_version_at) ->
        [v4, v3]

      is_nil(anchor.prev_anchor_id) and is_nil(anchor.prev_anchor_digest) ->
        [v4, v3, v2, v1]

      true ->
        [v4, v3, v2]
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
    # Newest first by the SIGNED `sequence` (#666) — not by `inserted_at`, which
    # is attested by nothing and was therefore a way to change the verification
    # baseline without deleting anything. `sequence` is `NOT NULL` and unique per
    # document, so this is already a total order — no `id` tiebreak needed, and a
    # backward scan of a plain btree serves it as a top-1 with no sort node.
    #
    # Restated here rather than left to `for_content`'s own
    # `prepare build(sort: …)`: `Ash.Query.sort/3` APPENDS, so a `query:` sort
    # that disagreed would become a tiebreak of the resource's rather than
    # replacing it. Identical on purpose.
    query = [sort: [sequence: :desc]]
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

  # A second running fold, over the fields `item_digest/1` leaves out but an
  # editorial audit is most *for*: the author (`user_id`) and the action type
  # (#713). Kept separate from `chain_hash` so it can be added without
  # invalidating every anchor already minted — a v5 anchor records it, older
  # anchors carry `nil` and are simply not attested for attribution.
  #
  # `verify/4` always recomputes from genesis, so `attribution_hash/1` folds the
  # whole prefix. `mint` extends the predecessor's value over the fresh tail
  # instead (`attribution_fold/2`), keeping the O(new) cost the incremental
  # `chain_hash` has — and because folding the tail onto an honest prefix yields
  # the same digest as folding from genesis, the two agree on intact history.
  defp attribution_hash(versions), do: attribution_fold(@genesis, versions)

  defp attribution_fold(seed, versions) do
    Enum.reduce(versions, seed, fn version, prev ->
      Canonical.digest(%{"prev" => prev, "item" => attribution_item(version)})
    end)
  end

  defp attribution_item(version) do
    Canonical.digest(%{
      "version_id" => version.id,
      "user_id" => Map.get(version, :user_id),
      "action_type" => to_string(version.version_action_type)
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
  # `v: 4` adds `sequence`, for the same reason the boundary joined at v3: it
  # steers verification — it is the order `for_content` reads in and therefore
  # what picks the baseline — so it has to be attested (#666). The v3, v2 and v1
  # shapes below keep anchors minted by earlier releases verifying.
  # `v: 5` (#713) is `v: 4` plus `attribution_hash`. What every version bump here
  # shares: a field that must be attested joins the signed payload, and the older
  # shapes stay so anchors minted by earlier releases keep verifying. Because the
  # encoded payloads differ byte for byte, a v5 anchor's signature can only ever
  # satisfy the v5 candidate — see `payload_candidates/3`.
  defp anchor_payload_v5(type, source_id, computed, prev, prev_digest, boundary, sequence, attr) do
    Canonical.encode(%{
      "v" => 5,
      "type" => type,
      "source_id" => source_id,
      "chain_hash" => computed.chain_hash,
      "attribution_hash" => attr,
      "version_count" => computed.version_count,
      "prev_anchor_id" => prev && prev.id,
      "prev_anchor_digest" => prev_digest,
      "last_version_id" => boundary.id,
      "last_version_at" => boundary.at && DateTime.to_iso8601(boundary.at),
      "sequence" => sequence
    })
  end

  defp anchor_payload(type, source_id, computed, prev, prev_digest, boundary, sequence) do
    Canonical.encode(%{
      "v" => 4,
      "type" => type,
      "source_id" => source_id,
      "chain_hash" => computed.chain_hash,
      "version_count" => computed.version_count,
      "prev_anchor_id" => prev && prev.id,
      "prev_anchor_digest" => prev_digest,
      "last_version_id" => boundary.id,
      "last_version_at" => boundary.at && DateTime.to_iso8601(boundary.at),
      "sequence" => sequence
    })
  end

  # The pre-#666 signed shape.
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
