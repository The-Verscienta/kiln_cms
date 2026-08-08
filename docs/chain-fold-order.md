# Governance chain: assigned fold order (#598 / #670)

`KilnCMS.Governance.Chain` folds a document's versions into a hash and anchors
it. This document is the design for **what order it folds them in**, and why the
obvious answers are wrong.

#670 asked for this decision to be made explicitly before implementing. It also
sketched a fix whose stated guarantee turns out not to hold as written — so the
analysis is here rather than in a commit message.

## The bug

Today the fold order is `(version_inserted_at, id)`. That timestamp is
`DateTime.utc_now/0` **on the node performing the write**, so it is not monotonic
with respect to commit order:

1. **Out-of-order commits.** Anchoring runs in `after_transaction`, outside any
   lock. Two writes to one document can have their version rows become visible
   in a different order than their stamps.
2. **Clock skew.** Two app nodes a few hundred milliseconds apart produce rows
   whose stamp order contradicts their commit order. No concurrency needed —
   just a multi-node deploy.

When a row lands *inside* a range an anchor already committed to, that anchor can
never reproduce. `verify/4` recomputes the prefix from genesis, gets a different
sequence, and the document reads `{:tampered, …}` **permanently**, with no
tampering having occurred. Reproduced 10/10 in review. PR #669 fixed the
secondary damage (double-folded rows, inflated `version_count`) and explicitly
did not change this verdict.

Exposure is widest with `audit_anchor_every_write: true` — the regulated
deployment the flag exists for.

## The decision, stated plainly

Fixing the false positive means folding in an order the system **assigns**, so a
late row appends at the tail instead of landing mid-sequence. That trades away
something real: today, a version row spliced into an anchored range *is* detected,
precisely because it breaks the recomputed prefix.

So the question is whether a late row and a spliced row can be told apart. Three
candidate mechanisms; two of them fail.

### ✗ A database sequence assigned at INSERT

The obvious answer: give every version row a `bigserial` and fold by it. A splice
inserted later gets a higher number, so it cannot land in the middle.

**It does not work.** `nextval` fires at INSERT, not at COMMIT. Two transactions
can take 5 and 6 and commit in the opposite order, so a reader — including the
minting process — can see 6 while 5 is still in flight and observe 5 afterwards.
A row appearing later with a lower sequence is *exactly* what a splice looks
like. The problem has moved, not gone.

### ✗ A settling window

Only fold versions older than N seconds; anything appearing afterwards with a
position inside an already-folded range is definitively anomalous, because a
legitimate row that old would already have been folded.

Sound in isolation, and **incompatible with what this feature is for**. Anchoring
runs in `after_transaction`, so under `audit_anchor_every_write: true` a publish
would no longer anchor its own version. `unanchored_tail/2` would show a
permanent phantom pending edit that no publish clears — which is one of the
symptoms #670 exists to remove.

### ✓ Signing the version row at write time

A version row carries a signature over its own immutable identity, minted with
the provenance key when the source write happens. Then:

* a **late** row has a valid signature and no chain entry — fold it at the tail;
* a **spliced** row has no valid signature — fail.

This sits inside the threat model the chain already assumes: an attacker with
database write access does not hold the signing key. That is the same assumption
that makes a signed anchor meaningful in the first place, so this adds no new
trust, only a second application of an existing one.

## The condition, which is the important part

**Provenance signing is optional.** With no `KILN_PROVENANCE_PRIVATE_KEY`,
anchors are already stored unsigned (`KilnCMS.Governance.Chain` logs it), and
version rows would be too. On such a deployment "no valid signature" cannot
distinguish a splice from an ordinary unsigned row.

So the guarantee is **conditional**, and the docs must say so rather than imply
otherwise:

| Deployment | False tamper verdicts | Splice inside an anchored range |
|---|---|---|
| Signing key configured | Gone | **Fails verification** |
| No signing key | Gone | **Flagged, does not fail** |

This is the right shape. The deployments that need hard detection are exactly the
ones that configure a key — `audit_anchor_every_write` and a signing key are the
same operator making the same decision. A default install gets the false-positive
fix, which is the bug it actually suffers from, and an honest verdict about what
it can and cannot prove.

