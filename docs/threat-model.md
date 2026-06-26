# Threat model: public APIs

Scope for the Phase 8 security-hardening work (issue #51). This documents the
externally reachable surface of KilnCMS, the trust boundaries, the controls
already in place, and the residual risks an operator should watch. It is a
living document — revisit it whenever a new public route, API, or integration is
added.

Authorization internals (who-can-do-what) live in
[`docs/policy-matrix.md`](policy-matrix.md); this doc is about the network edge.

## Assets

- **Published content** — public by design; integrity (no unauthorized edits)
  and availability matter, confidentiality does not.
- **Draft / in-review content** — must never leak before publish.
- **User accounts & roles** — credentials, password hashes, and the `role`
  attribute that drives RBAC.
- **Auth tokens** — AshAuthentication JWTs (session + bearer) and the magic-link
  / password-reset tokens.
- **Media & object storage** — uploaded files and their storage credentials.
- **Outbound webhook secrets** — HMAC signing keys for delivery.

## Trust boundaries & entry points

| Surface | Route(s) | Auth | Actor |
|---------|----------|------|-------|
| Public HTML delivery | `/`, `/:slug`, `/<type>/<slug>`, `/sitemap.xml`, `/robots.txt` | none | anonymous |
| Health probes | `/up`, `/ready` | none | anonymous |
| GraphQL | `/gql` | Bearer (optional) | user or anonymous |
| JSON:API | `/api/json` | Bearer (optional) | user or anonymous |
| Headless content/artifact delivery | `/api/...` | Bearer (optional) | user or anonymous |
| Headless sign-in | `/api/auth/sign_in` | credentials → JWT | anonymous → user |
| Swagger UI / OpenAPI | `/swaggerui`, `/api/open_api` | none | anonymous |
| Editor / admin LiveViews | `/editor/*`, `/admin` | session cookie | editor/admin |
| Auth flows | `/sign-in`, `/register`, `/auth/*`, `/password-reset/*` | varies | anonymous → user |

The **server-side Ash policies are the authorization boundary** — every read and
mutation through GraphQL, JSON:API, REST, LiveView, and AshAdmin runs through
`Ash.Policy.Authorizer` with the bearer/session actor. The API layers do not add
their own authorization; they inherit the resource policies. This is the single
most important property: there is no "API is trusted" shortcut.

## Controls in place

- **Authentication** — AshAuthentication (password + magic link), bcrypt hashes,
  short-lived JWTs, token store with presence check, and `log_out_everywhere` on
  password change. Public reads default to anonymous; elevated actions require an
  authenticated actor whose `role` satisfies the policy.
- **Authorization** — per-resource `policies`, field policies hiding `role` from
  non-owners, and a `:published`-state filter as the security boundary on public
  reads. Backed by the policy test suite and `docs/policy-matrix.md`.
- **Rate limiting** — `KilnCMSWeb.Plugs.RateLimit` (Hammer-backed) on the `:gql`,
  `:api`, and `:auth` pipelines, so the unauthenticated GraphQL/JSON/REST and
  sign-in endpoints are throttled per client. Tune limits in
  `lib/kiln_cms_web/rate_limit.ex`.
- **CSP & secure headers** — `put_secure_browser_headers` plus an explicit
  Content-Security-Policy on the browser pipelines (a relaxed, scoped CSP only
  for the Swagger explorer). Sobelow checks the CSP placeholders in CI.
- **HTTPS / HSTS** — `force_ssl` enforced in `config/prod.exs` (see
  [`docs/domain-and-ssl.md`](domain-and-ssl.md)).
- **SSRF protection on webhooks** — outbound webhook targets are validated by
  `KilnCMS.Webhooks.SafeUrl`: HTTPS required in prod, and DNS resolution rejects
  private/loopback/link-local addresses so a webhook cannot be pointed at
  internal services or cloud metadata endpoints.
- **CSRF** — `protect_from_forgery` on browser/LiveView pipelines. Token APIs are
  cookieless (bearer only), so they are not CSRF-exposed.
- **Static analysis & deps** — Sobelow, Credo, and now `mix deps.audit`
  (mix_audit) run in CI and `mix precommit`, failing the build on a known-vulnerable
  dependency.

## Per-surface risks & mitigations

### Public content delivery
- **Draft leak** — mitigated by the `state == :published` filter on public reads;
  covered by policy tests. *Watch:* any new public read action must carry the
  same filter.
- **Enumeration / scraping** — content is public; sitemap is intentional. No PII
  is exposed. Rate limiting is not applied to HTML delivery (cacheable); front it
  with a CDN (see [`docs/cdn.md`](cdn.md)) to absorb load.

### GraphQL / JSON:API / REST
- **Authorization bypass** — prevented by Ash policies running with the request
  actor; there is no unauthenticated mutation path that skips them.
- **Query-complexity / depth abuse (GraphQL)** — *residual.* Rate limiting caps
  request volume, but a single deep/expensive query is not yet bounded. *Action:*
  consider Absinthe complexity analysis + max depth if the GraphQL endpoint is
  exposed to untrusted clients. Tracked as a follow-up.
- **Mass-assignment** — Ash actions accept only declared inputs (`accept`),
  closing over-posting.
- **Error verbosity** — keep `:logger` at `:info` in prod (already set) and avoid
  leaking internals in API errors.

### Headless sign-in (`/api/auth/sign_in`)
- **Credential stuffing / brute force** — mitigated by the `:auth` rate-limit
  pipeline and bcrypt cost. *Watch:* monitor 401 rate via the `/ready`/telemetry
  signals; consider account lockout/backoff if abuse appears.
- **Token theft** — JWTs are bearer tokens; clients must store them securely and
  use TLS. Tokens are revocable via the token store.

### Webhooks (outbound)
- **SSRF** — mitigated by `SafeUrl` (HTTPS + private-range DNS rejection).
- **Replay / forgery at the receiver** — deliveries are HMAC-signed; receivers
  must verify the signature and timestamp.

### Object storage / media
- **Credential exposure** — S3 keys come from env (`AWS_*`), never committed.
- **Unrestricted upload** — uploads are validated/processed server-side; keep the
  bucket scoped to public-read for delivered variants only.

## Residual risks / follow-ups

1. GraphQL query complexity & depth limiting (not yet enforced).
2. Automated account lockout/backoff on repeated auth failures (rate-limit only
   today).
3. Periodic re-review of CSP as the editor adds third-party assets.
4. Secrets rotation runbook (DB URL, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`,
   S3 keys) — pairs with [`docs/backups.md`](backups.md).

## Operating the dependency audit

`mix deps.audit` (the [mix_audit](https://github.com/mirego/mix_audit) package)
checks `mix.lock` against the Elixir security advisory database. It runs:

- in CI (the **Dependency audit** step in `.github/workflows/ci.yml`), and
- locally as part of `mix precommit`.

A new advisory affecting a locked dependency fails the build. Remediate by
upgrading the dependency; if a fix is genuinely unavailable, document the
accepted risk and pin via mix_audit's ignore options rather than dropping the
check.
