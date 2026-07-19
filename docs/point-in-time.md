# Point-in-time content API (compliance cluster)

Serve a published document **as it was on a past date** — a compliance/audit
superpower for regulated content ("what did our published guidance say on
2026-03-01, provably"). First of the compliance cluster
([#338](https://github.com/The-Verscienta/kiln_cms/issues/338); see also #352
governance dashboard, #356 tamper-evident + consent).

## Using it

Add **`?as_of=<date>`** to the headless delivery endpoint:

```
GET /api/content/post/my-post?as_of=2026-03-01
GET /api/content/post/my-post?as_of=2026-03-01T09:00:00Z&surface=web
```

`as_of` accepts a full ISO 8601 datetime, or a bare date (treated as the **end
of that day**, UTC). It serves the same surfaces as live delivery (`json`
default, `json_ld`, `web`), plus response headers:

- `x-kiln-as-of` — the moment requested.
- `x-kiln-published-at` — the **effective publish time** of the version served.

`404 not_published` if nothing was published by that moment; `400 invalid_as_of`
for an unparseable date.

## How it works

`KilnCMS.Firing.PointInTime`:

1. Finds the last `:publish` / `:publish_scheduled` **PaperTrail version** at or
   before `as_of` (versions are tagged with their action name).
2. **Replays** the `:changes_only` version history up to that version to
   reconstruct the full published state (the same merge `RestoreVersion` uses).
3. Re-fires that state through `KilnCMS.Firing.Engine` in **`:preview` mode** — no
   DB write, no cache — producing the historical per-surface artifacts.

Because it reconstructs from immutable version history and re-fires with the same
engine as live delivery, the historical artifact is faithful to what was
actually published, and **drafts/edits made after that publish never leak** into
it.

## The collection view (#338 phase 2, shipped)

**"What was published on this site on date X?"** —

    GET /api/content/:type?as_of=2026-03-01          # REST
    { contentAsOf(type: "post", asOf: $t) { … } }    # GraphQL twin

Index entries (`slug`, `title`, `published_at`, `href` to the per-document
snapshot) reconstructed from version history: a document counts as published
iff its last publish/unpublish transition ≤ `as_of` was a publish, and its
title/slug are replayed to that publish (a later rename doesn't leak in).
Unlike the single-document read, the **index respects unpublish** — a list
that included since-removed content would misrepresent the site as it stood.
Bounded (`limit`, default 100, max 500) — the last-transition scan runs as one
`DISTINCT ON` SQL pass, so cost scales with matching documents, never with
total publish history — and results are server-cached for 5 minutes.
Compiled types only (a dynamic type answers 404 — the documented later-phase
boundary), and content whose history predates version tracking can't be
reconstructed and is omitted.

## Scope & later phases

- **Single-document lookup is by the current record's id** (resolved from the
  slug), so a since-deleted document's snapshot isn't reachable that way — use
  the collection index for discovery; id-addressable single-doc history is a
  later phase.
- The single-document read's temporary-unpublish "dark window" still reports
  the most recent publish (dark-window awareness is a later phase; the
  collection index already accounts for it).
- Compiled types (page/post/project types); dynamic (D17) entries are a later
  phase.
- Pairs with **#356** (tamper-evident history + signed versions) and **#352**
  (a governance dashboard that surfaces version diffs + point-in-time export).
