# Full-surface audit — July 2026

A four-dimension audit (security, performance, correctness, consistency/a11y)
over the ten features shipped since the July performance/usability audit:
dynamic content types were already covered; this pass covers **search tail,
plugin field types, content scheduling, webhook reliability, localization
workflows, asset pipeline, forms, and GraphQL subscriptions**.

**Headline:** the new surface is in good shape. The load-bearing security and
correctness properties all held up under scrutiny — webhook SSRF pinning,
form input coercion/validation, the honeypot + rate-limit compensations for
the deliberately-CSRF-free form endpoints, HTML escaping on every
user-data render path, the focal-point rotation math, the scheduling
`ScheduleOrder` validation, and the GraphQL subscription **policy scoping**
(anonymous subscribers provably never receive drafts). The material findings
were one missing index and two accessibility gaps.

## Fixed

| # | Dimension | Finding | Fix |
|---|-----------|---------|-----|
| 1 | Perf | `webhook_deliveries.inserted_at` unindexed — the nightly retention prune and the "recent deliveries" read both seq-scanned it. `form_submissions.form_id` likewise (FKs aren't auto-indexed), used by the per-form submissions viewer + count. | `add_ledger_indexes` migration: `webhook_deliveries(inserted_at)` and `form_submissions(form_id, inserted_at DESC)`. |
| 2 | A11y | The media focal-point editor was click-only (WCAG 2.1.1) — no keyboard path to set the point crops center on. | Container is now a focusable `role="button"`; the `FocalPoint` JS hook handles arrow keys (5% nudges from the current point, read off `data-focal-*`), alongside the existing click. |
| 3 | A11y | The form-builder's inline "add field" inputs used placeholders as their only labels (WCAG 1.3.1 / 4.1.2). | `sr-only` `<label>`s associated with each input. |

## Reviewed and dismissed (false positives / deliberate)

- **FormField world-readable via API (security):** Form/FormField/FormSubmission are on `AshAdmin.Resource` only — no GraphQL or JSON:API extension — so there is no anonymous query surface. The world-readable read serves only the internal render path. Not exploitable.
- **Facets tag N+1 (perf):** `Ash.Query.load(tags: …)` issues one batched query per relationship across all matched rows, not one per row.
- **Form-block dedup (perf):** the `for … uniq: true` comprehension already deduplicates slugs before loading.
- **Calendar `published_at` unindexed (perf):** the `<table>_published_feed_index` partial index already exists on every content table; the calendar is admin-only and bounded per type.
- **Form JSON error shape (consistency):** field-keyed validation errors (`{ok, errors: {field: msg}}`) are the correct, separately-documented (`docs/forms.md`) contract for form submission — the right shape for form UIs, distinct from the transport-level `{errors: [...]}` envelope the same controller uses for 404/rate-limit. Deliberate, not a defect.
- **Nested block-id regeneration on translation copy (correctness):** no block schema nests block arrays (Portable Text children are inline spans), so the recursive strip guards a structure that doesn't exist.
- **Webhook health double-count on mid-settle crash (correctness):** the failure counter only bumps on the final attempt, which Oban discards rather than retries; the success path resets idempotently. No live window.
- **Select-option content validation (security):** options are HTML-escaped on every core render path (`~H`, the notification email's `h/1`, the schema JSON). A character allowlist would reject legitimate option text for a defense the core already provides.
