# Full-surface security audit — 2026-09-27

A whole-codebase security pass against the living threat model and policy
controls (not a feature delta). Scope matches [`.github/SECURITY.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/.github/SECURITY.md):
authz bypass, cross-tenant leak, XSS, secret exfiltration, SSRF. Out of scope:
volumetric DoS, dependency CVEs with no Kiln-specific path, operator misconfig
already warned against in deploy docs.

**Headline:** posture remains strong. Automated gates are green; Ash policies
cover every non-embedded resource; request-path `authorize?: false` sites under
`lib/kiln_cms_web` are justified. **No Critical findings.** The one High item is
the already-accepted same-origin code-injection residual. Three Medium footguns
were fixed in this pass; remaining Medium/Low items are backlog or accepted
residuals.

Prior audits: [`audit-2026-07-full-surface.md`](audit-2026-07-full-surface.md)
(feature-scoped), three security audits since June 2026 noted in the project plan.

## Phase 0 — Baseline gates

| Gate | Result |
|------|--------|
| `mix sobelow --config` | Clean |
| `mix kiln.authz.check` | Pass — no new unexplained sites; **304** still in `#1402` backlog (127 files) |
| `mix deps.audit` | No vulnerabilities |
| `mix hex.audit` | No retired / advisory packages |
| `mix test test/kiln_cms/policy_coverage_test.exs` | 6 passed |

## Surface delta (vs threat-model table)

The edge table in [`threat-model.md`](threat-model.md) under-listed several live
routes that already exist and are controlled. This audit added them to the
table: `/ready`, `/setup`, `/membership`, ActivityPub (`/actor*`), calendars,
billing webhook, content unlock, sync/schema/menus/revisions, release preview,
newsletter subscribe POST.

## Findings

| # | Severity | Status | GitHub | Location | Finding |
|---|----------|--------|--------|----------|---------|
| 1 | High (accepted residual) | Accepted | [#1661](https://github.com/The-Verscienta/kiln_cms/issues/1661) | `docs/code-injection.md`, `plugs/console_host.ex` | Same-origin site code injection can `fetch` console cookies when `KILN_CONSOLE_HOST` is unset. Mitigation exists and is opt-in. Operators on shared-origin multi-tenant deploys must set the console host. |
| 2 | Medium | **Fixed** — verify | [#1651](https://github.com/The-Verscienta/kiln_cms/issues/1651) | `priv/repo/seeds.exs` | Seeds had no `:prod` guard and published demo passwords. Now refuses `:prod` unless `ALLOW_PROD_SEEDS=confirm` **and** non-default passwords. |
| 3 | Medium | **Fixed** — verify | [#1652](https://github.com/The-Verscienta/kiln_cms/issues/1652) | `lib/kiln_cms/accounts/user.ex` `:change_password` | Password change revoked tokens via `log_out_everywhere` but did not drop live sockets. Added `EvictSessions` (same pairing as admin sign-out-everywhere). Regression in `session_eviction_test.exs`. |
| 4 | Medium | **Fixed** — verify | [#1653](https://github.com/The-Verscienta/kiln_cms/issues/1653) | `lib/kiln_cms/unsplash.ex` | Unsplash download used bare `Req` (open redirects, no byte cap). Now routes through `SafeFetch`. SSRF regression test added. |
| 5 | Medium | Open / backlog | [#1654](https://github.com/The-Verscienta/kiln_cms/issues/1654) | `lib/kiln_cms_web/tenant/org_count.ex` | After a second org exists, a node that missed PubSub can stay `:single` for up to 5 minutes, leaving strict-host off. Boot `:unknown` fails closed; stale `:single` does not. |
| 6 | Medium | Open / ops | [#1662](https://github.com/The-Verscienta/kiln_cms/issues/1662) | `TENANT_STRICT_HOST=false` | Explicit disable with ≥2 orgs is a default-org Host leak. Warned in UI; not hard-blocked. |
| 7 | Medium | Open / backlog | [#1655](https://github.com/The-Verscienta/kiln_cms/issues/1655) | `lib/kiln_cms/newsletter.ex` + `newsletter_live.ex` | Campaign create uses `authorize?: false` behind a LiveView tier check only. Demoted global admin mid-session is an acknowledged gap. Prefer Ash policy + actor. |
| 8 | Medium | Accepted residual | [#1663](https://github.com/The-Verscienta/kiln_cms/issues/1663) | `docs/threat-model.md` residual (CSP) | `connect-src` allows `ws:`/`wss:` to any host — documented 1.0 item. |
| 9 | Medium | Accepted residual | [#1664](https://github.com/The-Verscienta/kiln_cms/issues/1664) | Newsletter `GET …/confirm` | Confirm mutates on GET (mail prefetch can complete opt-in). Tokens are high-entropy; subscribe remains POST-only. Consider POST confirm later. |
| 10 | Low | **Fixed** | [#1656](https://github.com/The-Verscienta/kiln_cms/issues/1656) | `lib/kiln_cms/cms/changes/sanitize_blocks.ex` | Orphaned change module; live write path is `TypedBlocks.sanitize_attrs/1`. Audit drift, not a bypass. |
| 11 | Low | Open | [#1665](https://github.com/The-Verscienta/kiln_cms/issues/1665) | ActivityPub inbox | Actor fetch before signature verify (SSRF-bounded by SafeFetch). Documented residual. |
| 12 | Low | **Fixed** | [#1657](https://github.com/The-Verscienta/kiln_cms/issues/1657) | Newsletter honeypot | Weaker than forms honeypot (whitespace passes). |
| 13 | Low | **Fixed** | [#1658](https://github.com/The-Verscienta/kiln_cms/issues/1658) | Media workers | Missing `org_id` in legacy job args → `nil` tenant; fail-closed under default `strict_tenancy`. Align with `default_org_id()` like other workers. |
| 14 | Info | Track | [#1659](https://github.com/The-Verscienta/kiln_cms/issues/1659) | `#1402` follow-up | 304 unexplained `authorize?: false` in non-web lib — ratchet holds; SystemActor migration incomplete. |
| 15 | Info | **Documented** | [#1666](https://github.com/The-Verscienta/kiln_cms/issues/1666) | `/uploads/*` | Capability-URL residual; private storage correctly off Plug.Static. |

**Tracking:** [#1667](https://github.com/The-Verscienta/kiln_cms/issues/1667). Collab prototype pin: [#1660](https://github.com/The-Verscienta/kiln_cms/issues/1660).

## Triage (Phase 3)

| Finding | Decision |
|---------|----------|
| Critical | None |
| #1 High code-injection residual | **Accept + document** (already in threat model / code-injection.md). Do not force `KILN_CONSOLE_HOST` in this pass. |
| #2–#4 Medium | **Fix now** (shipped below). |
| #5–#9 Medium | **Backlog / accept** — issue-track #5 and #7; #6/#8/#9 already residual. |
| Low / Info | Issue-track or leave as hygiene. |

`#1402` / `#1309` authorize-bypass sweep stays a **separate track** — not expanded here.

## Remediation shipped this pass

1. **Seeds prod guard** — `priv/repo/seeds.exs`
2. **Password-change socket eviction** — `EvictSessions` on `:change_password` + test
3. **Unsplash via SafeFetch** — pin, redirect re-validate, byte cap + SSRF test
4. **Threat-model edge table** — surface delta rows added

## Reconfirmed controls (summary)

- AuthN: AshAuthentication (password, magic link, remember-me, API keys, optional OIDC, passkeys, site SSO, TOTP); `__Host-` cookies in prod; token store presence required; 2FA hold/release; rate limits on LiveView credential submits.
- AuthZ: Authorizer on all non-embedded resources; GraphQL/JSON:API/MCP inherit policies; API-key `:read` cannot write; keys cannot hard-delete; LiveRouteGuard on LiveViews.
- Tenancy: host→org; sockets take tenant from URI; audiences fail closed for foreign org; Meilisearch forces `org_id`.
- XSS: write-time TypedBlocks sanitize; delivery `raw` only post-sanitize or intentional code injection; CSP nonces; embed iframe allowlist.
- SSRF: SafeFetch/SafeUrl on content-chosen fetches (webhooks, import-url, federation, oEmbed, …); Unsplash now included.
- Public edges: forms honeypot + `:form` rate; Stripe verify-before-write; preview tokens scoped to one doc/org; bootstrap `NoAdminExists`.
- APIs: prod docs/introspection off; GraphQL complexity/depth/batch; collab prototype off unless flagged; MCP requires API key.

## Remediation backlog (ordered)

1. Shorten or eliminate OrgCount stale-`:single` window (#5).
2. Newsletter campaign create through Ash policies (#7).
3. Optional: POST newsletter confirm; tighten honeypot (#9, #12).
4. Continue `#1402` SystemActor migration.
5. Delete or re-wire orphaned `SanitizeBlocks` (#10).
6. Align media worker missing-`org_id` with `default_org_id()` (#13).
7. ~~Consider pinning `:collab_prototype, false` in `prod.exs` (Info).~~ Done (#1660).

## Method notes

Eight parallel workstreams (authn, authz, tenancy, XSS/CSP, media/SSRF, public edges, APIs/sockets, secrets/deploy) against the checklist in the audit plan, plus Phase 0 scanner baseline.
