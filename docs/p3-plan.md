# P3 plan — the remaining backlog after the P0/P1/P2 waves

*Revised 2026-07-19 against current main (`fdabc52`). Supersedes the 2026-07-18 draft:
since then #330 (write APIs) and #355 (visual-editing bridge) shipped **and closed**
(PRs #385, #388/#390/#391), #335's nested-columns block landed (#386), multi-tenancy
started shipping (#387 merged, #389 open), staging tooling landed (#381), and #333
was scoped by decision docs (#380/#383).*

## What "P3" means here

No `P3` label exists. Exactly one open issue is literally marked **Priority: P3**
(#379, split from #343). This plan therefore defines the **P3 wave** the same way
the P1 and P2 waves were defined in practice: *everything still open and unbuilt* —
the five follow-up splits (#375–#379), the Phase-2 tails of shipped P1 features,
the in-flight multi-tenancy epic (#336), and the five stale pre-priority epics
(#346–#350).

Standing rules carried over from the P1/P2 waves:

- One verified PR per feature, branched off **latest `origin/main`**.
- Full local gate before push: `compile --warnings-as-errors`, `mix format`,
  credo, sobelow (`exit:low`), `mix ash.codegen --check`, dialyzer, `mix test`.
  **`mix format` after any `ash.codegen`** (migrations aren't format-clean).
- CI green before merge; never merge red.
- Each feature ships with a `docs/<feature>.md` (or extends the existing one) and
  a closing/Phase-note comment on its issue.
- Deploy remains manual Coolify *Redeploy*; finish the wave with a
  `docs/deploy-p3.md` checklist (POOL_SIZE / restart / new-env-var reminders).

## Inventory (current as of 2026-07-19)

| # | Item | Cluster | Status today | Size |
|---|------|---------|--------------|------|
| PR #389 | Multi-tenancy PR 2: tenant-aware delivery + host routing | 0 | **open PR, in flight** | land it |
| #375 | Automation: review-workflow triggers | A | unbuilt (split of #342) | S |
| #376 | Automation: newsletter fan-out action | A | unbuilt (split of #342); overlaps #337-P2 auto-send | M |
| #378 | Preview: shared variant/locale switcher | A | unbuilt (split of #343) | S |
| #379 | Preview: presence on `/preview/:token` | A | unbuilt — **the only literal P3** | M |
| #336 | Multi-tenancy epic | B | PR 1 merged (#387); PR 2 open (#389); PR 3+ remain | L (phased) |
| #356 | Tamper-evident audit log | C | consent half shipped (#365); hash-chain half unbuilt | M/L |
| #352 | Governance dashboard tail | C | Phase 1 shipped (#366); value diffs, signed trail, consent UI remain | M |
| #338 | Point-in-time tail | C | Phase 1 shipped (#364); collection/GraphQL `as_of` remain | M |
| #357 | GEO Phase 2 | D | `llms.txt` shipped (#359); `:llm` variant, JSON-LD, citations remain | M |
| #339 | RAG Phase 2 | D | `/api/ask` retrieval shipped (#361); generator + intelligence remain | M/L |
| #377 | Agentic editorial tasks | D | unbuilt theme issue; needs #375 + #339 pieces | L |
| #331 | AuthN tail: SSO + 2FA polish | E | TOTP shipped (#360); recovery codes/QR, OAuth/OIDC, SAML/passkeys remain | S–L |
| #332 | Granular RBAC Phase 2 | E | per-type editor scope shipped (#363); read-axis/per-field/custom roles remain | L |
| #333 | Runtime extensibility | park | decision + vetted compile-time registry docs shipped (#380/#383); open only for a future runtime-code (WASM) effort | park |
| #334 | Managed cloud offering | park | staging tooling shipped (#381/#384 via #382); rest is a business decision | park |
| #335 | Visual page building | F | nested-columns block shipped (#386) — the reframed scope is **done**; close with mapping | close |
| #354 | In-context editing | F | shipped (#367 + follow-ups); close or leave a residual note | close |
| #346–#350 | Pre-priority epics | F | mostly superseded by shipped work | audit & close |

**Done since the first draft, no longer planned:** #330 write-capable APIs
(closed, PR #385 — D7 reversed with sign-off) and #355 visual-editing bridge/SDK
(closed — bridge #388, Presentation console #390, per-span stega/title editing
#391, guide in `docs/visual-editing-bridge.md`).

## Sequencing — a wave 0 landing, three waves, and a hygiene track

Ordering logic: first land what's already in flight (#389); then cheap, low-risk
continuations that finish clusters fresh in the codebase; the compliance chain
(#356 → #352) ordered so the signed trail exists before the dashboard surfaces
it; multi-tenancy's multi-org enablement in the last wave because it's the
largest correctness-sensitive change.

### Wave 0 — land what's in flight

1. **PR #389 — multi-tenancy PR 2 (tenant-aware delivery + host routing)**
   - Review-current, get CI green, merge. Note from #336: main gained the #355
     visual-editing/Presentation surfaces *while #389 was in flight*; the shared
     **write** path is already tenant-scoped (`InlineEditing.write/4` scopes by
     `record.org_id`), but the #355 **reads** (`PresentationLive`
     `ContentTypes.list!` etc.) load with `actor:` only. Fold that read-scoping
     into #389 if small, else make it the first commit of PR 3.
   - Reminder from the epic memory: **no second org until the tenant is fully
     threaded** — HNSW index needs `all_tenants?`, versions need
     `attributes_as_attributes([:org_id])`.

### Wave 1 — finish what just shipped (4 small PRs + gardening)

2. **#375 — review-workflow automation triggers** (S)
   - Emit `<type>.in_review` / `<type>.returned_to_draft` through the single
     editorial funnel `KilnCMS.Webhooks.dispatch/2`. Natural emission point:
     alongside `KilnCMS.CMS.Changes.NotifyWorkflowEmail`, which already fires on
     `:submitted_for_review` / `:returned_to_draft`.
   - Add both triggers to `KilnCMS.Automation.Rule.triggers/0` (executor already
     keys on event name); add the verbs to `WebhookEndpoint.verbs/0` for parity
     (same funnel — recommended yes).
   - Tests: rule fires on `submit_for_review` transition; drain Oban
     (`drain_queues?: true`); new transition actions need a `state_machine`
     `transition` entry.

3. **#378 — shared variant/locale switcher in multiplayer preview** (S)
   - A variant/locale control in `PreviewLive` broadcasting on the existing
     preview PubSub topic; all viewers re-render to the same view. Presence
     metadata (`track_preview_viewer/5` meta) carries the group's current
     variant/locale for the presence bar.
   - Guards: only editor-role viewers may switch; late joiners adopt current
     state. Tests: two mounted `Phoenix.LiveViewTest` views, assert both switch.

4. **#331 (part 1) — 2FA recovery codes + QR enrolment** (S)
   - One-time recovery codes (hashed at rest, shown once) accepted at the 2FA
     gate; regeneration invalidates the old set. QR image for the otpauth URI on
     `/editor/settings` (pure-Elixir QR encoding — avoid a NIF). Extends
     `docs/two-factor-auth.md`.

5. **#379 — presence on the token preview** (M) — *the literal P3 item*
   - Upgrade `/preview/:token` (`PreviewController`) to a LiveView (or embedded
     live render) reusing `KilnCMSWeb.Presence.track_preview_viewer` and the
     `PreviewCursors` hook/PubSub, joining the same `{kind, id}` topic as the
     editor pop-out so internal and external viewers see each other.
   - Anonymous identity: session-stored display name with a one-field prompt,
     default "Guest N"; distinct badge so editors can tell guests apart. Never
     leak editor emails to guests — display names only.
   - Security posture unchanged: keep the tight `:preview` rate limit and token
     scoping; token viewers get presence + cursors only. Tests: presence
     join/leave; token expiry still enforced.

6. **Track F — issue gardening** (no feature code; see below).

### Wave 2 — product depth (4–5 PRs)

7. **#376 + #337 Phase 2 — newsletter automation** (M) — one PR satisfies both
   - New `:newsletter` action in `KilnCMS.Automation` whose config selects a
     segment (existing `Newsletter` segments; "all confirmed" default),
     enqueueing the existing `Newsletter.MailWorker` — this *is* #337's
     "auto-send-on-publish" hook point noted in `docs/newsletter.md`.
   - Double-send guard: a send ledger keyed on
     `{content_id, publish_version, rule_id}` — re-publish of the same version
     or a re-fired rule is a no-op; a genuinely new publish sends.
   - #337's paid-membership gating stays a separate later item.

8. **#356 (part 2) — tamper-evident audit log** (M/L)
   - Hash-chain AshPaperTrail versions: each version row stores
     `prev_hash` + `entry_hash = H(prev_hash ‖ canonical(version))`, computed in
     a change on the version resource; reuse `KilnCMS.Provenance.Canonical`
     (already float-safe post-#374). Note: version resources already carry
     `org_id` via `attributes_as_attributes` (#387) — include it in the
     canonical form.
   - Anchor: sign the chain head with `KilnCMS.Keys` (same RSA/DKIM infra as
     #340) on every publish; detached signatures.
   - Verification: `mix kiln.audit.verify` + admin endpoint returning the
     first broken link. Config-gated like provenance; genesis hash for
     pre-existing rows (history before enablement is unanchored — document).

9. **#352 (part 2) — governance dashboard tail** (M)
   - Side-by-side value diffs per version pair (block-aware diffing of the
     union-nested dumps — block id lives inside `"value"`).
   - Surface #356's chain-verification status per content item; consent
     management UI (create/link consent records in the dashboard).
   - Sequenced after #356 so the dashboard shows real signed-trail status.

10. **#357 Phase 2 — the `:llm` fired variant** (M)
    - New fired variant `:llm`: clean chunked Markdown per content item,
      rendered at publish time alongside `:html`/`:json` (add a `to_markdown/1`
      per block type with a **plain-var head** — never `%__MODULE__{}`, the
      clean-compile gotcha).
    - Link each entry from `llms.txt`; same cache-invalidation path. Expanded
      schema.org/JSON-LD + claim-citation metadata as the follow-on bullet.

11. **#331 (part 2) — OAuth2/OIDC SSO** (M)
    - AshAuthentication OAuth2 strategy (generic OIDC + one concrete provider),
      config-gated per provider via env; link to existing users by verified
      email. Doc + `docs/environment-variables.md` entries.
    - **SAML and passkeys: assess-only** — comment findings on #331; SAML needs
      a dep decision (esaml vs samly) deserving its own PR later.

### Wave 3 — the big rocks

12. **#336 PR 3+ — multi-org enablement** (L, phased; after #389)
    - Tenant-scope the remaining read surfaces flagged in #336 (the #355
      Presentation/bridge reads, plus any others the epic checklist names).
    - Then, in order: org management resource/actions + admin UI; per-tenant
      API keys and host mapping; **only then** create a second org (the epic's
      explicit gate); per-tenant search/cache/storage key prefixing validation.
    - Each phase its own PR against the epic checklist in #336.

13. **#332 Phase 2 — granular RBAC** (L)
    - Read-axis scoping + per-field write scoping + custom roles with a team
      admin UI, extending the single `EditableContentType` policy-check pattern
      from #363; per-dynamic-type support. Design note first (in-issue) —
      per-field enforcement interacts with the block union and now also with
      tenant scoping (#336); write the policy matrix before code.

14. **#339 Phase 2 — RAG intelligence** (M/L)
    - Reference local generator behind the existing `KilnCMS.Ask.Generator`
      seam (config-gated; retrieval-only remains default). Related-content +
      near-duplicate surfaces from existing block embeddings; auto-tagging
      suggestions in the editor; content-gap report from search analytics.
    - Split into 2 PRs if the generator drags.

15. **#377 — agentic editorial tasks** (L, after #375 + #339-P2)
    - AI tasks as automation actions / review-workflow gates over the existing
      MCP server (now write-scoped end-to-end thanks to #330/#385):
      internal-linking suggestions, metadata generation on transitions,
      compliance/claim checks feeding #352's dashboard.
    - Land as 2–3 separate PRs, one per task type, behind the same `action`
      enum.

16. **#338 tail — point-in-time breadth** (M, opportunistic)
    - `as_of` on collection reads + the GraphQL twin (search reads generate in
      pairs from one template in the Content macro — extend the template, both
      surfaces update); reference-graph traversal as-of a date.

### Parked (no build this wave; keep the recorded decisions)

- **#333 runtime extensibility** — decision shipped in #380/#383: vetted,
  git/hex-distributed compile-time plugins + a lightweight registry; no BEAM
  hot-loading. Issue stays open only for a future dedicated, security-reviewed
  runtime-code effort (out-of-process / WASM via Wasmex).
- **#334 managed cloud** — the repo-side slice (ephemeral staging, #382) shipped
  in #381 with its operator checklist (#384). What remains is a product/business
  decision (pricing, control plane) that rides on #336; keep parked.

### Track F — issue gardening (one pass, no feature code)

Close what's done; split what's genuinely left:

- **#335 visual page building** — the P2 assessment narrowed it to the
  nested-layout primitive, and that shipped as the first-party `columns`
  container block (PR #386). → close with a mapping comment (reorder/palette
  #29/#171, in-context #367, nesting #386).
- **#354 in-context editing** — shipped (#367) plus drag-reorder follow-up; the
  #355 arc (now closed) built on it. → close with a mapping comment unless a
  concrete residual bullet remains in the body.
- **#346 block editor + preview** — shipped across #29/#171/#30 + `PreviewLive`.
  → close with mapping.
- **#347 Spark/Ash block DSL v2** — `use Kiln.Block` + D17 dynamic content
  types shipped. → close.
- **#348 no-code builder** — dynamic content types (D17, #255/#256) + custom
  field-type registry (#266) + admin custom fields cover it. → close.
- **#349 media pipeline** — variants, focal points (#273), S3/MinIO
  (`KilnCMS.Storage.S3`), EXIF stripping shipped. Verify the two residual
  bullets (alt-text *enforcement*, usage tracking + trash/restore); split any
  unmet one as a small issue, then close the epic.
- **#350 team collaboration** — review workflow, scheduled publishing (#269),
  in-context editing (#367), multiplayer preview (#343) shipped. The one
  genuinely unbuilt bullet is **block-level comments/annotations** (no Comment
  resource exists) → split into a new scoped issue (pairs naturally with #377's
  review gates), then close the epic.

## Dependency graph

```
PR #389 ──► #336 PR 3+ (multi-org enablement)
#375 ──► #377 ◄── #339-P2
#376 ═══ #337-P2 (same PR)
#356 ──► #352-tail
#343(done) ──► #378, #379
#363(done) ──► #332-P2   (design must also account for #336 tenancy)
#330/#355 — DONE, dependency retired
```

## Suggested PR cadence

Wave 0 is landing #389. Wave 1 is 4 small PRs plus gardening, closing out the
P2 splits (including the only literal P3, #379) and up to 7 stale issues. Wave 2
is ~5 medium PRs finishing every shipped feature's Phase 2. Wave 3 is 5–7 larger
PRs led by the multi-tenancy enablement phases. Finish with `docs/deploy-p3.md`
and a max-effort code review of the wave (the P2 wave's review caught 3 real
defects; keep the practice).
