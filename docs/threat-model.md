# Threat model: public APIs

The externally reachable surface of KilnCMS, its trust boundaries, the controls
in place, and the residual risks an operator should watch (issue #51). It is a
living document — revisit it whenever a new public route, socket, or outbound
integration is added.

Authorization internals (who-may-do-what per resource) live in
[`policy-matrix.md`](policy-matrix.md) and [`granular-rbac.md`](granular-rbac.md);
data retention and PII handling live in [`data-flows.md`](data-flows.md). This
document is about the network edge.

## Assets

- **Published content** — public by design; integrity (no unauthorized edits)
  and availability matter, confidentiality does not.
- **Draft / in-review content** — must never leak before publish.
- **Audience-restricted content** — published but readable only by users holding
  a matching audience (see the policy matrix). Confidentiality matters.
- **User accounts & roles** — credentials, password hashes, TOTP secrets,
  passkey credentials, and the `role` / `audiences` attributes driving RBAC.
- **Auth tokens** — AshAuthentication JWTs, magic-link and password-reset
  tokens, preview tokens, collab and bridge socket tokens.
- **API keys** — `kiln_…` bearer keys carrying a `:read` or `:read_write` scope.
- **Tenant isolation** — one deployment serves multiple organizations; content,
  media, branding and analytics must not cross org boundaries.
- **Media & object storage** — uploaded files and their storage credentials.
- **Outbound webhook secrets** — HMAC signing keys for delivery.
- **Form submissions** — arbitrary end-user input, frequently PII.

## Trust boundaries & entry points

Requests pass through the endpoint plug stack (`lib/kiln_cms_web/endpoint.ex`)
before routing. Three controls live there rather than in the router, and so
apply to *every* surface below: `Plugs.ClientIp` (proxy-aware `remote_ip`),
`Plugs.SetTenant` (host → organization), and `Plugs.ApiCORS` (mounted ahead of
the router so preflights are answered before route matching).

| Surface | Route(s) | Auth | Rate bucket |
|---|---|---|---|
| Public HTML delivery | `/`, `/:slug`, `/:type/:slug`, `/blog`, `/blog/:slug`, `/search`, `/*path` | none | `:delivery` |
| Probes & SEO | `/up`, `/sitemap.xml`, `/robots.txt`, `/llms.txt` | none | `:probe` |
| GraphQL | `/gql` (GET + POST), `/ws/gql` | optional JWT / API key | `:gql` |
| JSON:API | `/api/json/**` (GET/POST/PATCH/DELETE) | optional JWT / API key | `:api` |
| Headless REST | `/api/content/**`, `/api/resolve`, `/api/locales`, `/api/search`, `/api/ask`, `/api/provenance/**`, `/api/visual-editing/:type/:slug` | optional JWT / API key | `:api` |
| OpenAPI & explorer | `/api/json/open_api`, `/api/json/swaggerui` | **none, all envs** | `:docs` |
| Headless sign-in | `POST /api/auth/sign_in` | credentials → JWT | `:auth` |
| MCP (LLM authoring) | `/mcp` | **API key required** | `:api` |
| Public forms | `GET /api/forms/:slug`, `POST /forms/:slug`, `POST /api/forms/:slug` | none (no CSRF by design) | `:form` |
| Form embed | `GET /forms/:slug/embed` | none | `:delivery` |
| Preview | `/preview/:token`, `/preview/:token/live` | signed token *is* the credential | `:preview` |
| Newsletter | `/newsletter/confirm/:token`, `/newsletter/unsubscribe/:token` | signed token | `:form` |
| Auth flows | `/sign-in`, `/register`, `/reset`, `/auth/**`, `/sign-in/verify`, `/auth/passkey/*` | varies | `:auth` |
| Editor / admin LiveViews | `/editor/**`, `/media` | session cookie + role | none |
| Media blobs | `/uploads/*` (`Plug.Static`) | none | none |
| Sockets | `/live`, `/ws/collab`, `/ws/bridge` | session / signed token / API key | none |
| Dev tools | `/dev/dashboard`, `/dev/mailbox`, `/admin`, `/gql/playground` | compile-gated off in prod | — |

**The server-side Ash policies are the authorization boundary.** Every read and
mutation through GraphQL, JSON:API, REST, MCP and LiveView runs through
`Ash.Policy.Authorizer` with the request's actor and tenant. The API layers add
no authorization of their own; they inherit the resource policies. There is no
"the API is trusted" shortcut. `test/kiln_cms/policy_coverage_test.exs` fails the
build if a resource is ever registered without that authorizer.

## Controls in place

- **Authentication** — AshAuthentication: password (bcrypt), magic link (which
  deliberately does not self-provision), API keys, and optional OIDC SSO; plus
  TOTP 2FA and Wax-based passkeys/WebAuthn. Short-lived JWTs with a token store,
  and `log_out_everywhere` on password change.
- **Authorization** — per-resource `policies`, field policies hiding `role` and
  author PII, a `state == :published` filter as the public-read boundary, the
  orthogonal audience axis, granular per-type and per-field editor grants, and
  block-level `editable_by` field policies (below). Backed by the policy test
  suite and [`policy-matrix.md`](policy-matrix.md).
- **API-key scoping** — keys store only a SHA-256 hash, carry an immutable
  `:read` / `:read_write` access scope, require an expiry, and can be revoked.
  A `:read` key is refused every write action; no key may hard-delete.
- **Multi-tenancy** — `Plugs.SetTenant` resolves the org from the HTTP host
  (subdomain of `TENANT_BASE_HOST`, then custom domain) and sets it as the Ash
  tenant for the whole request, so tenant scoping applies to GraphQL and
  JSON:API without resolver changes.
- **Rate limiting** — `Plugs.RateLimit` (Hammer/ETS, per-IP) across eight
  buckets; limits in `lib/kiln_cms_web/rate_limit.ex`.
- **CSP & secure headers** — `put_secure_browser_headers` plus a per-request
  nonce-based Content-Security-Policy on browser pipelines; a narrower static
  policy for preview/forms/embeds and a relaxed one scoped to the Swagger
  explorer. Sobelow checks CSP placeholders in CI.
- **CSRF** — `protect_from_forgery` on browser and LiveView pipelines. Token
  APIs are cookieless (bearer only) and so are not CSRF-exposed. Public form
  submission and RFC 8058 one-click unsubscribe are deliberately CSRF-free;
  see the per-surface notes.
- **CORS** — Corsica, scoped to `/api` and `/gql` only, with an exact-string
  origin allowlist that **defaults to deny** in production and no
  `allow_credentials`. Browser pages stay same-origin.
- **GraphQL abuse limits** — `analyze_complexity: true, max_complexity: 200`,
  and introspection disabled in production.
- **HTTPS / HSTS** — `force_ssl` with `x_forwarded_proto` rewriting in
  `config/prod.exs`.
- **Session cookies** — signed *and* encrypted, `SameSite=Lax`, `http_only`, and
  `secure` in production.
- **SSRF protection on outbound webhooks** — `KilnCMS.Webhooks.SafeUrl`: HTTPS
  required in prod, private/loopback/link-local/metadata ranges rejected for
  both IPv4 and IPv6, DNS resolved with an all-or-nothing rule and a hard
  timeout. Delivery connects to the *pinned* resolved IP with SNI and cert
  validation kept on the original hostname, closing the DNS-rebinding window,
  and follows no redirects.
- **Upload handling** — uploads validated from bytes rather than declared type,
  EXIF stripped, and blobs served with `Content-Disposition: attachment` and
  `X-Content-Type-Options: nosniff`.
- **Static analysis & dependencies** — Credo, Sobelow, Dialyzer, and
  `mix deps.audit` (mix_audit) in CI and `mix precommit`, failing the build on a
  known-vulnerable locked dependency.

## Per-surface risks & mitigations

### Public content delivery
- **Draft leak** — mitigated by the published-state filter on public reads,
  covered by policy tests. *Watch:* any new public read action must carry the
  same filter.
- **Audience leak** — audience-restricted records require reader membership.
  *Resolved (#337 Phase 2):* the delivery payload cache is the anonymous,
  `:public`-only shape, and audience-aware renders (a member's full document, and
  the paywall teaser) bypass it entirely rather than the key gaining an audience
  axis — so a gated payload is never in the cache to be mis-keyed. Those responses
  are `private, no-store` with `Vary: Cookie`, since the public delivery headers
  (`public, max-age=60`) would otherwise let a shared cache serve one member's
  gated render to every anonymous visitor.
- **Scraping / enumeration** — content is public and the sitemap is intentional.
  The `:delivery` bucket caps volume; front with a CDN to absorb load.

### GraphQL / JSON:API / REST
- **Authorization bypass** — prevented by Ash policies running with the request
  actor and tenant; there is no unauthenticated mutation path that skips them.
- **Write surface** — `/api/json` accepts POST/PATCH/DELETE including
  publish/unpublish (#330). Gated by resource policies *and* the API-key access
  scope, not by the router. `destroy` is a soft delete; `purge` is never routed.
- **Mass assignment** — Ash actions accept only declared inputs (`accept`).
- **Query complexity** — bounded at 200; introspection off in production.
- **Error verbosity** — keep `:logger` at `:info` in prod (already set).

### MCP (`/mcp`)
- **Unauthenticated tool use** — prevented: the pipeline requires an API key
  (401 without one). The tool allowlist is compile-time and deliberately omits
  publish and destroy, so an LLM client can author and submit for review but
  cannot publish or delete.

### Headless sign-in (`POST /api/auth/sign_in`)
- **Credential stuffing / brute force** — mitigated by the `:auth` bucket and
  bcrypt cost; failures return a generic 401. *Residual:* no account lockout or
  progressive backoff (see below).
- **Token theft** — JWTs are bearer tokens; clients must store them securely and
  use TLS. Tokens are revocable via the token store.

### Public forms
- **CSRF** — deliberately absent: forms are meant to be posted from third-party
  pages. Abuse is bounded by the `:form` bucket and a honeypot field, and a
  tripped honeypot returns success so a bot cannot distinguish rejection.
- **Framing** — the embed route sets its own `frame-ancestors` from
  `EMBED_ORIGINS`. See residual risk 1: the default is permissive.
- **Submission contents** — treat as untrusted PII; retention is covered in
  [`data-flows.md`](data-flows.md).

### Preview
- **Token as credential** — `/preview/:token` verifies a signed token and then
  loads the record with `authorize?: false`, so token possession is full read
  access to that record in whatever state it is in. Tokens are the sharing
  mechanism for unpublished work; treat a leaked preview URL as a content leak.
  See residual risk 5.

### Media (`/uploads/*`)
- **Unauthenticated access** — local blobs are served by `Plug.Static` with no
  auth, no rate limit and no tenant check. Storage keys are unguessable UUIDs,
  which is the only thing standing between an unpublished asset and the world.
  `Content-Disposition: attachment` + `nosniff` prevent the bucket being used to
  serve active content. S3/MinIO deployments serve media entirely outside the
  app.

### Webhooks (outbound)
- **SSRF** — mitigated by `SafeUrl` with IP pinning (see Controls).
- **Replay / forgery at the receiver** — deliveries are HMAC-signed; receivers
  must verify the signature and timestamp.

### Other outbound calls
`Kiln.Updates` (GitHub releases, admin-triggered), `KilnCMS.Unsplash`,
Meilisearch, S3/MinIO, the mailer, and the LLM providers behind `/api/ask` and
SEO drafting all make outbound requests to *operator-configured or fixed*
endpoints, not user-supplied ones — so they are not SSRF vectors in the way
webhooks are. Note that `/api/ask` lets an anonymous caller drive an outbound
LLM request; it is config-gated and rate-limited under `:api`, but it is a cost
amplification surface.

### Object storage
- **Credential exposure** — S3 keys come from env, never committed.
- **Bucket scope** — keep the bucket public-read for delivered variants only.

## Residual risks

Known and accepted, in rough order of how much they should worry an operator.
Each is a deliberate trade-off, not an oversight — but each is worth revisiting.

1. **Form embeds default to `frame-ancestors *`.** `EMBED_ORIGINS` unset means
   `:all`, so any site may frame `/forms/:slug/embed` out of the box. Set
   `EMBED_ORIGINS` to your allowlist in production. Tracked in #562.
2. **Unknown `Host` headers resolve to the default organization.** A bare host,
   an IP, `localhost`, or an unrecognized domain silently serves the default org
   rather than erroring — deliberate single-host compatibility. On a
   multi-tenant deployment, terminate unknown hosts at the proxy. Tracked in #563.
   `Tenant.current_org_id/1` has the same default-org fallback when the
   `:current_org` assign is missing.
3. **The OpenAPI spec and Swagger explorer are unauthenticated in every
   environment**, production included. They describe the write surface. This is
   a disclosure convenience; gate them at the proxy if that is not wanted.
   Tracked in #567.
4. **Rate limiting keys on `remote_ip`.** Behind a proxy with `TRUSTED_PROXIES`
   unset, every request shares one bucket — which throttles all clients together
   and makes per-IP limits meaningless. Set `TRUSTED_PROXIES`. Tracked in #564.
5. **Preview tokens bypass authorization and tenancy.** `PreviewController`
   loads with `authorize?: false` and no tenant, and `live_session
   :token_preview` carries no `on_mount` hooks, so the preview LiveView has no
   `:current_org`. Token validity and expiry are the whole control.
6. **Four resources are world-readable by policy** —
   `Firing.PublishedArtifact`, `Firing.ReferenceEdge`, `CMS.FormField`, and
   `Search.BlockEmbedding` all declare `authorize_if always()` on reads. Each is
   deliberate and none is exposed through `json_api`/`graphql` directly, so
   reachability is via internal code paths. The notable one is
   `PublishedArtifact`: it holds *rendered* bodies, so the audience axis
   enforced on `Content` is not re-enforced at the artifact tier. Tightening
   these means touching the firing engine, search indexer and form rendering,
   and was deliberately left out of #51. Tracked in #565.
7. **Unauthenticated GraphQL runs with `actor: nil` *and* `tenant: nil`.**
   Policies still run, so the audience and published filters hold, but the
   tenant boundary does not for that request.
8. **A block field policy can be cleared by omission.** `EnforceBlockFieldPolicy`
   stops an editor setting an admin-only block field, but a headless client that
   submits a block tree without ids and omits the field gets the declared
   default — which silently clears an admin-set value. Enforcing more requires
   stable block identity on the headless write path. Tracked in #566.
9. **No account lockout or progressive backoff** on repeated auth failures —
   the `:auth` rate-limit bucket is the only control.
10. **The `:browser` pipeline is not rate-limited**, so `/`, `/developers`, all
    `/editor/**` LiveView mounts, and the account/governance export endpoints
    are unthrottled. They are session-gated (except the first two), so this is
    an availability rather than a confidentiality concern.
11. **Periodic CSP re-review** as the editor adds third-party assets. The
    runtime `img-src` is widened by `CSP_IMG_SRC` and by the Unsplash
    integration — the only externally-influenced part of the policy.
12. **Secrets rotation runbook** (DB URL, `SECRET_KEY_BASE`,
    `TOKEN_SIGNING_SECRET`, S3 keys) is not written down; pairs with
    [`backups.md`](backups.md).

## Operating the dependency audit

`mix deps.audit` ([mix_audit](https://github.com/mirego/mix_audit)) checks
`mix.lock` against the Elixir security advisory database. It runs:

- in CI, as its own **Dependency audit** job in
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml), and
- locally as part of `mix precommit`.

A new advisory affecting a locked dependency fails the build — including on a PR
that changed no dependencies, since the advisory database moves independently of
this repo. It is a separate job so that failure does not bury the lint and test
results of an unrelated change. Remediate by upgrading the dependency; if no
fixed version exists, document the accepted risk and use mix_audit's ignore
options rather than dropping the check.

The CI job fetches the advisory database explicitly before auditing. mix_audit
clones it at run time and discards the exit status of its own git commands, so a
failed fetch would otherwise leave it with zero advisories and report a green
"No vulnerabilities found" — a pass that verified nothing.
