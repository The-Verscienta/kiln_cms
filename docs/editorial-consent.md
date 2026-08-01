# Editorial consent linking (compliance cluster)

Link content to **editorial / authorization consent** records — proof that a
piece of content is *cleared to publish*: a medical-reviewer sign-off, a
patient/source release, source licensing, etc. Part of the compliance cluster
([#356](https://github.com/The-Verscienta/kiln_cms/issues/356); pairs with #338
point-in-time and #352 governance dashboard).

> This is **cleared-to-publish** consent, not GDPR data-subject/cookie consent.

## What it does

`KilnCMS.CMS.Consent` records, per content item:

- **`kind`** — one of the configured kinds (`:reviewer_signoff`, `:source_release`,
  `:licensing`, `:other` by default; override with `config :kiln_cms, [:consent,
  :kinds]`).
- **`reference`** — a pointer to the underlying authorization (ticket id, URL,
  document ref). **Never the sensitive consent document itself**, so PHI-adjacent
  material isn't pulled into the CMS.
- **`grantor`** — who granted/approved; **`granted_at`**; **`recorded_by`** — the
  user who logged it.

Recording and reading are editor/admin; deletion is admin-only. Recorded via the
`:record` action (AshAdmin / code interface today); consents will surface in the
governance dashboard (#352).

```elixir
KilnCMS.CMS.record_consent!(
  %{content_type: "post", content_id: post.id, kind: :reviewer_signoff,
    grantor: "Dr. Ada", reference: "REVIEW-1234"},
  actor: admin
)
```

## The publish gate

Off by default. A deployment can require consent kinds before any content may be
published:

```elixir
config :kiln_cms, :consent, required_before_publish: [:reviewer_signoff]
```

With this set, `:publish` / `:publish_scheduled` **fail** unless a `Consent` of
each required kind is already linked to the document — making "cleared to
publish, approved by X on date Y" *enforceable*, not just documentary. Empty or
absent config is a no-op, so existing publishing is unchanged
(`KilnCMS.CMS.Validations.RequiredConsent`).

## Scope & the rest of #356

Phase 1 was the consent side of #356. The **tamper-evident audit log** shipped
as **signed history anchors**: the document's PaperTrail version chain is
folded into a canonical hash and recorded append-only
(`KilnCMS.CMS.HistoryAnchor`), RSA-signed via the #340 signing key when
configured — see `KilnCMS.Governance.Chain`, `mix kiln.audit.verify`, and the
chain status on the governance dashboard. Any later alteration, deletion, or
reordering of anchored history is detected.

Two properties are worth knowing:

- **Anchors chain to each other,** two ways. Each anchor is folded
  incrementally from the *previous anchor's recorded hash*, never re-derived
  from the live version rows — re-deriving would let someone doctor history,
  wait for the next publish, and receive a fresh valid anchor over the doctored
  rows. Each anchor also records the previous anchor's **id and a digest of its
  contents**, both inside the signed payload, so deleting or rewriting an anchor
  row leaves a hole its successor still points at (#597).

  This **narrows** the laundering route rather than closing it, and it is worth
  being precise about which half is which. Deleting or rewriting a *middle*
  anchor is detected. Deleting the *newest* anchors is not — nothing points at
  the newest anchor, so a truncated chain looks like a younger one, and it is the
  newest anchors that cover the most recent versions. Wiping every anchor returns
  the document to `unanchored`, and the next write anchors it afresh. On a
  deployment with **no signing key** — the default — the link is advisory, since
  the digest is computed from columns anyone with database access can read.

  Closing the truncation case needs state the document's own anchor set cannot
  provide (a monotonic sequence with an external witness, or an append-only
  store). Until then, revoking `DELETE` on `history_anchors` for the application
  role is the defence that actually holds, and configuring a signing key is what
  makes any of the rest mean anything.
- **The incremental fold resumes by position, not by count** (#598). An anchor
  records the sort key of the version it ended on, and the next fold takes the
  rows sorting after *that key* — not `OFFSET version_count`, which means "skip
  the first n rows of the current result set" and so quietly skips the wrong row
  whenever one becomes visible below the boundary afterwards. Two ordinary ways
  that happens: concurrent writes whose version rows commit out of stamp order,
  and wall-clock skew between app nodes, since `version_inserted_at` is stamped
  by the node doing the writing. The boundary is inside the signed payload,
  because it decides which rows the next anchor covers — repointing it would
  otherwise stop the chain while the verdict stayed green.

  **A row that lands inside an already-anchored range is still fatal to that
  anchor,** which committed to an order the table no longer holds; no later
  anchor repairs it, and the document reads `tampered` either way. What changed
  is that the chain records no fabricated state, that anchoring logs the
  condition when it happens rather than leaving it for an audit months later,
  and that the verdict names it instead of reporting a bare hash mismatch that
  reads identically to doctored content. Making it *impossible* needs a fold
  order assigned at write time instead of inferred from a wall clock — which
  also settles whether such a row is tampering or a latecomer, so it is a
  deliberate call rather than a detail.
- **Every write can be anchored.** `config :kiln_cms,
  :audit_anchor_every_write, true` — or `KILN_AUDIT_ANCHOR_EVERY_WRITE=true`
  at runtime, so it can be turned off without a rebuild — extends the chain
  after every versioned write, not just at publish, closing the
  between-publish window (#356's "sign every version"). Off by default: it
  costs one signature and one row per save. The incremental fold keeps that
  cost flat as history grows.

Consent recording now has a dashboard UI (#352). The publish gate is currently
a single global required-kinds list; per-content-type requirements are a later
phase.
