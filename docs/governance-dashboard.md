# Governance dashboard (compliance cluster)

The **compliance & governance dashboard** ([#352](https://github.com/The-Verscienta/kiln_cms/issues/352))
at **`/editor/governance`** is the visible home for the compliance cluster — it
brings the editorial audit trail, consent records (#356), and point-in-time
history (#338) together per content item. Admin-only.

## What it shows

- **Index** (`/editor/governance`) — recent content (compiled **and** dynamic
  D17 types, under their public type names) with its type and state; each links
  to its trail.
- **Detail** (`/editor/governance/:type/:id`):
  - **Consent records** (#356) — each linked consent's kind, grantor, when, and
    reference.
  - **Version timeline** — the PaperTrail history newest-first: what action
    (`create` / `update` / `submit_for_review` / `publish` / …), when, **who**
    (the acting user on the write — versions from before attribution landed
    show as unattributed), and which fields changed (from `:changes_only`
    tracking — a lightweight diff).
  - **Point in time** (#338) — every publish row links to
    `/api/content/:type/:slug?as_of=<that instant>` ("View as of then"), serving
    exactly what was published at that moment.
  - **Export trail (JSON / CSV)** — downloadable compliance records of the
    timeline + consents: JSON carries the full structure (diffs, chain
    verdict); CSV is the flat spreadsheet-friendly twin
    (`/editor/governance/:type/:id/export.json` and `…/export.csv`,
    admin-only).

## How it's built

`KilnCMS.Governance` is a read-only context that assembles the trail:
`content_index/1` for the list (compiled resources plus the shared entry tier
for dynamic types), and `trail/3` which loads the item, its PaperTrail versions
(via `Module.concat(resource, Version)` on the **storage** resource — dynamic
types version on `KilnCMS.CMS.Entry`), and its consents
(`KilnCMS.CMS.list_consents_for!`). Actor attribution comes from
`belongs_to_actor :user` on the paper-trail config (nilified if the account is
ever deleted — audit rows outlive users). Gathered as the system
(`authorize?: false`) behind the admin-gated route. `KilnCMSWeb.GovernanceLive`
renders it; `KilnCMSWeb.GovernanceController` serves the JSON and CSV exports.

## Scope & later phases

Phase 1 was a read model over what the cluster already produces. Phase 2
(shipped with #356's anchors):

- **Side-by-side value diffs** — each timeline entry expands to old → new per
  changed field (strings verbatim, structures inspected + capped).
- **Tamper-evidence** — the detail header shows the signed-anchor chain
  verdict (`verified` / `intact-unsigned` / `unverifiable` / `unanchored` /
  `TAMPERED`), and the JSON export carries it. Anchors are minted at publish
  (`KilnCMS.Governance.Chain`); verify fleet-wide with `mix kiln.audit.verify`.
  Anchors verify against the key that signed them, so rotating the signing key
  doesn't turn the corpus `unverifiable` — provided you register the outgoing
  key's public half first, via `KILN_PROVENANCE_RETIRED_KEY_FILES` or
  `retired_keys` (see docs/provenance.md#key-rotation).

  Anchors chain to each other and carry a signed per-document position, so a
  `TAMPERED` verdict also covers a removed or rewritten middle anchor, a middle
  anchor removed together with its successor, and a reordering of the chain
  (#597). Note that on an unsigned deployment the links and the sequence are
  ordinary columns and the verdict is `unsigned` regardless: configure a signing
  key before treating any of this as evidence.

  A forged head is held to the newest anchor that still verifies (#708), but
  only within *that* anchor's prefix. An attacker with DELETE as well as INSERT
  moves the doctoring past it — delete the verified head, doctor only the
  versions it covered, re-insert an unsigned anchor refolded over the doctored
  rows — and the result reads `unsigned`, not `TAMPERED` (#811). Nothing inside
  `history_anchors` can distinguish that from a deployment whose signing key
  went away between publishes; the two produce identical tables.

  `mix kiln.audit.verify` therefore reports how far the attestation actually
  reaches rather than calling such a chain "intact", and fails the run when a
  signing key **is** configured — a deployment that could have signed and did
  not is an anomaly to explain. The checkpoint witness below is what settles it.
- **Checkpoints** (#666) — a clean truncation of the *newest* anchors is the one
  thing no column inside the document can catch: a shorter chain is
  indistinguishable from a younger one. So a scheduled job mints a signed,
  org-wide Merkle commitment to every document's head anchor and publishes it
  outside the database (`KilnCMS.Governance.Checkpoint` /
  `KilnCMS.Governance.Witness`). A document witnessed at position 7 that now
  heads at 5 reads `TAMPERED`, and one whose anchors were wiped entirely reads
  `TAMPERED` rather than `unanchored`.

  Three things an operator has to know before treating this as evidence:

  - Anchors minted since the last checkpoint are **not yet witnessed**, so the
    exposure window is one `KILN_GOVERNANCE_CHECKPOINT_CRON` interval wide.
  - The default witness keeps the commitment **in the database**. That catches
    the attack in its ordinary form and not an attacker who remembers the second
    table; set `KILN_GOVERNANCE_WITNESS` to `file`, `s3` or `http` for the real
    property.
  - Publishing is half of it. `mix kiln.audit.checkpoint --audit` is what
    compares the sink to the database, and it wants to run somewhere the
    application host does not control.
  - `--audit` also walks the run's **predecessor links** — each row records a
    digest of the one before it (#732). That half needs no sink, so it runs on
    the default adapter too, and it catches a checkpoint rewritten in place
    without any signature to check against. It is not a substitute for the
    witness: the digest is an unkeyed hash over public columns, so a careful
    attacker recomputes every link after the row they edited, and the newest
    checkpoint has no successor to record its digest at all.
- **Consent recording UI** — record a consent (kind / grantor / reference /
  note) directly from the trail page.

Phase 3 (closing #352):

- **"Who" on each version** — `belongs_to_actor` on the paper-trail config
  relates each version to the acting user; the dashboard, JSON, and CSV
  exports show it. Versions written before this landed (or by tenant-less
  system jobs) are unattributed.
- **Dynamic (D17) types** — entries appear in the index under their public
  type names and have full trails (chain anchors already keyed on the `:entry`
  storage tier). Point-in-time delivery now covers them too, so every publish
  row links to its snapshot — the earlier suppression is gone.
- **CSV export** — the flat spreadsheet twin of the JSON export: one row per
  timeline event or consent, formula-escaped against CSV injection.

Later phases:

- **PDF export** — JSON/CSV cover regulator-ready records today; a typeset PDF
  report needs a rendering dependency and is deliberately deferred.
