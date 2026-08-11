defmodule KilnCMS.Governance.Checkpoint do
  @moduledoc """
  Minting, publishing and reading org-wide anchor-chain checkpoints (#666).

  ## The hole this closes

  `KilnCMS.Governance.Chain` detects any alteration to a document's anchored
  history except one: deleting the **newest** anchors. Nothing points at the
  head, so a chain of three that used to be five is indistinguishable from a
  chain that was only ever three, and the surviving prefix still folds to its
  recorded hash. An attacker who doctors version *k* deletes the anchors
  covering it, leaves the rest, and the verdict is `:verified`.

  No column on the anchors fixes that, because the missing fact is not *in* the
  document — it is "how far had this got", and the attacker controls every row
  that could say so. So a checkpoint says it from outside: a signed Merkle
  commitment to every anchored document's head, minted on a schedule and
  published through `KilnCMS.Governance.Witness` to a sink the database
  credentials do not own.

  ## What one run does

  1. Read every document's head anchor for the org — one `DISTINCT ON` over
     `history_anchors`, not one query per document.
  2. Read the newest previously-witnessed head per document, for the delta.
  3. Build the Merkle tree over the **full** head set (a commitment to only the
     changed ones would say nothing about the document an attacker wants to
     look unchanged) and sign the root.
  4. Write the checkpoint and an entry — with its inclusion proof — for each
     document whose head moved.
  5. Hand the canonical checkpoint document to the witness adapter and record
     the receipt.

  ## Writing an entry can destroy evidence, so it is refused rather than risked

  A new entry supersedes the standing one. Writing it over a document whose
  witnessed anchor is gone therefore hands the attacker the erasure: truncate,
  let one ordinary write re-anchor, and the next scheduled run replaces the
  entry naming the real anchor with one naming the replacement. The cron would
  do the laundering. So `changed?/4` refuses on three conditions, and the third
  is the one that is easy to miss — the anchor now sitting at the witnessed
  position is not the one that was witnessed there, which a head-versus-head
  comparison cannot see because the head may legitimately have grown past it.

  The standing entry keeps the document red until someone looks. That is the
  correct behaviour for a tamper-evidence mechanism and the wrong one for a
  self-healing cache. The benign cause is worth naming too: restoring
  `history_anchors` from a backup older than the last checkpoint produces exactly
  this, and it should also be loud.

  ## What verification gets from it

  `witnessed_head/3` returns the **strongest standing** attested entry for a
  document, or an explicit reason it could not be trusted. `Chain.verify/4`
  compares the anchor at that entry's position against it — see there for the
  verdict rules. The entry is attested by four things together, and each closes a
  way of forging the others:

    * the **checkpoint's signature** over its root, sequence and links;
    * the **inclusion proof** from the entry's own columns to that root, so a
      rewritten entry does not reconstruct it;
    * a **non-empty proof** whenever the checkpoint covered more than one
      document — a one-leaf tree's root *is* its leaf, so without this, forging a
      checkpoint needs no proof at all: set `root` to the leaf you want attested
      and everything else passes;
    * `checkpoint_sequence` matching the checkpoint's signed `sequence`, so the
      denormalized ordering column cannot promote an entry.

  A checkpoint that cannot be judged — unsigned deployment, key rotated out —
  **floors** the verdict rather than being skipped, for the reason
  `Chain.chain_intact/1` documents at length: skipping what you cannot judge is
  the same hole one column over. So does an entry that cannot be *read*: `proof`
  is a `jsonb[]` Postgres accepts any JSON into and Ecto raises on, so returning
  "no witness" there was a one-statement kill cheaper than the deletion this
  defends against.

  ## What it still does not close

  Two limits, both structural rather than oversights:

    * **Anchors above the witnessed position are not witnessed.** Truncating back
      to the last witnessed position stays invisible, so the exposure window is
      one checkpoint interval wide. That is what makes the cadence a security
      parameter.
    * **Deleting the entry rows removes the witness**, and nothing in
      `verify/4` can see that — the same argument that made checkpoints necessary
      one level down. What closes it is `mix kiln.audit.checkpoint --audit`
      *enumerating the sink* and finding what the database no longer has, which
      only works with a real witness adapter configured.
  """
  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Governance.Merkle
  alias KilnCMS.Governance.Witness
  alias KilnCMS.Provenance.Canonical
  alias KilnCMS.Provenance.Signer

  @typedoc "What a document's strongest checkpoint entry says, or why it says nothing."
  @type witnessed ::
          {:ok, entry :: struct(),
           attestation :: :ok | :unsigned | :unverifiable | {:tampered, String.t()}}
          | :none
          | :unreadable
          | {:tampered, String.t()}

  # The attestation element carries `{:tampered, reason}` as well as the three
  # atoms, because `checkpoint_attestation/2` returns it when a signature
  # demonstrably fails to verify. It was declared as atoms only, and the first
  # consumer written against the declaration (#731's dashboard badge) rendered a
  # tampered checkpoint as a *green* one — dialyzer could not catch the missing
  # clause, because the declared success typing never contained the tuple.

  @doc "Whether checkpointing is enabled (default true; kill switch in config)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :governance_checkpoints_enabled, true)

  # ── minting ───────────────────────────────────────────────────────────────

  @doc """
  Mint (and publish) a checkpoint for one org.

  Returns `{:ok, checkpoint}`, or `{:error, reason}` when the checkpoint could
  not be written at all. Publication failing is **not** an error: the checkpoint
  row lands with `witness_error` set and the next run retries it, because a sink
  that is briefly unreachable must not cost the commitment.
  """
  @spec mint(Ash.UUID.t()) :: {:ok, struct()} | {:error, term()}
  def mint(org_id) do
    heads = current_heads(org_id)
    witnessed = witnessed_heads(org_id)
    covered_at = DateTime.utc_now()

    {leaves, changed} = tree_inputs(heads, witnessed, org_id)
    {root, proofs} = Merkle.build(leaves)

    previous = latest(org_id)
    sequence = next_sequence(previous)
    prev_digest = digest(previous)

    payload =
      checkpoint_payload(%{
        org_id: org_id,
        sequence: sequence,
        root: root,
        document_count: length(heads),
        covered_at: covered_at,
        prev_checkpoint_id: previous && previous.id,
        prev_checkpoint_digest: prev_digest
      })

    {signature, key_id} = sign(payload)

    attrs = %{
      sequence: sequence,
      root: root,
      document_count: length(heads),
      covered_at: covered_at,
      prev_checkpoint_id: previous && previous.id,
      prev_checkpoint_digest: prev_digest,
      signature: signature,
      key_id: key_id,
      witness: Witness.name()
    }

    # The checkpoint row and its entries are ONE transaction. Each Ash action is
    # otherwise its own, so a single failing entry insert — the unique index
    # firing under a cron overlap is the expected case — left a committed
    # checkpoint whose signed root covers the full head set beside a truncated
    # entry list. That is unrepairable and permanently red for any auditor who
    # recomputes the root, and `republish_pending/1` would then publish it.
    #
    # Publication is deliberately OUTSIDE: it is network I/O, and holding a
    # transaction open across an S3 round trip is its own problem.
    case commit(attrs, changed, proofs, org_id) do
      {:ok, {checkpoint, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, publish(checkpoint, org_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `return_notifications?: true` because these actions run inside an explicit
  # transaction: Ash cannot dispatch a notification from inside one, and drops it
  # with a warning. They are sent by the caller once the commit lands.
  defp commit(attrs, changed, proofs, org_id) do
    KilnCMS.Repo.transaction(fn ->
      case CMS.create_chain_checkpoint(attrs,
             authorize?: false,
             tenant: org_id,
             return_notifications?: true
           ) do
        {:ok, checkpoint, notifications} ->
          {checkpoint, notifications ++ write_entries(checkpoint, changed, proofs, org_id)}

        {:error, reason} ->
          KilnCMS.Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Publish a checkpoint that has no receipt yet, recording the outcome.

  **Every outcome is confirmed by reading the object back and comparing bytes**,
  including the one that looks like success. Two reasons, both of which were live
  defects before:

    * `:already_published` means *an* object occupies that key, which is not the
      same as *this* object. After a rolled-back `chain_checkpoints` the re-mint
      lands on a sequence the sink already holds with different contents — the
      exact fingerprint of the attack — and recording that as a green receipt is
      the worst possible answer.
    * A sink that silently ignores `If-None-Match` (several S3-compatible stores
      historically, or any proxy in front of one) returns `{:ok, _}` on an
      overwrite. Nothing else in the design would ever find that out, and the
      module doc's claim that "the 412 is how you find out" was only true of
      stores that implement it.

  A mismatch is recorded as a `witness_error`, never as a publication.
  """
  @spec publish(struct(), Ash.UUID.t()) :: struct()
  def publish(checkpoint, org_id) do
    if Witness.enabled?() do
      do_publish(checkpoint, org_id)
    else
      checkpoint
    end
  end

  defp do_publish(checkpoint, org_id) do
    key = Witness.key(org_id, checkpoint.sequence)
    body = document(checkpoint, org_id)

    case Witness.publish(key, body) do
      {:ok, receipt} -> confirm(checkpoint, org_id, key, body, receipt)
      {:error, :already_published} -> confirm(checkpoint, org_id, key, body, nil)
      {:error, reason} -> publication_failed(checkpoint, org_id, reason)
    end
  end

  defp confirm(checkpoint, org_id, key, body, receipt) do
    case Witness.fetch(key) do
      {:ok, ^body} ->
        record_publication(checkpoint, org_id, %{
          witness: Witness.name(),
          witness_receipt: receipt || %{"key" => key, "note" => "already present in the sink"},
          witnessed_at: DateTime.utc_now(),
          witness_error: nil
        })

      {:ok, _other} ->
        publication_failed(
          checkpoint,
          org_id,
          "the sink already holds a DIFFERENT document at #{key}. Either this deployment's " <>
            "checkpoint chain was rolled back, or the sink accepted an overwrite it should " <>
            "have refused"
        )

      {:error, reason} ->
        publication_failed(
          checkpoint,
          org_id,
          "published to #{key} but could not read it back: #{inspect(reason)}"
        )
    end
  end

  defp publication_failed(checkpoint, org_id, reason) do
    # `describe/1`, not `to_string/1`: adapters return raw terms — S3 gives
    # `{:http_error, 503, resp}` for anything that is not the 412 it names, and
    # the File adapter's rescue gives an `%ErlangError{}`. Interpolating either
    # raises `Protocol.UndefinedError` out of `publish/2`, which the worker's
    # blanket rescue then swallows — so the row never gets the `witness_error`
    # that is the operator's only signal, and a retry sweep aborts its remaining
    # checkpoints.
    described = describe_reason(reason)

    Logger.error(
      "Governance checkpoint #{checkpoint.sequence} for org #{org_id} was minted but is " <>
        "NOT witnessed at #{Witness.describe()}: #{described}. Until it is, the truncation " <>
        "guarantee holds only against an attacker who leaves chain_checkpoints alone. See #666."
    )

    record_publication(checkpoint, org_id, %{
      witness: Witness.name(),
      witness_error: described
    })
  end

  defp describe_reason(reason) when is_binary(reason), do: reason
  defp describe_reason(reason) when is_atom(reason), do: inspect(reason)
  defp describe_reason(reason), do: inspect(reason)

  @doc """
  The canonical JSON document published to the witness.

  Self-contained on purpose: an auditor holding one of these and the public key
  can check the signature and every entry's proof without the database. That is
  what makes the sink a witness rather than a backup.
  """
  @spec document(struct(), Ash.UUID.t()) :: binary()
  def document(checkpoint, org_id) do
    Canonical.encode(%{
      "kiln_checkpoint" => 1,
      "canonicalization" => Canonical.id(),
      "org_id" => org_id,
      "sequence" => checkpoint.sequence,
      "root" => checkpoint.root,
      "document_count" => checkpoint.document_count,
      "covered_at" => DateTime.to_iso8601(checkpoint.covered_at),
      "prev_checkpoint_id" => checkpoint.prev_checkpoint_id,
      "prev_checkpoint_digest" => checkpoint.prev_checkpoint_digest,
      "signature" => checkpoint.signature,
      "key_id" => checkpoint.key_id,
      "entries" =>
        checkpoint
        |> entries(org_id)
        |> Enum.map(fn entry ->
          Map.put(leaf_content(entry, org_id), "proof", entry.proof)
        end)
    })
  end

  # Every anchored document's head, one query. `DISTINCT ON` rather than a
  # per-document read: an org with ten thousand documents would otherwise cost
  # ten thousand round trips on a nightly job, and the ordering this needs is
  # exactly what the `(org_id, resource_type, source_id, sequence)` unique index
  # already provides.
  #
  # `sequence DESC` picks the head, matching `Chain.anchors/4`'s ordering — the
  # signed position, never `inserted_at`.
  defp current_heads(org_id) do
    {:ok, %{rows: rows}} =
      KilnCMS.Repo.query(
        """
        SELECT DISTINCT ON (resource_type, source_id)
               resource_type, source_id, id, sequence, chain_hash, version_count
        FROM history_anchors
        WHERE org_id = $1
        ORDER BY resource_type, source_id, sequence DESC
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    Enum.map(rows, fn [type, source_id, id, sequence, chain_hash, version_count] ->
      %{
        resource_type: type,
        source_id: Ecto.UUID.load!(source_id),
        head_anchor_id: Ecto.UUID.load!(id),
        head_sequence: sequence,
        chain_hash: chain_hash,
        version_count: version_count
      }
    end)
  end

  # The newest entry per document across every checkpoint this org has, keyed
  # for the delta comparison.
  #
  # `DISTINCT ON` for the same reason `current_heads/1` uses it, and it is worth
  # being explicit because the obvious Ash read is wrong here: the table grows
  # with every head that has ever *moved*, so reading it whole and reducing in
  # memory rehydrates the org's entire editorial history on every nightly mint.
  # The `(org_id, resource_type, source_id, checkpoint_sequence)` index serves
  # this directly.
  defp witnessed_heads(org_id) do
    {:ok, %{rows: rows}} =
      KilnCMS.Repo.query(
        """
        SELECT DISTINCT ON (resource_type, source_id)
               resource_type, source_id, head_anchor_id, head_sequence
        FROM chain_checkpoint_entries
        WHERE org_id = $1
        ORDER BY resource_type, source_id, checkpoint_sequence DESC
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    Map.new(rows, fn [type, source_id, head_anchor_id, head_sequence] ->
      {{type, Ecto.UUID.load!(source_id)},
       %{head_anchor_id: Ecto.UUID.load!(head_anchor_id), head_sequence: head_sequence}}
    end)
  end

  # Leaves for the whole head set (in a defined order, so the root is
  # reproducible), and the subset that needs a row written.
  defp tree_inputs(heads, witnessed, org_id) do
    ordered = Enum.sort_by(heads, &{&1.resource_type, &1.source_id})
    leaves = Enum.map(ordered, &Merkle.leaf(leaf_content(&1, org_id)))
    standing = standing_at_witnessed_positions(witnessed, org_id)

    changed =
      ordered
      |> Enum.with_index()
      |> Enum.filter(fn {head, _index} ->
        changed?(head, Map.get(witnessed, {head.resource_type, head.source_id}), standing, org_id)
      end)

    {leaves, changed}
  end

  defp changed?(_head, nil, _standing, _org_id), do: true

  # Whether this document's head has moved in a way worth recording — and,
  # crucially, whether recording it would DESTROY evidence.
  #
  # A new entry supersedes the old one, because `witnessed_head/3` reads the
  # strongest standing claim. So writing one over a document whose witnessed
  # anchor is gone hands the attacker the erasure: truncate, let one write
  # re-anchor at the same position, and the next scheduled mint replaces the
  # entry naming the real anchor with one naming the replacement. The nightly
  # cron would do the laundering.
  #
  # Three refusals, and the third is the one that is easy to miss:
  #
  #   * the head is BELOW what was witnessed — a truncated chain, or a restore
  #     from a backup older than the last checkpoint;
  #   * the head has not moved at all — nothing to say;
  #   * the anchor still sitting AT the witnessed position is not the one that
  #     was witnessed there. Anchors are immutable and positions are never
  #     reused, so this can only be a substitution. It is invisible to a
  #     head-versus-head comparison, since the head may legitimately have grown
  #     past it.
  defp changed?(head, previous, standing, org_id) do
    key = {head.resource_type, head.source_id}

    cond do
      head.head_sequence < previous.head_sequence ->
        refuse(
          head,
          org_id,
          "heads at anchor position #{head.head_sequence} but was " <>
            "witnessed at #{previous.head_sequence}"
        )

      head.head_anchor_id == previous.head_anchor_id ->
        false

      Map.get(standing, key) != previous.head_anchor_id ->
        refuse(
          head,
          org_id,
          "no longer carries the anchor checkpoint history witnessed at " <>
            "position #{previous.head_sequence}"
        )

      true ->
        true
    end
  end

  defp refuse(head, org_id, what) do
    Logger.error(
      "Governance checkpoint: #{head.resource_type} #{head.source_id} in org #{org_id} " <>
        "#{what}. Anchors are append-only, so this is a truncated or rewritten chain — or a " <>
        "restore from a backup older than the last checkpoint. No new entry is recorded, so " <>
        "the standing one keeps the document verifying as tampered until an operator " <>
        "resolves it. See #666."
    )

    false
  end

  # The anchors currently occupying the positions earlier checkpoints witnessed,
  # as `{resource_type, source_id} => anchor_id`. One query over the whole
  # witnessed set rather than one per document: `unnest` turns the pairs into a
  # join, so this stays a single round trip however many documents the org has.
  defp standing_at_witnessed_positions(witnessed, org_id) do
    pairs = Map.to_list(witnessed)

    if pairs == [] do
      %{}
    else
      source_ids = Enum.map(pairs, fn {{_type, id}, _} -> Ecto.UUID.dump!(id) end)
      sequences = Enum.map(pairs, fn {_key, %{head_sequence: n}} -> n end)

      {:ok, %{rows: rows}} =
        KilnCMS.Repo.query(
          """
          SELECT a.resource_type, a.source_id, a.id
          FROM history_anchors a
          JOIN unnest($2::uuid[], $3::bigint[]) AS w(source_id, sequence)
            ON a.source_id = w.source_id AND a.sequence = w.sequence
          WHERE a.org_id = $1
          """,
          [Ecto.UUID.dump!(org_id), source_ids, sequences]
        )

      Map.new(rows, fn [type, source_id, id] ->
        {{type, Ecto.UUID.load!(source_id)}, Ecto.UUID.load!(id)}
      end)
    end
  end

  # What the leaf commits to. `version_count` and `chain_hash` are in here as
  # well as the position, so replacing the head with a *different* anchor at the
  # same position is caught too — truncation is the headline case, not the only
  # one.
  #
  # `org_id` is in it because the leaf otherwise says what a document's head was
  # and never *who* asserted it. The tenant filter on the read and the `org_id`
  # inside the signed checkpoint payload already make a cross-org entry
  # unreachable, so this is belt-and-braces — but a leaf that omits the subject
  # of its own assertion is the kind of gap that becomes exploitable the moment
  # a caller forgets a tenant.
  defp leaf_content(head, org_id) do
    %{
      "org_id" => org_id,
      "resource_type" => head.resource_type,
      "source_id" => head.source_id,
      "head_anchor_id" => head.head_anchor_id,
      "head_sequence" => head.head_sequence,
      "chain_hash" => head.chain_hash,
      "version_count" => head.version_count
    }
  end

  defp write_entries(checkpoint, changed, proofs, org_id) do
    proofs = List.to_tuple(proofs)

    Enum.flat_map(changed, fn {head, index} ->
      {_entry, notifications} =
        CMS.create_chain_checkpoint_entry!(
          %{
            checkpoint_id: checkpoint.id,
            checkpoint_sequence: checkpoint.sequence,
            resource_type: head.resource_type,
            source_id: head.source_id,
            head_anchor_id: head.head_anchor_id,
            head_sequence: head.head_sequence,
            chain_hash: head.chain_hash,
            version_count: head.version_count,
            proof: elem(proofs, index)
          },
          authorize?: false,
          tenant: org_id,
          return_notifications?: true
        )

      notifications
    end)
  end

  defp record_publication(checkpoint, org_id, attrs) do
    CMS.record_checkpoint_publication!(checkpoint, attrs, authorize?: false, tenant: org_id)
  rescue
    error ->
      Logger.error("Recording checkpoint publication failed: #{inspect(error)}")
      checkpoint
  end

  # ── reading ───────────────────────────────────────────────────────────────

  @doc "This org's newest checkpoint, or nil."
  @spec latest(Ash.UUID.t()) :: struct() | nil
  def latest(org_id) do
    org_id |> recent(1) |> List.first()
  end

  @doc "This org's checkpoints, newest first."
  @spec recent(Ash.UUID.t(), pos_integer() | nil) :: [struct()]
  def recent(org_id, limit \\ nil) do
    query = if limit, do: [limit: limit], else: []

    CMS.list_chain_checkpoints!(authorize?: false, tenant: org_id, query: query)
  end

  @doc """
  Checkpoints minted but never published to the sink, oldest first.

  `limit` bounds the read. The backing action is an unpaginated
  `is_nil(witnessed_at)`, and on the `None` adapter *every* checkpoint an org has
  ever minted matches — forever. A caller that only needs a count and the oldest
  row (the dashboard panel, #731) must not load a year of them to get it, and the
  page that reports an outage is exactly the page that would get slowest as the
  outage lengthened.
  """
  @spec unwitnessed(Ash.UUID.t(), pos_integer() | nil) :: [struct()]
  def unwitnessed(org_id, limit \\ nil) do
    query = if limit, do: [limit: limit], else: []

    CMS.list_unwitnessed_checkpoints!(authorize?: false, tenant: org_id, query: query)
  end

  @doc """
  The entries recorded by one checkpoint, in the tree's own leaf order.

  Sorted **in Elixir**, not by `ORDER BY`. This list is embedded in the document
  the witness holds, and `mix kiln.audit.checkpoint --audit` compares those bytes
  exactly — so a Postgres text collation (the glibc 2.28 reorder, or an audit run
  against a replica with a different `lc_collate`) would reorder `resource_type`
  and report every historical checkpoint as altered. `tree_inputs/3` sorts the
  leaves the same way for the same reason.
  """
  @spec entries(struct(), Ash.UUID.t()) :: [struct()]
  def entries(checkpoint, org_id) do
    checkpoint.id
    |> CMS.list_checkpoint_entries_in!(authorize?: false, tenant: org_id)
    |> Enum.sort_by(&{&1.resource_type, &1.source_id})
  end

  @doc """
  The **strongest standing** attested checkpoint entry for one document.

  Strongest, not newest. Reading the newest was a one-row hole: a document
  witnessed at position 1 by checkpoint 1 and at position 3 by checkpoint 2 only
  needs the checkpoint-2 entry deleted for the surviving claim to be the weaker
  one, after which truncating to position 2 reads as ordinary growth. Entries are
  append-only assertions that a position held a given anchor, and deleting some
  of them must only ever remove claims — never demote the claim that remains.

  `:none` when the document was never witnessed — one younger than the last
  checkpoint, or a deployment that has not minted one yet. `:unreadable` when a
  row exists and will not load. `{:tampered, reason}` when an entry exists and
  does not hold up. Otherwise the entry and how strongly it is attested, which
  the caller floors its verdict to.
  """
  @spec witnessed_head(String.t(), Ash.UUID.t(), Ash.UUID.t()) :: witnessed()
  def witnessed_head(type, source_id, org_id) do
    if enabled?() do
      case latest_entry(type, source_id, org_id) do
        nil -> :none
        entry -> attest(entry, org_id)
      end
    else
      :none
    end
  rescue
    # `:unreadable`, NOT `:none`. This module's own rule is that skipping what
    # you cannot judge is the same hole one column over, and returning "no
    # witness" here broke it in the cheapest possible way: `proof` is an Ash
    # `{:array, :map}` over a `jsonb[]` column, so Postgres accepts any JSON into
    # it and Ecto raises on load. One `UPDATE … SET proof = ARRAY['"x"'::jsonb]`
    # on a single row therefore switched the witness off for that document, with
    # a log line as the only trace — cheaper than the deletion it defends
    # against, and it leaves the evidence visibly in place.
    #
    # The caller floors to `:unverifiable`. That is also the honest answer for
    # the benign case this rescue exists for: a deploy that has not run the
    # migration yet reads `:unverifiable` corpus-wide until it does, which is
    # loud but true, and self-heals. It is deliberately not `{:tampered, …}` —
    # an unreadable table is not evidence of tampering.
    error ->
      Logger.error(
        "Checkpoint lookup failed for #{type} #{source_id}; the document cannot be verified " <>
          "against its witness: #{inspect(error)}"
      )

      :unreadable
  end

  defp latest_entry(type, source_id, org_id) do
    CMS.list_checkpoint_entries_for!(type, source_id,
      authorize?: false,
      tenant: org_id,
      query: [limit: 1]
    )
    |> List.first()
  end

  # Three checks, and each one closes a way of forging the other two. See the
  # module docs.
  defp attest(entry, org_id) do
    case Ash.get(CMS.ChainCheckpoint, entry.checkpoint_id,
           authorize?: false,
           tenant: org_id,
           not_found_error?: false
         ) do
      {:ok, %{} = checkpoint} ->
        attest_against(entry, checkpoint, org_id)

      _ ->
        {:tampered,
         "checkpoint entry #{entry.id} names checkpoint #{entry.checkpoint_id}, " <>
           "which no longer exists"}
    end
  end

  defp attest_against(entry, checkpoint, org_id) do
    cond do
      entry.checkpoint_sequence != checkpoint.sequence ->
        {:tampered,
         "checkpoint entry #{entry.id} claims position #{entry.checkpoint_sequence} but " <>
           "checkpoint #{checkpoint.id} is at #{checkpoint.sequence}"}

      # A one-leaf tree's root IS its leaf, so an empty proof is legitimate there
      # and nowhere else. Without this, forging a checkpoint needs no proof at
      # all: insert a row whose `root` is the leaf you want attested, pair it
      # with `proof = '{}'`, and every other check passes. On the default
      # unsigned deployment that forgery is free, and its verdict (`:unsigned`)
      # is the one an honest keyless deployment shows daily.
      entry.proof == [] and checkpoint.document_count > 1 ->
        {:tampered,
         "checkpoint entry #{entry.id} carries no inclusion proof, but checkpoint " <>
           "#{checkpoint.sequence} committed to #{checkpoint.document_count} documents"}

      not Merkle.verify(Merkle.leaf(leaf_content(entry, org_id)), entry.proof, checkpoint.root) ->
        {:tampered,
         "checkpoint entry #{entry.id} is not included in the root checkpoint " <>
           "#{checkpoint.sequence} signed"}

      true ->
        {:ok, entry, checkpoint_attestation(checkpoint, org_id)}
    end
  end

  @doc """
  How strongly a checkpoint is attested: `:ok`, `:unsigned`, `:unverifiable`, or
  `{:tampered, reason}` when its signature fails under a key we DO hold.
  """
  @spec checkpoint_attestation(struct(), Ash.UUID.t()) ::
          :ok | :unsigned | :unverifiable | {:tampered, String.t()}
  def checkpoint_attestation(%{signature: nil}, _org_id), do: :unsigned

  def checkpoint_attestation(checkpoint, org_id) do
    payload =
      checkpoint_payload(%{
        org_id: org_id,
        sequence: checkpoint.sequence,
        root: checkpoint.root,
        document_count: checkpoint.document_count,
        covered_at: checkpoint.covered_at,
        prev_checkpoint_id: checkpoint.prev_checkpoint_id,
        prev_checkpoint_digest: checkpoint.prev_checkpoint_digest
      })

    case Signer.verify(payload, checkpoint.signature, checkpoint.key_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:tampered, "checkpoint #{checkpoint.sequence}'s signature does not verify"}
      {:error, _reason} -> :unverifiable
    end
  end

  @doc """
  Every broken predecessor link across an org's whole checkpoint run (#732).

  Each row signs its predecessor's id **and** a digest of that predecessor's
  contents, but until this nothing walked the run: `Chain.verify/4` attests only
  the single checkpoint an entry names, and the audit's contiguity check reads
  the sequence numbers, not the links. So a checkpoint whose *contents* were
  rewritten while its number was left alone was caught only by its own signature
  failing — which on an unsigned deployment it does not.

  Walking the links catches that, because a rewritten row's recomputed digest no
  longer matches what its successor recorded. It is the same walk
  `KilnCMS.Governance.Chain.chain_intact/1` does over anchors, for the same
  reason and with the same limits.

  Four ways a link is wrong, and each is a distinct edit an attacker has to make:

    * a checkpoint names a predecessor that is **gone** — the row was excised;
    * the named predecessor's **digest no longer matches** — its contents were
      rewritten in place, keeping its sequence;
    * a checkpoint past the first names **no predecessor at all** — the cheapest
      way to detach a row from the run, and invisible to a walk that simply
      skips null links;
    * the named predecessor is **not the immediately preceding sequence** — a
      link that jumps backwards over a surviving checkpoint, which contiguity
      alone cannot see because every number is still present.

  Returns messages, oldest checkpoint first; an empty list is a clean run.

  ## What this cannot do

  Three limits, and the first two are about the newest checkpoint specifically.

  **A clean truncation of the newest checkpoints.** A run of `[3, 2, 1]` after
  deleting 5 and 4 has intact links throughout. That is the argument that made
  checkpoints necessary in the first place, one level up.

  **A rewrite of the head.** Nothing records the newest checkpoint's digest —
  it has no successor — so its `root`, `document_count`, `covered_at` or
  `signature` can be changed in place and every link still resolves. The head
  carries the most recent commitments, so it is the more valuable target of the
  two.

  **A careful attacker.** `digest/1` is an unkeyed hash over public columns, so
  whoever rewrote checkpoint *k* can recompute `digest(k)`, write it into
  *k+1*'s `prev_checkpoint_digest`, and cascade to the head — where it
  terminates for free, by the limit above. On a deployment that signs nothing
  that is the whole cost.

  What it is, then: a check on a *careless* edit, and a multiplier against a
  careful one — because `prev_checkpoint_digest` is inside `document/2`,
  cascading forces the attacker to rewrite every published object after the
  doctored row, turning one witness mismatch into many. All three limits are
  answered by the same thing: the external witness, and the audit's enumeration
  of keys the database no longer accounts for.

  Deliberately not called from `verify/4`: loading an org's whole run once per
  audit is affordable, and doing it per document on the governance dashboard is
  not. Same reasoning that put the inclusion proofs on the entries.
  """
  @spec link_failures([struct()]) :: [String.t()]
  def link_failures(checkpoints) do
    by_id = Map.new(checkpoints, &{&1.id, &1})

    checkpoints
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(&link_failure(&1, by_id))
  end

  # Sequence 1 is the genesis checkpoint and correctly names nothing — BOTH
  # columns, as `Chain.links_intact/2` requires of a genesis anchor. A stray
  # digest beside a null id is caught by the successor's link too (it changes
  # `digest/1`), but saying it here names the doctored row rather than the one
  # that noticed.
  defp link_failure(%{sequence: 1, prev_checkpoint_id: nil, prev_checkpoint_digest: nil}, _by_id),
    do: []

  defp link_failure(%{sequence: 1, prev_checkpoint_id: nil}, _by_id),
    do: ["checkpoint 1 is the first in the run but records a predecessor digest"]

  defp link_failure(%{sequence: 1} = checkpoint, _by_id) do
    [
      "checkpoint 1 is the first in the run but names predecessor " <>
        "#{checkpoint.prev_checkpoint_id}"
    ]
  end

  defp link_failure(%{prev_checkpoint_id: nil} = checkpoint, _by_id) do
    # Nulling one column detaches a row from the run. A walk that only rejects
    # null links before comparing digests would skip straight past it.
    [
      "checkpoint #{checkpoint.sequence} names no predecessor, but the run does " <>
        "not start until 1"
    ]
  end

  defp link_failure(checkpoint, by_id) do
    case Map.fetch(by_id, checkpoint.prev_checkpoint_id) do
      :error ->
        [
          "checkpoint #{checkpoint.sequence} names predecessor " <>
            "#{checkpoint.prev_checkpoint_id}, which no longer exists"
        ]

      {:ok, prev} ->
        digest_failure(checkpoint, prev) ++ position_failure(checkpoint, prev)
    end
  end

  defp digest_failure(checkpoint, prev) do
    if digest_matches?(prev, checkpoint.prev_checkpoint_digest) do
      []
    else
      [
        "checkpoint #{checkpoint.sequence} does not match the contents of " <>
          "predecessor #{prev.sequence} it names — that row was rewritten"
      ]
    end
  end

  # Three shapes, not two. A link pointing FORWARD (or at itself) skips nothing,
  # and saying "skipping N" would send an operator hunting a deletion that never
  # happened.
  defp position_failure(%{sequence: n}, %{sequence: prev_n}) when prev_n == n - 1, do: []

  defp position_failure(%{sequence: n}, %{sequence: prev_n} = prev) when prev_n >= n do
    [
      "checkpoint #{n} names #{prev_n} (#{prev.id}) as its predecessor, which is not " <>
        "earlier than it — the run is not ordered"
    ]
  end

  defp position_failure(%{sequence: n}, %{sequence: prev_n} = prev) do
    [
      "checkpoint #{n} links back to #{prev_n} (#{prev.id}), skipping " <>
        "#{n - 1} — the run is threaded around a surviving checkpoint"
    ]
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp next_sequence(nil), do: 1
  defp next_sequence(%{sequence: n}), do: n + 1

  @doc """
  A digest over a checkpoint's identity and contents, recorded by its successor.

  Same *reason* as `KilnCMS.Governance.Chain.anchor_digest/1`: the id alone would
  let a deleted predecessor be replaced by a forged row reusing it. `digest/1` is
  `digest/2` at `newest_digest_version/0` — every writer (`mint/1`) and every
  existing caller wants "the current shape" and none passes a version.

  ## Versions (#892)

  **v1** hashes `id`, `sequence`, `root`, `document_count`, `signature` and the
  two link columns — but not `covered_at`, `key_id` or `org_id`, all three of
  which `document/2` carries and two of which `checkpoint_payload/1` signs. So
  under v1 a row whose `covered_at` is moved forward, or whose `key_id` is
  pointed at a key nobody holds, produces an identical digest and is invisible
  to `link_failures/1`. `key_id` is the same one-column hole `Chain` catalogues
  for anchors; nulling `signature`, by contrast, *was* already caught.

  **v2** adds `covered_at` and `key_id` to close that. `org_id` deliberately
  does **not** join the digest: it is already in the *signed* set
  (`checkpoint_payload/1`), which is the stronger guarantee where a witness is
  configured, and adding it here would need every caller of `digest/2` to also
  carry an org id, which the hand-built test fixtures and `link_failure/2`'s
  walk (keyed on checkpoint structs alone) do not.

  Widening `digest/1`'s coverage could not be a one-line edit: its output is
  already embedded in every existing `prev_checkpoint_digest`, so changing the
  input set outright would retro-break every recorded run — `link_failures/1`
  would report every checkpoint ever minted as tampered the moment the code
  deployed. `digest_matches?/2` is what actually gets used for comparison; it
  tries versions newest-first, the same fallback shape
  `Chain.signature_verdict/3` uses for `anchor_payload`. Unlike the anchor
  side, no stored version tag is needed: none of v1's or v2's covered columns
  are ever absent on a real row, so "does the newest shape match" is decidable
  outright, with nothing to disambiguate by content.

  **Not retroactive.** `prev_checkpoint_digest` is written once, at mint time;
  there is no migration here that recomputes it. A link minted before this
  shipped stays exactly as v1-shaped, and as unprotected on `covered_at`/
  `key_id`, as it always was — v2 protects checkpoints minted from here
  forward, not history already on disk.
  """
  @spec digest(struct() | nil) :: String.t() | nil
  def digest(checkpoint), do: digest(checkpoint, newest_digest_version())

  @doc "`digest/1` at an explicit version — see its docs for what each covers."
  @spec digest(struct() | nil, pos_integer()) :: String.t() | nil
  def digest(nil, _version), do: nil

  def digest(checkpoint, 1) do
    hash_digest(%{
      "id" => checkpoint.id,
      "sequence" => checkpoint.sequence,
      "root" => checkpoint.root,
      "document_count" => checkpoint.document_count,
      "signature" => checkpoint.signature,
      "prev_checkpoint_id" => Map.get(checkpoint, :prev_checkpoint_id),
      "prev_checkpoint_digest" => Map.get(checkpoint, :prev_checkpoint_digest)
    })
  end

  def digest(checkpoint, 2) do
    hash_digest(%{
      "id" => checkpoint.id,
      "sequence" => checkpoint.sequence,
      "root" => checkpoint.root,
      "document_count" => checkpoint.document_count,
      "covered_at" => digest_timestamp(Map.get(checkpoint, :covered_at)),
      "key_id" => Map.get(checkpoint, :key_id),
      "signature" => checkpoint.signature,
      "prev_checkpoint_id" => Map.get(checkpoint, :prev_checkpoint_id),
      "prev_checkpoint_digest" => Map.get(checkpoint, :prev_checkpoint_digest)
    })
  end

  @doc """
  Whether `recorded_digest` is `checkpoint`'s digest — under the newest shape
  `digest/1` would compute today, or any earlier one it could have been
  written under (#892). This is what `link_failures/1` compares with, so a
  link minted before the widening keeps verifying afterward rather than the
  whole prior history reporting as tampered on deploy.
  """
  @spec digest_matches?(struct() | nil, String.t() | nil) :: boolean()
  def digest_matches?(checkpoint, recorded_digest) do
    Enum.any?(1..newest_digest_version(), &(digest(checkpoint, &1) == recorded_digest))
  end

  @doc false
  # The version `digest/1` and `mint/1` write at. Bump when a digest version is
  # added; `digest_matches?/2` picks up every version up to this one.
  @spec newest_digest_version() :: pos_integer()
  def newest_digest_version, do: 2

  defp hash_digest(fields) do
    :sha256 |> :crypto.hash(Canonical.encode(fields)) |> Base.encode16(case: :lower)
  end

  # `document/2` and `checkpoint_payload/1` both stringify `covered_at` before
  # canonicalizing, because `Canonical.encode/1` has no clause for a bare
  # `DateTime` struct. The hand-built checkpoint fixtures in
  # `governance_witness_test.exs` predate v2 and carry no `covered_at` key at
  # all, so `Map.get/2` above already answers `nil` for them — passed through
  # unchanged rather than crashing on `DateTime.to_iso8601(nil)`.
  defp digest_timestamp(%DateTime{} = covered_at), do: DateTime.to_iso8601(covered_at)
  defp digest_timestamp(other), do: other

  # `org_id` is inside the payload: a checkpoint is an org-wide statement, and
  # without it a checkpoint from a quiet org could be moved onto a busy one,
  # where its lower `document_count` and shorter head set would look like an
  # honest earlier state.
  defp checkpoint_payload(fields) do
    Canonical.encode(%{
      "v" => 1,
      "org_id" => fields.org_id,
      "sequence" => fields.sequence,
      "root" => fields.root,
      "document_count" => fields.document_count,
      "covered_at" => DateTime.to_iso8601(fields.covered_at),
      "prev_checkpoint_id" => fields.prev_checkpoint_id,
      "prev_checkpoint_digest" => fields.prev_checkpoint_digest
    })
  end

  # Same contract as `Chain.sign/1`: an unresolvable key is logged loudly rather
  # than silently degrading to an unsigned commitment, since an unsigned
  # checkpoint still *looks* like a witness on the dashboard.
  defp sign(payload) do
    with {:ok, signature} <- Signer.sign(payload),
         {:ok, key_id} <- Signer.key_id() do
      {signature, key_id}
    else
      {:error, reason} ->
        Logger.warning(
          "Governance checkpoint stored UNSIGNED - provenance signing key unavailable: " <>
            KilnCMS.Keys.describe_error(reason)
        )

        {nil, nil}
    end
  end
end
