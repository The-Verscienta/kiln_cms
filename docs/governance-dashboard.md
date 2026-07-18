# Governance dashboard (compliance cluster)

The **compliance & governance dashboard** ([#352](https://github.com/The-Verscienta/kiln_cms/issues/352))
at **`/editor/governance`** is the visible home for the compliance cluster — it
brings the editorial audit trail, consent records (#356), and point-in-time
history (#338) together per content item. Admin-only.

## What it shows

- **Index** (`/editor/governance`) — recent content with its type and state; each
  links to its trail.
- **Detail** (`/editor/governance/:type/:id`):
  - **Consent records** (#356) — each linked consent's kind, grantor, when, and
    reference.
  - **Version timeline** — the PaperTrail history newest-first: what action
    (`create` / `update` / `submit_for_review` / `publish` / …), when, and which
    fields changed (from `:changes_only` tracking — a lightweight diff).
  - **Point in time** (#338) — every publish row links to
    `/api/content/:type/:slug?as_of=<that instant>` ("View as of then"), serving
    exactly what was published at that moment.
  - **Export trail (JSON)** — a downloadable compliance record of the timeline +
    consents (`/editor/governance/:type/:id/export.json`, admin-only).

## How it's built

`KilnCMS.Governance` is a read-only context that assembles the trail:
`content_index/1` for the list, and `trail/2` which loads the item, its
PaperTrail versions (via `Module.concat(resource, Version)`), and its consents
(`KilnCMS.CMS.list_consents_for!`). Gathered as the system (`authorize?: false`)
behind the admin-gated route. `KilnCMSWeb.GovernanceLive` renders it;
`KilnCMSWeb.GovernanceController` serves the JSON export.

## Scope & later phases

Phase 1 is a read model over what the cluster already produces. Later phases:

- **Full side-by-side version diffs** (today the timeline names the changed
  fields; not the before/after values).
- **Signed / tamper-evident** trail once #356's hash-chained versions land — the
  export would then carry a verifiable signature.
- **"Who"** on each version — richer actor attribution on PaperTrail versions
  (the workflow action + time is shown today; the grantor is captured on
  consents).
- Dynamic (D17) types and a consent-recording UI here (recording is via
  AshAdmin / the code interface today).
