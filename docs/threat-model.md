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
- **Outbound webhook secrets** — HMAC signing keys for delivery, encrypted at
  rest with `KilnCMS.Keys.Vault`.
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
| GraphQL | `/gql` (GET + POST), `/ws/gql` | optional JWT / API key | `:gql` (per operation, on both transports), `:gql_join` (socket connects) |
| JSON:API | `/api/json/**` (GET/POST/PATCH/DELETE) | optional JWT / API key | `:api` |
| Headless REST | `/api/content/**`, `/api/resolve`, `/api/locales`, `/api/search`, `/api/ask`, `/api/provenance/**`, `/api/visual-editing/:type/:slug` | optional JWT / API key | `:api` |
| OpenAPI & explorer | `/api/json/open_api`, `/api/json/swaggerui` | none — and **not served in prod** unless `API_DOCS_ENABLED` (#567); the document (never the explorer) also answers any valid API key | `:docs` |
| GraphQL SDL | `GET /api/graphql/schema.graphql` | none where introspection is on; **API key required** in prod unless `GRAPHQL_INTROSPECTION_ENABLED` | `:docs` |
| Headless sign-in | `POST /api/auth/sign_in` | credentials → JWT, or a pending token for a 2FA account | `:auth` + per-account (#478) |
| Headless second factor | `POST /api/auth/sign_in/verify` | encrypted pending token + TOTP or recovery code | `:auth`; the same per-account second-factor budget as the browser prompt (#714, #726) |
| Media upload | `POST /api/media`, `/api/media/import-url`, `/api/media/uploads[/complete]` | JWT / API key; `:read_write` + editor, checked **before** `POST /api/media`'s body is parsed (the endpoint leaves it unread) | `:api` + `:media_upload` |
| MCP (LLM authoring) | `/mcp` | **API key required** | `:api` |
| Public forms | `GET /api/forms/:slug`, `POST /forms/:slug`, `POST /api/forms/:slug` | none (no CSRF by design) | `:form` |
| Form embed | `GET /forms/:slug/embed` | none | `:delivery` |
| Preview | `/preview/:token`, `/preview/:token/live` | signed token *is* the credential | `:preview` |
| Newsletter | `/newsletter/confirm/:token`, `/newsletter/unsubscribe/:token` | signed token | `:form` |
| Auth flows | `/sign-in`, `/register`, `/reset`, `/auth/**`, `/auth/passkey/*` | varies | `:auth`, except `POST /auth/*/password/register`, which takes `:register` **instead** so the two registration doors agree (#724) |
| Second factor | `GET`/`POST /sign-in/verify` | signed `:pending_2fa` token + TOTP or recovery code | `:auth`; the `POST` also per-account, tighter than sign-in (#714) |
| Credential submits over `/live` | LiveView `"submit"` on the sign-in, register, reset-request and magic-link forms — **all four render on all three auth pages** | credentials → session / account / mail | charged on the *action*, since no plug can reach them: sign-in `:auth` (#715) + per-account (#478); registration `:register` (#724); reset and magic-link `:auth` (#724) + the per-address mail budget |
| Editor / admin LiveViews | `/editor/**`, `/media` | session cookie + role | none, except the three TOTP actions on `/editor/settings`: per-account, the second factor's own bucket (#727) |
| Media bytes | `/media/:id/download`, `/media/:id/stream` | session (a gated item needs its audience) | `:delivery` |
| Image transforms | `/media/:id/t/:ops` | session (same read as the download); unsigned URLs allowlisted, signed ones HMAC-checked | `:media_transform` per request + `:media_render` per cache miss, plus a per-node render gate |
| Media blobs | `/uploads/*` (`Plug.Static`) | none | none |
| Sockets | `/live`, `/ws/collab`, `/ws/bridge` | session / signed token + per-document read / preview token (one document, re-verified until it expires) or API key + per-document read | `/live` root joins `:live_join` per address (#1183); every frame on a `/ws/collab` connection `:collab_event` per account (#1305); otherwise none (except the sign-in submit, above) |
| Dev tools | `/dev/dashboard`, `/dev/mailbox`, `/admin`, `/gql/playground` | compile-gated off in prod | — |

**`/ws/collab` is a prototype surface.** Its joins are refused unless
`config :kiln_cms, :collab_prototype` is set, and that is set only in
`config/dev.exs` and `config/test.exs` — so a production build carries the socket
but accepts no CRDT session (#1324, and
[collaborative-editing-spike.md](collaborative-editing-spike.md)). Everything
below about the collab room is modelled as if it were live, because that is the
bar it has to clear before it can be enabled; it is not a live surface today.

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
  default org unless strict host matching is on — `TENANT_STRICT_HOST=true`, or
  unset on a deployment with more than one org (#1547) — which 404s it instead;
  see residual risk 3.
- **Rate limiting** — `Plugs.RateLimit` (Hammer/ETS, per-IP) across nine
  buckets; limits in `lib/kiln_cms_web/rate_limit.ex`. **The credential forms
  submit where no plug can reach them:** each is an AshAuthentication
  LiveComponent calling `AshPhoenix.Form.submit/2` in-process, so the
  credentials arrive as a `/live` event and pass no pipeline. (`auth_routes`
  also generates a POST route per strategy action as the non-JS fallback; those
  *are* plug-reachable, which is why the registration one is charged
  `:register` there too — see `KilnCMSWeb.Plugs.AuthRateLimit`.) And all four —
  sign-in, register, reset-request, magic-link — render on all three of
  `/sign-in`, `/register` and `/reset`, hidden from each other only by a CSS
  class, so which page a caller is on bounds nothing.

  They are charged on the *action* instead (#715 for sign-in, #724 for the
  other three) — `KilnCMSWeb.SignInLive` attaches the
  socket's own client address (`:peer_data`/`:x_headers`, resolved through the
  same trusted-proxy rule `Plugs.ClientIp` applies) to the form's context, and
  `Preparations.ThrottleSignIn` charges it on the action. Same bucket as the
  HTTP form, so switching transport buys no second budget; charged only when
  that context is present, so a request that already paid the plug is not
  charged twice. Every one of these charges from a `before_action` hook rather
  than from the `prepare`/`change` body, because those run per changeset build
  and `AshPhoenix.Form.validate/2` builds one **per keystroke** on a
  `phx-change` form — a charge there would lock a user out while they typed.

  **Registration gets its own `:register` bucket** rather than a share of
  `:auth` (#724): it was the unbounded one, at a bcrypt hash and a confirmation
  mail per socket event, but sharing would let a burst of legitimate sign-ups
  lock *sign-in* for everyone behind one office NAT — the shared-NAT trade
  residual risk 5 records. It carries no per-*account* budget, because there is
  no account yet and the address being registered is attacker-chosen: keying on
  it would let anyone deny a specific address its first registration. Password sign-in is limited on a second axis by
  `KilnCMS.Accounts.AccountThrottle` (#478): a flat per-**account** budget,
  which IP rotation cannot escape (twenty attempts per fifteen minutes — see the
  #762 note below on why it is not ten). The IP is charged first and a refusal spends
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
  reason: the pending token's five-minute life bounds nothing on its own, since
  re-running the password step mints a fresh one. Since #742 that renewal costs
  a unit of the *sign-in* budget rather than being free — it no longer clears
  on a password that stops at the code prompt — so the two budgets now compose
  rather than one cancelling the other. TOTP codes and recovery codes share the budget; two would be one budget
  twice as large. This refusal is a plain 429 that says so, unlike every other
  refusal in the auth flow: the account is already known to whoever is asking,
  so there is nothing to hide, and a generic "that code isn't valid" would tell
  a legitimate user their correct code was wrong.

  Since #742 the sign-in budget and the second-factor budget **compose**: a
  password that stops at the code prompt no longer clears the first, so an
  account whose second factor is locked out spends first-factor budget on every
  retry — and both controllers tell a refused user to do exactly that. The
  owner can reach this state alone, because #727 shares the second-factor
  bucket with `/editor/settings`: fumble five codes regenerating recovery
  codes, then retry the password, and the first factor can lock too for the tail
  of its own window. A password reset clears both and is the remedy to offer.

  **#762 pulled that lever**: the sign-in budget is now **twenty** per fifteen
  minutes, not ten. Twenty keeps an attacker bound in the same order of
  magnitude — still not unlimited guesses, still one window's tail at worst —
  while putting the self-inflicted compounding case out of practical reach, since
  it now takes twenty password retries inside one window rather than ten. The
  alternatives were rejected as riskier than moving a number: refunding the
  first-factor unit when the second factor refuses reopens the unbounded
  token-minting loop #742 exists to close, and a "hand back one unit" primitive
  would mean `hit/3` is no longer one atomic increment-and-compare, which is
  what stops a simultaneous burst all reading "under budget" and all proceeding.

  A lockout at either sign-in gate **mails the owner** (#728), and it is a much
  stronger signal than the password alert above: reaching that prompt requires
  a pending token, and a pending token is only minted once a **first factor has
  already succeeded**. That case used to be structurally invisible to the
  password alert — sustaining the grind means re-running the first factor,
  which succeeds and forgave the sign-in counter every time, so its budget was
  never reached. Before #728 the one case where a primary credential was
  provably in someone else's hands produced no notification at all. #742 closed
  that reset, so the password alert can now fire on the same attack too; this
  one still rings first, because the second-factor budget is the tighter.

  The copy is careful about two things the obvious wording gets wrong. It does
  **not** say "someone has your password": `AuthController.success/4` is the
  callback for every strategy, so a magic link or an OIDC assertion reaches the
  prompt the same way, and for those users the compromised credential is a
  mailbox or an IdP — the mail names all three rather than sending them to
  secure the wrong account. And it does not assume an attacker, because the
  budget is shared with the settings forms (#727), so an owner who fumbles
  codes there and then signs in trips it with nobody attacking them. Its
  once-per-six-hours budget is separate from the password alert's, so the
  weaker signal cannot suppress the stronger one in exactly the order an attack
  produces them; the refusal is logged when the mail goes and when it is
  suppressed; and a delivery failure hands the window back rather than
  swallowing six hours of alerts with it.
  *Watch:* a lockout confined to `/editor/settings` — no sign-in attempt after
  it — still notifies nobody (#757); different news, because the person there
  holds a session rather than a first factor.
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
- **GraphQL abuse limits** — one document pipeline for `/gql` and `/ws/gql`
  (`KilnCMSWeb.GraphqlLimits`). Every document gets complexity analysis with a
  cap of 200, a depth limit of 15 and a token limit of 2,000. These are pinned
  where the pipeline is built, because the socket's Absinthe options are
  replaced after its first document and a plug can override the HTTP ones.
  To-many relationships without a `limit` are priced at five rows each, so a
  relationship cycle (`relatedPosts`, `featuredImage { featuredPosts }`) cannot
  nest for free. A batched `/gql` body may carry 10 operations at most, and each
  is charged to `:gql` (`KilnCMSWeb.Plugs.GraphqlBatchLimit`). Introspection is
  refused in production by a pipeline phase that reads the parsed document, so
  a batched body and a socket document are checked like a single query. Each
  document sent over `/ws/gql` is charged to `:gql` too, under the address the
  socket connected from (`KilnCMSWeb.GraphqlLimits.SocketDocumentBudget`); a
  subscription's pushes are not. Until 2026-09 the cap applied only to single
  `/gql` requests: the socket had no limits, a batch was one request whatever
  it carried, a batched body got past the introspection block, and a socket
  could send any number of documents once connected.
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

  The **remember-me** cookie is inside the same rule (#699), and had to be: it
  is the better credential of the two — a 30-day token rather than a browser
  session — and `sign_in_with_remember_me` runs ahead of `load_from_session`, so
  planting one signs a visitor in who has no session on the target host at all.
  AshAuthentication's default writer hardcodes `secure: Mix.env() != :dev` and
  leaves the name unprefixed, so `KilnCMSWeb.AuthController` overrides both the
  writer and the deleter; both take their attributes from
  `SessionCookie.remember_me_options/1` and the name from
  `remember_me_key/1` — which is also what the *read* path keys on, since the
  strategy's `cookie_name` is set from it. Sign-out deletes it through the same
  override, so the two sides cannot drift into a deletion the browser will not
  match.

  It is read on `:browser_auth` only, never on `:browser`. Signing a visitor in
  writes the session, so `Plug.Session` emits `Set-Cookie` — and `:browser`
  serves public delivery pages marked `public, max-age=60`, where a shared cache
  would be free to store one editor's session cookie against a public URL. A
  remembered visitor who opens an authoring URL is redirected to `/sign-in`,
  signed in there, and sent on.

  *Residual:* signing out revokes only the token in the browser doing it, so a
  cookie copied elsewhere keeps working until it expires — or until something
  revokes every stored token for the account. Two things do: a password change
  (`log_out_everywhere` with `apply_on_password_change? true` on
  `KilnCMS.Accounts.User`, since #734), and an administrator's *Sign out
  everywhere* on the account's page under `/editor/accounts`. An account holder
  has no self-service "sign out other devices" affordance short of changing
  their password.

  **Remember-me and the second factor.** The cookie is a completed sign-in in a
  cookie — the read plug hands it to `store_in_session/2` directly, so it never
  passes `AuthController.success/4` and never reaches the 2FA diversion. Since
  AshAuthentication issues it in `Plug.Dispatcher` *before* `success/4` runs, a
  2FA account would otherwise be handed a 30-day credential having proved only
  its password: tick the box, abandon the code prompt, and the second factor is
  gone entirely. So `success/4` withholds the cookie on the diversion and
  carries the *intent* in the pending token; `TwoFactorController` issues a
  freshly minted one once a code verifies (a fresh mint rather than the withheld
  token, to keep a 30-day credential out of the five-minute pending blob). That
  the resulting cookie then signs the user in later *without* a code is the
  deliberate part — it is a "this device completed every factor" credential, and
  that is what remember-me is for on a 2FA account.
- **SSRF protection on outbound calls** — `KilnCMS.Webhooks.SafeUrl`: HTTPS
  required in prod, private/loopback/link-local/metadata ranges rejected for
  both IPv4 and IPv6, DNS resolved with an all-or-nothing rule and a hard
  timeout. Callers connect to the *pinned* resolved IP with SNI and cert
  validation kept on the original hostname, closing the DNS-rebinding window,
  and follow no redirects — a followed redirect is a fresh resolution the pin
  never sees. `KilnCMS.SafeFetch` packages that plus a streaming byte cap, since
  an attacker-influenced response has an attacker-influenced *length* too.
  Since #753 there is exactly one implementation: every caller that fetches a
  URL the *content* chose — webhook delivery, oEmbed, link checking, federation,
  social posting, portability import — goes through `SafeFetch`. A new caller
  reaching for `Req` directly, or copying its `connect_options`, is the bug that
  invariant exists to catch.
- **Upload handling** — uploads validated from bytes rather than declared type,
  EXIF stripped, and blobs served with `Content-Disposition: attachment` and
  `X-Content-Type-Options: nosniff`.
- **Static analysis & dependencies** — Credo, Sobelow, Dialyzer, and two
  dependency audits (`mix deps.audit` against mirego's advisory mirror,
  `mix hex.audit` against Hex's own feed) in CI and `mix precommit`, failing
  the build on a known-vulnerable locked dependency.

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

### Image transforms (`/media/:id/t/:ops`)
- **Resource exhaustion** — every distinct parameter set is a decode, a resize
  and an encode, and the route is anonymous. Bounded in layers: unsigned URLs
  may only use an allowlist of sizes, ratios and qualities (a signed URL may use
  any value, and signing needs `KILN_IMAGE_TRANSFORM_KEY` or `SECRET_KEY_BASE`);
  every output side is capped at 4000px and every source at the upload pixel
  cap, the latter checked from the recorded dimensions before decoding; cache
  misses spend a per-IP `:media_render` budget and wait on a per-node
  concurrency gate; and an item keeps at most 200 derivatives, after which
  renders are served but not stored. Parameters and signatures are checked
  before the item is read, so refusals cost no I/O. *Watch:* behind a proxy
  or CDN that isn't configured as trusted, every client shares the proxy's
  address and so one render budget — the same caveat as every per-IP bucket.
- **Signing-key exposure** — a leaked `KILN_IMAGE_TRANSFORM_KEY` lifts the
  allowlist, not the hard caps or the render gate. Rotating it invalidates
  signed URLs already in pages. It must stay server-side; the SDKs say so.
- **Gated media** — the route reads the item with the request's actor through
  the same policy-checked read as `/media/:id/download`, so a gated or
  quarantined item is a 404 there too, and a gated item's derivatives live in
  private storage and are served `private, no-store`.

### GraphQL / JSON:API / REST
- **Authorization bypass** — prevented by Ash policies running with the request
  actor and tenant; there is no unauthenticated mutation path that skips them.
- **Write surface** — `/api/json` accepts POST/PATCH/DELETE including
  publish/unpublish (#330). Gated by resource policies *and* the API-key access
  scope, not by the router. `destroy` is a soft delete; `purge` is never routed.
- **Mass assignment** — Ash actions accept only declared inputs (`accept`).
- **Query cost** — each document is capped at complexity 200, depth 15 and
  2,000 tokens on both transports, and a batch at 10 operations. Complexity is
  a price, not a row count: a relationship list without `limit` is priced at
  five rows and can return more, so the cap limits how deeply lists nest rather
  than how many rows one document returns. Each document on `/ws/gql` is
  charged to `:gql` like a `/gql` request (residual item 10). Introspection is
  off in production.
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
- **Skipping the second factor** — *closed (#726).* This endpoint used to return
  a full JWT for a 2FA-enabled account on the password alone, where the browser
  flow diverts to `/sign-in/verify`. That made TOTP optional in practice rather
  than in policy: there is no point bounding six digits at one prompt while a
  door next to it does not ask. A 2FA account now gets `200` with a pending
  token instead of `201` with a JWT, and finishes at
  `POST /api/auth/sign_in/verify`.
  - **What is withheld is access to the token, not its existence.**
    `Strategy.action/3` mints the JWT and — because `User` sets
    `store_all_tokens?` — stores it, before anything looks at `totp_enabled?`.
    The second factor gates whether the caller ever receives it. Say it that way
    round: "no token is issued" would tell an incident responder that a
    password-alone compromise leaves nothing to revoke, and it leaves something.

    Since #742 the row's **use** is withheld too, on both doors.
    `PendingSignIn.mint_and_hold/4` moves it to the `pending_second_factor` purpose and
    shortens its expiry to the length of the step, and `claim/1` puts it back
    once a code verifies. `AshAuthentication` requires a row under the `user`
    purpose to authenticate a JWT (`require_token_presence_for_authentication?`),
    so between the two steps the token authenticates nothing, wherever it is —
    and an exchange that is never finished leaves an inert row that expires with
    the step rather than a live credential nobody holds for the JWT's full
    lifetime. The rate was already bounded: #742's first half stopped a password
    that stops at the code prompt from clearing the per-account sign-in counter,
    so an attacker gets `@budget` of them per window per account rather than as
    many as their IP pool allows.

    Held, not revoked: `:revoke_jti` writes a thousand-year `revocation` row,
    and the exchange may still complete. The filter cuts the other way too — a
    release only ever moves a row *off* the hold purpose, and that predicate is
    in the UPDATE's own WHERE rather than checked against the row the caller
    read, so a revocation landing mid-release is not overwritten rather than
    merely usually surviving. `log_out_everywhere` (password change) and account
    erasure sweep every row a subject owns, held ones included; sign-out revokes
    only the token held in that session, which a browser waiting at the code
    prompt does not have.

    *Residual:* a hold that cannot be written does not fail the sign-in — it
    logs and leaves the pre-#742 behaviour, because refusing instead would turn
    a token-store hiccup into "no account with a second factor can sign in".
    The token is still minted; what is closed is that it is usable.
  - The pending blob is **encrypted** (`Phoenix.Token.encrypt/4`), not signed.
    The browser's equivalent can be signed because it lives in the encrypted
    session cookie; this one is handed to the client, and signing it would
    publish the first-factor JWT it carries in a decodable payload —
    reintroducing the bypass in a form that looks fixed. It follows that the
    blob is itself a credential and has to be handled as one; `docs/api.md` says
    so to integrators, because "opaque" reads as "harmless" otherwise.
  - It is **single-use**: a completed redemption is recorded as spent, so a
    captured verify request cannot be replayed — and a *successful* request is
    the one most likely to be sitting in a log, a CI transcript or a crash
    report. The browser flow gets this by deleting the session key. A wrong code
    or a spent budget does *not* burn it, because neither is a failed
    authentication.
    Single use is **exact**, on one node and on a cluster (#743): the record is
    a `KilnCMS.Accounts.Token` row whose primary key is the blob's `jti`, so the
    INSERT *is* the check and two redemptions of one blob race at Postgres. The
    loser is refused rather than issued a token.

    It was a node-local `Cachex` entry, which failed **open** across nodes — a
    replay landing on a node that never saw the redemption was accepted — and,
    less obviously, could hand out two tokens for one blob on a *single* node
    when both requests resolved before either recorded. Nothing rejects a reused
    TOTP code, so the two only had to arrive together.

    `WebAuthn.take_challenge/1` and `AccountThrottle` still make the node-local
    trade for their own state; residual risk #10 below covers the throttle.
  - Codes are charged `AccountThrottle.consume_second_factor/1` on the **same
    per-account bucket** the browser prompt charges. Per-surface budgets would
    let an attacker double their guesses by alternating endpoints, and the
    five-minute pending lifetime bounds nothing on its own — re-running the
    password step mints a fresh token. Since #742 each of those costs a unit of
    the sign-in budget, so the renewal is bounded rather than free. That bucket is per node too (residual risk #10 below), so the real
    ceiling is 5 × nodes per window.
    *Residual:* reaching that bucket used to require a browser session and a
    CSRF token. It now takes five `curl` calls from anyone holding the password,
    and because the bucket is shared it locks the owner out of *both* surfaces
    for the window — the denial-of-service #478 chose a flat budget to avoid,
    arriving by another route. The flat window still bounds it to one window's
    tail rather than an escalating lockout.
  - `two_factor_required` discloses that an account has a second factor, but
    only to a caller who has already supplied the correct password — which the
    browser flow discloses just as plainly by redirecting to the prompt. Every
    refusal *before* that point is still the same generic 401, and costs the
    same bcrypt.
- **Passkeys as a side door** — a verified passkey completes sign-in with no
  TOTP diversion (`KilnCMSWeb.PasskeyController`), and that is policy, not an
  oversight: every Kiln passkey is registered *and* asserted with user
  verification required, so the ceremony proves possession + PIN/biometric — the
  bar the TOTP flow enforces. It is also browser-only; there is no headless
  passkey route, so it is not a second door onto this surface.
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
  compile-gated to `:dev_routes`. AshAuthentication's are now all routed through
  thin Kiln wrappers, so they carry the guard like everything else:
  `/sign-in`, `/register` and `/reset` through `KilnCMSWeb.SignInLive` (#715),
  and `/password-reset/:token`, `/confirm_new_user/:token`, `/magic_link/:token`
  and `/sign-out` through `KilnCMSWeb.AuthLive` (#701). Before that last one
  those four skipped `:assign_current_org` on a url-less join and rendered with
  the **default org's** branding on a tenant host — no authorization was
  reachable that a signed-out visitor could not reach anyway, but the identity
  on the page was another tenant's, the leak #48 exists to prevent.
  `/sign-out` is worth calling out because it is the one that reads as
  controller-only: `sign_out_route/3` emits a `DELETE` to the auth controller
  **and** a `live` route in its own `live_session`, and only the first appears
  at the call site. Its live half had a replayable session like any other.
  `KilnCMSWeb.LiveJoinWithoutUrlTest`'s exemption list is now empty, which is
  what keeps this true as views are added.
- **Session as the credential** — the whole surface is gated by the session
  cookie plus the per-org effective tier, so the cookie's integrity is the
  boundary; see the `__Host-` prefix under Controls (#686).
- **Second-factor codes over the socket** — `/editor/settings` verifies a TOTP
  code for `disable_totp`, `regenerate_totp_recovery_codes` **and**
  `confirm_totp`. A LiveView event passes no router pipeline, so none of them
  got the per-IP `:auth` bucket: a stolen session could push the event in a
  loop and grind 10^6 at socket speed. On a hit `disable_totp` removes the
  second factor outright, and either of the other two hands over a working
  recovery-code set. *Mitigated (#727):* all three charge
  `AccountThrottle.consume_second_factor/1` — five per account per fifteen
  minutes, the **same** bucket `/sign-in/verify` uses, so they cannot be spent
  independently. The charge lives on the Ash action rather than in the
  `handle_event` clauses, so a future caller inherits it.
  *Watch:* the bound is per node (residual risk 10), and it bounds *guessing*
  only. It hands a stolen session a small denial-of-service it did not have:
  five wrong codes here deny the real owner `/sign-in/verify` for the rest of
  the window. That is strictly less than what the session already grants, so
  the trade is accepted.
- **`setup_totp` as a second, code-free door to the same removal** —
  `confirm_totp` was never scoped to an enrolment in progress, so on an already
  -enrolled account it checked the account's **live** secret; a session that
  called `setup_totp` first got a fresh secret written straight into
  `totp_secret` with `totp_confirmed_at` nulled in the same call — turning 2FA
  off with zero code guesses, no budget charged, and nothing telling the owner
  the account had stopped asking (#754). *Mitigated (#754):* `setup_totp` now
  stages the new secret into a separate `totp_pending_secret` attribute and
  touches nothing else; only `confirm_totp` — checked against the *pending*
  secret and still budgeted (#727) — ever promotes it to `totp_secret` and
  stamps `totp_confirmed_at`. Enrolling (or re-enrolling) can therefore never
  by itself disable an existing factor. *Watch:* a session that completes both
  `setup_totp` and `confirm_totp` with a code of its own choosing still
  replaces *which* secret backs the account's 2FA — `totp_confirmed_at` never
  goes false, but the owner's own authenticator silently stops working. That
  swap is not new here (the pre-fix `setup_totp`+`confirm_totp` pair could
  reach the same end state, just via a moment where 2FA visibly dropped) and is
  tracked separately rather than folded into this fix.

### Public forms
- **CSRF** — deliberately absent: forms are meant to be posted from third-party
  pages. Abuse is bounded by the `:form` bucket and a honeypot field, and a
  tripped honeypot returns success so a bot cannot distinguish rejection.
- **Framing** — the embed route sets its own `frame-ancestors` from the form's
  `embed_origins` (#648), falling back to the deployment-wide `EMBED_ORIGINS`,
  which defaults to same-origin only (#562), so cross-site embedding is opt-in.
  Per form because a deployment-wide allowlist has to be the union of every
  org's embedders, and that union is what every org's forms become framable by.
  A form's list is written by an org admin — the party whose submissions an
  overlay would harvest — and grants nothing across the tenant boundary.
- **Submission contents** — treat as untrusted PII; retention is covered in
  [`data-flows.md`](data-flows.md).

### Preview
- **Token as credential** — `/preview/:token` verifies a signed token and then
  loads the record with `authorize?: false`, so token possession is full read
  access to that record in whatever state it is in. Tokens are the sharing
  mechanism for unpublished work; treat a leaked preview URL as a content leak.
  See residual risk 6.

### Media (`/uploads/*`)
- **Unauthenticated access** — local blobs are served by `Plug.Static` with no
  auth, no rate limit and no tenant check. Storage keys are unguessable UUIDs,
  which is the only thing standing between an unpublished asset and the world.
  `Content-Disposition: attachment` + `nosniff` prevent the bucket being used to
  serve active content. S3/MinIO deployments serve media entirely outside the
  app.

### Webhooks (outbound)
- **Gated content is delivered** — a content event carries the full block tree
  whether the document is public, audience-gated, or passphrase-locked. That is
  deliberate: an endpoint is operator-configured, HMAC-signed and SSRF-guarded,
  unlike the anonymously-queryable Meilisearch index, which excludes gated
  content outright (#1006). The payload marks both gates (`audience`, `locked`,
  #1014) so a receiver can filter — but the filtering is the receiver's, and a
  webhook endpoint's blast radius is therefore *every* document that fires an
  event, not only the public ones. Treat an endpoint URL as a credential.
- **SSRF** — mitigated by `SafeUrl` with IP pinning (see Controls).
- **Forgery at the receiver** — deliveries are HMAC-SHA256-signed; a receiver
  that verifies `x-kilncms-webhook-signature` knows a delivery is genuinely
  from Kiln, with unmodified content, and sent within the tolerance window it
  enforces (five minutes by default), because the timestamp is inside the MAC.
  Inside the window a receiver dedupes on the signed `delivery_id`. The older
  body-only `x-kilncms-signature` is still sent, deprecated: it proves origin
  and integrity, not freshness. See residual risk 15 and
  [webhooks.md](webhooks.md#verifying-the-signature).
- **Secret disclosure** — each endpoint's signing secret is vault-encrypted at
  rest, so a database dump, backup or replica does not hand out the ability to
  sign deliveries. The trade-off is the vault's: rotating `SECRET_KEY_BASE`
  orphans the secrets, and each endpoint must be re-created
  ([secrets-rotation.md](secrets-rotation.md)).

### oEmbed resolution (`OEMBED_ENABLED`, #489)
- **Content choosing the destination** — prevented by design. Kiln does **not**
  use oEmbed discovery, which would mean fetching the embedded page and
  following a `<link rel="…oembed">` — i.e. letting a field any editor can type
  decide which host the server dials, with its egress IP. Endpoints are
  constants in `KilnCMS.OEmbed.Provider`; the URL only selects which of them is
  asked, and a URL no provider claims produces no request at all.
- **The dial itself** — `KilnCMS.SafeFetch` (pinned, no redirects, 64KB cap).
  Belt and braces given the endpoints are constants, but a provider's *DNS* is
  not, and "the endpoint is hardcoded" is the assumption that makes a later
  `OEMBED_PROVIDERS` change quietly dangerous.
- **Provider HTML** — discarded, not sanitized. An oEmbed response carries an
  `html` field of provider-authored iframe/script markup; rendering it means
  trusting a third party with script execution on the delivery origin. Cards are
  built from escaped scalars, and the canonical-iframe rewrite for YouTube and
  Vimeo remains the only thing that emits an `<iframe>`.
- **Thumbnails** — checked against that provider's own CDN hosts, on resolve
  *and* on any write, because the metadata fields are ordinary block scalars an
  editor or a headless caller can set directly. `img-src` widens to exactly that
  list, and only while the feature is enabled.
- **Cost amplification** — a save containing an unresolved embed costs one
  outbound request. Bounded by the resolve being enqueued only when a provider
  claims the URL *and* the block has no title yet, so a resolved document does
  not re-fetch; and by Oban's per-document uniqueness window.

### A site's own AI provider (`/editor/site-ai`, #1557)
A site admin — a tenant, on a hosted deployment — can point the site's SEO
suggestions, block assist and `/api/ask` answers at their own provider account.
That makes the site admin the one choosing where this server sends content and
a credential, so the operator's trust assumptions do not carry over:

- **The destination** — a closed list of hosted providers, each dialled at the
  provider's own published API root, or one `https://` OpenAI-compatible URL.
  That URL is SSRF-checked at save (`Validations.AiBaseUrl`) and dialled only
  through `KilnCMS.SafeFetch` (re-checked and pinned per request, no redirects,
  1MB response cap), never through `req_llm`'s own client. `ollama` and `vllm`
  are not offered: their default endpoint is `localhost`, the operator's box.
- **Exfiltrating the operator's secrets** — the key is database-only, with no
  env-var or file source, so it cannot be pointed at `SECRET_KEY_BASE` or the
  operator's `ANTHROPIC_API_KEY`. And because `req_llm` fills an unset key or
  endpoint from the operator's `config :req_llm` and `<PROVIDER>_API_KEY`, a
  site request always passes both explicitly (an absent key is sent as `""`,
  which `req_llm` refuses rather than fills). `SiteProviderIsolationTest`
  plants the operator's key and endpoint in every place `req_llm` reads.
- **Exfiltrating the site's own key** — write-only in the form, and dropped
  when the provider or endpoint changes, so a co-admin who was never shown the
  key cannot redirect it to a host they control. Vault-encrypted at rest;
  a `SECRET_KEY_BASE` rotation makes it unreadable
  ([secrets-rotation.md](secrets-rotation.md)).
- **Falling back** — a site whose provider is set but unusable (unreadable
  row, undecryptable key) is refused, never served by the operator's provider.
  Falling back would send its content through an account and DPA it opted out
  of, billed to the operator. See `KilnCMS.LLM.SiteProvider`.
- **Cost** — the `KilnCMS.LLM.Budget` buckets apply to a site's key as to the
  operator's, so `/api/ask` stays rate-limited per caller and per site; each
  call still occupies a process here for up to the feature's timeout.
- **What the provider sees** — the same as the operator's provider would: a
  page's text, a block and the editor's instruction, or published passages and
  an anonymous visitor's question. It is the site's choice and the page says so.

### Other outbound calls
`Kiln.Updates` (GitHub releases, admin-triggered), `KilnCMS.Unsplash`,
Meilisearch (the operator's instance — a site's own is below), S3/MinIO, the
mailer, and the LLM providers behind `/api/ask` and
SEO drafting all make outbound requests to *operator-configured or fixed*
endpoints, not user-supplied ones — so they are not SSRF vectors in the way
webhooks are. The exceptions are a site's own SMTP relay (#1322) and AI
endpoint (above), which are tenant-chosen and SSRF-checked. Note that `/api/ask` lets an anonymous caller drive an outbound
LLM request; it is config-gated and rate-limited under `:api`, but it is a cost
amplification surface.

### A site's own Meilisearch instance (#1558)
The one outbound integration above whose endpoint a **site admin** chooses
rather than the operator — on a hosted deployment, a tenant. It carries two
things out: the site's public content, and a bearer key.

- **SSRF** — the URL is tenant-supplied, so it is treated like a webhook
  target: HTTPS only, no userinfo/query/fragment, and refused if it resolves
  to a private, loopback, link-local or metadata address — at save
  (`Validations.SearchUrl`) and on every request, which goes through
  `KilnCMS.SafeFetch` (resolved once, connected to by address, TLS verified
  against the name, no redirects, 5 MB response cap). A refused or failed
  request's status reaches only the job log and the site admin's own page.
- **Credential exfiltration** — the key is database-only. There is no env-var
  or file source a tenant could aim at `SECRET_KEY_BASE`, and a site's request
  is built from its row alone: the operator's `MEILI_MASTER_KEY`, URL and index
  never ride along (pinned by `SiteInstanceIsolationTest`, with operator
  credentials planted).
- **Cross-tenant disclosure** — the fail direction. A site instance that can't
  be used (unreadable row, undecryptable key) never falls back to the
  operator's: indexing holds and retries, and `search/2` errors so the caller
  uses Postgres search rather than an index that holds other sites' content.
- **What leaves** — the same public-only documents the operator's index gets
  (#1006, #496). The settings page says so above the form; add the site's
  provider to your DPA if you host sites for others.
- **Accepted** — the site admin chooses who runs the instance, and whoever runs
  it can read (and alter) what is in it. That is the site's choice about its
  own public content. A site moving off an instance leaves its documents
  there.

### Object storage
- **Credential exposure** — S3 keys come from env, never committed.
- **Bucket scope** — keep the bucket public-read for delivered variants only.

### A site's own sign-in provider (`/editor/site-sso`, #1561)
A site admin can point their site's sign-in page at an OpenID Connect provider
they choose. On a hosted deployment that admin is a tenant, the provider is
theirs, and accounts belong to the whole deployment — so the provider is treated
as able to assert *anything*, and what it may achieve is bounded by Kiln, not by
the provider. See [sso.md](sso.md#per-site-providers).

- **Asserting someone else's address** — a provider is honoured only for email
  addresses in a domain the site verified by DNS (a `_kiln-sso.<domain>` TXT
  record carrying a per-site random token), re-checked on every sign-in, exact
  domains only, and only with `email_verified` true. DNS control implies control
  of the domain's mail, so this concedes nothing beyond what a password-reset
  email to that domain already would.
- **Reaching another site** — a site's provider never signs in an account with
  access anywhere else: a platform admin (standing or temporary), a member of
  any other organization at any tier, or a membership-less account whose global
  role or legacy audiences reach beyond the site. Checked at every sign-in, in
  `KilnCMS.Accounts.SiteSso.Admission`. Kiln has no site-scoped session, so the
  guarantee is made at admission. **Accepted:** a session such a provider
  minted before the account later gained access elsewhere keeps working until
  it ends — no wider than the mail-control concession above.
- **Pre-registered accounts** — an unconfirmed account is never handed to a
  provider's user (it may have been registered in advance by someone else).
- **Identity collisions with the operator's provider** — none possible: the
  site flow is not an AshAuthentication strategy, writes no `UserIdentity` row,
  and matches only by verified email. The operator's `OIDC_*` provider is
  unchanged.
- **Token forgery** — Assent's OIDC callback with state, nonce and PKCE, the ID
  token checked for `iss`/`aud`/`azp`/`exp`, and `RS256` only: `alg: none` and
  `HS*` (verifiable with the client secret, which this server also holds) are
  refused. The flow's parked parameters are bound to the org that started it,
  single-use, and expire after ten minutes.
- **SSRF** — the issuer must be `https://` and pass `SafeUrl` at save; every
  request the flow makes — discovery, the token endpoint (which is sent the
  client secret), the signing keys — goes through `KilnCMS.SafeFetch`, pinned,
  no redirects, 256 KB cap. The discovery document must name the same issuer,
  and `https://` endpoints.
- **Secret disclosure** — the client secret is vault-encrypted, write-only, and
  database-only (no env-var or file indirection a tenant could aim at
  `SECRET_KEY_BASE`). A rotation that orphans it makes the site's SSO
  unavailable; it never falls back to the operator's provider
  ([secrets-rotation.md](secrets-rotation.md)).
- **Second factor** — a site-provider sign-in completes through
  `AuthController.success/4`, so a TOTP-enrolled account is still asked for its
  code.

#### A site's own bucket (`/editor/site-storage`, #1559)
A site admin — a tenant, on a hosted deployment — can point the site's new
uploads at their own S3-compatible bucket. That makes the site admin the one
choosing a host this server sends signed requests and file bodies to:

- **The destination** — the endpoint must be `https://host[:port]`, is
  SSRF-checked at save (`Validations.StorageEndpoint`), and is re-checked and
  pinned every time a profile is resolved: `KilnCMS.Storage.S3.ReqClient`
  connects to the checked address (SNI and certificate verification on the
  name, via `KilnCMS.SafeFetch`'s connect target) and follows no redirect.
- **Exfiltrating the operator's credentials** — the site's ExAws config is
  built from the site's settings alone and passed to
  `ExAws.Operation.perform/2`; `ExAws.request/2` would merge the operator's
  `:ex_aws` config (session token, endpoint, instance-role lookup) underneath.
  `SiteStorageIsolationTest` plants operator credentials and checks no request
  or presigned URL carries them. The secret is database-only (no env-var or
  file source), so it cannot be pointed at `SECRET_KEY_BASE`.
- **The site's own secret** — write-only in the form and vault-encrypted. A
  blank secret is carried to a new bucket only on the same endpoint, region
  and access key, so a co-admin cannot aim the stored key at a host of their
  choosing. (SigV4 never sends the secret anyway; only signatures, scoped to
  the host they were made for.)
- **Falling back** — a site whose bucket is set but unusable (unreadable
  settings or secret, refused endpoint) has its uploads refused. Nothing is
  written to, or read from, the operator's bucket in its place.
- **Cross-site reads** — every media row records its profile, and a profile is
  resolved tenant-scoped to the row's own site, so a row cannot name another
  site's bucket.
- **CSP** — the site's public base URL origin (a plain host name, validated)
  is added to that site's own `img-src` and `media-src`
  (`KilnCMSWeb.Plugs.SiteStorageCsp`); never `script-src`, never another site.

## Residual risks

Known and accepted, in rough order of how much they should worry an operator.
Each is a deliberate trade-off, not an oversight — but each is worth revisiting.

**1.0 review (#1535).** Each item below ends with a **proposed** 1.0 verdict:
*still accepted at 1.0*, *fix before 1.0*, or *fix after 1.0*, with the reason
and the code it was checked against on `main` (v0.10.0). They are proposals for
the maintainer to confirm or overturn, except item 3, which roadmap decision 4
already settled. Items keep their numbers because other files cite them by
number.

1. ~~**Form embeds default to `frame-ancestors *`.**~~ **Closed in #562.**
   `EMBED_ORIGINS` unset now means same-origin only, so cross-site embedding is
   opt-in, and a malformed value closes the policy rather than widening it.
   `EMBED_ORIGINS=*` restores the old any-site behaviour if a deployment
   genuinely wants it. See [forms.md](forms.md#embedding-on-another-site).
   **Remainder, narrowed in #648:** the allowlist can now be set **on the
   form**, and a form's list replaces the deployment's rather than extending it,
   so an entry made for one org reaches no other org's forms. What is *not*
   closed is the default: a form that has not been given a list still inherits
   `EMBED_ORIGINS`, which has no tenant dimension — so on a multi-org instance
   the shared union governs every untouched form. **Narrowed further in
   #1131:** `KilnCMS.CMS.SiteEmbedSettings`, resolved by
   `KilnCMS.Forms.EmbedPolicy`, inserts a per-org default between the form and
   the deployment — `form.embed_origins -> SiteEmbedSettings.embed_origins ->
   EMBED_ORIGINS` — so an org decides once and every untouched form in that
   org inherits it, rather than the deployment-wide union. **The operator
   ceiling, closed in #1133 — as an opt-in.** By default an org admin can
   still open framing — on a form, or on the org default — that the operator
   had left closed; that stays deliberate (the allowlist governs who may
   overlay *that org's* forms and harvest *that org's* submissions, and grants
   nothing across the tenant boundary). But an operator who wants the other
   reading sets `EMBED_ORIGINS_LOCKED=true`, and `EMBED_ORIGINS` becomes the
   *most* a tenant may open as well as the default: a per-form or per-org
   list may narrow it but every entry must be covered by it, writes outside
   it are refused (naming the entry, never the ceiling), and the served
   header is clamped to it too, so a list saved before the cap cannot keep a
   page wider than the operator now allows (`KilnCMS.Forms.EmbedCeiling`).
   With the cap off nothing changes; with `EMBED_ORIGINS=*` the cap is a
   ceiling of everything; with `EMBED_ORIGINS` unset it is a ceiling of
   nothing. It also gives the operator the switch an org-admin compromise
   used to lack: under the cap, a taken-over admin account cannot re-open the
   overlay-and-harvest surface #562 closed beyond what the operator listed.

   **1.0 verdict (proposed, #1535): still accepted at 1.0.** Verified on main:
   the default is same-origin (#562), a form's list resolves form -> org ->
   deployment in `KilnCMS.Forms.EmbedPolicy` (#1131), and the operator ceiling
   is `KilnCMS.Forms.EmbedCeiling` behind `EMBED_ORIGINS_LOCKED`
   (`config/runtime/cross_origin.exs:37`, #1133). What remains is a stated
   choice: an org admin decides who may frame that org's own forms, which grants
   nothing across the tenant boundary, and an operator who disagrees has a
   switch. One question for the maintainer to take alongside #1547, not proposed
   here: should `EMBED_ORIGINS_LOCKED` also default on once a second
   organization exists? The case is weaker than for an unknown `Host`, because
   the uncapped default leaks nothing to another tenant.
2. **Passphrase-locked content is weak by construction (#496).** A shared secret
   typed into a public form is not access control in the sense the rest of this
   document uses the phrase: there is no per-reader identity, so no audit trail
   and no way to revoke one reader; the passphrase is chosen by an editor for
   convenience and is therefore short and guessable far more often than a
   password is; anyone who has it can pass it on, and you will not know.

   The mitigations are bounding, not eliminating. Guessing is bounded by a tight
   dedicated rate-limit bucket (`:unlock`, 10/min per IP, separate from `:auth`
   precisely because there is no account to lock out instead). Grants expire in
   12 hours and die the moment the passphrase is rotated, because a grant names
   a fingerprint of the stored hash rather than the document. The stored value
   is a bcrypt hash, excluded from version history so it does not outlive
   rotation. The headless unlock endpoint answers identically for a wrong
   passphrase and for an unlocked document, so it cannot enumerate what is
   locked. (The built-in site's does not need to: a plain GET there already
   shows a lock page or the document.)

   **Audiences remain the real access-control axis**, and the two compose by AND:
   a locked document in a gated audience needs both. Point operators at
   [api.md](api.md#password-protected-content) before they use this for anything
   that would matter if it leaked.

   **1.0 verdict (proposed, #1535): still accepted at 1.0.** Nothing here is a
   bug to fix. A shared passphrase is weak by construction, and the item says
   so. The bounds it lists still hold on main: the `:unlock` bucket is 10/min
   per address (`lib/kiln_cms_web/rate_limit.ex:53`), and grants live 12 hours
   (`lib/kiln_cms/cms/content_password.ex:54`) and name a fingerprint of the
   bcrypt hash, so rotating the passphrase kills them. The 1.0 obligation is
   documentation. The pointer to `api.md` already meets it: audiences are the
   access-control axis.

3. **Unknown `Host` headers resolve to the default organization — on a
   single-org deployment, or where `TENANT_STRICT_HOST=false`.** #563 added
   the control; since #1547 an unset `TENANT_STRICT_HOST` turns it on by
   itself once a second organization exists, on every node and with no
   restart, so a multi-tenant deployment is no longer exposed by default. With
   it on, an unresolvable `Host` is refused with a bare 404 rather than served
   the default org, across everything the router serves plus LiveView mounts
   and the GraphQL and visual-editing sockets. What remains:
   - An operator can still set `TENANT_STRICT_HOST=false` on a multi-org
     deployment. The app warns about that at boot, when the second org is
     created, and on `/editor/system`.
   - A node that misses the create's `Phoenix.PubSub` broadcast (partitioned,
     or mid-boot) stays lenient until its periodic recount, at most five
     minutes later.
   - If the organizations cannot be counted at all (boot with Postgres down),
     an unset setting fails **closed**: unknown hosts are refused until a
     count succeeds.

   Terminating unknown hosts at the proxy is still worth doing as well.

   A host whose lookup could not *run* — Postgres down — is refused too, since
   falling back would reopen exactly this leak on an unrecognized host, but with
   a `503` rather than a `404` (#341): the host may well exist, and the two
   answers must not be conflated. With the control **off** a failed lookup takes
   the same default-org fallback an unmatched host does, so an outage refuses
   nothing that a working database would have served.

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

   **That caching fix applies uniformly to all five callers** that resolve a
   tenant (`SetTenant`, the LiveView on_mount hook, and the three sockets —
   all route through `Tenant.fetch_org/1` or `fetch_org_from_connect_info/1`),
   so a *repeated* refusal is cheap everywhere, not just at the plug. What
   remained until #678 was visibility: a flood of *distinct* invented hosts
   still costs a lookup each, on every one of the five, and none of it reached
   an operator. `KilnCMSWeb.TenantRefusalAlert` now fires one aggregated,
   cooldown-limited `Logger.warning` + Sentry alert per surface — tagged
   `:plug`/`:live`/`:gql`/`:bridge`/`:collab` so an alert says *which* surface
   is being flooded — the first time each is refused in a 15-minute window.
   It is deliberately **not** wired into `Tenant.fetch_org/1` itself (that
   would also fire for host-agnostic traffic on its way to being served, and
   for the LiveView on_mount's foreign-claim check, which is driven by the
   client's *claimed* host rather than one that failed to resolve) — each
   caller alerts from its own refusal decision instead.

   The issue also floated rate-limiting `/live/longpoll` specifically at the
   router, alongside the plug's pipeline limiters. That turned out not to be
   available: `use Phoenix.Endpoint` installs `socket_dispatch` as the first
   plug in the endpoint unconditionally, ahead of `SetTenant`, the session
   plug and the router itself, regardless of where a `socket "/path", …`
   declaration sits in the module — so every one of `/live`, `/ws/gql`,
   `/ws/collab` and `/ws/bridge` is dispatched and its connection accepted or
   refused before any router pipeline would run, on every transport including
   longpoll. There is no router-reachable place to put a limiter in front of
   them. Accepted rather than closed: the per-request cost a longpoll flood
   adds beyond the alerting above is one cached-miss lookup and one LiveView
   process spun up and torn down per request, the same bound #677 already
   put on every other caller — real but small, and an operator who sees the
   new alert firing can add a proxy-level limiter on `/live` and `/ws/gql` the
   same way one is already recommended for unknown hosts generally, above.

   The quieter half is closed unconditionally: `Tenant.current_org_id/1` now
   **raises** when the `:current_org` assign is missing rather than reading the
   default org, so a forgotten `SetTenant` plug or `:assign_current_org`
   on_mount fails loudly in test instead of serving the wrong tenant in
   production.

   **1.0 verdict (decided, #1547): fixed.**
   Roadmap decision 4 (2026-09-18) settled this, and #1547 implements it: an
   unset `TENANT_STRICT_HOST` turns on once a second organization exists, and
   an explicit setting still wins (see the top of this item). The
   sub-residuals stay accepted: the plain-text refusal lets a sweep enumerate
   org slugs, and nothing router-reachable can meter `/live` longpoll. Both are
   documented with a proxy-level remedy.
4. **The OpenAPI spec and Swagger explorer describe the write surface** —
   *closed (#567).* Both were unauthenticated in every environment, production
   included, while GraphQL introspection was already disabled there for the
   same reconnaissance reason. They now follow `config :kiln_cms, :api_docs`:
   on in dev and test, off in a production build, and back on with
   `API_DOCS_ENABLED=true` for an operator publishing a public API. Disabled,
   both answer 404 rather than 403, so the instance is indistinguishable from
   one built without the surface. *Residual:* the gate is a plug on the `:api`
   pipeline that knows the two documentation paths, because the spec is served
   from inside the `AshJsonApiRouter` forward and has no route of its own to
   hang a pipeline on — so a future rename of either path has to be made in
   `KilnCMSWeb.Plugs.ApiDocs` too. A test pins that the content routes it sits
   in front of are unaffected.

   **1.0 verdict (proposed, #1535): still accepted at 1.0.** The residual is a
   maintenance hazard, not an exposure, and it is pinned.
   `KilnCMSWeb.Plugs.ApiDocs` hard-codes both paths
   (`lib/kiln_cms_web/plugs/api_docs.ex:78-79`), and
   `test/kiln_cms_web/api_docs_test.exs` and `api_explorer_routes_test.exs`
   cover the gate and the routes behind it. The spec is also committed as
   `docs/api/openapi.json`, so a disabled explorer hides nothing an attacker
   could not read in the repository.
5. **Rate limiting keys on `remote_ip`.** Behind a proxy with `TRUSTED_PROXIES`
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

   **1.0 verdict (proposed, #1535): still accepted at 1.0 (correct the
   arithmetic).** Detection is in `KilnCMSWeb.Plugs.ClientIp`
   (`lib/kiln_cms_web/plugs/client_ip.ex:164-170`, a once-per-node warning that
   names the fix). Honouring forwarding headers without a trusted list would be
   the worse bug. The arithmetic here has drifted, though. #747 doubled `:auth`
   to 40/min (`lib/kiln_cms_web/rate_limit.ex:28`), so a successful browser
   sign-in spends three of forty, not three of twenty: about thirteen sign-ins
   per minute per address, not six. The 1.0 action is to correct that sentence.
   The trade itself stays.
6. **Preview tokens bypass authorization and tenancy.** `PreviewController`
   loads with `authorize?: false` and no tenant. Token validity and expiry are
   the whole control. (`live_session :token_preview` does now carry
   `:assign_current_org`, added in #563, so the preview LiveView resolves the
   host it is served from — but the token lookup itself is still tenant-less.)

   **1.0 verdict (proposed, #1535): still accepted at 1.0 (rewrite the item).**
   The item is out of date. #1309 closed the tenant half. Every redeemer pins
   the token's `org_id` to the serving org and then reads with `tenant: org_id`:
   `PreviewController`
   (`lib/kiln_cms_web/controllers/preview_controller.ex:23,45`),
   `TokenPreviewLive` (`lib/kiln_cms_web/live/token_preview_live.ex:33`), the
   visual-editing read
   (`lib/kiln_cms_web/controllers/visual_editing_controller.ex:117`) and
   `BridgeSocket` (`lib/kiln_cms_web/channels/bridge_socket.ex:250`).
   `PreviewToken.verify/1` also refuses an older token that names no org
   (`lib/kiln_cms/cms/preview_token.ex:159-168`). What is left is the design
   itself. The read uses `authorize?: false` because the signed token is the
   grant. The token is bound to one record, lives 15 minutes
   (`preview_token.ex:42`) and is metered by `:preview` at 30/min. It cannot be
   revoked short of rotating `SECRET_KEY_BASE`. That is an acceptable 1.0 shape
   for a short-lived bearer link, and the item should say so instead of "no
   tenant".
7. ~~**Four resources are world-readable by policy.**~~ **Closed in #565.**
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

   **1.0 verdict (proposed, #1535): nothing to decide (closed).** Closed in #565
   and re-checked on main. `PublishedArtifact` reads through
   `Firing.Checks.DocumentReadable`
   (`lib/kiln_cms/firing/published_artifact.ex:103`), and the only `authorize_if
   always()` left among the four resources is `FormField`'s org-admin bypass. It
   keeps its place in the list because later items are cited by number.
8. **Unauthenticated GraphQL runs with `actor: nil` *and* `tenant: nil`.**
   Policies still run, so the audience and published filters hold, but the
   tenant boundary does not for that request.

   **1.0 verdict (proposed, #1535): fix before 1.0 (a test and a rewrite, not
   new code).** The item is stale. `KilnCMSWeb.Plugs.SetTenant` runs in the
   endpoint (`lib/kiln_cms_web/endpoint.ex:187`) and sets the Ash tenant on
   every HTTP request (`lib/kiln_cms_web/plugs/set_tenant.ex:221`).
   `AshGraphql.Plug` copies that tenant into the Absinthe context for `/gql`
   (`lib/kiln_cms_web/router.ex:78`), `/ws/gql` resolves its own from the
   connect URI (`lib/kiln_cms_web/graphql_socket.ex:46`), and `:strict_tenancy`
   (`config/config.exs:483`) makes a tenant-less read fail closed instead of
   spanning orgs. So an anonymous query is already scoped to the host's org.
   What is missing is proof. No test sends an anonymous HTTP `/gql` query on one
   org's host and asserts that another org's published content is absent; the
   strict-host suite covers only the socket. Pin that before 1.0 makes the
   promise, then close the item.
9. **A block field policy could be cleared by omission** — *closed for the
   reported case (#566).* `EnforceBlockFieldPolicy` stopped an editor *setting*
   an admin-only block field, but a headless client that submitted a block tree
   without ids and omitted the field got the declared default, silently
   clearing an admin-set value. A **wholly id-less** tree that omits such a
   field is now refused when any stored block of that type holds a non-default
   value for it, with a message naming the remedy (send the ids).

   The rule only ever refuses: it never permits a write that used to fail and
   never writes a value nobody submitted. Both alternatives considered were
   worse — pairing id-less blocks by position looks like identity and is not
   (it hands the featured slot to whatever new content lands there, and refuses
   an editor merely inserting a block above a featured one), and carrying the
   value forward silently writes something the client never sent.

   Nested `columns` children are covered too (#774): the whole tree's multiset
   of role-restricted non-default nested values must be identical before and
   after, so a non-admin can neither introduce one nor drop one by omission, but
   may resubmit a column holding an admin-set value unchanged — which the old
   per-child default rule refused outright.

   That comparison is only sound if it sees a value exactly where a reader
   would. It used to *search* the submitted term for maps carrying a `"blocks"`
   key, which is a guess about where children live, and a guess is defeatable:
   `{:array, :map}` fields carry no schema, so a whole child list could be
   parked under any key — `%{"blocks" => [real], "trash" => [%{"blocks" =>
   [parked]}]}`, or inside `gallery.images` with no `columns` block present at
   all — and the parked copy was counted while nothing rendered it, offsetting
   the removal of a real one. The traversal now **asks the block** for its
   children (`Columns.child_maps/1`), so it reads the same positions the
   renderer does (#956). A block type that nests children and does not declare
   them is invisible to this check, which is the cost of mirroring rather than
   guessing — and strictly better than a guess that failed open silently, for
   content no reader ever sees.

   A multiset preserves the *count* of admin-set values, not their *binding*, so
   on its own it allowed a **re-target** — clearing the value on one child and
   setting it on another of the same type in one write. That is **narrowed, not
   closed** (#865).

   The content editor stamps each nested child an `"id"` for its own
   bookkeeping, and the key survives into storage. Where those ids exist the
   check binds each admin-set value to the child holding it: a child returning
   under a known id must return with that id's value, and a child that *held* a
   restricted non-default value must return under the same id still holding it.
   Separately and unconditionally, an id that names **two** children in one
   submission is refused — without that the two collapse when indexed, the last
   wins, and a decoy sharing the real child's id satisfies the binding while the
   rendered content quietly loses the value.

   The binding is **required, not gated** (#954). It used to apply only when
   the client demonstrably round-tripped ids, because ids were unreadable —
   `blocks` is not `public?` and GraphQL carries `hide_inputs: [:blocks]`, so
   demanding an id back named a remedy most callers could not perform, and a
   caller willing to drop every id was quietly downgraded to the count-only
   multiset, where the re-target survived. Every caller can now read them: the
   public `block_ids` calculation projects the tree to `_id`/`_type` only —
   nested children in the positions they render, **no field values**, so the
   non-`public?` `blocks` boundary is untouched — on any policy-scoped read.
   Drafts are therefore editor-scoped by the row read policy; on published rows
   the fired `:json` artifact already names each block's id `_id`, nested
   children included, and the write path accepts that spelling (#990). An
   id-less submission against an identified stored tree is refused with the
   surface named in the error.

   Two deliberate carve-outs, both keyed on what is stored rather than on who
   is asking: a `restore_version` fold that carries no ids is exempt (the tree
   is our own history, vetted by this same policy when written, and versions
   captured before the editor stamped children fold back id-less by
   construction — no surface can ever hand those ids back; a restore that does
   carry ids keeps the binding like any other write). And a stored tree whose
   children carry no ids binds nothing, so it is governed by the multiset
   exactly as before rather than bricked by a demand for ids never stored.

   *Residual:* that second carve-out — a restricted value stored on an
   **id-less child** (a page authored by an id-less headless admin client; the
   editor always stamps) can still be re-targeted until an id-stamping save
   gives the document identity, and an id-less `restore_version` replays
   whichever vetted placement history holds. Both are bounded by the multiset:
   the count can never change.

   *Residual, all about **which block an id names** rather than what a field may
   hold:* an editor can still reuse the id of another block **of the same type**
   to move an admin-set field off the block that had it, and an empty
   `block_tree` deletes the block outright. Both predate this and need the write
   path to verify a submitted id belongs to the block it claims. The same is
   true of nested children: ids there are client-supplied, so relabelling which
   child an id names is believed, and only the two-children-one-id case is
   decidable without an ownership check.

   **1.0 verdict (proposed, #1535): fix after 1.0.** Verified unchanged on main
   (`lib/kiln_cms/cms/changes/enforce_block_field_policy.ex:140-153`). What
   remains needs an editor who may already write that document in that org. Such
   an editor can move or drop an admin-set block field by relabelling ids, or
   re-target a value stored on an id-less child. The multiset bounds the count,
   and nothing crosses a tenant or an audience, so this is integrity within an
   editor's own grant, not confidentiality. Closing it needs a new primitive:
   server-verified block identity on the write path. That is a design change to
   the block tree, too large for the contract-freeze window, and better done
   after the legacy block shape is retired (#1537).
10. **Per-account throttling is per node, in memory, and keyed on
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

    **1.0 verdict (proposed, #1535): still accepted at 1.0, if 1.0 says single
    node.** The trade is unchanged: `AccountThrottle` counts with
    `:ets.update_counter`, and `KilnCMSWeb.RateLimit` is Hammer with `backend:
    :ets` (`lib/kiln_cms_web/rate_limit.ex:5`). It is still right for one node,
    because a row-backed counter reopens enumeration and turns every guess into
    a write. The app is multi-node *capable*, though: `DNSCluster` is supervised
    and PubSub is distributed. So 1.0's supported-deployment statement has to
    say plainly that budgets are per node, and that N nodes multiply every
    budget by N. If 1.0 instead promises multi-node, this becomes a fix before
    1.0, because the budgets need a shared counter.
11. **The `:browser` pipeline is not rate-limited**, so `/`, `/developers`, all
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
    attempt. A *malformed* join — one whose `"url"` is present but not a binary
    — is worse than uncounted: it function-clauses before any mount hook, ahead
    of the channel's `try/rescue`, so it is a crash rather than the clean 404 a
    url-less probe gets. #700 stops that reaching the error tracker
    (`KilnCMS.SentryFilter` drops exactly that one function's
    `FunctionClauseError` at one arity, leaving the local report intact). Sizing
    it honestly: Sentry.Dedupe already collapsed the flood to roughly one
    event, so what this removes is a caller's ability to *plant* a real-looking
    issue at will, not a quota burn. The join itself is still free, and the
    Sentry logger handler's own `:rate_limiting` option — which would bound any
    crash shape rather than one named function — is available and unset.
    **Narrower than it sounds:** #678 closed the *tenant-refusal* half of
    "`/live` is unthrottled" — a flood of unresolvable hosts now alerts (see
    item 3 above) — but a flood of *valid*, successfully-resolving joins is
    still free and still uncounted. That's this item's actual gap, and it
    remains open; tracked in #1183.
    **Narrowed by #1183:** `/live` **root joins** are now charged per client
    address (`KilnCMSWeb.LiveJoinBudget`, the `:live_join` bucket in
    `KilnCMSWeb.RateLimit`, 300/minute by default). It is an `on_mount` hook on
    every Kiln LiveView *module* — ahead of `LiveRouteGuard`, so a url-less
    join is charged before it is refused — and only a connected root mount
    pays: the dead render is an HTTP request, a nested child was covered by
    its parent's join, and patch/navigate inside a `live_session` does not
    remount. Over budget, the join raises a 429 before `mount/3`, which the
    channel turns into a `reload` reply and a stopped process (no mount, no
    render); the JS client backs off with jitter.
    **Narrowed by #1305:** frames on an established **`/ws/collab`**
    connection are now charged, per *account* rather than per address or per
    connection (`KilnCMSWeb.SocketEventBudget`, the `:collab_event` bucket,
    6,000/minute per actor by default). Every `handle_in/3` — update,
    awareness, and the ignored rest — and the `join/3` that opened the channel
    spend the same budget, keyed on the actor the socket authenticated as, so
    a reconnect, a second tab or a second room does not mint a fresh budget
    and a flooder is bounded per credential; a join over budget is refused
    before its authorization reads. Per account because legitimate
    collaboration *is* a high-frequency stream and one office NAT holds many
    editors (address), and because a fresh websocket is the cheapest thing a
    flooder has and the honest recovery from a refusal is itself a reconnect
    (connection). Over it, the **connection is closed** — not the channel: a
    `{:shutdown, _}` stop is `phx_close`, which `phoenix.js` treats as a
    finished leave and never rejoins — so the client reconnects on a backoff,
    its rejoins are refused until the window turns, and on the join that
    succeeds it pushes back the local ops the room is missing (a Yjs
    state-vector diff in `assets/js/collab.js`), so nothing typed meanwhile is
    lost. Two things on the client are part of the control: awareness pushes
    are coalesced to ~10/s (without that a mouse-drag selection emitted at the
    browser's event rate and one long drag could reach the ceiling alone),
    and an `"over budget"` join refusal is treated as transient rather than
    seeding the document as the first peer. `awareness_request` — the one
    frame that makes every *peer* send a frame — is relayed at most once per
    ten seconds per channel, so one seat cannot spend the room's budgets
    through it. What this bounds is the per-frame work: the `DocServer` apply
    and room fan-out per update, and the full re-authorization (three DB
    reads) every `SocketReauth.update_floor/0` of them.

    **Narrowed further, the `/ws/*` half:** `/ws/gql`, `/ws/bridge` and
    `/ws/collab` **connects** are now charged the same way, per client address,
    each against its own bucket (`KilnCMSWeb.SocketJoinBudget`; `:gql_join`,
    `:bridge_join`, `:collab_join` in `KilnCMSWeb.RateLimit`, 300/minute by
    default each — three buckets rather than one shared, so a flood against
    `/ws/gql`, the one of the three anonymous by default, cannot spend a budget
    a signed-in editor's `/ws/collab` session then pays for from the same
    office NAT). Charged first in each socket's own `connect/1,2,3`, ahead of
    tenant/token/auth resolution, the same ordering `LiveJoinBudget` uses and
    for the same reason: a connect this deployment is about to refuse anyway
    still cost a handshake. A refused connect returns `:error` — there is no
    4xx-during-mount shape to raise here, so the client's own reconnect logic
    backs off and retries, the same as any other refused socket connect.

    **Narrowed further, `/ws/gql` documents:** each document a client sends
    over an open `/ws/gql` connection (a query, a mutation or a subscription)
    is now charged to `:gql`, the bucket `/gql` requests are charged to, under
    the address the connect was charged under
    (`KilnCMSWeb.GraphqlLimits.SocketDocumentBudget`, the first phase of the
    socket's document pipeline). One bucket for both transports, so moving
    from `/gql` to the socket gains a client nothing. Per address, not per
    actor as `/ws/collab` frames are: documents are not a per-keystroke
    stream, the per-address size `/gql` already has fits them, and an
    anonymous socket, where the gap was, has no actor. A subscription's pushes
    are not charged. They re-run the phases Absinthe.Phase.Init recorded when
    the client subscribed, and the budget runs before Init. Over budget, the
    document is answered with a GraphQL error (`too_many_requests`, with
    `retry_after` in seconds) before it is parsed, and the connection and its
    subscriptions stay up. Each document is also held to the complexity, depth
    and token limits `/gql` has (`KilnCMSWeb.GraphqlLimits`).

    Still uncounted, and still this item's remaining gap: events on
    `/live` (no lifecycle hook runs before every `handle_event/3`; the sign-in
    submit stays the one charged case, #715). `/ws/gql`'s `unsubscribe` frames
    are not charged either; each removes one registry entry and runs no
    document. `/ws/collab` frames and `/ws/gql` documents are the event
    surfaces counted so far (above); `/live` events remain the harder problem
    #1305 described (no single choke point, no obvious per-event cost model).

    **1.0 verdict (proposed, #1535): fix after 1.0.** Every path this item
    called a confidentiality concern is now closed or metered.
    `KilnCMSWeb.LiveJoinBudget` meters `/live` root joins,
    `KilnCMSWeb.SocketJoinBudget` meters `/ws/*` connects, `SocketEventBudget`
    meters `/ws/collab` frames, `GraphqlLimits.SocketDocumentBudget` meters
    `/ws/gql` documents, and the sign-in submit is charged (#715). What is left
    is volume: `/live` events after a join, and the unmetered `:browser`
    pipeline (`lib/kiln_cms_web/router.ex:81-90`). Both sit behind a session for
    everything except `/` and `/developers`. One correction for whoever takes
    this on: the item says no lifecycle hook runs before every `handle_event/3`.
    In fact `attach_hook(socket, name, :handle_event, fun)` does exactly that
    for a LiveView's own events, and the codebase already uses it
    (`lib/kiln_cms_web/nav_preset.ex:30`). Only LiveComponent events bypass it,
    so a per-actor event budget is feasible, just not free. A cheap companion
    could land at any time: the Sentry logger handler's `:rate_limiting` option
    is still unset (`lib/kiln_cms/application.ex:333-335`).
12. **Periodic CSP re-review** as the editor adds third-party assets. The
    runtime `img-src` is widened by `CSP_IMG_SRC` and by the Unsplash
    integration — the only externally-influenced part of the policy.

    **1.0 verdict (proposed, #1535): fix before 1.0 (do the review once; it
    finds one directive).** More sources now widen the policy than when this was
    written. `img-src` also takes the enabled oEmbed providers' thumbnail hosts
    (#489), and `media-src` takes the storage hosts (#494)
    (`lib/kiln_cms_web/router.ex:1286-1304`). More important, `connect-src
    'self' ws: wss:` (`router.ex:26`) has not changed since the skeleton commit,
    and it allows a websocket to *any* host. Script that gets past `script-src`
    could exfiltrate data over it, which is what `connect-src` exists to stop.
    Every Kiln socket is same-origin, so narrowing the directive to `'self'`
    (which CSP Level 3 applies to `ws:`/`wss:` on the same host) looks free,
    though it needs a browser check. `style-src 'unsafe-inline'` belongs in the
    same pass. At 1.0 the threat model should record a reviewed CSP, not a
    standing reminder to review one.
13. ~~**Secrets rotation runbook** (DB URL, `SECRET_KEY_BASE`,
    `TOKEN_SIGNING_SECRET`, S3 keys) is not written down.~~ **Closed by
    #1304:** [`secrets-rotation.md`](secrets-rotation.md) is the per-secret
    procedure, verified against what the code does rather than what would be
    reasonable. ~~Rotating `SECRET_KEY_BASE` permanently orphans the
    vault-encrypted columns, and the ActivityPub actor key cannot be
    re-keyed.~~ **Closed by #1487:** `KilnCMS.Keys.Vault` reads under
    `PREVIOUS_SECRET_KEY_BASE` as well while a rotation is under way, and
    `mix kiln.vault.reencrypt` (`KilnCMS.Release.reencrypt_vault/1` in a
    release) moves every vault column to the new secret. It finds those columns
    by type, never overwrites a value it cannot open, and is safe to run twice.
    `SiteFederation`'s admin-only `:rekey` replaces the actor's keypair under
    the same actor id and sends followers a signed actor `Update`.
    *Residual, and the reason to read the runbook before an incident rather
    than during one:*
    - **Sessions and tokens are still hard cutovers.** `TOKEN_SIGNING_SECRET`
      and `SECRET_KEY_BASE` each sign every user out. The read window covers
      the vault only: `Plug.Session` and `AshAuthentication.Jwt` each derive
      one key from one secret.
    - **The order of steps decides whether data survives.** If the old value is
      retired before the task has run, the vault columns are orphaned exactly as
      before. The only signal is the task's `unreadable` count, a warning in the
      log and the federation panel.
    - **Re-encryption is not revocation.** Backups taken before the task, and
      any other copy of the database, still open with the old secret. After a
      *leak*, the underlying secrets have to be rotated as well: the DKIM key,
      billing and social credentials, and the actor key.
    - **A re-keyed actor depends on its peers.** Servers that ignore actor
      `Update`s keep the old key until they re-fetch the actor, and until then
      the old key still signs traffic they accept.

    Pairs with [`backups.md`](backups.md), where the same `SECRET_KEY_BASE` is
    part of the backup.

    **1.0 verdict (proposed, #1535): still accepted at 1.0.** The two gaps this
    item was opened for are closed: the runbook (#1304), and the vault read
    window with `mix kiln.vault.reencrypt` and the actor `:rekey` (#1487). The
    four remaining bullets are properties of the mechanisms, and no change in
    Kiln removes them. Sessions and JWTs are each signed with one secret,
    backups outlive a re-encrypt, and peers cache an actor key. Rotating without
    signing everyone out would need dual-key session verification. That is a
    feature for after 1.0, not a fix.
14. ~~**The collaborative-editing socket is scoped by topic, not by
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

    **Authorization runs at connect and join and is not revisited** — *closed
    for the deliberate cases (#675).* An account that was demoted, removed from
    an org, had its scopes or audiences narrowed, or was erased used to keep
    everything its live sockets already held, for as long as the tab stayed
    open, while every HTTP surface refused it immediately.
    `KilnCMS.Accounts.SessionEviction` now drops those sockets from the actions
    that make the change, and all four surfaces can actually be dropped:
    `GraphqlSocket.id/1` returned `nil` (Phoenix for "never disconnectable"),
    `BridgeSocket` is a raw transport with no `id/1` callback and subscribes
    itself, and nothing set a `live_socket_id`, so `/live` was undroppable too.
    Evicting is not re-authorizing: the client reconnects and runs the full
    check again, which is the cheapest correct answer and costs nothing on the
    CRDT hot path.

    **Periodic re-authorization is the backstop — *closed by #775.*** Eviction
    is prompt but not complete: it fires on the actions wired to it, so an
    authorization change nobody remembered to wire in — a new action that
    narrows a grant, a role-resource edit, a direct `Ash.update` from a
    migration or a mix task — was invisible to a live socket, and so was a
    change to the *document* rather than to the user. `CollabChannel` now
    re-runs `authorize/3` — the same function `join/3` runs, not a second
    spelling of it — against a **reloaded actor**, on a timer and after every
    200 inbound updates, and closes the **connection** when it no longer passes
    (`KilnCMSWeb.SocketReauth.close_connection/1`, the same `"disconnect"`
    broadcast eviction uses), then stops the channel. The order matters and is
    not a detail: a channel that merely stops with `{:shutdown, _}` is a
    `phx_close` frame, which `phoenix.js` treats as a finished leave and never
    rejoins — the room would stay dead in that tab until a reload, buffering
    edits into a channel that would never send them, even after the grant came
    back. A closed socket is what the client recovers from: it reconnects on a
    backoff and rejoins, and every rejoin runs the full `join/3`, refused while
    the grant is narrowed and admitted once it is restored. `BridgeSocket` does
    the same for its read on the same timer (no update count: it accepts no
    writes; and as a raw transport its stop *is* the socket closing). The
    reload is the mechanism: re-running the policies against the actor struct
    the socket connected with would answer from the same stale role, scopes and
    audiences forever.

    **The exposure window an operator can rely on is 30 seconds** — the
    interval in `KilnCMSWeb.SocketReauth` — plus the in-flight message. Both
    ends of the bound are load-bearing: the timer covers a room that is
    connected but idle, and the 200-update floor covers one that is busy, since
    at typing speed a timer alone bounds the *time* a revoked editor keeps
    writing but not the *number* of writes. The floor only binds above ~6.7
    updates/second; below that the timer always fires first.

    The interval comes from a measurement, not a round number —
    `MIX_ENV=dev mix run priv/bench/socket_reauth.exs`, on a local Postgres:

    | | | |
    |---|---|---|
    | actor reload | 1 query | 0.31–0.38 ms |
    | document read + `Ash.can?(:autosave)` | 2 queries | 2.7–3.0 ms |
    | **full check** | **3 queries** | **3.0–3.4 ms** |
    | `Crdt.apply_update/2` | — | 0.002 ms |

    Note what that says, because it is the opposite of the assumption the issue
    started from: the check is **not** cheap relative to the CRDT work. It is
    ~1,900x a single update apply, because Yjs runs in a NIF and the check is
    three database round trips. One room's CPU was never the constraint though.
    The binding cost is queries per second across the deployment, and the number
    to reason about is the open-document ceiling
    (`Collab.Crdt.max_documents/0`, 500) at ~5 peers each: 2,500 channels checking every 30s is **+250
    queries/s, or ~0.27 connection-seconds per second — under 3% of the default
    `POOL_SIZE` of 10** — at a ceiling no real deployment sits at. Ten seconds
    would be roughly three times that for a window an operator gains little
    from; sixty would halve it for a window they reason about as "a minute" and
    would have to round up. 30s is the value; it is overridable with
    `config :kiln_cms, :socket_reauth_interval_ms` (and
    `:socket_reauth_update_floor`), both validated so a bad value falls back to
    the default rather than silently disabling the backstop.

    This also makes the mechanism **cluster-safe by construction**, which
    eviction is not: each channel re-checks itself against the database from
    whichever node holds it, so it needs no message to cross a node boundary.

    **Eviction's cross-node reach is reasoned about, not exercised — a
    deliberate decision (#1060), not an oversight.** The deployment genuinely
    is multi-node capable (`DNSCluster` is in the supervision tree, and
    `Phoenix.PubSub` is started with no adapter override, so it defaults to
    the distributed one), and `SessionEviction.evict/2` is one
    `Endpoint.broadcast/3` call — no custom fan-out to get wrong. What this
    codebase does not do, anywhere, is stand up a second BEAM node inside the
    test suite to prove a `Phoenix.PubSub` broadcast crosses one: `Cache.ClusterBust`
    (#739), landed for the identical shape of problem — a local action that
    must reach every node — draws the same line. Its own suite proves the
    writing node's broadcast and a receiving node's handler independently,
    against the same topic, and stops there; it does not spin up a real
    second node either. `SessionEvictionTest` mirrors that scope: every
    trigger, every socket's droppability, and the broadcaster/listener topic
    agreement are all proven on one node, which is what our own code is
    responsible for — `Phoenix.PubSub`'s distributed delivery is upstream,
    third-party behavior this app depends on rather than implements, the same
    way a test suite here does not re-verify Postgres's own transaction
    isolation. `#743` records the identical per-node assumption for the
    pending-sign-in cache, for the same reason. The 30-second backstop
    applies either way, and bounds the cost of trusting this.

    *Residual:* the re-check re-runs the join's rule, so what it catches is
    exactly what a *fresh join* would refuse — no more. A document publish under
    an open room used to make that concrete: `Ash.can?` on `:autosave` does not
    consult the row-level `state == :draft` filter that action carries, so
    publishing does not close the room, and collaborative prose no client
    autosave had captured was lost at checkpoint. That was a data-loss bug
    rather than an authorization one, and it is closed at the publish path
    rather than at the authorization check (#1061):
    `Changes.CheckpointCollabRoom` carries the room's converged prose into the
    publish's own write, and the room is told afterwards so its editors stop
    typing into a document nothing will persist. The authorization re-check is
    unchanged — collaborative editing of published content remains supported.

    **1.0 verdict (proposed, #1535): still accepted at 1.0.** Closed by #655,
    #675 and #775. The residual is that the re-check catches exactly what a
    fresh join would refuse, and that is the intended meaning: it is an
    authorization check. Its one data-loss consequence, publishing under an open
    room, was closed at the publish path (#1061). The bound an operator can rely
    on stays 30 seconds (`lib/kiln_cms_web/channels/socket_reauth.ex`), and
    cross-node eviction stays reasoned, not exercised, as #1060 decided.
15. ~~**Webhook deliveries have no anti-replay.**~~ **Closed for receivers
    that verify the timestamped signature.** Every delivery now carries
    `x-kilncms-webhook-signature: t=<unix>,v1=<hex>`, an HMAC of
    `"<t>.<body>"`, and a `delivery_id` inside the signed body (echoed in
    `x-kilncms-delivery-id`) that stays the same across a delivery's retries.
    A receiver that rejects a `t` outside its window (five minutes is the
    documented default) and remembers the delivery ids it has seen inside that
    window cannot be replayed to. Re-stamping a captured request with a fresh
    `t` does not verify, because `t` is inside the MAC.

    **Remainder.** The original body-only `x-kilncms-signature` is still sent
    during a deprecation period. A receiver that verifies only that header is
    as exposed as before: anyone who captures one signed request (TLS would
    have to fail first) can replay it indefinitely. The replay re-announces old
    state rather than granting new access, but the replayed body may be
    audience-gated or passphrase-locked content (`audience`/`locked`, #1014).
    So the exposure lasts as long as the receiver keeps that body, not merely
    as long as the body is harmless. An admin **redelivery** is a new delivery
    with a new id and a fresh timestamp, on purpose. See
    [webhooks.md](webhooks.md#verifying-the-signature).

    **1.0 verdict (proposed, #1535): fix before 1.0 (remove the deprecated
    header).** The timestamped scheme closes replay for receivers that verify it
    (`lib/kiln_cms/webhooks.ex:46-65`; both headers are sent at
    `lib/kiln_cms/webhooks/delivery_worker.ex:158-161`). The remainder exists
    only because the body-only `x-kilncms-signature` is still sent. 0.10.0
    deprecated it with "will be removed in a later release" and no date
    (`lib/kiln_cms/webhooks.ex:21-24`, `docs/webhooks.md:157`). If it survives
    into 1.0 it becomes part of the covered webhook contract and can only be
    removed at 2.0. The removal therefore belongs in 0.12, where the roadmap
    puts deprecations, with an upgrade note telling receivers to switch.

**Not on this list, but named by the 1.0 roadmap: `/api/ask` lets an anonymous
caller drive LLM cost** (see *Other outbound calls* above). **1.0 verdict
(proposed, #1535): still accepted at 1.0.** Generation is off by default
(`generator: nil`, `KilnCMS.Ask`). When an operator turns it on, `/api/ask` has
its own `KilnCMS.LLM.Budget` buckets on top of the `:api` limiter. One is per
caller and falls back to the client address; the other is per org and is the
actual spend ceiling. Exhausting either degrades the answer to retrieval-only
instead of failing (`lib/kiln_cms/ask.ex:60-69`). An operator who enables
generation chooses the ceiling. This paragraph is deliberately not a numbered
item, so no reference elsewhere shifts.

## Operating the dependency audit

`mix deps.audit` ([mix_audit](https://github.com/mirego/mix_audit)) checks
`mix.lock` against mirego's mirror of the Elixir security advisory database,
and `mix hex.audit` checks it against the advisories Hex itself serves. Both
run, because the two databases are not the same: on 2026-09-18 the mirror
knew none of the 89 advisories — six CRITICAL, all in `ash_authentication` —
that Hex listed against the v0.9.0 lock. They run:

- in CI, as its own **Dependency audit** job in
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml), and
- locally as part of `mix precommit`.

A new advisory affecting a locked dependency fails the build — including on a PR
that changed no dependencies, since the advisory database moves independently of
this repo. It is a separate job so that failure does not bury the lint and test
results of an unrelated change. Remediate by upgrading the dependency; if no
fixed version exists, document the accepted risk and acknowledge the advisory
(mix_audit's ignore options; the `:hex` section of `mix.exs` for `hex.audit`)
rather than dropping the check.

The CI job fetches the advisory database explicitly before auditing. mix_audit
clones it at run time and discards the exit status of its own git commands, so a
failed fetch would otherwise leave it with zero advisories and report a green
"No vulnerabilities found" — a pass that verified nothing.
