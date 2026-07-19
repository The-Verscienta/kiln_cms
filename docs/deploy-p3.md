# Deploying the P3 waves

Operator checklist for the P3 feature arc (docs/p3-plan.md): waves 0–3 —
review-workflow events (#375), shared preview switcher (#378), 2FA recovery
codes + QR (#331 pt 1), token-preview presence (#379), newsletter automation
(#376/#337), signed history anchors + governance phase 2 (#356/#352), the
`:llm` fired surface (#357), OIDC SSO (#331 pt 2), the point-in-time
collection view (#338), content intelligence (#339), and the automation
intelligence reactions (#377).

Deploy = the usual manual Coolify **Redeploy**; migrations run on boot.

## Merge order (stacked PRs)

`#399 → #406` (newsletter automation is stacked on the review-events branch;
retarget #406 to `main` after #399 merges) and `#411 → #412` (automation
intelligence is stacked on content intelligence). Everything else is
independent; #408 and #410 both touch `ArtifactController`, so whichever
merges second needs a trivial rebase.

## Migrations (all safe, additive)

| PR | Migration |
| --- | --- |
| #402 | `users.totp_recovery_hashes` (`text[] not null default []`) |
| #406 | `newsletter_sends.automation_rule_id` + `content_published_at` + partial-unique dedupe index |
| #407 | `history_anchors` table + lookup index |
| #409 | `user_identities` table |

No backfills required; no locks beyond ordinary DDL.

## Config & env

- **OIDC SSO is compile-gated OFF.** To enable: set
  `config :kiln_cms, :sso_oidc, enabled: true`, rebuild, and provide
  `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` / `OIDC_ISSUER` /
  `OIDC_REDIRECT_URI` (see docs/sso.md — note `assume_email_verified` for
  claim-omitting IdPs like Entra, and register the
  `<redirect>/user/sso/callback` URL at the IdP).
- **History anchors default ON** (`:audit_anchors_enabled`) — anchors mint at
  each publish; signing activates automatically when the provenance signing
  key (#340) is configured. Verify fleet-wide with `mix kiln.audit.verify`.
- No new Oban queues; POOL_SIZE guidance unchanged from the P2 checklist.

## Post-deploy actions

1. **Re-fire sweep for the `:llm` surface** (#357): content published before
   this deploy has no `:llm` artifact until re-fired. Either republish over
   time (each publish fires it) or run a bulk re-fire; until then
   `?surface=llm` answers a retryable 503 for old content and `llms.txt` `md`
   links to it 503 as well.
2. **Webhook review events are opt-in** (#375 hardening): newly created
   endpoints subscribe to the published lifecycle only; select
   `*.in_review` / `*.returned_to_draft` explicitly on endpoints that should
   receive draft-carrying review events. Pre-existing endpoints keep their
   stored lists (they never included the new events).
3. **Newsletter auto-send** (#376): create the rule at `/editor/automation`
   ("on `post.published` → `newsletter`", optional `segment_id`/`subject`).
   One campaign per {rule, content, publish revision}; default-locale variant
   only.
4. **Intelligence reactions** (#377) need semantic search enabled
   (`KilnCMS.Search semantic: true` + an embedding backfill via
   `mix kiln.embed_all`) — without it, `:flag_duplicates`/`:suggest_tags`
   and `/related` are clean no-ops.
5. **Governance dashboard** now shows the chain verdict per document; after a
   provenance-key rotation old anchors read "signed under a previous key"
   (never TAMPERED) — see docs/editorial-consent.md.

## Rollback notes

Every feature is config- or data-gated: disable anchors via
`:audit_anchors_enabled`, SSO via the compile gate, newsletter automation by
disabling the rule. Migrations are additive and safe to leave in place on a
rollback.
