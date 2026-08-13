defmodule Mix.Tasks.Kiln.Audit.Verify do
  @shortdoc "Verify tamper-evident history anchors (#356)"

  @moduledoc """
  Recompute every anchored document's version chain and compare it against the
  latest recorded (signed) anchor:

      mix kiln.audit.verify

  Prints one line per anchored document and exits non-zero if any chain fails
  to reproduce its anchor — i.e. anchored history was altered, deleted, or
  reordered, or an anchor signature made under the currently configured key no
  longer verifies. Edits newer than a document's latest anchor are covered at
  its next publish.

  ## `intact (unsigned)` does not always mean the whole chain (#811)

  A chain can have anchors that verify AND a newer one that does not. When it
  does, `verify/4` can only hold the document to the newest *attested* anchor's
  prefix — so versions past that point are anchored by a row nothing attests,
  and the old wording ("intact (unsigned)") claimed more than was known.

  Those documents now print the version the attestation actually reaches:

      post/my-post (…): ATTESTED ONLY TO VERSION 2 — versions 3-3 are anchored
      but unsigned, so nothing attests them

  That shape is exactly what an attacker with INSERT **and** DELETE on
  `history_anchors` produces: delete the verified head, doctor only the versions
  it covered, re-insert an unsigned anchor refolded over the doctored rows. It is
  also exactly what an honest deployment produces when its signing key goes away
  between publishes — the two are byte-identical inside the table, which is why
  this is reported rather than called tampering.

  **The exit code splits on whether a key is configured**, because that is the
  only thing that distinguishes them from here. A deployment that can sign and
  did not is an anomaly to explain, and fails the run. A deployment with no key
  configured is describing a choice its operator made, and does not.

  A chain where **nothing** verifies is reported on the same terms, and for a
  sharper reason: `Chain.anchor_digest/1` covers neither `key_id` nor `sequence`,
  so a single `UPDATE … SET key_id = '<unknown>'` makes every anchor of a
  document unjudgeable while leaving every link and every sequence number intact.
  That is a cheaper primitive than the DELETE #811 describes, and it would
  otherwise land in the same silent `intact (…)` line. On a keyed deployment,
  "no anchor here verifies" is at least as much of an anomaly as a short prefix.

  Neither case is settled by this task. The checkpoint witness is what settles
  it — see `mix kiln.audit.checkpoint` and #666. With the default `None` witness,
  this task's guarantee against laundering beyond the attested prefix is only as
  strong as an operator reading these lines.

  ## A TAMPERED line may be the #598 bug, not tampering (#1058)

  #598 fixed the CAUSE of a false `{:tampered, …}` — a version row that became
  visible late no longer sorts into an already-anchored range — but it could
  not repair a document that had already hit it: that anchor committed to an
  order the table no longer holds, and the verdict stays red forever. A
  deployment upgrading past #598 keeps a population of permanently-red
  documents sitting next to any that are genuinely tampered, and the two
  verdicts are byte-identical.

  A TAMPERED line is annotated when the chain COULD be that bug — at least one
  of its anchors predates #598 (`payload_version` is nil rather than `6`, so
  its fold order was inferred from a timestamp rather than assigned at write
  time):

      post/my-post (…): TAMPERED — anchored history does not reproduce the
      recorded chain hash (chain predates the #598 fold-order fix — this may
      be the ordering bug rather than tampering; see #1058)

  This is a triage hint, not a softer verdict: the exit code and the failure
  count both still treat it as tampering. It exists so a sweep with a handful
  of unexplainable reds can be read as "these are worth investigating first"
  instead of N identical alarms.
  """
  use Mix.Task

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Governance.Chain
  alias KilnCMS.Provenance.KeyRegistry
  alias KilnCMS.Provenance.Signer

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    # One signing-key resolution for the whole sweep, not one per anchor (#643).
    # Every `Chain.verify` below resolves the active + retired keys to check an
    # anchor's signature; across all orgs × types × records that is the same
    # file reads and PEM parses repeated per document, and an unreadable retired
    # path warns once per document — burying the TAMPERED lines this task exists
    # to surface. The scope is this run only, so a key rotated before the next
    # run is still picked up.
    KeyRegistry.with_cache(&verify_all/0)
  end

  defp verify_all do
    # Resolved ONCE for the whole sweep. `Signer.key_id/0` is uncached on
    # failure, so calling it per decision let a transient resolution error
    # report "no signing key is configured" and pass the run in the same
    # breath as finding gaps — and the condition that CREATES gaps (the key
    # went away) is exactly the condition that would suppress reporting them.
    keyed? = match?({:ok, _key_id}, Signer.key_id())

    # Strict tenancy (#419): verify per org — the content/version reads and the
    # dynamic-type registry both require a tenant.
    results =
      for org_id <- KilnCMS.Accounts.list_org_ids(),
          ct <- ContentTypes.all_for_org(org_id),
          # Minimal select — the verifier needs identity, not block trees. The
          # dynamic tier shares the :entry storage resource, which is also what
          # the publish hook keys anchors on.
          record <-
            ContentTypes.list!(ct,
              authorize?: false,
              tenant: org_id,
              query: [select: [:id, :slug, :org_id]]
            ),
          storage = to_string(ContentTypes.storage_type(ct)),
          verdict = Chain.verify(ct.resource, storage, record.id, record.org_id),
          verdict != :unanchored do
        # Only asked about chains that did not come back `:verified`: a verified
        # chain has an attested head by definition, and a tampered one has
        # already failed. Keeps the extra signature pass off the healthy path.
        gap = gap_for(verdict, storage, record)
        legacy? = legacy_fold_order?(verdict, storage, record)

        line(ct.type, record, verdict, gap, keyed?, legacy?)
        {verdict, gap, legacy?}
      end

    tampered = Enum.count(results, &match?({{:tampered, _}, _, _}, &1))
    gaps = Enum.count(results, &match?({_, {:gap, _, _}, _}, &1))
    unattested = Enum.count(results, &match?({_, :unattested, _}, &1))
    legacy_tampered = Enum.count(results, &match?({{:tampered, _}, _, true}, &1))

    Mix.shell().info(
      "#{length(results)} anchored document(s) checked, #{tampered} failure(s), " <>
        "#{gaps} with an attested prefix short of the head, " <>
        "#{unattested} with no attested anchor at all."
    )

    report_legacy_fold_order(tampered, legacy_tampered)
    report_attestation(gaps, unattested, keyed?)

    # A short or absent attested prefix fails the run only where the deployment
    # could have signed and did not (see the moduledoc). Where no key is
    # configured it describes the operator's own choice, and failing every run
    # on it is how an exit code stops being read.
    if tampered > 0 or (keyed? and (gaps > 0 or unattested > 0)),
      do: exit({:shutdown, 1})
  end

  defp gap_for(verdict, storage, record) when verdict in [:unsigned, :unverifiable],
    do: Chain.attested_gap(storage, record.id, record.org_id)

  defp gap_for(_verdict, _storage, _record), do: :none

  # Only asked about documents that already failed (#1058): a chain that reads
  # `:verified`/`:unsigned`/`:unverifiable` never lands on the tampered line
  # this exists to annotate, so paying for the extra anchor read there would
  # cost every healthy document something this task never prints.
  defp legacy_fold_order?({:tampered, _}, storage, record),
    do: Chain.predates_fold_order?(storage, record.id, record.org_id)

  defp legacy_fold_order?(_verdict, _storage, _record), do: false

  defp report_legacy_fold_order(0, _legacy_tampered), do: :ok
  defp report_legacy_fold_order(_tampered, 0), do: :ok

  defp report_legacy_fold_order(tampered, legacy_tampered) do
    Mix.shell().info(
      "#{legacy_tampered} of #{tampered} TAMPERED document(s) predate the #598 " <>
        "fold-order fix and may be that bug rather than genuine tampering — see the lines " <>
        "marked '(chain predates the #598 fold-order fix …)' and #1058."
    )
  end

  defp report_attestation(0, 0, _keyed?), do: :ok

  defp report_attestation(_gaps, _unattested, true) do
    Mix.shell().error(
      "A signing key IS configured, so these anchors should verify. Either the key was " <>
        "unavailable when they were minted — which was logged loudly at the time — or the " <>
        "rows were written by something that does not hold it. Note a whole chain can be " <>
        "made unjudgeable by one UPDATE of key_id, which anchor_digest/1 does not cover, " <>
        "so 'no attested anchor' is not a milder finding than a short prefix. Only the " <>
        "checkpoint witness can tell those apart: see mix kiln.audit.checkpoint and #666."
    )
  end

  defp report_attestation(_gaps, _unattested, false) do
    Mix.shell().info(
      "No signing key is configured, so unsigned anchors are expected and nothing above " <>
        "is attested by anything. Configure KILN_PROVENANCE_PRIVATE_KEY before treating " <>
        "this task's output as evidence."
    )
  end

  # A gap outranks the verdict in the wording, because it is the stronger
  # statement: `:unsigned` says nothing was signed, while a gap says something
  # WAS and stopped. Calling that "intact" is the claim #811 objected to.
  #
  # Unreachable with `legacy? == true`: `legacy_fold_order?/3` only returns
  # true for a `{:tampered, _}` verdict, and a gap's verdict is always
  # `:unsigned`/`:unverifiable` — but the arity has to agree with the other
  # clauses, so it is accepted and ignored rather than assumed away.
  defp line(type, record, verdict, {:gap, attested, head}, _keyed?, _legacy?) do
    Mix.shell().error(
      "#{type}/#{record.slug} (#{record.id}): ATTESTED ONLY TO VERSION #{attested} — " <>
        "versions #{attested + 1}-#{head} are anchored but #{unattested_because(verdict)}, " <>
        "so nothing attests them"
    )
  end

  # Only shouted where a key IS configured. On a deployment that signs nothing,
  # "no attested anchor" is every document's normal state, and printing it as an
  # error per record is a wall of red that says only what the operator chose.
  defp line(type, record, verdict, :unattested, true, _legacy?) do
    Mix.shell().error(
      "#{type}/#{record.slug} (#{record.id}): NO ATTESTED ANCHOR — every anchor in this " <>
        "chain is #{unattested_because(verdict)}, so none of its history is attested"
    )
  end

  defp line(type, record, verdict, _no_gap, _keyed?, legacy?) do
    status =
      case verdict do
        :verified ->
          "VERIFIED"

        :unsigned ->
          "intact (unsigned)"

        :unverifiable ->
          "intact (signed by an unregistered key — see KILN_PROVENANCE_RETIRED_KEY_FILES)"

        {:tampered, reason} ->
          "TAMPERED — #{reason}#{legacy_annotation(legacy?)}"
      end

    Mix.shell().info("#{type}/#{record.slug} (#{record.id}): #{status}")
  end

  # A sibling annotation on the tampered line (#1058), never a softer verdict:
  # the status string still starts "TAMPERED", the count above still counts
  # it, and the exit code still fails on it. This only tells a human reading
  # the sweep which reds are worth investigating first.
  defp legacy_annotation(true),
    do:
      " (chain predates the #598 fold-order fix — this may be the ordering bug " <>
        "rather than tampering; see #1058)"

  defp legacy_annotation(false), do: ""

  defp unattested_because(:unsigned), do: "unsigned"
  defp unattested_because(:unverifiable), do: "signed by an unregistered key"
  # Unreachable via `gap_for/3`'s guard, but this runs inside a security sweep:
  # a third verdict added to that guard must not turn the run into a crash.
  defp unattested_because(_verdict), do: "not attested"
end
