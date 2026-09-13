# 0003. History anchors verify as a chain, and an unjudgeable anchor floors the chain

- **Status** — accepted, shipped in
  [0.5.0](../changelog/v0.5.0.md) (Security).
- **References** — [#597](https://github.com/The-Verscienta/kiln_cms/issues/597), [#666](https://github.com/The-Verscienta/kiln_cms/issues/666), [#591](https://github.com/The-Verscienta/kiln_cms/issues/591).
- **Changelog** — [0.5.0 → Security](../../CHANGELOG.md#050---2026-08-09).

## Decision

**History anchors verify as a chain, not just at the head.** Three ways to
move the verification baseline without deleting anything the chain would
notice, all closed (#597, #666).

**The foundation: every anchor's signature is now checked, not only the
baseline's — and an anchor that cannot be judged floors the whole chain.**
While only the head was checked, every other anchor's attested columns were
freely rewritable, and those columns are exactly what any structural invariant
is computed from. Merely *skipping* an unjudgeable anchor was the same hole one
column over: the digest chain covers neither `key_id` nor `sequence`, so
`UPDATE … SET signature = NULL` on a non-head anchor made it invisible to the
sweep, after which it could be renumbered into the baseline position with
nothing objecting. A chain containing an anchor nobody can vouch for now reads
`:unsigned` or `:unverifiable`, never `:verified`.

**That means some deployments will see a verdict change without anything being
wrong.** An instance that turned signing on partway through its life has
anchors from before it, and those are genuinely unattested — such a document
now reads `:unsigned` where the head alone read `:verified`. That is the
honest answer, not a regression; it is the same answer a fully keyless
deployment already got. The floor never *softens* anything either: the hash
comparison needs no key, so real tampering is still reported as `TAMPERED`
even with no signing key configured at all.

Cost is one signature verification per anchor, measured at ~72 µs — about
150 ms for a document with 2 000 anchors. Audit paths only: the governance page
and `mix kiln.audit.verify`. Nothing on the delivery path verifies a chain, but
note the fleet sweep is now O(total anchors) rather than O(documents), so it is
not something to put on a tight cron on an `anchor_every_write` deployment.

**Reordering.** `verify/4` takes the *latest* anchor as its baseline, and
"latest" was decided by `inserted_at` — a column written by the database and
attested by nothing. So `UPDATE history_anchors SET inserted_at = now() WHERE
id = <an older, shorter anchor>` made that anchor the baseline: the doctored
versions then sat outside the anchored prefix, were never hashed, and the
verdict was `:verified` with not a single row deleted. Anchors now carry a
1-based per-document `sequence`, inside the signed payload (v4), and that is
the order they are read in.

It is **`NOT NULL` and unique**, and both matter. A nullable position would
have been the same hole one column over — nothing attests an *absent* value,
so nulling the newest positions would have rolled the baseline back just as
the timestamp rewrite did. Unique because assigning it is a read-then-write in
`after_transaction`: without the constraint two concurrent mints pick the same
number, and the run reads `[2, 2, 1]` — a permanent, unrepairable false tamper
verdict on a document nobody touched. With it, the loser's insert fails into
the existing rescue as a logged skip.

**Holes.** The predecessor links added in #591 catch a middle anchor removed
while its successor survives. They do not catch it when the successor goes too
— every surviving link still resolves. On a signed deployment the signature
sweep does, because the attacker has to rewrite the survivor's link columns to
get there and those are signed. On an unsigned one, where that is free, the
position gap is what is left. `prev_anchor_id` also gains `ON DELETE
RESTRICT`, which forces the attacker into that shape.

Be precise about what `RESTRICT` does **not** buy: Postgres checks the
constraint after the statement's rows are gone, so `DELETE … WHERE source_id =
…` removes referrer and referent together and succeeds. It narrows the attack;
it does not stop a wipe. Both behaviours have tests.

**Still open, and stated rather than implied.** Deleting the *newest* anchors
is undetectable — and so is *hiding* them, since rewriting `resource_type` or
`source_id` takes them out of the set the query returns, which is the same
attack with `UPDATE` instead of `DELETE`. (Worth knowing because "revoke
`DELETE` from the application role" is the usual advice and it does not cover
this.) Nothing points at the newest one, so a shorter chain is
indistinguishable from a younger one, and no state inside the document's own
anchor set can tell them apart — which is why **#666 stays open** for a witness
outside the database (an append-only log, retention-locked object storage, a
transparency log). `docs/governance-dashboard.md` now tells operators to export
the head digest on a schedule if the property has to actually hold. On an
unsigned deployment the structural checks still run and still report, but treat
them as advisory: they raise the cost of a forgery, they do not attest
anything.

Existing anchors are backfilled in write order and keep verifying — they were
signed before the column existed, so both the v4 and v3 payload shapes are
offered and each anchor matches exactly one. Their positions are therefore not
covered by their own signatures; what holds them in place is that
`version_count` must rise with position — on columns the signature sweep has
established are attested, which is why an anchor it cannot judge floors the
chain rather than being skipped. A short early anchor cannot be promoted to the
baseline. (#597, #666)
