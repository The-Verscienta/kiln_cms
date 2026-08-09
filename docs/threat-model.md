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
| OpenAPI & explorer | `/api/json/open_api`, `/api/json/swaggerui` | none — and **not served in prod** unless `API_DOCS_ENABLED` (#567) | `:docs` |
| Headless sign-in | `POST /api/auth/sign_in` | credentials → JWT, or a pending token for a 2FA account | `:auth` + per-account (#478) |
| Headless second factor | `POST /api/auth/sign_in/verify` | encrypted pending token + TOTP or recovery code | `:auth`; the same per-account second-factor budget as the browser prompt (#714, #726) |
| MCP (LLM authoring) | `/mcp` | **API key required** | `:api` |
| Public forms | `GET /api/forms/:slug`, `POST /forms/:slug`, `POST /api/forms/:slug` | none (no CSRF by design) | `:form` |
| Form embed | `GET /forms/:slug/embed` | none | `:delivery` |
| Preview | `/preview/:token`, `/preview/:token/live` | signed token *is* the credential | `:preview` |
| Newsletter | `/newsletter/confirm/:token`, `/newsletter/unsubscribe/:token` | signed token | `:form` |
| Auth flows | `/sign-in`, `/register`, `/reset`, `/auth/**`, `/auth/passkey/*` | varies | `:auth`, except `POST /auth/*/password/register`, which takes `:register` **instead** so the two registration doors agree (#724) |
| Second factor | `GET`/`POST /sign-in/verify` | signed `:pending_2fa` token + TOTP or recovery code | `:auth`; the `POST` also per-account, tighter than sign-in (#714) |
| Credential submits over `/live` | LiveView `"submit"` on the sign-in, register, reset-request and magic-link forms — **all four render on all three auth pages** | credentials → session / account / mail | charged on the *action*, since no plug can reach them: sign-in `:auth` (#715) + per-account (#478); registration `:register` (#724); reset and magic-link `:auth` (#724) + the per-address mail budget |
| Editor / admin LiveViews | `/editor/**`, `/media` | session cookie + role | none, except the three TOTP actions on `/editor/settings`: per-account, the second factor's own bucket (#727) |
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
  residual risk 4 records. It carries no per-*account* budget, because there is
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
  cookie copied elsewhere keeps working until it expires. There is no
  "sign out other devices" affordance, and #734 records that a password change
  does not currently revoke stored tokens either.

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
  (`Webhooks.DeliveryWorker` still has its own copy of the pinning; folding it
  onto `SafeFetch` is tracked in #753.)
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
    *Residual:* an abandoned exchange still leaves a live token row nobody
    holds, for the JWT's natural lifetime. The **rate** is now bounded — #742
    stopped a password that stops at the code prompt from clearing the
    per-account sign-in counter, so an attacker gets `@budget` of them per
    window per account rather than as many as their IP pool allows. Not minting
    the token until the second factor verifies is the deeper fix and fights
    `require_token_presence_for_authentication?`; #742 stays open for it.
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
    trade for their own state; residual risk #9 below covers the throttle.
  - Codes are charged `AccountThrottle.consume_second_factor/1` on the **same
    per-account bucket** the browser prompt charges. Per-surface budgets would
    let an attacker double their guesses by alternating endpoints, and the
    five-minute pending lifetime bounds nothing on its own — re-running the
    password step mints a fresh token. Since #742 each of those costs a unit of
    the sign-in budget, so the renewal is bounded rather than free. That bucket is per node too (residual risk #9 below), so the real
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
  *Watch:* the bound is per node (residual risk 9), and it bounds *guessing*
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
- **Gated content is delivered** — a content event carries the full block tree
  whether the document is public, audience-gated, or passphrase-locked. That is
  deliberate: an endpoint is operator-configured, HMAC-signed and SSRF-guarded,
  unlike the anonymously-queryable Meilisearch index, which excludes gated
  content outright (#1006). The payload marks both gates (`audience`, `locked`,
  #1014) so a receiver can filter — but the filtering is the receiver's, and a
  webhook endpoint's blast radius is therefore *every* document that fires an
  event, not only the public ones. Treat an endpoint URL as a credential.
- **SSRF** — mitigated by `SafeUrl` with IP pinning (see Controls).
- **Forgery at the receiver** — deliveries are HMAC-SHA256-signed over the raw
  body; a receiver that verifies `x-kilncms-signature` knows a delivery is
  genuinely from Kiln with unmodified content. There is no timestamp or nonce
  in the scheme, so this proves origin and integrity, not freshness — see
  residual risk 14 and [webhooks.md](webhooks.md#verifying-the-signature).

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

3. **Unknown `Host` headers resolve to the default organization — unless
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
   production.3. **The OpenAPI spec and Swagger explorer describe the write surface** —
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
8. **A block field policy could be cleared by omission** — *closed for the
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

   The binding applies only when the client demonstrably round-trips ids, and
   that gate is forced rather than chosen: `blocks` is not `public?` and GraphQL
   carries `hide_inputs: [:blocks]`, so most callers cannot read a child's id,
   and `restore_version` accepts nothing but a `version_id` — versions captured
   before the editor stamped children restore id-less by construction. Demanding
   an id back from those callers would refuse them permanently while naming a
   remedy neither could perform.

   **Published content is now round-trippable** (#954). The fired `:json`
   artifact names each block's id `_id`, nested children included, and the write
   path accepts that spelling — so a headless client editing published content
   can read the artifact, send it back, and get the binding. Before, that
   arrived id-less (fresh ids minted, `_id` stored as a junk key nothing read),
   so the one available route to round-tripping silently did not work.

   *Residual:* a **draft** has no readable block surface at all, so a headless
   client editing one still cannot produce ids, and a caller willing to drop
   every id is governed by the count alone. Closing that needs a draft-readable
   block-tree surface — a genuine API addition rather than a fix, tracked in
   #954.

   *Residual, all about **which block an id names** rather than what a field may
   hold:* an editor can still reuse the id of another block **of the same type**
   to move an admin-set field off the block that had it, and an empty
   `block_tree` deletes the block outright. Both predate this and need the write
   path to verify a submitted id belongs to the block it claims. The same is
   true of nested children: ids there are client-supplied, so relabelling which
   child an id names is believed, and only the two-children-one-id case is
   decidable without an ownership check.
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
    Tracked in #678.
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
    *Residual:* it is prompt, not complete — it fires on the actions wired to
    it, so an authorization change nobody remembered to wire in is still
    invisible to a live socket. The backstop is periodic re-authorization inside
    the channel, tracked as #775. The broadcast itself is cluster-wide —
    `Phoenix.PubSub`'s default adapter carries it to every node — but nothing
    verifies that, so treat multi-node eviction as untested rather than
    unsupported.
14. **Webhook deliveries have no anti-replay.** The signature
    (`x-kilncms-signature`, HMAC-SHA256 over the raw body) proves a delivery's
    origin and integrity, not its freshness — there is no timestamp or nonce
    binding it to a point in time, so anyone who captures one signed request
    (TLS would have to fail first) can replay it to the receiver indefinitely.
    Accepted for now: a replay re-announces old state rather than forging new
    access — it delivers a payload the receiver was already sent once, to a
    receiver the operator chose. Note this is **not** because the payload is
    always public content: a content event carries an audience-gated or
    passphrase-locked body too, marked by `audience`/`locked` (#1014), so the
    replay window is bounded by the receiver's own retention of that body
    rather than by the body being harmless. A
    receiver with exactly-once requirements should dedupe on its own terms
    (the content payload's `id`/`updated_at`, or a delivery id tracked out of
    band) — see [webhooks.md](webhooks.md#verifying-the-signature).

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
