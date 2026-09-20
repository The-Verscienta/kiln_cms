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

`400 invalid_as_of` for an unparseable date, and two distinct 404s:

- `not_published` — nothing had been published by that moment.
- `withdrawn` — it *had* been published, but was unpublished or archived
  before `as_of` and not republished by then. See
  [Withdrawn content](#withdrawn-content).
- `not_public` — it was published, but not to an anonymous reader: its
  audience at `as_of` was not public. See [Who can read history](#who-can-read-history).

A passphrase-locked document (#496) takes the same grant as live delivery
(`x-kiln-unlock` or `?unlock=`), and a snapshot read with one is served
`private, no-store` — never `public` — for the same reason.

## How it works

`KilnCMS.Firing.PointInTime`:

1. Finds the last **state transition** — publish *or* unpublish/archive — at or
   before `as_of` (PaperTrail versions are tagged with their action name). An
   unpublish means the document was dark then, and the read stops there.
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
total publish history — and results are server-cached for 5 minutes. Content
whose history predates version tracking can't be reconstructed and is omitted.

## Who can read history

`?as_of=` is on the unauthenticated API and its answers are CDN-cacheable, so
it applies every rule live delivery applies to *who* may read a document. The
feature is about *when*; it widens nothing else.

- **The snapshot** resolves the document through the live delivery read first
  (published now, `:public` audience, passphrase lock unless a grant is
  presented), then checks that it was **public at `as_of`** — the last
  `audience` on its version history at or before that moment. A document that
  was members-only then and is public now answers `404 not_public` for dates
  it was gated; one that was public then and is gated now is not found at all.
  Edits to a published document land on the live row without a republish, so
  this is the audience *at `as_of`*, not at the last publish before it.
- **The collection index** (REST and GraphQL) lists only documents public to an
  anonymous reader both **now** (public audience, no passphrase lock) and
  **then**. The rule takes no caller input, which is what lets the index keep
  one server-cache slot per `{org, type, as_of, limit}`; a locked document is
  never listed, grant or not.
- **The passphrase lock has no history.** Its hash is deliberately kept out of
  version rows (so a bcrypt hash never outlives a rotation there), so the
  current lock is the only one there is and it applies to every date: locking
  a document hides it from the historical index for dates it was open too.
- A document whose history records no audience at all fails closed.
  Version tracking records every attribute on create, defaults included, so
  this only affects history older than the `audience` column itself.

## Dynamic (D17) types

Dynamic types are served too, under their public type name. They need no
special handling on the single-document read — the storage resource comes from
the resolved record rather than the registry descriptor (a dynamic descriptor
carries `resource: nil`).

The **collection index** does need care: every dynamic type shares the
`KilnCMS.CMS.Entry` table, so an unscoped historical index for one type would
list every other type's documents. `index/4` takes a `:type_definition_id` and
scopes on the **source row**, not the version `changes` map — a publish or
unpublish version carries no `type_definition_id` in its diff (only the create
version does), and the source row is the authority anyway since a document
can't change type.

Because the governance dashboard's "View as of then" links no longer have to
be suppressed for dynamic entries, every publish row in a trail now links to
its snapshot.

## Withdrawn content

Publishing is not a one-way door: content gets taken down, corrected, and put
back. If you ask what a document said on a date when it had been **withdrawn**,
answering with the publish that preceded the withdrawal would assert the
content was live at a moment it demonstrably wasn't — precisely the claim this
endpoint exists to make truthfully, and the one a regulator would test.

So the single-document read resolves the last *transition* (publish or
unpublish/archive) rather than the last publish, and answers `404 withdrawn`
inside a dark window. This matches what the collection index already did, so
the two views can't contradict each other: a document absent from the index for
a date can no longer serve content for that same date.

Republishing reopens the window — `as_of` after the republish serves the
republished state, as before.

## Scope & later phases

- **Single-document lookup is by the current record's id** (resolved from the
  slug), so a since-deleted document's snapshot isn't reachable that way — use
  the collection index for discovery; id-addressable single-doc history is a
  later phase.
- Pairs with **#356** (tamper-evident history + signed versions) and **#352**
  (a governance dashboard that surfaces version diffs + point-in-time export).
