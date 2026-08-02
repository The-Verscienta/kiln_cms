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
  (#597, #666). What it does **not** cover is a clean truncation of the newest
  anchors: a shorter chain is indistinguishable from a younger one, and nothing
  inside the database can tell them apart. If that matters for your obligations,
  export the head digest somewhere outside the database on a schedule — the
  fleet sweep (`mix kiln.audit.verify`) is the natural place to hang it. Note
  too that on an unsigned deployment the links and the sequence are ordinary
  columns and the verdict is `unsigned` regardless: configure a signing key
  before treating any of this as evidence.
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
