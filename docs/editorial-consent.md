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

Phase 1 was the consent side of #356. The **tamper-evident audit log** phase 2
shipped as **signed history anchors**: at every publish the document's full
PaperTrail version chain is folded into a canonical hash and recorded
append-only (`KilnCMS.CMS.HistoryAnchor`), RSA-signed via the #340 signing key
when configured — see `KilnCMS.Governance.Chain`, `mix kiln.audit.verify`, and
the chain status on the governance dashboard. Any later alteration, deletion,
or reordering of anchored history is detected; edits after the newest anchor
are covered at the next publish. Per-write chaining (an entry per version at
write time, closing that between-publish window) remains the finer-grained
follow-on. Consent recording now has a dashboard UI (#352). The publish gate
is currently a single global required-kinds list; per-content-type
requirements are a later phase.
