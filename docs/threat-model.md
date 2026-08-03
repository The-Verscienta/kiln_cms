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
  a matching audience (see the policy matrix). Confidentiality matters, and since
  #337 Phase 2 the audience may be **paid for**, so a leak is also revenue loss.
  Audiences resolve per-organization and fail closed for a foreign org.
- **User accounts & roles** — credentials, password hashes, TOTP secrets,
  passkey credentials, and the `role` / `audiences` attributes driving RBAC.
- **Auth tokens** — AshAuthentication JWTs, magic-link and password-reset
  tokens, preview tokens, collab and bridge socket tokens.
- **API keys** — `kiln_…` bearer keys carrying a `:read` or `:read_write` scope.
- **Tenant isolation** — one deployment serves multiple organizations; content,
  media, branding and analytics must not cross org boundaries.
- **Media & object storage** — uploaded files and their storage credentials.
- **Outbound webhook secrets** — HMAC signing keys for delivery.
- **Payment credentials** — the provider API key and the inbound-webhook signing
  secret, both held through the `KilnCMS.Keys` provider model. The API key has
  full authority over the payment account; the signing secret is what stops
  forged entitlement grants. Off by default — an unconfigured instance exposes no
  payment surface at all.
- **Membership state** — provider customer/subscription ids, pseudonymous but a
  live external reference: acting on them from a clone would affect real billing,
  which is why the staging scrub severs them.
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
| Headless sign-in | `POST /api/auth/sign_in` | credentials → JWT | `:auth` + per-account (#478) |
| MCP (LLM authoring) | `/mcp` | **API key required** | `:api` |
| Public forms | `GET /api/forms/:slug`, `POST /forms/:slug`, `POST /api/forms/:slug` | none (no CSRF by design) | `:form` |
| Form embed | `GET /forms/:slug/embed` | none | `:delivery` |
| Preview | `/preview/:token`, `/preview/:token/live` | signed token *is* the credential | `:preview` |
| Newsletter | `/newsletter/confirm/:token`, `/newsletter/unsubscribe/:token` | signed token | `:form` |
| Auth flows | `/sign-in`, `/register`, `/reset`, `/auth/**`, `/auth/passkey/*` | varies | `:auth`; password sign-in also per-account (#478) |
| Second factor | `GET`/`POST /sign-in/verify` | signed `:pending_2fa` token + TOTP or recovery code | `:auth`; the `POST` also per-account, tighter than sign-in (#714) |
| Sign-in submit over `/live` | LiveView `"submit"` on `/sign-in` | credentials → session | `:auth`, charged on the action (#715) + per-account (#478) |
| Editor / admin LiveViews | `/editor/**`, `/media` | session cookie + role | none |
| Media blobs | `/uploads/*` (`Plug.Static`) | none | none |
| Sockets | `/live`, `/ws/collab`, `/ws/bridge` | session / signed token + per-document read / API key + per-document read | none (except the sign-in submit, above) |
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
  JSON:API without resolver changes. A host matching neither falls back to the
  default org unless `TENANT_STRICT_HOST=true`, which 404s it instead — see
  residual risk 2.
- **Rate limiting** — `Plugs.RateLimit` (Hammer/ETS, per-IP) across eight
  buckets; limits in `lib/kiln_cms_web/rate_limit.ex`. The browser sign-in is
  the one credential path no plug can reach: AshAuthentication's form is a
  LiveComponent that calls `AshPhoenix.Form.submit/2` in-process, so the
  credentials arrive as a `/live` event and pass no pipeline. It is charged the
  same `:auth` bucket anyway (#715) — `KilnCMSWeb.SignInLive` attaches the
  socket's own client address (`:peer_data`/`:x_headers`, resolved through the
  same trusted-proxy rule `Plugs.ClientIp` applies) to the form's context, and
  `Preparations.ThrottleSignIn` charges it on the action. Same bucket as the
  HTTP form, so switching transport buys no second budget; charged only when
  that context is present, so a request that already paid the plug is not
  charged twice. Password sign-in is limited on a second axis by
  `KilnCMS.Accounts.AccountThrottle` (#478): a flat per-**account** budget,
  which IP rotation cannot escape. The IP is charged first and a refusal spends
  no account budget — otherwise a flood from one address could lock out every
  account it named. Deliberately flat rather than escalating —
  a lockout that lengthens each time an attacker burns a window is a denial of
  service against any known address. A successful sign-in, a completed password
  reset and a passkey sign-in each clear it. A separate flat per-address budget
  covers the two mail-triggering requests (password reset, magic link) so
  neither becomes a mailbomb.

  The **second factor** carries its own, tighter per-account budget (#714): five
  submitted codes per fifteen minutes at `POST /sign-in/verify`, keyed on the
  account the signed pending token names, with a verified code clearing it.
  Tighter because six digits and a skew window are guessable in a way a password
  is not, and because whoever is at that prompt has already got past the first
  factor. It keys on the account rather than on the pending token for the same
  reason: `@pending_2fa_max_age` bounds nothing on its own, since re-running the
  password step mints a fresh token *and* — because that step succeeds — clears
  the sign-in counter, so an attacker holding the password renews the window for
  free. TOTP codes and recovery codes share the budget; two would be one budget
  twice as large. This refusal is a plain 429 that says so, unlike every other
  refusal in the auth flow: the account is already known to whoever is asking,
  so there is nothing to hide, and a generic "that code isn't valid" would tell
  a legitimate user their correct code was wrong.
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
  `secure` in production. Wherever `secure` is on, the cookie is also
  **`__Host-`-prefixed** (`__Host-_kiln_cms_key`), which is what makes it
  host-scoped for *writes* as well as reads: orgs are siblings under one
  registrable domain, and RFC 6265 otherwise lets script on any tenant origin
  set a same-named cookie for the parent domain. It would then outrank the
  victim's own — Plug honours the header's *first* cookie of a name, and
  RFC 6265 §5.4 sends longer `Path`s first, so `Domain=.<base_host>;
  Path=/editor` wins on exactly the authoring routes. Browsers refuse to store
  a `__Host-` cookie that is not `Secure`, `Path=/`, and `Domain`-less, so the
  sibling's write is rejected at the source; the prefix rides the same flag as
  `Secure`, and dev, test and e2e keep the bare name over plain HTTP
  (`KilnCMSWeb.SessionCookie`, #686).
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
- **Credential stuffing / brute force** — mitigated on two axes: the per-IP
  `:auth` bucket, and the per-account budget in `KilnCMS.Accounts.AccountThrottle`
  (#478), which an attacker rotating source addresses cannot escape. Bcrypt cost
  applies to both — including to a *throttled* attempt, which burns the same
  simulated hash, so response time doesn't reveal that an address is currently
  at its budget. Failures return a generic 401 and so does a throttled attempt;
  the budget keys on the *submitted* identifier, so an address with no account
  throttles identically and the refusal is not an enumeration oracle. The
  account owner is mailed once per window when attempts start being refused.
  *Residual:* this endpoint does not ask for a second factor at all — a
  2FA-enabled account's password alone returns a full JWT here, where the
  browser flow would divert to `/sign-in/verify`. Tracked in #726.
- **Token theft** — JWTs are bearer tokens; clients must store them securely and
  use TLS. Tokens are revocable via the token store.

### Editor / admin LiveViews (`/editor/**`, `/media`)
- **Router gates skipped by a url-less join** — a `/live` join whose payload
  carries neither `"url"` nor `"redirect"` matches no route, and Phoenix only
  attaches a `live_session`'s `on_mount` hooks when a route matched. So such a
  join runs none of the tier gates. The credential is the signed
  `data-phx-session` blob scraped from any page the caller was served, which
  outlives both the visit and a later demotion. *Mitigated (#688):*
  `KilnCMSWeb.LiveRouteGuard` is declared by `use KilnCMSWeb, :live_view`, so it
  is attached to the view rather than to the `live_session` and runs anyway; it
  refuses a connected join that matched no route **and whose session names a
  `live_session`** as a 404, which the channel turns into a client reload rather
  than a crash. (The `live_session` half is load-bearing: a sticky
  `live_render` child is a "main" session that legitimately carries no URL, so
  refusing on "root with no route" would put it in a reload loop.) A test walks
  every `live` route in the router and fails if its view does not carry the
  guard, which is what enforces it for plugin panels rather than assuming it.
  *Watch:* third-party LiveViews keep the framework behaviour — AshAdmin's are
  compile-gated to `:dev_routes`; AshAuthentication's remaining views
  (`/password-reset/:token`, `/confirm`, `/magic-link`, `/sign-out`) are
  unauthenticated, so a url-less join reaches no authorization it could not
  reach signed out, but it does skip `:assign_current_org` and therefore renders
  with the **default org's** branding on a tenant host (tracked in #701).
  `/sign-in`, `/register` and `/reset` are routed to `KilnCMSWeb.SignInLive`
  (#715), a Kiln module, so those three do carry the guard and are outside that.
- **Session as the credential** — the whole surface is gated by the session
  cookie plus the per-org effective tier, so the cookie's integrity is the
  boundary; see the `__Host-` prefix under Controls (#686).

### Public forms
- **CSRF** — deliberately absent: forms are meant to be posted from third-party
  pages. Abuse is bounded by the `:form` bucket and a honeypot field, and a
  tripped honeypot returns success so a bot cannot distinguish rejection.
- **Framing** — the embed route sets its own `frame-ancestors` from
  `EMBED_ORIGINS`, which defaults to same-origin only (#562), so cross-site
  embedding is opt-in.
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

1. ~~**Form embeds default to `frame-ancestors *`.**~~ **Closed in #562.**
   `EMBED_ORIGINS` unset now means same-origin only, so cross-site embedding is
   opt-in, and a malformed value closes the policy rather than widening it.
   `EMBED_ORIGINS=*` restores the old any-site behaviour if a deployment
   genuinely wants it. See [forms.md](forms.md#embedding-on-another-site).
   **Remainder:** the allowlist is deployment-global while forms are org-scoped,
   so on a multi-org instance an origin added for one org may frame every org's
   forms. Tracked in #648.
2. **Unknown `Host` headers resolve to the default organization — unless
   `TENANT_STRICT_HOST` is set.** #563 added the control; it ships **off**, so
   an existing deployment is exactly as exposed as before until an operator
   turns it on. Do that on any multi-tenant deployment: an unresolvable `Host`
   is then refused with a bare 404 rather than served the default org, across
   everything the router serves plus LiveView mounts and the GraphQL and
   visual-editing sockets. The app logs a warning at boot when it is off and
   more than one org exists. Terminating unknown hosts at the proxy is still
   worth doing as well.

   Surfaces outside the control, none of which reads the ambient tenant:
   `Plug.Static` (both mounts, including `/uploads` under the local storage
   adapter — UUID-keyed assets answer on any host, as they would behind a CDN);
   the health probes and the payment-provider webhook, both deliberately exempt
   so the control cannot fail a deployment's own liveness check or silently drop
   billing events. `/ws/collab` was a fourth until #655 wired it through
   `Tenant.fetch_org/1` like the other two sockets.

   A **connected** LiveView mount was outside it in a different way until #654,
   and strict matching would not have closed it: the host was known, just not
   the caller's. `socket.host_uri` is rebuilt from the client's join payload
   rather than from a `Host` header, and `check_origin` admits every subdomain
   of the base host, so a client served one org's page could join naming
   another's and take its `:current_org` — the assign editor LiveViews pass as
   the `tenant:` on authoring writes. `/live` now carries `connect_info: [:uri]`
   like the other three sockets and resolves from the host it connected on,
   refusing a claim that names a different org. Per-org authorization
   (`Scoping.effective_tier/2`, fail-closed on a foreign org) is still what
   authorizes the actions; this makes the assign mean what its callers assume.

   **Two things about the refusal itself** (#659). It is halted above the router
   and so above every rate limiter, which left one uncached organization lookup
   per request; unresolvable hosts are now cached as misses (in a cache of their
   own, so a flood cannot evict published content) rather than bounded by a
   per-IP budget, which could not tell a flood from a legitimate request behind
   the same NAT and so would have refused hosts that exist. And its plain-text
   body is distinguishable
   from the branded HTML 404 a *known* host gets for an unmatched path, so a
   dictionary sweep enumerates configured org slugs and custom domains. That
   second one is accepted rather than closed — the alternatives are showing
   unknown hosts the branded page (the default-org leak this control exists to
   prevent) or degrading every tenant's real 404, to hide names already public
   in DNS and TLS certificates. Terminate unknown hosts at the proxy if your
   tenant list is confidential.

   The quieter half is closed unconditionally: `Tenant.current_org_id/1` now
   **raises** when the `:current_org` assign is missing rather than reading the
   default org, so a forgotten `SetTenant` plug or `:assign_current_org`
   on_mount fails loudly in test instead of serving the wrong tenant in
   production.3. **The OpenAPI spec and Swagger explorer are unauthenticated in every
   environment**, production included. They describe the write surface. This is
   a disclosure convenience; gate them at the proxy if that is not wanted.
   Tracked in #567.
4. **Rate limiting keys on `remote_ip`.** Behind a proxy with `TRUSTED_PROXIES`
   unset, every request shares one bucket — which throttles all clients together
   and makes per-IP limits meaningless. Set `TRUSTED_PROXIES`. **No longer
   silent (#564):** the app logs a warning, once per node, the first time a
   request arrives carrying a forwarding header (`Forwarded`, `X-Forwarded-For`,
   `X-Client-IP` or `X-Real-IP`) while no proxies are trusted. The
   trap itself remains — honouring the header without a trusted-proxy list would
   be worse, since it is spoofable — so this is detection, not a fix.

   Two things about `:auth` specifically, both worse for addresses many people
   share (an office NAT, or any deployment in the trap above). **One successful
   browser sign-in now spends three of its twenty:** the page GET, the submit
   (#715), and the token-exchange GET the LiveView redirects to on success. A
   failed guess spends one, so the budget bites a legitimate user harder than
   the attacker it is aimed at — roughly six sign-ins per minute per address.
   And **the refusal reads as a wrong password**, deliberately: it is the same
   generic `AuthenticationFailed` a bad credential produces, with no 429 and no
   `Retry-After`, because distinguishing it would tell an attacker exactly when
   their window rolls. The cost is that a throttled user is told the wrong
   thing. Both are accepted rather than closed; a per-address `:auth` limit that
   is generous enough never to inconvenience a shared egress is not a limit.
   `TRUSTED_PROXIES` is what makes the buckets per-*client* and is the real
   remedy on any deployment behind a proxy.
5. **Preview tokens bypass authorization and tenancy.** `PreviewController`
   loads with `authorize?: false` and no tenant. Token validity and expiry are
   the whole control. (`live_session :token_preview` does now carry
   `:assign_current_org`, added in #563, so the preview LiveView resolves the
   host it is served from — but the token lookup itself is still tenant-less.)
6. ~~**Four resources are world-readable by policy.**~~ **Closed in #565.**
   `Firing.PublishedArtifact`, `Firing.ReferenceEdge`, `CMS.FormField` and
   `Search.BlockEmbedding` no longer declare `authorize_if always()` on reads:

   - `PublishedArtifact` — the one that mattered, because it holds *rendered*
     bodies and #337 Phase 2 made gated content *paid* rather than merely
     restricted. Its read now runs `Firing.Checks.DocumentReadable`, which
     re-reads the source document under the caller's own authorization, so the
     audience axis holds at the artifact tier too. It was never exploitable over
     HTTP (every path resolved the record through the audience-gated
     `Firing.Delivery.published/4` first); what is closed is the *future*
     internal caller that would have read one without that resolution.
   - `ReferenceEdge`, `BlockEmbedding` — enumeration surfaces (the link graph
     including draft sources; `ancestor_context` block text from every indexed
     document), now editor-and-up.
   - `FormField` — reads now filter on `form.active == true`, mirroring the
     parent `Form`'s visibility instead of relying on it being enforced
     elsewhere.

   Delivery, the re-fire wave, the indexer and form rendering were unaffected
   because they read as the system (`authorize?: false`). See
   [`policy-matrix.md`](policy-matrix.md) for the resulting grants.
7. **Unauthenticated GraphQL runs with `actor: nil` *and* `tenant: nil`.**
   Policies still run, so the audience and published filters hold, but the
   tenant boundary does not for that request.
8. **A block field policy can be cleared by omission.** `EnforceBlockFieldPolicy`
   stops an editor setting an admin-only block field, but a headless client that
   submits a block tree without ids and omits the field gets the declared
   default — which silently clears an admin-set value. Enforcing more requires
   stable block identity on the headless write path. Tracked in #566.
9. **Per-account throttling is per node, in memory, and keyed on
   attacker-chosen strings.** `AccountThrottle` (#478) holds its budgets in ETS,
   so a restart forgives every accumulated attempt and a second node would carry
   its own counters — the same trade `KilnCMSWeb.RateLimit` makes, and deliberate:
   counters on the user row would turn every guess into a write to a row the
   attacker chooses, and would leave an unknown address with nowhere to count,
   which is what reopens account enumeration. Two consequences to watch: unlike
   the per-IP buckets the key space is unbounded (one row per distinct address
   *submitted*, for the window's length), and an attacker who spends a victim's
   mail budget delays that victim's own reset mail until the window rolls — the
   suppression is logged for exactly that reason. Revisit if Kiln is ever
   deployed multi-node.
10. **The `:browser` pipeline is not rate-limited**, so `/`, `/developers`, all
    `/editor/**` LiveView mounts, and the account/governance export endpoints
    are unthrottled. They are session-gated (except the first two), so this is
    an availability rather than a confidentiality concern.

    The `/live` socket is unthrottled in the same way, and more broadly: it has
    no limiter on joins or on events at all. The one thing that used to make
    that a *confidentiality* concern is closed — the sign-in submit is a
    LiveView event, and #715 charges it the `:auth` bucket on the action rather
    than at a plug it never passes, so brute force over the socket is bounded
    per address exactly as the HTTP form is. What remains is volume: joins are
    uncounted, so a caller replaying a scraped session token pays nothing per
    attempt, and #700 notes that a *malformed* join costs an error-tracker
    event. Tracked in #678 and #700.
11. **Periodic CSP re-review** as the editor adds third-party assets. The
    runtime `img-src` is widened by `CSP_IMG_SRC` and by the Unsplash
    integration — the only externally-influenced part of the policy.
12. **Secrets rotation runbook** (DB URL, `SECRET_KEY_BASE`,
    `TOKEN_SIGNING_SECRET`, S3 keys) is not written down; pairs with
    [`backups.md`](backups.md).
13. ~~**The collaborative-editing socket is scoped by topic, not by
    tenancy.**~~ **Closed by #655.** The socket token still names only a user,
    so it establishes *who* and nothing more; `CollabChannel.join/3` now
    resolves the topic to a real document, loads it as that user under the
    connection's org, and authorizes the `:autosave` **write** — not the read,
    which is the wider scope and would have let a reader author, since the
    checkpoint persists with `authorize?: false`. The socket resolves its tenant
    from the connect URI, so it is inside `TENANT_STRICT_HOST` like the other
    two; the doc key is rebuilt from the resolved record rather than the client's
    topic string; and `Collab.Crdt.Checkpoint` writes back under the document's
    own org rather than `default_org_id/0`. Every refusal reports the same "not
    found", so the channel answers no question a caller could not already answer
    over HTTP.

    **Still open, and general to every socket:** authorization runs at connect
    and join and is never revisited. Nothing calls `Endpoint.disconnect/1`, so
    deleting an account, demoting it, or narrowing its scopes does not evict a
    live session — it keeps what it was granted until the socket drops (at most
    the token's 24 hours, in practice as long as the tab stays open).

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