## Design

### The fold order lives on the anchor, not in a side table

#670 sketched a `history_chain_entries` table with a per-document `seq`. A
simpler mechanism gives the same guarantee with less machinery: record the
folded version ids **on the anchor itself**, as an ordered array, and include
them in the signed payload.

```
history_anchors.folded_version_ids  uuid[]  NOT NULL DEFAULT '{}'
```

`verify/4` folds the concatenation of every anchor's list, in anchor order.
That is the order the chain committed to, read back from the rows that
committed to it.

Three things fall out that the side table does not give you:

* **The order is signed.** It is part of the anchor's payload, so rewriting the
  recorded order breaks the signature — the order becomes as tamper-evident as
  the hash it explains. In a side table it would be unsigned rows an attacker
  with database access could rewrite freely.
* **No sequence allocation.** No `seq` to hand out, so no read-then-write, no
  two-mint race, and no second unique index to enforce.
* **`version_count` stops being a separate claim.** It is `length(ids)` — the
  count and the hash describe the same set by construction, which is exactly
  the `unanchored_tail/2` over-reporting #670 folds in.

A version row that becomes visible late appears in no anchor's list, so the next
mint appends it at the tail. Every earlier anchor keeps reproducing. That is the
self-healing half, and it holds whether or not signing is configured.

### Version signatures

Each version row carries `chain_signature` and `chain_key_id` over a canonical
payload of the fields that identify it and cannot change:
`(org_id, resource_type, source_id, version_id, version_inserted_at)`.

Deliberately **not** the `changes` map. A signature over editorial content would
start failing for reasons that are not tampering — a re-serialisation, a
migration touching an embedded type — and a tamper alarm that cries wolf is one
operators learn to ignore. Content integrity is the chain hash's job; this
answers the narrower question *did this row come from Kiln, or did it appear in
the table?*

`KilnCMS.Governance.VersionSignature` returns a **three-way** verdict, never a
boolean: `:valid`, `:invalid` (checked against a key we hold and failed — that
is evidence), `:unknown` (unsigned, or a `key_id` we do not hold — that is
nothing). `KilnCMS.Provenance.Signer` warns about exactly this conflation in its
own docs.

### `verify/4`

For a version row absent from every anchor's list but positioned inside the
anchored range:

| Signature | Verdict |
|---|---|
| `:valid` | Late arrival. Not tampering; the next mint appends it. |
| `:invalid` | **Tampering.** The signed payload is immutable, so a doctored row cannot carry a valid one. |
| `:unknown` | Anomaly. Reported, does not fail — this chain cannot prove it either way. |

### Existing history

Compatibility is by **construction, not by migration**. A chain with any
pre-#598 anchor falls back wholesale to the timestamp order, because mixing the
two would put an old anchor's versions (which are in no list) *after* a newer
anchor's recorded ids — reordering them, and breaking the verification this
exists to protect.

So an existing document behaves exactly as it does today, and documents anchored
from here on get the fix. No backfill, and no data migration over every version
row.

**A document already reading falsely-tampered stays that way.** Its anchor
committed to an order the table no longer holds, and that order is not
recoverable — nothing here can invent it. This stops the bug happening again; it
does not repair a document it already happened to.

### Cost

`mint/3` gains one indexed `COUNT` per anchored write, to notice that a row
arrived below the boundary. The expensive path — re-reading the document's
versions to find what no anchor folded — runs only when that count says
something is missing, which is rare. `verify/4` pays nothing extra: it already
holds the anchor list and passes it down.

## What this does not fix

A splice on a deployment with **no signing key** is flagged, not failed — see the
table above. An operator who needs the stronger property configures a key. There
is no way to give it to them without one, and pretending otherwise would be worse
than the false positives this replaces.

An **unsigned row inside the anchored range** floors the verdict to
`:unverifiable` rather than failing it, on every deployment. That is deliberate:
version rows written before this shipped carry no signature, and reading those as
tampering would turn an upgrade into a fleet-wide red alert.
