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
- **API keys** — `kiln_…` bearer keys carrying a `:read`, `:read_write` or
  `:draft_write` scope.
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
| Probes & SEO | `/up`, `/ready`, `/sitemap.xml`, `/news-sitemap.xml`, `/robots.txt`, `/.well-known/security.txt` (+ `/security.txt` redirect), `/llms.txt`, `/manifest.webmanifest`, `/offline.html` | none | `:probe` |
| First-run bootstrap | `/setup` | none — the `:bootstrap_admin` policy (`Checks.NoAdminExists`) + advisory lock in `KilnCMS.Accounts.Bootstrap` are the gate | none |
| GraphQL | `/gql` (GET + POST), `/ws/gql` | optional JWT / API key | `:gql` (per operation, on both transports), `:gql_join` (socket connects) |
| JSON:API | `/api/json/**` (GET/POST/PATCH/DELETE) | optional JWT / API key | `:api` |
| API landing | `GET /api` (302 to `/developers`) | none | none (`:browser` pipeline) |
| Headless REST | `/api/content/**`, `/api/resolve`, `/api/locales`, `/api/search`, `/api/ask`, `/api/provenance/**`, `/api/visual-editing/:type/:slug`, `/api/sync`, `/api/schema`, `/api/menus/**`, `/api/content/:type/:id/revisions/**` | optional JWT / API key | `:api` |
| Change feed (SSE) | `GET /api/feed` | optional JWT / API key; the stream is the anonymous view whatever the credential, like `/api/sync` | `:feed_join` (connects, per address, charged first and refused as a `200` + `event: busy`), then `:api`; open streams capped per API key or address (50) and per node (20,000), resumes replaying at once per node (8) |
| OpenAPI & explorer | `/api/json/open_api`, `/api/json/swaggerui` | none — and **not served in prod** unless `API_DOCS_ENABLED` (#567); the document (never the explorer) also answers any valid API key | `:docs` |
| GraphQL SDL | `GET /api/graphql/schema.graphql` | none where introspection is on; **API key required** in prod unless `GRAPHQL_INTROSPECTION_ENABLED` | `:docs` |
| Headless sign-in | `POST /api/auth/sign_in` | credentials → JWT, or a pending token for a 2FA account | `:auth` + per-account (#478) |
| Headless second factor | `POST /api/auth/sign_in/verify` | encrypted pending token + TOTP or recovery code | `:auth`; the same per-account second-factor budget as the browser prompt (#714, #726) |
| Content unlock | `POST /api/content/:type/:slug/unlock`, `POST /_unlock` (CSRF) | passphrase | `:unlock` (`POST /_unlock` also `:delivery`) |
| Media upload | `POST /api/media`, `/api/media/import-url`, `/api/media/uploads[/complete]` | JWT / API key; `:read_write` + editor, checked **before** `POST /api/media`'s body is parsed (the endpoint leaves it unread) | `:api` + `:media_upload` |
| MCP (LLM authoring) | `/mcp` | **API key required** | `:api` |
| Security posture (monitoring) | `GET /api/security/posture` (#2521) | **JWT or API key of an administrator of the request's site required** (never a `:draft_write` key); behind the site's admin allowlist, checked first | `:api` |
| Public forms | `GET /api/forms/:slug`, `POST /forms/:slug`, `POST /api/forms/:slug` | none (no CSRF by design) | `:form` |
| Form embed | `GET /forms/:slug/embed` | none | `:delivery` (framing CSP) |
| Form page | `GET /forms/:slug` (#2138): not a route, the last fallback of `/:type/:slug` delivery; active forms of the serving org only | none | `:delivery` (site CSP) |
| Preview | `/preview/:token`, `/preview/:token/live`, `/preview/release/:token` | signed token *is* the credential | `:preview` |
| Headless draft mode | `GET /api/json/*`, `GET /api/content/:type/:slug` and `GET /api/visual-editing/:type/:slug` with `x-kiln-preview-token` / `?preview_token=` (#1887) | signed token, pinned to the serving site, admits its one record on the primary read only; never read on a write | `:api` + `:preview_api` |
| Newsletter | `POST /newsletter/subscribe`, `/newsletter/confirm/:token`, `/newsletter/unsubscribe/:token` | honeypot / opaque token; the confirm and unsubscribe GETs only render a page, the POST changes the subscription (#1664) — confirm's POST is also CSRF-checked | `:form` |
| Billing webhook | `POST /billing/webhooks/stripe` | HMAC over raw body | `:billing_webhook` |
| ActivityPub | `GET /.well-known/webfinger`, `/actor`, `/actor/outbox`, `/actor/followers`, `/ap/object/:id`; `POST /actor/inbox` | none (GET) / HTTP Signature over the raw body (inbox) | `:probe` (GET) / `:api` (inbox) |
| Calendars / feeds | `/calendar.ics`, `/:plural/calendar.ics`, `/:plural/:slug/calendar.ics`, `/:plural/index.json`, `/feed.xml`, `/feed.json`, `/:plural/feed.{xml,json}` (and the category/tag variants) | none (published only) | `:probe` |
| Membership (paid audiences) | `/membership` | optional session | `:delivery` |
| Auth flows | `/sign-in`, `/register`, `/reset`, `/auth/**`, `/auth/passkey/*`, `/auth/site-sso[/callback]` | varies | `:auth`, except `POST /auth/*/password/register`, which takes `:register` **instead** so the two registration doors agree (#724) |
| Second factor | `GET`/`POST /sign-in/verify` | signed `:pending_2fa` token + TOTP or recovery code | `:auth`; the `POST` also per-account, tighter than sign-in (#714) |
| Sign-in unlock (#2250) | `GET`/`POST /sign-in/unlock` (ask for a link), `GET`/`POST /auth/unlock/:unlock_token` (the emailed link) | none to ask; the signed, stored `sign_in_unlock` token is the credential, and only the `POST` spends it | `:auth`; the mail also `mail:sign_in_unlock` per address (3/h), charged only for a paused member of the site |
| Credential submits over `/live` | LiveView `"submit"` on the sign-in, register, reset-request and magic-link forms — **all four render on all three auth pages** | credentials → session / account / mail | charged on the *action*, since no plug can reach them: sign-in `:auth` (#715) + per-account (#478); registration `:register` (#724); reset and magic-link `:auth` (#724) + the per-address mail budget |
| Editor / admin LiveViews | `/editor/**`, `/media` | session cookie + role | none, except the three TOTP actions on `/editor/settings`: per-account, the second factor's own bucket (#727) |
| Media bytes | `/media/:id/download`, `/media/:id/stream` | session (a gated item needs its audience) | `:delivery` |
| Image transforms | `/media/:id/t/:ops` | session (same read as the download); unsigned URLs allowlisted, signed ones HMAC-checked | `:media_transform` per request + `:media_render` per cache miss, plus a per-node render gate |
| Media blobs | `/uploads/*` (`Plug.Static`) | none | none (and not covered by the IP block list) |
| Sockets | `/live`, `/ws/collab`, `/ws/bridge` | session / signed token + per-document read / preview token (one document, re-verified until it expires) or API key + per-document read | `/live` root joins `:live_join` per address (#1183); every frame on a `/ws/collab` connection `:collab_event` per account (#1305); otherwise none (except the sign-in submit, above) |
| Dev tools | `/dev/dashboard`, `/dev/mailbox`, `/admin`, `/gql/playground` | compile-gated off in prod | — |

**`/ws/collab` is a prototype surface.** Its joins are refused unless
`config :kiln_cms, :collab_prototype` is on, and it is on only in
`config/dev.exs` and `config/test.exs` (`config/prod.exs` pins it `false`,
#1660) — so a production build carries the socket but accepts no CRDT session
(#1324, and [collaborative-editing-spike.md](collaborative-editing-spike.md)). Everything
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
  and every stored token revoked on a password change or reset
  (`KilnCMS.Accounts.Changes.RevokeAllTokens`, #734).
- **Authorization** — per-resource `policies`, field policies hiding `role` and
  author PII, a `state == :published` filter as the public-read boundary, the
  orthogonal audience axis, granular per-type and per-field editor grants, and
  block-level `editable_by` field policies (below). Backed by the policy test
  suite and [`policy-matrix.md`](policy-matrix.md).
- **API-key scoping** — keys store only a SHA-256 hash, carry an immutable
  `:read` / `:read_write` / `:draft_write` access scope, require an expiry, and
  can be revoked. A `:read` key is refused every write action; a `:draft_write`
  key may only create drafts and edit its own, by an allowlist placed above the
  admin bypass (#2273); no key may hard-delete.
- **Multi-tenancy** — `Plugs.SetTenant` resolves the org from the HTTP host
  (subdomain of `TENANT_BASE_HOST`, then custom domain) and sets it as the Ash
  tenant for the whole request, so tenant scoping applies to GraphQL and
  JSON:API without resolver changes. A host matching neither falls back to the
  default org unless strict host matching is on — `TENANT_STRICT_HOST=true`, or
  unset on a deployment with more than one org (#1547) — which 404s it instead;
  see residual risk 3.
- **Rate limiting** — `Plugs.RateLimit` (per-IP) across nine
  buckets; limits in `lib/kiln_cms_web/rate_limit.ex`. The credential buckets
  (`:auth`, `:register`, `:unlock`) and every `AccountThrottle` budget count in
  Postgres (`KilnCMS.Accounts.ThrottleStore`, #1619), so they hold across nodes
  and restarts; the rest are flood ceilings counted per node in ETS. Inside
  `:delivery`, a request whose `User-Agent` claims to be a search engine, an AI
  crawler, another bot or nothing at all is refused at its own share of the same
  per-address count (#2243, see [Bot budgets](#bot-budgets)); browsers are
  unchanged. **The credential forms
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
  reset and a passkey sign-in each clear it, and so does an emailed unlock link
  (#2250), which clears nothing else ([Account unlock](#account-unlock-2250)). A separate flat per-address budget
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
  or reset, and an administrator's *Sign out everywhere* on the account's page
  under `/editor/accounts`. The password actions do it through an explicit
  `KilnCMS.Accounts.Changes.RevokeAllTokens`, inside the write's transaction —
  the password is not changed if the revocation fails. Not through
  `log_out_everywhere`'s `apply_on_password_change? true`, which
  `KilnCMS.Accounts.User` declared but which never fired before
  AshAuthentication 5.0.0-rc.16: its change was gated on `hashed_password`
  being *touched*, evaluated when the changeset is built, and both actions
  write the hash in a `before_action`. (Once rc.16 made it fire, its
  resource-wide sweep also revoked the session a reset signs its user into, so
  Kiln turned it off.) Until 1.0 that made
  this control a claim rather than a fact, which is how an earlier revision of
  this page came to say it held "since #734" (fixed properly in #734's reopen,
  with the socket half in #1637). The session on the device that changed the
  password is revoked too; the settings page sends the user to sign in again.
  Since #1823 an account holder can also do it themselves: *Active sessions* on
  `/editor/settings` lists their own sessions and signs out one, or every one
  but the current, through `KilnCMS.Accounts.Sessions`. That revokes the
  session's token, the remember-me cookie issued to the same browser (its jti
  is recorded on the session row at sign-in), and closes that session's open
  LiveViews (`SessionEviction.evict_session/2`). It does not reach a
  `/ws/collab` or `/ws/gql` socket already connected from that browser: those
  are keyed per user, and close at their next reconnect or re-check.
  Since #2246 a site admin can also end sessions on one site: after a
  configurable idle time, or all at once with *Sign out everyone*; see
  [Idle timeout and sign out everyone](#idle-timeout-and-sign-out-everyone-2246).

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
- **Breached-password check (#2240)** — when a password is set (register,
  change, reset, first-run setup) `KilnCMS.Accounts.Changes.CheckBreachedPassword`
  looks it up against the Have I Been Pwned range API by k-anonymity: SHA-1
  here, only the 5-character prefix out (`Add-Padding: true`), the match made
  locally, through `KilnCMS.SafeFetch` with no redirects, a 128 KB cap and a 3 s
  deadline. The site's stance is `CMS.SitePasswordPolicy` (off / warn / block,
  `/editor/password-policy`, admin-only), then `BREACHED_PASSWORD_POLICY`, then
  warn; `block` refuses only an account whose tier is admin (the stricter of its
  global role and its tier on the request's org), and the tier is the
  *target's*, never the actor's. `BREACHED_PASSWORD_CHECK=false` makes no call.
  The lookup runs once per submitted action (a `before_transaction` hook, so
  not per keystroke and holding no connection), after the validations and the
  registration throttle, and nothing identifying the password, hash, prefix,
  account or org is logged or put in telemetry. See *Breached passwords* below.
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
  social posting, portability import, Unsplash import (#1653) — goes through
  `SafeFetch`. A new caller
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
  The `:delivery` bucket caps volume per address, and since #2243 a client that
  declares itself a script or bot, or sends no user agent, is capped lower than a
  browser ([bot-budgets.md](bot-budgets.md)). *Residual:* the class comes from the
  `User-Agent` header, so a scraper that claims to be a browser gets a browser's
  ceiling; this is cost control, not a defence. Front with a CDN to absorb load.

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
  Taking content down is held to the same bar as putting it up: `unpublish`,
  `archive` and their scheduled twins sit in the publish policy (#2134), so an
  editor's `:read_write` key on a site where only admins publish gets `403` for
  them, as for `publish`. Before that, an editor who could not publish could
  still unpublish or archive live content
  ([policy matrix](policy-matrix.md)).
- **Mass assignment** — Ash actions accept only declared inputs (`accept`).
- **Query cost** — each document is capped at complexity 200, depth 15 and
  2,000 tokens on both transports, and a batch at 10 operations. Complexity is
  a price, not a row count: a relationship list without `limit` is priced at
  five rows and can return more, so the cap limits how deeply lists nest rather
  than how many rows one document returns. Each document on `/ws/gql` is
  charged to `:gql` like a `/gql` request (residual item 11). Introspection is
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
  The operator can also ask for a human-verification check here with
  `CHALLENGE_API_SIGN_IN` (off by default, so the contract is unchanged); see
  [Human verification](#human-verification-2249).
- **Skipping the second factor** — *closed (#726).* This endpoint used to return
  a full JWT for a 2FA-enabled account on the password alone, where the browser
  flow diverts to `/sign-in/verify`. That made TOTP optional in practice rather
  than in policy: there is no point bounding six digits at one prompt while a
  door next to it does not ask. A 2FA account now gets `200` with a pending
  token instead of `201` with a JWT, and finishes at
  `POST /api/auth/sign_in/verify`.
  - **What is withheld is access to the token, not its existence.**
    `Strategy.action/4` mints the JWT and — because `User` sets
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
    merely usually surviving. A password change or reset (`RevokeAllTokens`, #734)
    and account erasure sweep every row a subject owns, held ones included; sign-out revokes
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

    `WebAuthn.take_challenge/1` still makes the node-local trade for its own
    state. `AccountThrottle` no longer does: since #1619 its budgets live in
    Postgres (residual risk #10 below, closed).
  - Codes are charged `AccountThrottle.consume_second_factor/1` on the **same
    per-account bucket** the browser prompt charges. Per-surface budgets would
    let an attacker double their guesses by alternating endpoints, and the
    five-minute pending lifetime bounds nothing on its own — re-running the
    password step mints a fresh token. Since #742 each of those costs a unit of
    the sign-in budget, so the renewal is bounded rather than free. The bucket
    is shared by every node (#1619, residual risk #10 below), so the ceiling
    is 5 per window however many nodes serve the endpoint.
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
  *Watch:* the bound holds across nodes since #1619 (residual risk 10), and it
  bounds *guessing* only. It hands a stolen session a small denial-of-service it did not have:
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

### Blocked addresses

An admin (#2242) can refuse an address or range per site from `/editor/ip-blocks`; see
[ip-blocking.md](ip-blocking.md).

- **What it stops.** Every dynamic route, via `KilnCMSWeb.Plugs.IpBlock` straight
  after tenant resolution, and the sockets (`/live`, `/ws/gql`, `/ws/collab`,
  `/ws/bridge`), which check the same list on connect. The answer is an empty
  `403`; nothing says a list exists.
- **What it does not.** `Plug.Static` assets and `/uploads/*` are served above the
  tenant lookup and cannot be scoped to a site, so a block does not cover them
  (see "Media" below): refuse those at a CDN or proxy. Loopback is never blocked,
  and `/up` and `/ready` are exempt.
- **The address is only as good as the proxy config.** The rule matches the
  address `KilnCMSWeb.Plugs.ClientIp` resolves. Behind a proxy with
  `TRUSTED_PROXIES` unset that is the proxy, so a rule would block every visitor.
  The console page warns when it sees that state.
- **It cannot lock the operator out silently or wholesale.** Ranges wider than
  `/8` (IPv4) or `/16` (IPv6) and anything overlapping loopback are refused on
  write; a rule containing the admin's own address needs confirmation.
- **It fails open.** An unreadable list lets requests through rather than taking
  the site down with the database. Nothing is cached from a failed read.
- **Who can edit.** Organization admins only, every action including the read; no
  API surface exposes it, so a leaked API key cannot lock a site out.
- **No address in logs.** The refusal counter `kiln_cms.ip_block.refused.count`
  carries the surface only.
- **Limits.** Matching is per source address: it does not stop a distributed
  source, and a visitor can change address. Expired rules are not swept.

### Admin allowlist (#2248)

`KilnCMS.Security.AdminAllowlist`, `KilnCMSWeb.Plugs.AdminAllowlist`,
`KilnCMSWeb.AdminAllowlist`. A site admin can restrict the console and every
sign-in route to listed networks at `/editor/admin-allowlist`; see
[admin-allowlist.md](admin-allowlist.md) and
[ADR 0019](decisions/0019-the-admin-allowlist-fails-closed-and-only-the-operator-lifts-it-from-outside.md).

- **What it stops.** A stolen admin (or any) password, session cookie or
  remember-me cookie used from outside the listed networks to reach the
  console, its exports, `/setup` or any sign-in route, including the headless
  password exchange `POST /api/auth/sign_in`, and any credential, API keys
  included, used from outside to read the site's security posture
  (`GET /api/security/posture`, #2521). The password form checks the
  password over its LiveView socket (`SignInLive`), so the socket join is gated
  as well as the HTTP request; otherwise an outsider could test passwords.
- **Gated by route, not by path.** The HTTP gate is the router pipelines
  `:admin_allowlist` and `:admin_allowlist_api` (the console's surface) and
  `:sign_in_allowlist` and `:sign_in_allowlist_api` (sign-in's, #2493), first
  in each gated
  `pipe_through`, ahead of `fetch_session`: a refused request reads no session
  and is never signed in by a remember-me cookie. The socket gate is an
  `on_mount` hook on every LiveView module and in every gated `live_session`,
  acting for exactly the `live_session`s behind the pipeline.
  `test/kiln_cms_web/admin_allowlist_routes_test.exs` pins the gated route set
  route by route, so a new console or sign-in route cannot land ungated by
  accident.
- **Fails closed.** An unreadable list answers `503` and refuses joins, and is
  not cached. The exception is a site this node last read as off, which stays
  off through a failed read (per node, a day, replaced by any save), so a
  database blip does not take every site's console down. A host that resolves
  no site refuses a gated join. Public delivery never reads the list.
- **Cannot lock the saver out.** A save that does not admit the address the
  page was loaded from (and the socket's own address, when it has one) is
  refused, as is one made while a forwarding header arrives that nothing
  trusts. Loopback, and ranges wider than `/8` or `/16`, cannot be listed.
- **Break-glass only widens or clears.** `KilnCMS.Release.admin_allowlist/1`
  runs `operator_override` as the `:operator` system actor and records
  `admin_allowlist_overridden`; adding to a list that is off is refused. An org
  admin is refused that action.
- **The block list wins.** `KilnCMSWeb.Plugs.IpBlock` runs at the endpoint
  before any gated pipeline.
- **No platform-admin exemption.** The gate runs before anyone is known, so
  an exemption would make a stolen platform credential the bypass.
- **Sampled, address-free telemetry.** `admin_access_refused` is sampled per
  site and address (an IPv6 address per `/64`) because anyone outside can
  cause it. The counter `kiln_cms.admin_allowlist.refused.count` carries
  surface and reason, never the address.
- **Residual risks.**
  1. **Stamp-vouched socket joins on Fly.io and App Platform.** Where the
     socket cannot see the client (`Fly-Client-IP`, `do-connecting-ip`, or a
     proxy that sets only `Forwarded:`), a join is admitted on the address the
     HTTP gate stamped into the page's signed LiveView session. A session
     token carried to another network, or scraped from a page, can join for up
     to **5 minutes** after the HTTP load that stamped it; after that the join
     is refused and the page must reload over HTTP.
  2. **Platform-header spoofing from inside the platform.** `CLIENT_IP_HEADER`
     trusts the platform's header with no peer check. A machine inside the
     platform's private network (another app in the same Fly.io organization,
     a Railway project's private network) can reach the app directly, set the
     header to a listed address and bypass the list.
  3. **Long-poll keeps its first connect info.** The LiveView long-poll
     transport evaluates `connect_info` on the first poll; later polls from a
     different address are not re-checked until the session reconnects.
  4. **A session cookie carried outside still reaches the ungated signed-in
     routes**: `/account` (the reader's own settings) and the media routes
     (`/media/:id/download` and its siblings), which serve what the session
     may read. It cannot reach the console.
  5. **Issued JWTs and API keys keep working anywhere**, including a JWT
     obtained from a listed network before the attacker left it, on every
     surface but `GET /api/security/posture` (#2521), which is behind the
     allowlist whatever the credential. A per-key allowlist is a follow-up.
  6. **The kill switch is not in the security log.** `KILN_ADMIN_ALLOWLIST_DISABLED`
     has no site and no person; the boot log warns and the allowlist page
     shows a banner, and the platform's environment history is the only trail.
     The direct SQL recovery is not recorded either.
  7. **Rolling back turns the control off silently.** A release before #2248
     has no gate; the table stays and is ignored. The upgrade notes say so.
  8. **Members are gated with admins, unless the site opts out.** While a list
     is on and "Also restrict sign-in" is on (the default), members, readers
     and apps that sign people in from their own devices can only sign in from
     listed networks.
  9. **With "Also restrict sign-in" off (#2493), passwords work from
     anywhere.** The sign-in routes and `POST /api/auth/sign_in*` answer every
     network, so an outsider can test a password and, with an admin's, get a
     full-role JWT that JSON:API, GraphQL and MCP accept from anywhere. The
     console, `/setup`, `/ws/collab` and the posture endpoint stay gated. The
     setting is the site admin's, audited as `sign_in` on
     `admin_allowlist_changed`; the page recommends two-factor sign-in.

### Scanner 404 blocking (#2253)

An opt-in control on top of the block list above: `KilnCMS.Security.ScannerGuard`
adds a temporary `IpBlockRule` for an address that racks up delivery 404s or
probes bait paths. Off unless `KILN_SCANNER_BLOCKING` is on; see
[ip-blocking.md](ip-blocking.md#block-scanners-automatically).

- **What it is for.** Slowing automated probing (credential-file and CMS-plugin
  scans) and cutting its load. It is not a defence against a determined or
  distributed attacker: matching is per address, an attacker can rotate
  addresses (an IPv6 host is counted per `/64`), and blocks expire.
- **Turning it against others.** The main hazard is a hostile page or email that
  makes visitors' browsers request missing paths on our site so the visitors are
  blocked. Browser-like requests (`Sec-Fetch-Mode`, `Sec-Fetch-Dest`, or a
  `Sec-Fetch-Site` other than `none` / `same-origin`) are never counted, and a
  signed-in visitor is never counted. Header absence is not proof of a scanner, so
  the threshold stays the real control, and a recent sign-in from the address
  (24 hours) prevents a block. Addresses that are private, loopback,
  link-local, CGNAT or in `TRUSTED_PROXIES` are never counted, and a forwarded
  request with no trusted proxy is never counted, so a shared proxy or office
  NAT is not blocked as one scanner.
- **Search-engine exemption, checked by DNS.** A `User-Agent` naming a search
  engine (`KilnCMS.BotClass.search_engine/1`) skips the miss threshold only,
  never the bait threshold, and only until crawler verification (#2254, below)
  proves the claim false. A claim not yet checked, skipped, or whose DNS gave no
  answer keeps the exemption, so a real crawler's first misses from a new
  address never count. A scanner claiming to be Googlebot is therefore counted
  once its address fails the reverse-DNS check, but one whose PTR zone never
  answers (an attacker's own reverse zone left silent) keeps the exemption, as
  every claim did before #2254. A DuckDuckBot claim cannot be checked and is
  always exempt. With `KILN_CRAWLER_VERIFICATION=false` the six search-engine
  names in the user agent are enough, as before. Link-preview fetchers
  (`facebookexternalhit`, `Twitterbot`, `LinkedInBot`) and `Slurp` are not
  exempt in either mode: anyone can claim them and there is nothing to check.
- **Bounded blast radius.** One rule per address, always with an expiry (60 minutes
  by default), so a false positive heals itself; an admin can remove one at any
  time. At most 300 automatic rules per site, so spreading a scan over many
  addresses cannot grow the list or the matcher's cache without bound. At the
  cap a new trip is skipped and logged.
- **Least privilege.** The guard acts as the `:scanner_guard` system actor, which
  can `create` an `IpBlockRule` and read one kind of security event (a recent
  `sign_in` from an address) and nothing else. It cannot list or remove rules.
  See the [policy matrix](policy-matrix.md).
- **Fails open.** A dropped count, a database fault or a failed sign-in lookup
  never blocks the 404 from rendering. The counting runs off the request path.
  A failed sign-in lookup at the moment of a trip leans toward not blocking.
- **A skipped trip is not retried.** A trip is claimed once per block window, so a
  trip skipped for the cap, a recent sign-in or a database error is not retried
  until the window rolls over. The window itself is fixed, not sliding, so a burst
  split across a boundary may not trip.
- **No address or path in logs or metrics.** The counter
  `kiln_cms.scanner_guard.blocked.count` is tagged by reason only. The
  `ip_auto_blocked` security event carries the address (as the event IP, subject
  to the log's retention and erasure) and never the attacker-controlled path.

### Bot budgets

Each `:delivery` request is put in a class by its `User-Agent` (#2243,
`KilnCMS.BotClass`): browser, search engine, AI crawler, other bot, or no user
agent. Each class is refused at its own percentage of the `:delivery` limit;
see [bot-budgets.md](bot-budgets.md).

- **What it stops.** Volume from clients that say what they are: a runaway
  `curl` loop, a crawler with no user agent, an over-eager SEO tool. Defaults
  are 50% of the browser limit for other bots and 20% for no user agent.
- **What it does not.** Anything that lies about being a browser, an AI
  crawler or a script. The user agent is spoofable, so those classes grant
  nothing: AI crawlers default to 100%, the same as a browser, and raising that
  class by environment raises it for every spoofer too. Search engines default
  to 200% (#2587), but their claims are checked (next point), and the part
  above 100% goes only to verified addresses; with verification off the
  default is 100%.
- **Search-engine claims are checked by DNS (#2254).**
  `KilnCMS.CrawlerVerification` looks up the address's PTR name, requires it
  under the engine's published domain (label-aligned, so `evilgooglebot.com`
  fails), and requires the name's forward lookup to contain the address. Only a
  claim **proven** false (no PTR, wrong domain, forward mismatch) is charged as
  no user agent. Everything not proven either way (lookup pending, skipped, DNS
  error or timeout, DuckDuckBot, a non-public address, untrusted forwarding)
  keeps the search-engine class but held to the `:delivery` limit, so a
  search-engine value above 100% (the default 200% included) is spent only on
  verified addresses: a spoofer typing "Googlebot" never gets more than a
  browser. A DNS outage or a
  busy verifier therefore never refuses a real crawler; the cost is that a
  spoofer whose claim cannot be settled gets what a browser gets. The lookup
  runs off the request path, so a request never waits on DNS.
- **Lookups as an amplification surface.** An anonymous client can make the
  node send DNS queries by naming a search engine from a new address. Bounded:
  at most 3 queries per address (1 PTR, forward only for up to 2 of the first
  3 names, only the client's family), a 3-second deadline per lookup,
  single-flight per address, results cached per address (6 h verified, 1 h
  proven false, 5 min DNS error), at most 16 concurrent lookups per node with
  no queue, and new lookups rate limited per network (IPv4 `/24` 30 and `/16`
  120 a minute; IPv6 `/64` 30, `/48` 60, `/32` 120) and per node (600 a
  minute). The cache is bounded (50,000 addresses, evicted oldest-written
  first) and is its own Cachex instance, so a flood of new addresses cannot
  evict anything else. No address, hostname, user agent or org is in any
  verification event or log line.
- **Residual: lookup starvation.** An attacker who controls a slow or silent
  reverse zone can hold lookup slots until the deadline, and an attacker with
  many addresses can spend the per-network and per-node lookup budgets or churn
  the cache. Either way new real-crawler addresses stay unverified for longer.
  That only costs anything when the operator has set the search-engine value
  above 100%, because an unverified claim is held to the browser limit, not
  refused.
- **Residual: no IP-range verification.** DuckDuckBot publishes IP ranges only,
  so its claims are never verified (and never proven false); the other
  engines' published ranges are not read either.
- **Outbound DNS to the system resolver.** Each node sends PTR, A and AAAA
  queries for visitors' addresses to the nameservers in its `/etc/resolv.conf`
  (`:inet_res`, not `SafeFetch`: no HTTP, and the names queried are the
  `in-addr.arpa` / `ip6.arpa` name of the client's address, then PTR names
  that matched an engine's domain). The resolver, and the authoritative server
  of the address's reverse zone, learn that this server was visited from that
  address; see [data-flows.md](data-flows.md#optional-subprocessors).
  `KILN_CRAWLER_VERIFICATION=false` turns all of it off.
- **Switching user agents gains nothing.** Every class charges the one
  per-address counter, so an address never gets past the highest single class
  ceiling. The cost of sharing is that a browser-heavy shared address (an office
  NAT) uses up a script's smaller ceiling.
- **A site cannot widen it.** A site admin may lower a class but not raise it
  above the operator's value: refused on write, clamped on read
  ([ADR 0018](decisions/0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)).
  An unreadable site row is answered with the operator's values, never looser.
- **Never classified.** `:probe` routes (`robots.txt`, `llms.txt`, sitemaps,
  feeds, `/up`, `/ready`) and `/live`, so crawlers can always read the files
  that tell them what to do and probes are never throttled by class.
- **No user agent, address or org in the metric.** The counter
  `kiln_cms.delivery.client_class.count` carries only `class` and `result`;
  `class` is the class charged, so a proven spoof is counted as `empty`.

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
- **Scripted submissions** — a site admin can make a form ask for a
  human-verification check (#2249). A submission without a pass is held in
  Spam rather than refused, so a script gets nothing acted on; see
  [Human verification](#human-verification-2249).

### Preview
- **Token as credential** — `/preview/:token` verifies a signed token and then
  loads the record with `authorize?: false`, so token possession is full read
  access to that record in whatever state it is in. Tokens are the sharing
  mechanism for unpublished work; treat a leaked preview URL as a content leak.
  See residual risk 6.
- **Headless draft mode (#1887)** — the same token on `/api/json` and the
  fired-artifact read. It does *not* bypass authorization there:
  `KilnCMSWeb.Plugs.PreviewGrant` verifies it, pins it to the serving site and
  puts a grant in the Ash context, and `Checks.PreviewGrant` adds
  `id == grant.id` to the content read policy for the **primary read** only.
  The published-only actions, search and every write are unchanged, and an
  edge to another draft stays hidden (`LinkEndsReadable`). A presented token
  that does not verify is a 404, never a fall back to the anonymous read.
  A write never reads the token. Responses are `private, no-store`; every
  response of an honouring route `Vary`s on the header; the query-string form
  is filtered from the request log, and Sentry events drop the header and mask
  the parameter (`KilnCMSWeb.SentryScrubber`).

### Media (`/uploads/*`)
- **Unauthenticated access** — local blobs are served by `Plug.Static` with no
  auth, no rate limit and no tenant check. Storage keys are unguessable UUIDs,
  which is the only thing standing between an unpublished asset and the world.
  `Content-Disposition: attachment` + `nosniff` prevent the bucket being used to
  serve active content. S3/MinIO deployments serve media entirely outside the
  app. Accepted by design (security audit 2026-09-27, finding 15, #1666): a
  public media URL is a capability URL. Gated documents and A/V live in
  private storage, which has no static mount and is served only through the
  policy-checked download and stream routes. Operator guidance is in
  [media-pipeline.md](media-pipeline.md#public-media-urls-are-capability-urls)
  and [deploy.md](deploy.md#public-media-is-readable-by-anyone-with-its-url).

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
  body-only `x-kilncms-signature`, which proved origin and integrity but not
  freshness, is no longer sent (0.12.0, #1616). See residual risk 15 and
  [webhooks.md](webhooks.md#verifying-the-signature).
- **Secret disclosure** — each endpoint's signing secret is vault-encrypted at
  rest, so a database dump, backup or replica does not hand out the ability to
  sign deliveries. The trade-off is the vault's: rotating `SECRET_KEY_BASE`
  orphans the secrets, and each endpoint must be re-created
  ([secrets-rotation.md](secrets-rotation.md)).
  In the console (`/editor/webhooks`, admin-only) each secret is masked to its
  last four characters, and the plaintext reaches the browser only when an
  admin clicks **Reveal** or has just added the endpoint (#2140), so a screen
  share or a saved page of the list doesn't carry it.

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

### Breached passwords

`KilnCMS.Accounts.BreachedPassword`, #2240. The one place a derivative of a
password leaves the server.

- **What leaves.** The first five hex characters of the password's SHA-1, as the
  path of `GET /range/<prefix>`, with `Add-Padding: true` so the response length
  does not reveal how many real hits the prefix has (padding lines carry count
  `0` and are never read as hits). The suffix, the password and the account
  stay on the node. The provider learns that *someone* on this IP set a
  password whose hash starts with that prefix, and nothing more.
- **Where it applies.** Self-registration, change password, password reset by
  token, the first-run wizard and accepting a site invitation with a password
  (#2135; judged by the *invited* site's policy for the *invited* tier, not the
  host the link was opened on). **Not** sign-in: a breached password that was
  set before this shipped is not noticed. Follow-up.
- **Exempt paths, deliberately.** The admin-sent reset *mail* is checked when
  its token is used (it is `reset_password_with_token`), but these set or
  create a credential without a lookup: `AdminPasswordReset` (the admin
  triggers a mail, not a password), magic links, SSO and passkey registration
  (no password is set), `AnonymizeUser` (account erasure), seeds,
  `Beta.Round` and `Staging.Scrub` (operator-run scripts).
- **Fails open.** A timeout, a non-200, a transport or malformed answer, an
  unreadable policy row, or an exception resolving the tier accepts the
  password, logs one warning without detail, and emits the telemetry event
  with `result: :error`. This is the right trade for an advisory control: the
  alternative is an attacker, or an outage at a third party, deciding whether
  anyone can change a password. An attacker who can block egress from the
  server (or poison its DNS, which `SafeUrl` pins against) can therefore turn
  the check off; they already hold the network position to do worse.
- **Residual risks.** (1) Fail-open, above. (2) The policy is the *request's*
  org and the tier is the account's tier the stricter of global role and that
  org's membership: an admin of org A with `block`, changing their password on
  org B's host, is judged by B's policy and B's tier for them. (3) No check at
  sign-in. (4) The warning after register or reset is a best-effort note held
  in a node-local cache for ten minutes; on a multi-node deployment without
  sticky routing, or after a restart, the person may never see it. The password
  was accepted either way. (5) `warn` is advisory; only an administrator's
  password can be refused. (6) The check is only as complete as the public
  corpus.
- **Telemetry.** `[:kiln_cms, :password, :breach_check]`; see
  [observability.md](observability.md#breached-password-checks).

### Human verification (#2249)

`KilnCMS.Challenge`, `KilnCMS.Challenge.Gate`, `KilnCMS.Challenge.Registry`,
`KilnCMS.Challenge.Siteverify`, `KilnCMS.Challenge.Providers.Turnstile`,
`KilnCMS.Challenge.Providers.Recaptcha`, `KilnCMSWeb.Plugs.ChallengeCsp`; the
contract `Kiln.Challenge.Provider` in `kiln_plugin`. An adaptive check on
password sign-in and registration, configured by the operator for the whole
deployment with one provider: Cloudflare Turnstile (recommended), Google
reCAPTCHA v2, or a plugin's. Off until a provider, a site key and a secret
are set. A site admin can also make each public form ask (below). Guide:
[human-verification.md](human-verification.md); decisions:
[ADR 0020](decisions/0020-human-verification-is-deployment-wide-and-fails-open-only-within-the-sign-in-budget.md),
[ADR 0021](decisions/0021-a-form-opts-in-to-human-verification-and-an-unverified-submission-is-held-not-refused.md)
for forms,
[ADR 0022](decisions/0022-a-challenge-provider-is-a-plugin-contract-and-the-core-enforces-its-claims.md)
for providers.

- **What it slows.** Password guessing that stays under the per-account budget
  by spreading across accounts, and scripted self-registration. Sign-in asks
  once the submitted address has had `account_threshold` (3) attempts in the
  account window, or the client address `ip_threshold` (5) unrefunded attempts
  in `ip_window` (15 minutes); a correct password refunds the address's unit,
  so in effect only failures count there. Registration asks after
  `registration_threshold` (2) attempts per address per hour, or always.
- **Where it is enforced.** On the actions (`ThrottleSignIn` on
  `:sign_in_with_password`, `RequireRegistrationChallenge` on
  `:register_with_password`), so the LiveView, the no-JavaScript POST and
  `POST /api/auth/sign_in` pass one check. The API is checked only with
  `CHALLENGE_API_SIGN_IN` on. Passkeys, magic links, reset, the second factor,
  single sign-on and invitations are never challenged: each needs a proof the
  guesser lacks, and they are the way in for someone who cannot solve a check.
- **Deployment-wide.** No site setting can turn sign-in challenges off, because
  the account is shared across sites; the decision never reads the dialled
  host. Tested: a site's own host cannot weaken the mode.
- **A refusal costs the owner nothing.** The gate runs before
  `AccountThrottle.consume/1`; an attempt refused for want of a check spends no
  budget and runs no bcrypt, so the challenge cannot be used to lock an owner
  out.
- **No enumeration.** The account axis keys on the submitted string, the
  address axis on the caller's own IP; a known and an unknown address are
  refused alike (see the table below). The refusal is never "incorrect
  password".
- **Races.** Free attempts are spent with one atomic increment-and-compare per
  axis, so a burst at the start of a window cannot all skip the check; at most
  the threshold's worth do.
- **Token binding, enforced by the core.** A provider's pass reports the
  hostname and the action the token was solved for (`{:ok, claims}`), and
  `KilnCMS.Challenge.verify/4`, not the provider, applies them: a hostname
  that is missing or is not one this deployment serves (or one in
  `CHALLENGE_HOSTNAMES`) is `:hostname_mismatch`, and an action that is
  present and differs from the one the widget was drawn for (`sign_in`,
  `register`, `form`) is `:action_mismatch`. Turnstile always reports the
  action, and its provider refuses an answer without one. The request's
  `Host` and a LiveView join URL never vouch for a hostname (tested with a
  forged `Host`). Tokens are single-use at the provider and never cached by
  Kiln.
- **A provider's answer is read conservatively.** `:missing` and `:malformed`
  come only from the core's own precheck (absent; not a short printable
  string). A provider that returns either, or any refusal the contract does
  not name, is read as `:invalid`, because a missing token can be admitted
  during an outage and a refused one never can. An unknown unavailable
  reason, any answer outside `{:ok, _}` / `{:error, _}`, a crash, and the
  3-second deadline are `{:unavailable, :crashed}` or `:timeout`. Tested with
  a plugin provider answering `:missing` during an outage: refused, not
  admitted; on a form, refused, not held.
- **reCAPTCHA v2.** Its tokens carry no action, so the action rule cannot
  bind them: a token solved on one of this deployment's pages (a form, say)
  can be spent once on another of its checks (sign-in) within its two-minute
  life. The hostname is still enforced, so the token was solved on a page
  this deployment serves. An answer that carries a `score` (a v3 or
  Enterprise key) is refused as `:invalid`, never admitted on a guessed
  threshold. Google answers a wrong secret with `invalid-input-response`, the
  bad-token code, so a misconfigured reCAPTCHA secret refuses everyone
  rather than failing open, and does not log "could not use its secret
  key".
- **Fail rules.** A provider refusal never admits. "Unavailable" (timeout past
  the 3-second deadline, transport error, `5xx`, `429`, malformed answer,
  unreadable or rejected secret, crash) admits a sign-in until the account's
  own budget refuses or the client address reaches `ip_closed_after` (20)
  failed sign-ins in the window, and then refuses (`503` on the API). A
  registration is admitted within the `:register` rate limit. A missing token
  is a refusal, except within `outage_window` (60 s) of this node seeing an
  unavailable answer, when it gets the unavailable treatment.
- **Outbound call.** Through `KilnCMS.SafeFetch` (`KilnCMS.Challenge.Transport`),
  which a provider receives as the `:post` function: to
  `challenges.cloudflare.com` for Turnstile and
  `www.recaptcha.net/recaptcha/api/siteverify` for reCAPTCHA (never
  `www.google.com`, so an egress allowlist needs one host per provider). No
  redirects, no retries, a 16 KB cap, 1 s connect and 2 s receive timeouts,
  the whole call bounded at 3 s in an unlinked task. The secret is read from
  `KilnCMS.Keys` only at verification and never logged; the client address
  is sent only with `send_remote_ip`.
- **Content-Security-Policy.** `script-src`, `frame-src` and `connect-src`
  on the `:browser_auth` pipeline gain the provider's declared sources only
  while a challenge can be shown; the header is byte-identical otherwise,
  and also when the named provider is unknown or fails conformance (tested).
  Turnstile adds `https://challenges.cloudflare.com` to `script-src` and
  `frame-src`. reCAPTCHA adds `https://www.recaptcha.net/recaptcha/` and
  `https://www.gstatic.com/recaptcha/` to `script-src` and
  `https://www.recaptcha.net/recaptcha/` to `frame-src`, path-scoped. It is
  loaded from `www.recaptcha.net` because `www.google.com` serves JSONP
  endpoints that are a known way round a strict policy; no policy ever names
  `www.google.com` (tested). Checked in headless Chromium against the
  development server: `/sign-in`, `/register`, a form's page and its embed
  raised no violation with those sources. No inline script: the `Challenge`
  hook loads the provider's script.
- **Plugin providers.** A provider is compile-time plugin code
  (`c:Kiln.Plugin.challenge_providers/0`), as trusted as any plugin: it runs
  in the VM and sees the secret and each token in `verify/2`. What the core
  limits is what reaches the page and the decision. The provider is resolved
  once per node and id and checked with
  `Kiln.Challenge.Provider.conformance/1`: `script_url` must be `https://`,
  without credentials, fragment, whitespace or quotes, and covered by one of
  its own `script_src` entries; every CSP source must be
  `https://host[:port][/path]`, with no wildcard, keyword, quote, `;` or `,`,
  so a provider cannot inject a directive or `'unsafe-inline'`; render
  options must be JSON and may not set `sitekey` or the callbacks. A
  provider that fails, raises, or that no plugin registered, leaves the
  feature off with a boot warning, never on with a guessed policy. Request
  paths read only the memoised descriptor, so `widget/0` or `csp_sources/0`
  cannot slow or crash a page; only `verify/2` runs per attempt, under the
  deadline. A built-in id (`turnstile`, `recaptcha`) always resolves to the
  built-in, and `mix kiln.plugins.doctor` flags a plugin that claims one.
  Residual: once the operator names a plugin's provider, its sources are
  added to the `:browser_auth` policy, which includes the console host's
  sign-in, and its script runs there; a conformant source can still be an
  origin the operator would not otherwise trust. Choosing it is the
  operator's act, as choosing to install the plugin was.
- **Secrets in transit and logs.** `challenge_token`,
  `cf-turnstile-response`, `g-recaptcha-response` and the forms'
  `_kiln_challenge` are in `:filter_parameters` and the Sentry scrubber; the
  argument is `sensitive?` on both sign-in actions. A plugin provider's own
  `response_field` is added to the Sentry scrubber from the registry, but not
  to `:filter_parameters`, which Phoenix compiles before the plugins are
  read: a boot warning (`challenge_response_fields`) asks the operator to add
  it.
- **Residual risks.**
  1. **Outage as a bypass, bounded.** An attacker who can make verification
     fail (a network position between Kiln and Cloudflare, or a provider
     incident) gets attempts without a check, up to the account budget per
     address and `ip_closed_after` per client address. Rotating addresses
     defeats the second bound; the first still holds. The
     `kiln_cms.challenge.decision.count` `fail_open` share shows it.
  2. **A wrong secret fails open silently (Turnstile).** Only a missing
     secret *source* is logged at boot. A secret Turnstile rejects makes every
     verification "unavailable" (`result: :not_configured` in the verify
     metric), which also arms the outage memory, so missing tokens are
     admitted within the bounds above. A wrong reCAPTCHA secret fails closed
     instead (see reCAPTCHA v2 above).
  3. **Shared addresses.** Everyone behind one NAT shares the address axis:
     more than `ip_threshold` failures there challenge everyone for the window,
     and during an outage `ip_closed_after` failures refuse password sign-in
     for the whole address. Passkeys and magic links still work.
  4. **The outage memory is node-local.** Each node decides for itself whether
     a missing token means "down"; on a cluster, a node that has not yet seen
     the outage refuses missing tokens.
  5. **The API failure count is shared.** Failed `POST /api/auth/sign_in`
     attempts count toward the address's failure count even with
     `CHALLENGE_API_SIGN_IN` off, so API traffic from an address can bring the
     browser's outage closed point nearer. They do not trigger the browser
     check itself.
  6. **Solvers.** A paid CAPTCHA-solving service passes the check; it raises
     the cost of a run, it does not stop one. The per-account budget remains
     the limit.
  7. **Thin, wide stuffing.** A run spread across many accounts and addresses,
     each under its threshold, is never asked. A deployment-wide failure-rate
     trigger is a follow-up.
  8. **Third-party script.** When the widget is shown, the provider's script
     runs in the sign-in page's origin, which is the console's own origin
     when someone signs in on the console host. The policy admits only the
     provider's declared sources (one origin for Turnstile, two path-scoped
     ones for reCAPTCHA), and only on the auth pages and on responses that
     draw a form's widget (below).
  9. **reCAPTCHA cross-check reuse.** As above: a v2 token is not bound to
     sign-in, registration or a form, so one solved for any of them passes
     once on another within two minutes. Turnstile tokens are bound.
  10. **No `remove` in reCAPTCHA.** reCAPTCHA has no `remove`: a widget LiveView
     replaces stays in the script's own bookkeeping until the page unloads.
     Harmless (its element is gone).

#### Human verification on public forms

`KilnCMS.Challenge.Gate.form/3`, `KilnCMS.CMS.Validations.ChallengeAvailable`,
`KilnCMS.CMS.Changes.ScoreFormSubmission`, `KilnCMSWeb.FormController`.

- **Who sets it.** `Form.challenge` (`:off` by default, or `:always`) is a
  site admin's, per form: a form with it off exposes only that site's inbox
  (the ADR 0018 test). The operator's ceiling is `CHALLENGE_FORMS`, the kill
  switch and a usable provider. It is refused on write while forms cannot ask
  (only when the write changes `challenge`, so a form already on still saves
  and can be switched off) and clamped on every read
  (`KilnCMS.Challenge.form_required?/2`). Form writes stay admin-only; the
  system actor cannot write it. Tested per role and across sites.
- **Held, not refused.** No token, a token solved on a host this deployment
  does not serve, and a token the provider could not check (timeout,
  transport, `5xx`, `429`, crash, unreadable secret) are all *held*: stored
  as `:spam` with the threshold added to the score, so no notification,
  autoresponder, `form.submitted` webhook or experiment conversion. Holding is
  in the scorer, not a registry check, so a plugin cannot unregister it. Only
  a refusal the provider gave (invalid, expired, malformed, wrong action) is
  refused, with a `422`.
- **No outage bypass.** Unlike sign-in there is no fail-open: a missing token
  is held even during an outage, and so is a token the provider could not
  check. An attacker who provokes "unavailable" (a burst that draws `429`s)
  gets their submissions stored as spam, not acted on.
- **Order.** Inactive form, honeypot, field validation, then the check. A
  tripped honeypot is discarded without calling the provider and answers
  `200` with `"verified"` when any token was sent and `"held"` when none
  was. That matches a real submission except for a token the provider would
  refuse: with the honeypot empty, a junk token is a `422`, so a bot that
  sends junk can tell the two apart. A field error does not spend the token.
- **Token binding.** The same `KilnCMS.Challenge.hostname_allowed?/1` rule as
  sign-in, on both `POST /forms/:slug` and `POST /api/forms/:slug`: a host
  this deployment serves or one in `CHALLENGE_HOSTNAMES`, never the request's
  `Host`. The embed's `embed_origins` are not accepted hosts: the widget runs
  inside the iframe, on the site's own host. A provider that reports the
  action (Turnstile) must report `form`, so a sign-in token cannot be
  replayed on a form, nor the reverse; reCAPTCHA v2 reports none (residual
  risk 9 above). A mismatch is
  held, not refused, and logged at most once a minute per node with the host
  the provider reported (a config cause, almost always a headless site).
- **Content-Security-Policy.** Widened with the provider's origins only on a
  response that draws a form's widget: a delivered page whose blocks (or an
  experiment variant's) render a form that asks, `/forms/:slug`, and a
  non-embedded refused re-render. The embed policy adds the provider to
  `script-src` and an explicit `frame-src 'self' <origin>` only for such a
  form. Every other response's policy is byte-identical; tested. The embed's
  mount is a separate same-origin module script
  (`/assets/js/challenge_static.js`), never inline.
- **Not covered.** Fired artifacts (the `data-kiln-form` placeholder is
  settings-independent), previews (render no form), newsletter sign-up and
  any form left `:off`.
- **Residual risks.**
  1. **Held data is still stored.** A script can fill Spam up to the per-IP
     `:form` bucket (20 a minute); spam is pruned after
     `spam_retention_days`.
  2. **Stale pages.** A page loaded or cached (60 s plus 300 s
     stale-while-revalidate) before the check was switched on posts without a
     token and is held. No grace window is offered: held submissions keep
     their data, and a grace keyed on when the page was rendered would admit
     token-less posts for as long as an old render stamp stays valid.
  3. **Outage memory is sign-in's alone.** A form verification the provider
     could not answer never arms the node-local outage memory
     (`KilnCMS.Challenge.verify/4` skips it for `:form`), so a burst of junk
     form tokens that draws `429`s cannot switch on sign-in's bounded
     fail-open. Tested.
  4. **Solvers.** As for sign-in, a paid solving service passes the check.

### Idle timeout and sign out everyone (#2246)

`KilnCMS.Accounts.IdleTimeout`, `KilnCMS.Accounts.SignOutAll`. A site admin
can sign browsers out after a stretch of inactivity, and end every browser
session on the site at once. Admin guide:
[account administration](account-administration.md#sign-people-out-when-idle).

Configured at `/editor/sessions`.

- **Sessions are bound to a site.** A session's token row, and its remember-me
  row, record the site (`tokens.org_id`) they signed in on, or the first site
  that uses them if they predate #2246. The cookies are host-only, so a row
  bound to site A arriving on a host of site B was copied there: it is served
  signed out on B and nothing is written to it, so it can neither be used on B
  nor kept awake from B. A remember-me cookie's signature is verified before
  its row is looked at, and every write is also filtered on the account
  (`subject`), so a forged or foreign jti changes no one's row.
- **Last activity is the database's clock.** `last_used_at` is written by and
  compared with Postgres `now()`, never a node's clock, and the expiring
  UPDATE repeats the idle test in its `WHERE`, so a tab that kept the session
  awake a moment earlier wins the race. Idle time is measured from no earlier
  than the policy's last save (`policy_changed_at`), so enabling or shortening
  the timeout signs no one out for past inactivity. That stamp is the saving
  node's clock: skew between nodes shifts the grace by the skew.
- **Public pages stay cache-safe.** On `:browser` an expired session is served
  signed out without writing the session or a cookie (#699); the session and
  remember-me cookies are dropped only on `:browser_auth`. On
  `:media_transform` the check only reads.
- **Sign out everyone.** One transaction revokes every session, remember-me and
  two-factor hold row bound to the site, writes a watermark
  (`SiteSessionPolicy.sessions_revoked_at`) and records `all_sessions_revoked`.
  A row bound to no site that predates the watermark is revoked the next time
  it is used on this site's host, for 30 days (the remember-me lifetime). The
  token writes that bind a row to a site read the watermark in the same
  statement, so such a row cannot escape by being used first. Other sites are
  never reached.
- **Fails open.** An unreadable `SiteSessionPolicy` row is logged and treated as
  "no timeout, no watermark" for that request, uncached; an unreadable token
  row leaves the request as it was, and an open page looks again in a minute.
  The site decides the timeout; there is no operator ceiling
  ([ADR 0018](decisions/0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)
  constrains a site only against one).
- **Cost.** Every signed-in browser request and LiveView mount reads the
  session's token row by primary key, whether or not the site has a timeout,
  because the cross-site rule needs it.
- **Residual risks.** (1) Not covered: API keys and headless bearer tokens,
  including a token minted with a phished password. A breach response needs a
  password reset or *Sign out everywhere* as well. (2) `/ws/collab` (a 24-hour
  per-account token, behind a flag that is off by default) and `/ws/gql`
  sockets are keyed per account and survive both idle expiry and sign out
  everyone until their next reconnect or re-check. (3) Events a LiveComponent
  handles itself (`phx-target={@myself}`) do not count as activity on their
  own. (4) A node holding a cached policy from before a sign out everyone may,
  for up to the cache's minute and until the cluster-wide bust lands, let an
  unbound pre-watermark session through on a request; binding still refuses
  it, and the next check catches it. (5) Activity is written at most once per
  tenth of the timeout (30 seconds to 5 minutes), so a session can end after
  as little as 90% of the timeout since its real last use. (6) Fail-open,
  above.

### Site invitations (`/auth/invite/:invite_token`, #2135)

A platform admin invites an address to a site from `/editor/team`; the invitee
opens the mailed link and sets up an account, or adds the site to the account
they have. The link is the only credential, so this is a bearer token that
creates an account and grants a site tier.

- **The token.** 32 random bytes, URL-safe base64, mailed once. Only its SHA-256
  is stored (`invitations.token_hash`), so a database read or a backup cannot
  rebuild a link. Single use: accepting destroys the row in the same
  transaction as the account and membership, and both accepts re-read the row
  by token under `FOR UPDATE`, so two submits of one link serialize and the
  second finds nothing. A resend rotates the token and revoking destroys the
  row; either way the old link names nothing. Usable for 7 days.
- **Opening is not accepting.** The page only peeks at the token on `GET` and on
  the socket mount; nothing is written until a button is pressed. A mail
  scanner or link previewer that follows the link changes nothing.
- **Every write is system-only.** `User` `:register_with_invitation` and
  `:accept_invitation_with_password`, and `Invitation` `:by_token`, `:consume`
  and `:accept_existing`, are `forbid_if always()` and refuse any actor-carrying
  call in their own change or preparation, because the platform-admin bypass
  would otherwise pass them ([policy-matrix.md](policy-matrix.md)). The email
  of a new account is taken from the invitation row, never from input.
- **Pre-registered accounts (pre-hijack).** Anyone can register an unconfirmed
  account for any address. So an unconfirmed account is never added to a site
  directly: the Team page invites it instead, and accepting sets a new
  password, confirms the account, revokes every token it held, signs out its
  sessions and clears a display name the first registrant chose. It also
  forgets every other credential the first registrant could have set up
  (#2453, `Changes.ForgetPriorCredentials`): two-step verification (the live
  secret, recovery codes and any pending re-enrollment), passkeys,
  identity-provider links and push devices are removed, and every live API
  key is revoked. Whoever registered first can sign in with their own
  password while the account is unconfirmed, and an admin can raise an
  unconfirmed account's role (`:manage_access`, `:grant_temporary_role`) to one
  that reaches `/editor/settings`, or mint it an API key. So "a self-registered
  viewer cannot enroll a factor" is no defense. The removals run inside the accept's transaction, as
  `SystemActor.new(:invitations)` (each action admits that actor and no
  person; the passkey and push-device removals sit above the platform-admin
  bypass), with reads that fail closed, so any error rolls the whole accept
  back rather than handing over an account a stranger can still get into. The
  TOTP columns are cleared from the row re-read `FOR NO KEY UPDATE` in the
  transaction, not from the caller's possibly stale struct. Each removal is
  logged with no person: `second_factor_removed` and `passkey_removed` with
  `via` `invitation`, and `api_key_revoked`. A credential write the
  stranger's session already had in flight cannot slip past the takeover. The
  takeover holds the account's row (`FOR NO KEY UPDATE`) while it forgets the
  account's credentials. A passkey registration, push subscription,
  two-step confirmation, recovery-code regeneration or password change
  (`Passkey` `:register`, `PushSubscription` `:subscribe`, `User`
  `:confirm_totp`, `:regenerate_totp_recovery_codes`, `:change_password`)
  that the stranger's session had in flight takes the account's row first
  (`Changes.GuardAccountTakeover`, through `AccountLock.credentials/2`:
  `FOR SHARE` for the two inserts, `FOR NO KEY UPDATE` for the three user
  updates). If it gets there before the takeover, it commits first, and the
  takeover removes or overwrites what it wrote. If it gets there after, it
  waits, finds the password changed (or the staged secret cleared), and is
  refused with `Errors.AccountTakenOver`. The stranger's sessions are evicted
  once the takeover commits. `:setup_totp` and `:disable_totp` are left
  unguarded on purpose: a secret staged from a stale session is enforced by
  nothing until `:confirm_totp` promotes it, which the guard refuses, and the
  invitee's own enrollment stages a fresh one over it; a stale disable can
  only clear columns the takeover already cleared. Only a confirmed account accepts
  with one click, and it keeps its password and every credential. An erased
  account cannot accept.
- **Who can send, and for how long it counts.** Only a standing platform admin
  can invite or resend (`StandingAdminOnly`): a temporary admin's invitation
  would outlast the grant. An `:admin` invitation is honoured at accept time
  only while its sender is still a standing platform admin, not erased and not
  deleted. A `:viewer` or `:editor` invitation is honored whatever has
  happened to its sender since, and that now includes raising a lower
  membership (below), as it already included creating one.
- **An invitation raises, never lowers, and a later decision retires it
  (#2452).** Accepting over an active membership below the invited tier raises
  it (`OrgMembership.:raise_role_by_invitation`, admitted only for the
  `:invitations` system actor and a platform admin). The comparison is made on
  the membership row locked `FOR UPDATE`, against its standing tier, so a site
  admin's edit between the page load and the click is what is judged; an equal
  or higher tier is refused before any write and the invitation is simply
  used up. The other grant axes are kept, and the invitee's sessions are
  evicted after the commit. Because accepting can now raise, a pending
  invitation would otherwise outlive a demotion: `OrgMembership` `:update`
  (when it changes `role` or `role_id`) and `:destroy` delete the pending
  invitation for the member's address on the membership's own site
  (`Changes.RetirePendingInvitation`, through the system-only
  `Invitation.:retire`), locking it before the membership row, the same order
  as the accept, so an edit and an accept racing on one person serialize. The
  retirement is logged as `invitation_revoked`, with the admin who made the
  membership change as the actor, so an invitation never vanishes untraced.
- **Mail as a weapon.** The admin names any address. Invitation mail is budgeted
  per address (`mail:invitation`, the shared mail budget, 5 per hour by
  default), and a spent budget or a suppressed address is refused by name, so
  the admin is not told "sent" for mail that will not arrive. The "you were
  added" notice to a confirmed account has its own budget
  (`mail:membership_notice`) and is dropped silently when spent. The mail
  carries no free text from the inviter (that would be a phishing channel from
  this instance's address), and the site and inviter names are HTML-escaped.
- **Submit flooding.** Both password accepts and the one-click accept charge the
  per-client registration budget (`ThrottleRegistration`, the `:register`
  bucket), because they arrive over `/live`, past every router plug.
- **The right host.** The link is built on the invited site's host for the
  invited tier (`ConsoleHost.tier_url/3`: the public site host for a viewer,
  the console host for an editor or admin when `KILN_CONSOLE_HOST` is set). The
  page redirects to it if opened elsewhere, so the account and the first
  sign-in happen on the site it was made for.
- **Invite-only sites.** Accepting deliberately skips the `:registration_enabled`
  check: on an invite-only site this is how accounts arrive. The admin's
  choice to invite is the control.
- **Residuals.** (1) *The token is in the request path*, and Phoenix logs the
  path: `invite_token` is in `:filter_parameters`, which filters the logged
  params map only. The same holds for `/magic_link/…` and `/password-reset/…`.
  Whoever can read request logs within the 7 days can accept the invitation.
  (2) *The plaintext link sits in the mail job's args* in `oban_jobs`, and so
  in any backup taken meanwhile, until Oban's Pruner deletes the finished job 7
  days later, as for reset and magic-link mail. (3) *Whoever holds the mail
  holds the invitation.* A forwarded or intercepted link is accepted by
  whoever opens it first; the account it creates has the invited address,
  and an admin can remove the membership from Team. (4) *Accepting through single sign-on is not supported*, so an
  invitee whose organisation signs in by SSO must still accept with a password
  or an existing account first. (5) *Pending invitations from before #2452.*
  A tier change or removal made on a build that had invitations but not #2452
  did not retire the member's pending invitation, so for up to 7 days after
  upgrading such a link raises a demoted member back (and, as before, re-adds
  a removed one). Admins check **Pending invitations** on Team. (6) *The
  same takeover by another route keeps the stranger's credentials.*
  `:confirm_new_user` and `:reset_password_with_token` confirm an
  unconfirmed account without running the wipe above. A magic-link sign-in
  (`:sign_in_with_magic_link`, a read) neither confirms the account nor takes
  it over (#2516), so the stranger keeps a working password on an account the
  address's owner now shares and that stays unconfirmed. Both are the general
  pre-hijack residual, tracked in #2594. (7) *What the takeover does not touch:* memberships on
  other sites, billing, and newsletter subscriptions stay as the first
  registrant left them. (8) *Erasure leaves the TOTP columns.*
  `Changes.AnonymizeUser` removes passkeys and identities but not
  `totp_*`; a follow-up.

### Account unlock (#2250)

`AccountThrottle` pauses password sign-in for an address after 20 attempts in
15 minutes, and the pause answers exactly as a wrong password does. An emailed
link lets the owner lift it without waiting or resetting the password
(`KilnCMS.Accounts.SignInUnlock`; the reasoning is
[ADR 0023](decisions/0023-an-unlock-link-lifts-only-the-account-pause-and-the-pause-stays-undisclosed.md)).
The how-to is
[Lift a sign-in pause by email](account-administration.md#lift-a-sign-in-pause-by-email).

- **No stronger than a reset.** The link goes only to the account's mailbox,
  and whoever reads that mailbox can already reset the password, which lifts
  the pause too. The link does less: it clears the `signin` counter for the
  account's current address (`AccountThrottle.unlock/1`) and nothing else. Not
  `challenge:free_signin`, the `2fa` budget, the alert windows, `ip:auth` or
  the challenge gate's IP axes. It signs no one in, mints no session, confirms
  nothing and touches no other token.
- **The pause stays undisclosed.** The sign-in page shows the same link to
  everyone, the request page answers one sentence for every address, and
  `POST /api/auth/sign_in` still answers a paused account with the generic
  `401`. There is no JSON request or redeem endpoint.
- **The request does the same work for every address.** `request/2` hands
  the address to a task under its own `Task.Supervisor` (at most 20 children,
  apart from the shared `KilnCMS.TaskSupervisor`) and returns. The task mails
  only a confirmed, not erased, not demo-shared account that is paused right
  now and is a member of the requesting site, and only then charges the
  per-address budget (`mail:sign_in_unlock`, 3 an hour), so a name that is
  never mailed writes no counter row. The mail echoes nothing from the request
  (no IP, no attempt count), so it cannot carry a phisher's text.
- **The token.** An AshAuthentication JWT, purpose and `act`
  `sign_in_unlock`, 15 minutes, stored like every token. Single use through
  the token resource's atomic revoke (two concurrent redeems: exactly one
  wins), and revoked with every other token on a password change or reset. It
  is refused as a bearer credential and by the reset, confirmation,
  magic-link and token sign-in routes. Its claims, also stored in
  `tokens.extra_data`, bind it to the requesting site (`org`: refused
  elsewhere, and not spent there) and to the address it was mailed to (`ed`, an
  HMAC keyed from `secret_key_base`, so the stored value is not a lookup away
  from the address).
- **Opening is not redeeming.** The `GET` renders the same page for any token
  and spends nothing, so a scanner that follows the link does not use it.
  Only the CSRF-checked `POST` redeems.
- **Who calls it.** `User` `:request_sign_in_unlock` and
  `:redeem_sign_in_unlock` are `forbid_if always()`, and
  `SignInUnlockAction` refuses an actor-carrying call because the admin bypass
  would pass that ([policy-matrix.md](policy-matrix.md)). No signed-in person,
  an operator included, can mint or spend a link.
- **Audit.** `sign_in_unlock_requested` only once a mail is queued,
  `sign_in_unlocked`, and `sign_in_unlock_refused` (sampled per IP like a
  failed sign-in, with the account named only when the link's signature
  verified and the account belongs to the site). See
  [security-events.md](security-events.md).
- **Residuals.**
  (1) *A link holder gets 20 more attempts.* Whoever holds a link (the
  owner, or someone reading the owner's mail) can redeem it for a fresh
  sign-in budget: 20 more password attempts per link, at most 3 links an
  hour per address. Each attempt still pays the human-verification check
  where the operator turned it on (the free attempts are not given back), the
  per-IP limits and the second factor. Someone reading the mailbox could
  reset the password instead, so this is not a new capability, but it is a
  quieter one: the attacker keeps guessing without changing the password,
  which the owner would notice.
  (2) *Denial of the unlock mail.* An attacker who knows the address can
  keep the account paused by guessing, and can spend its 3 unlock mails an
  hour by asking for them; the owner then gets no link until the hour rolls
  (they receive the 3 the attacker caused). A password reset, which has its
  own mail budget, and waiting are still open, and an attacker still guessing
  re-pauses the account within seconds of any unlock anyway.
  (3) *The node-local fallback.* An unlock is a `forget` of the shared
  Postgres counter, so it reaches every node (`ThrottleStorePeerTest`). A node
  that counted attempts in its own ETS fallback while the database was
  unreachable keeps those counts through an unlock made elsewhere, until its
  window rolls. That is `ThrottleStore`'s documented bound, not a new one.
  (4) *The token is in the request path*, as for invitations, reset and
  magic links: `unlock_token` is in `:filter_parameters`, which filters the
  logged params map only. (5) *The plaintext link sits in the mail job's
  args* in `oban_jobs` until Oban's Pruner deletes the finished job 7 days
  later; it has expired long before. (6) *A newer link does not revoke an
  older one*; each is short-lived and single use, and the mail budget bounds
  how many exist. (7) *A scanner that submits forms* (not just follows
  links) can spend a link; the refusal page says so and offers a new one.
  (8) *A link revoked by a password change is logged as `used`*, not as
  revoked.

### Registration approval (#2251)

A site can make password sign-ups wait for an admin
(`KilnCMS.CMS.SiteRegistration`, `KilnCMS.Accounts.Registrations`; the
reasoning is
[ADR 0024](decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md)).
The how-to is
[Approving registrations](account-administration.md#approving-registrations).

- **One choke point.** Waiting is a `status` on the account's
  `OrgMembership`, and `KilnCMS.Accounts.Scoping` grants nothing through a row
  that is not `:active`: no tier, no audiences, a denied type scope, no field
  grants. Every surface already asks `Scoping`, so none needed its own check.
  The row still makes the account affiliated, so it is `:none` on every other
  site, the default one included.
- **Site admins see applicants' addresses, and only those.** Until now a site
  admin who is not a platform admin could not read another account (`User`
  reads are self-only). The queue shows each applicant's email address, name
  and whether it is confirmed. `Registrations.page/2` reads those columns as
  the system, for the user ids of rows that the `:registration_queue` read
  returned, and that read admits only an admin of the org the
  `organization_id` argument names (`Checks.AdminOfMembershipOrg`), never the
  request's host. So a site admin sees exactly the people who asked to join
  their site, and an admin of site B is refused site A's queue from any host.
  The `User` policies are unchanged.
- **Hijack by an unconfirmed address.** Anyone can register an address they
  don't own. Approving it would give the site's access to whoever typed it, and
  the real owner, signing up later, would find the address taken. So approving
  requires `confirmed_at`, checked on the locked row inside the action
  (`Changes.DecideRegistration`), not just hidden in the page. Rejecting does
  not require it.
- **Bot waves.** A flood of sign-ups costs an admin nothing to ignore: the
  queue lists confirmed, unconfirmed and rejected applicants separately, 50 a
  page on a keyset, with counts capped at 100, so an unconfirmed wave neither
  loads unbounded nor pushes approvable applicants off the first page.
  Registration's own per-address throttle and human verification apply first.
  A site that erases unconfirmed applicants it rejects (#2514, below) also
  removes the wave's accounts as it rejects them, rather than keeping a pile
  of accounts for addresses nobody proved they own.
  Residual: there is no bulk reject, and waiting rows never expire (a
  follow-up), so a wave stays in the unconfirmed list until rejected one by
  one.
- **Notifying admins can't be turned into a mail flood.** Admins are told
  only when an applicant confirms an address (a link mailed to it, a password
  reset, or accepting an invitation), not on sign-up, so an unconfirmed wave
  sends no notice at all. The `:registration_pending` notice collapses: one
  unread row per admin and site, and the email goes only when a new row is
  written (`Notifications.record_in_app_result/1`). A confirmed wave is one
  notice and one email per admin until that admin opens the queue.
- **No applicant data in the bell or the admin email.** The notice's title is
  the site's name, with no excerpt and no actor; the email names the site and
  links to the queue. An applicant's address and name stay in the queue,
  behind its admin-only read, and do not end up in an inbox or a mail
  provider's logs. Recipients are standing admins only
  (`Notifications.Registrations.recipient?/2`): a temporary platform admin,
  which may not decide, and an erased account are left out.
- **Decision emails can't be aimed at strangers.** Rejecting is allowed
  before confirmation, so the rejection is mailed only to a confirmed address
  (`Changes.MailRegistrationDecision`): registering someone else's address
  and getting it rejected does not make the site mail them. Approval already
  requires confirmation. An erased account is mailed nothing, and approving
  one is refused (`:erased`).
- **Decision emails carry nothing an admin typed.** Approval is one sentence
  and a sign-in link on the site's host; rejection is one neutral sentence
  with no reason, no link and no name of who decided. There is no free-text
  field, so the feature can't be used to send arbitrary content from the
  site's address. Both, and the admin email, are sent for the site
  (`org_id:`), so they leave through the site's own SMTP relay when it has one
  (#1322), and the site's suppression list applies.
- **Best effort, after commit.** Notices and mails run through
  `KilnCMS.AfterCommit` once the confirmation or decision has committed; a
  failure is logged and cannot roll it back or block it.
- **Billing.** The entitlement recompute gives a paying reader a viewer
  membership on a site where it has none, which would let anyone pay past the
  queue. On a site that requires approval, `Billing.Membership` `:start` is
  refused (`Validations.RegistrationApproved`) unless the account is already
  let in there (`Scoping.effective_tier/2` is not `:none`, which includes the
  legacy membership-less viewer on the default site), and the recompute
  creates no viewer row for an account that is not. A waiting or rejected row
  on the site is always refused. Residual: on a site that does **not** require
  approval, an account waiting on another site can still pay and becomes a
  viewer member of that site; that site chose open sign-up.
- **Fails closed.** The setting is read before the sign-up's transaction as
  a system actor admitted to `read` only, `authorize_with: :error`. An
  unreadable row refuses the sign-up and creates nothing, and an unreadable
  setting at checkout refuses the start; "no approval needed" is the
  direction that would let an unreviewed account in.
- **Decisions race safely.** Approve and reject lock the row
  (`get_and_lock_for_update`) and refuse one that is no longer waiting, so two
  admins or a stale tab cannot both decide. Sessions are evicted after commit,
  so the reconnect is authorized against the decided row. A temporary platform
  admin is refused by `StandingAdminOnly`.
- **Who may queue.** `OrgMembership` `:queue_registration` admits only the
  `:registrations` system actor (the password sign-up and the site single
  sign-on admission); the platform-admin bypass forbids it, so no person can
  create a waiting row, for themselves or anyone.
- **Mixed-version nodes.** A node on the previous release has no `status` and
  reads a waiting (or rejected) row as an active viewer membership: no
  audiences, but comments and checkout where viewers may. Operators turn
  approval on only once every node runs the new release, and before rolling
  back anonymize the waiting and rejected accounts they would not let in
  ([ADR 0024](decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md#upgrade-notes)).
- **Invitations decide registrations, without reopening a rejection by
  accident (#2514).** An invitation is a platform admin's decision to let an
  address in, so accepting one approves the invitee's waiting or rejected
  row on that site with the invited tier
  (`OrgMembership.:approve_registration_by_invitation`, admitted only for the
  `:invitations` system actor and a standing platform admin). A rejected row
  is approved only if the invitation was sent or last resent **after** the
  rejection (`invited_at` later than `decided_at`, compared on the locked
  row; equal or missing times leave the rejection standing). An invitation
  older than the rejection is refused as "no longer valid", with the same
  page as any other dead link, and the accept rolls back, confirming
  nothing. So a site admin's rejection is not undone by an invitation that
  predates it. A platform admin's direct add on Team overrides any rejection,
  because it is a decision made now, and does it visibly: the outcome is
  `:approved_over_rejection`, the page says the rejection was overridden, and
  the log records `registration_approved` with `via` `added` and that admin
  as the person. Approval still requires a confirmed, unerased applicant: an
  unconfirmed address is invited, never added, and the invitee proves the
  address by accepting. The applicant's sessions are evicted after the
  accept's own commit (`KilnCMS.AfterCommit`), not when the nested approval
  finishes, so a reconnect is never authorized against the row before it is
  committed, and a rolled-back accept evicts nothing.
- **A site's own single sign-on can be held for approval (#2514).**
  `SiteRegistration.approval_for_site_sso`, off by default and independent of
  `approval_required`, makes a **new** account the site's provider
  provisions a `:pending` row (`queue_registration`, `method: site_sso`)
  instead of a `:viewer` membership. The account gets a session that grants
  nothing. Rule 3 of `SiteSso.Admission` (no access on any other site) is
  unchanged and still sound: the pending row is on this site only, so the
  account stays affiliated and is never the legacy membership-less viewer on
  the default site, and a pending or rejected row on *another* site counts as
  access elsewhere and refuses the sign-in, as any membership does. The
  setting is read only when an account would be provisioned, before the
  transaction, and fails closed: an unreadable row refuses the sign-in
  (`:registration_settings_unavailable`) and creates nothing.
- **Erasing a rejected account is a site's opt-in, limited to unconfirmed
  applicants (#2514).** `SiteRegistration.rejected_accounts` is `:keep` by
  default; with `:erase_unconfirmed`, rejecting an applicant whose address was
  never confirmed erases the account (`User.:anonymize`) in the rejection's
  transaction (`Changes.EraseRejectedAccount`). A confirmed rejection is always
  kept: the kept account holds the address, which is what stops the same
  person registering on the site again, and erasing it would hand them a fresh
  start. An unconfirmed sign-up proves nothing about who owns the address, so
  erasing it gives up little, and it frees an address a stranger may have
  registered in its owner's name. Nobody is mailed, since an unconfirmed
  applicant never is. An unreadable setting means keep: erasure cannot be
  undone, so it needs the site's known consent.
- **Only an account that is nothing but its application can be erased.** A
  site admin may not erase accounts, and this does not let them: the account
  must have been created by this registration (`created_account`), be
  unconfirmed, unerased, a standing *Viewer* with no live grant and no
  audiences, with no other membership of any status on any site, and nothing
  may reference it (paid membership, API key, content, version, comment, task,
  media, release, invitation sent, consent, newsletter row or logged event:
  `Accounts.Registrations.Erasure`, one query). The referencing tables are a
  static list, and a test holds every foreign key to `users` to it, so a new
  table cannot silently stop blocking. Anything else keeps the account. So a
  site admin can erase only an account that exists solely because someone
  applied to *their* site and has done nothing since.
- **Who may erase.** A **standing** admin of the site, or a standing platform
  admin (`Erasure.standing_admin?/2`), and only when the console's dialog
  said the account would be erased (`erase: true`; a client pushing the
  argument without it is still bound by the setting and the check). A
  temporary admin may reject, but the account is kept: an erasure would
  outlast the grant that allowed it.
- **The system actor's grant is held to one erasure.** The deciding admin may
  be a site admin, who is refused `:anonymize`, so the erasure runs as
  `SystemActor.new(:registrations)`, which the `User` policy now admits to
  `:anonymize`. A policy can only name the subsystem, so
  `Changes.GuardRegistrationErasure` on the action narrows it: the changeset
  context must name a membership of this account on that site that is
  `:rejected`, with `created_account`, and with exactly the `decided_at` this
  transaction wrote; a transaction must be open; the account's row is locked
  `FOR UPDATE`; and the erasable check must pass again. Anything else is
  refused (`ErasureRefused`) before the scrub touches anything. Any other
  caller that ever obtains the `:registrations` actor cannot use it to erase
  an arbitrary account.
- **A row lock, not a check alone, against races.** Under READ COMMITTED the
  erasable check cannot see a membership, key or confirmation that another
  transaction is writing. So the rejection takes the account's `users` row
  `FOR UPDATE` before it locks the membership (only when it will try to
  erase), and every path that would give the account a footprint or confirm
  it takes the same row `FOR KEY SHARE` first (`Accounts.AccountLock`): every
  `OrgMembership` create (resource-wide), both approvals, `Billing.Membership`
  `:start` and `:comp`, the entitlement recompute's write, `ApiKey` `:create`
  and `:rotate`, and the three `User` updates that confirm an account
  (`:confirm_new_user`, `:reset_password_with_token`,
  `:accept_invitation_with_password`). Whichever locks first goes first. An
  erasure that waited checks against what the other committed, a
  confirmation included, and keeps the account. A writer that waited reads
  `anonymized_at` and is refused (`AccountErased`), so no membership, key,
  password or session lands on the tombstone, and the entitlement recompute
  writes nothing to an erased account. Lock order is the users row, then any
  membership row, on every path, so they cannot deadlock. A foreign-key
  insert alone would only make a writer wait and then succeed against the
  tombstone, which is why the listed paths lock and re-read explicitly.
- **One transaction.** A failed erasure rolls the rejection back, so a
  rejection never claims an erasure that did not happen. The security event
  is recorded after the erasure: `registration_rejected` with
  `outcome: erased` and no target (it would name only a tombstone), or
  `outcome: kept` naming the applicant.
- **Erasure itself deletes more (every erasure).** Web Push subscriptions (an
  endpoint that reaches the person's device), private saved views, and the
  notifications addressed to the account are deleted, and stored audiences
  are cleared in their own statement, which a stale copy of the account
  could previously skip ([data flows](data-flows.md#subject-rights-workflows)).
- **Enumeration.** The sign-up page says nothing about waiting, and a
  registration for an existing address answers as before. Single sign-on
  answers a new and an existing account the same way whether or not the new
  one waits: both are signed in. **Add or invite** tells a platform admin,
  after the fact, that a confirmed address had a waiting or rejected
  registration on the site (the outcome names it); for an unconfirmed address
  it says nothing and invites. That is an admin of the site learning about
  its own applicants, and a platform admin can read every account anyway.
  Erasing (#2514) adds one bit: "erased" or "kept" after rejecting an
  unconfirmed applicant tells a site admin whether that account is more than
  its application here (another membership, content, a key) without saying
  what. The account was created by a registration on their site, so the bit
  is about their own applicant, and the event records the same outcome.
- **Residuals.** (1) The erasable check scans several referencing columns
  that have no index while the account's row is locked `FOR UPDATE`, so an
  erasing rejection on a large site is slower, and holds that one account's
  writers (its memberships, billing, keys and confirmation) for as long. It
  runs only on a rejection that will try to erase; indexes are a follow-up.
  (2) A site admin whose admin tier is a temporary membership
  grant can decide registrations, and is told about them;
  `StandingAdminOnly` constrains only platform grants. (3) A node on an older
  release cannot load a `registration_pending` notification, so during a
  rolling deploy or after a rollback an affected admin's bell there lists
  nothing ([#2509](https://github.com/The-Verscienta/kiln_cms/issues/2509));
  an availability gap, not an exposure. (4) A magic-link sign-in does not
  confirm an account, so an applicant who only ever signs in that way is
  never announced
  ([#2516](https://github.com/The-Verscienta/kiln_cms/issues/2516)).
  (5) Holding single sign-on accounts covers new accounts only: an existing
  account the site's provider admits for the first time is not queued
  ([#2515](https://github.com/The-Verscienta/kiln_cms/issues/2515)).
  (6) Sending, resending or re-inviting an address whose registration was
  rejected does not tell the platform admin about the rejection; if the
  invitee accepts, the rejection is overridden, and only the
  `registration_approved` event (`via` `invitation`) after the
  `registration_rejected` shows it. (7) A node on an older release ignores
  `approval_for_site_sso` and provisions single sign-on accounts as active
  viewers; operators turn it on only once every node runs the release.
  (8) A node on an older release takes no account lock on its membership,
  billing, key and confirmation writes, so during a rolling deploy an
  erasure can race one of them and attach it to a tombstone, or erase an
  account that has just been confirmed. Operators turn `erase_unconfirmed`
  on only once every node runs the release
  ([ADR 0024](decisions/0024-a-registration-awaiting-approval-is-a-membership-that-grants-nothing.md#upgrade-notes)).

### Security posture (`/editor/security-posture`, #2252)

`KilnCMS.Security.Posture`, `KilnCMS.Security.PostureReport`,
`KilnCMSWeb.SecurityPostureLive`. A read-only page that lists which security
settings are on. The guide is [Security posture](security-posture.md); the
policy is under "Security posture" in [policy-matrix.md](policy-matrix.md).

- **It discloses configuration, so it is gated twice.** The page is a map of
  what is off, which is what an attacker wants. It sits in the `:admin_routes`
  live session (the tier gate) and its one action is authorized by
  `Checks.OrgAdmin` on the request's site, which is the tenant and never an
  argument. Editors, viewers, admins of other sites and admins whose
  membership is still waiting are refused. **Run checks again** re-checks the
  tier, because the socket outlives the mount.
- **The deployment's lines are for platform admins only.** Which checks run is
  decided inside the action from the actor's effective platform role, not by
  the page: a site admin's report contains no `:deployment` entry at all. So
  only platform admins learn which platform admins lack an authenticator app,
  whether metrics, the API explorer or introspection are exposed, which
  administrators hold long-lived or read-write keys, and how far behind the
  release is. The per-site second-factor check leaves platform admins out, so
  a site admin does not learn their two-factor status either. The JSON
  endpoint applies the same rule: a site admin's key gets no `:deployment`
  entry.
- **Email addresses are shown on the page and nowhere else.** A site admin
  sees the addresses of that site's administrators and editors who have no
  authenticator app (until now, a site admin who is not a platform admin
  could not read another account). A platform admin also sees the addresses
  of platform admins without one, and each flagged API key's name and owner.
  They are in a result's `details`, which only the page renders. `facts`
  carry counts, booleans and short values, and the SDK contract forbids
  secrets and addresses in them, because they are published to monitoring
  (below). Nothing is stored or logged; the only copy kept is the monitoring
  snapshot, which has no `details`.
- **Monitoring over HTTP (#2521).** `GET /api/security/posture`
  (`KilnCMSWeb.SecurityPostureController`, `KilnCMSWeb.SecurityPostureJSON`)
  serves the report as JSON through a second action, `:snapshot`, under the
  same policy as `:run` and the same scope rule
  (`Posture.scopes_for/1`). What a key reveals:
  - **Credential.** A JWT or API key of an administrator of the request's
    site; a platform administrator's also gets the deployment's lines. A
    `:draft_write` key is refused by `forbid_if DraftWriteKey` on both
    actions, even if its owner has since become an admin. Note that a
    long-lived `read` key on an admin account now carries this map; the
    page could only be read through a signed-in session.
  - **Allowlist first.** The route is behind `:admin_allowlist_api` ahead of
    the rate limit and the credential plugs, so a caller off the list gets
    `403` `network_not_allowed` without learning whether its key is valid.
    The allowlist's JSON refusal details are neutral ("Not available from
    this network", "Temporarily unavailable") since they now answer more than
    sign-in.
  - **No details.** `Posture.without_details/1` empties every result's
    `details` before the report is cached, and the serializer picks each
    field by name, so no email address, key name, check description,
    duration or module leaves the server. A field added to `Entry` or
    `Result` stays private until the serializer names it.
  - **Facts and summaries are published data.** A plugin's `facts` and
    `summary` reach every admin of the site (site checks) or every platform
    admin (deployment checks) who holds a key. The SDK documents that.
    Every string is passed through `String.replace_invalid/1` and non-scalar
    fact values become `null`, so a bad result cannot break the encoding.
  - **Cache.** The detail-free report is kept 30 s in the node's Cachex,
    keyed by site and scope set (`KilnCMS.Cache.security_posture_key/2`), so
    a site admin is never served a platform admin's deployment lines, and one
    site's answer never another's. A burst of monitors runs the checks once
    per window; a busy answer is not cached. Every response is
    uncacheable: `cache-control: private, no-store`, or `no-store` on the
    allowlist's own refusals.
- **Three system reads.** The two second-factor rosters and the API key list
  read with `authorize?: false` (`User` reads are self-only; `ApiKey` reads are
  platform-admin only), each with its reason at the call site. They select
  only what the page needs (id, email, `totp_confirmed_at`; key name, access,
  dates and owner), and only counts and the addresses above leave the check.
  The other site checks read through their existing system grants
  (`:accounts`, `:admin_allowlist`).
- **Plugin checks are trusted code, contained.** A plugin's
  `Kiln.Security.Check` runs in the node with the core's privileges and no
  actor, like any plugin code: the page cannot stop it reading what it likes.
  What the page does limit is the damage to the report. Each check runs in its
  own task with a kill timer armed before it is called, so it dies at its
  deadline even after the page is gone; a raise, throw, exit, timeout or
  non-result is one "could not run" row, never a pass; checks run under their
  own supervisor (50 tasks per node) so they cannot starve the rest of the
  app; and every result passes `Result.sanitize/1`: summary and details are
  escaped text, a fix link must be a `/editor/` path, a "Learn more" link must
  be `https://`, and facts are held to scalars. A plugin cannot take a `core.`
  id or displace a core check.
- **Load.** Each report starts one task per check. A page refuses a rerun while
  one runs and within five seconds of the last; at most three reports of one
  site run at once per node (`with_slot/2`, a `Registry` count), and a full
  supervisor makes the extra checks "busy" rows rather than queueing them.
- **Residual risks.** (1) Work a check hands to another process (a `Task` it
  starts, a `GenServer` call it makes) is not killed at its deadline. (2) A
  check's metadata callbacks (`title/0`, `description/0`, …) are called before
  the deadlines start, in the report's process: a plugin whose metadata
  blocks holds up the whole page. (3) The admin-allowlist check reads
  `KILN_ADMIN_ALLOWLIST_DISABLED` on the node that runs the report, so in a
  cluster whose nodes disagree the line can change between page loads. (4)
  The per-site cap is per node: N nodes allow 3×N concurrent reports of one
  site; monitoring runs count against the same three. (5) Opening the page,
  or a platform admin's call to `GET /api/security/posture`, sends the update
  check when nothing is cached, below. (6) The monitoring snapshot is per
  node, so a cluster runs the checks up to once per node per window, and two
  answers a second apart can differ.

### Other outbound calls
`Kiln.Updates` (the kilncms.dev release feed, then GitHub releases;
admin-triggered from System, or from Security posture when no answer is
cached, and the feed's `links.next` is followed only on its own
origin),
`Kiln.Plugins.Health` (hex.pm's package API for each plugin locked from
hex.pm, and the security notices feed; on the same platform-admin triggers,
through `SafeFetch`, the feed's `links.next` followed only on its own origin
and at most five pages; package names are checked against Hex's naming rule
before they are put in a URL),
`Kiln.SecurityNotices` (the same security notices feed, fetched once per
node and shared by `Kiln.Plugins.Health` and the `core.security_notices`
posture check; that check asks only while `KILN_UPDATE_CHECK` is on, on the
same platform-admin triggers plus System's **Check now**, and logs only
notice ids, never a notice's text or links),
Meilisearch (the operator's instance — a site's own is below), S3/MinIO, the
mailer, and the LLM providers behind `/api/ask` and
SEO drafting, and the breached-password check (`api.pwnedpasswords.com`, a
fixed host, 5-character hash prefix only, through `SafeFetch`; below),
all make outbound requests to *operator-configured or fixed*
endpoints, not user-supplied ones — so they are not SSRF vectors in the way
webhooks are. The exceptions are a site's own SMTP relay (#1322) and AI
endpoint (above), which are tenant-chosen and SSRF-checked, and
`KilnCMS.Unsplash`: its API host is fixed, but the image URL an import downloads
comes from Unsplash's response, so every Unsplash request goes through
`SafeFetch` — pinned, each redirect hop re-validated, and capped at the image
upload ceiling (#1653). Note that `/api/ask` lets an anonymous caller drive an outbound
LLM request; it is config-gated and rate-limited under `:api`, but it is a cost
amplification surface.

### ActivityPub inbox (`POST /actor/inbox`, #491)
Off unless both the deployment (`KILN_FEDERATION_ENABLED`) and the site turn it
on. Every activity the inbox acts on must carry an HTTP Signature, and the key
that verifies it lives in the sender's actor document — so authenticating costs
an outbound GET to a URL the unauthenticated caller named. That fetch is kept
behind everything that can be decided without it (#1665): only a `Follow` or
`Undo{Follow}` addressed to this site's actor needs one at all, and even that
one is refused with no request made unless the `Signature` header parses,
covers `(request-target) host date digest`, carries a `Date` inside the
five-minute window and a `Digest` matching the raw body, and names a `keyId`
belonging to the activity's own `actor`. What remains is the irreducible part —
a well-formed request for an actor URL the caller chose still costs one fetch,
because telling a forged signature from a real one needs the key. That fetch
goes through `SafeFetch` (pinned address, no redirects, 128 KB cap), is cached
per actor for ten minutes in a capped table, and sits under the route's per-IP
`:api` bucket. A verified signature is then recorded in the replay store, and
the fetched document must have been served from the URL it claims as its `id`.
See [Federation](federation.md#security).

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
  role reaches beyond the site. Checked at every sign-in, in
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

## Account enumeration by surface (#2255)

The question for every screen or endpoint that takes an email address or other
identifier: can a stranger tell, from the response, whether an account exists?
Each surface below was audited, and where a known and an unknown address
differed, the difference was removed. Every row has a test under
`test/**/enumeration_*` that compares the two responses **whole** (status,
redirect, headers that carry a credential or a challenge, the complete flash and
the complete body) through `KilnCMS.EnumerationAssertions`. A substring check
would pass when one side also said "no such account" three lines further down,
so none is used. The control for each refusal is that the test pins what the
answer actually says, so "equal" cannot mean "equally empty".

"Indistinguishable" means in the response. The one difference that is
deliberately left is in the **owner's inbox**: mail goes to the address that
was named, never to the person who named it.

| Surface | Result | Tested in | Residual |
| --- | --- | --- | --- |
| Browser sign-in (form and LiveView submit) | Wrong password for a known address and an unknown address: same page, same redirect, same flash ("Email or password was incorrect"). An unknown address still pays for one bcrypt check. | `enumeration_sign_in_test.exs` | Lockout owner mail (below). |
| Headless sign-in (`POST /api/auth/sign_in`) | Same generic 401 for both, with the simulated hash for an unknown address. | `enumeration_sign_in_test.exs` | None beyond timing. |
| Human-verification challenge (#2249) | A known and an unknown address are asked at the same attempt and refused with the same error, page, redirect and API body: the account axis keys on the submitted string and the address axis on the caller's IP. A refused attempt runs no bcrypt for either. | `accounts/sign_in_challenge_test.exs`, `challenge_auth_test.exs` | None. |
| Per-account sign-in budget | A known and an unknown address run out at the same attempt and get the same refusal, because the budget keys on the string typed. | `accounts/enumeration_throttle_test.exs` | Lockout owner mail (below). |
| Password reset request | Form, plain POST and the action answer `:ok` / the same page and flash for both. A spent mail budget (`mail:password_reset`) still answers as for an unknown address. | `enumeration_request_forms_test.exs`, `accounts/enumeration_throttle_test.exs` | Owner-only mail; request-time timing not equalised (below). |
| Magic link request | As password reset (`mail:magic_link`). | same | Same. |
| Registration (`register_with_password`, form and POST) | **Changed.** A known and a new address both get "Check your email - we have sent instructions for what to do next." and a redirect to `/sign-in`; neither is signed in. A known address creates no row and its owner is mailed a notice. Both pay for exactly one bcrypt hash. A real validation error (a short password) is still shown, alike for both. | `enumeration_registration_test.exs` | Owner-only mail; concurrent race (below). |
| Registration with self-registration off | A known and an unknown address are refused with the same error, and nobody is mailed. | `enumeration_registration_test.exs` | None. |
| Email confirmation link | A made-up token, a used one and one for a deleted account are refused alike; the page the link opens is the same for a real token and a made-up one. | `enumeration_confirmation_test.exs` | None. A token is mailed only to the address it names. |
| Newsletter subscribe | New, pending, confirmed and unsubscribed addresses get the same page. A malformed address is the one distinct answer and says nothing about anyone. | `enumeration_newsletter_test.exs` | Owner-only mail; pending address can be re-mailed (below). |
| Site SSO (`/editor/site-sso`) | An existing account, an account with access only on another site, an unconfirmed account and an invite-only refusal share one answer; an existing and a new account are both signed in with the same response. | `enumeration_site_sso_test.exs` | Server logs; `register_with_sso` (below). |
| `register_with_sso` | Covered by the site SSO test: the caller has already proved, at the provider, that they hold the address. | `enumeration_site_sso_test.exs` | Invite-only refusal (below). |
| Passkey options and verify | `options` ignores any identifier and offers no credential list. `verify` answers one 401 and one sentence for an unknown credential, one that fails verification, a regressed counter, a malformed payload and a missing challenge. | `enumeration_passkey_test.exs` | An unknown credential skips signature work (below). |
| API key sign-in | A key that never existed, an expired key and a revoked key are refused with the same status, challenge header and envelope. | `enumeration_api_key_test.exs` | None. A key is a random secret, not an address. |
| JSON:API, GraphQL, MCP reads | `User` is not a JSON:API resource, a GraphQL type or an MCP tool. A filter or sort through the content's `author` relationship (`filter[author][email]`, `sort=author.email`, an MCP `author.email` filter) answers an anonymous reader, a viewer and an editor the same for a registered and an unregistered address. An admin control proves the question is answerable, so the empty result comes from the read policy. | `enumeration_api_reads_test.exs` | None. |
| REST and author routes | No route serves accounts by name, address or slug outside the console and the sign-in flow. WebFinger answers a registered and an unregistered `acct:` handle with the same 404. A published post by a known account carries no address on HTML, feeds or the JSON:API. | `enumeration_author_routes_test.exs` | None. |
| Site invitation link (`/auth/invite/:invite_token`, #2135) | A made-up, expired, revoked and used token open the same page, "This invitation is no longer valid", on the dead render and the connected one. A token is mailed only to the address it names. | `enumeration_invitation_test.exs` | An admin-tier invitation whose sender lost the role gets the same page. |
| Admin lookups (`get_user_by_email`, `list_users`, `get_user`, admin password reset, add-or-invite) | Any actor but an admin, or none, finds nothing for a registered address and for an unregistered one alike; the admin-only reset and add-or-invite (#2135) refuse a non-admin before they look at the account. | `accounts/enumeration_lookups_test.exs` | Admin-only oracles (below). |
| Sign-in unlock (`/sign-in/unlock`, `/auth/unlock/:unlock_token`, #2250) | An unknown address, a known one that is not paused, a paused one, a paused one whose unlock-mail budget is spent and an erased one get the same page and the same sentence. The request hands the address to a background task before anything is looked up, so the request process does the same work for each. The sign-in page shows the same "Paused after too many attempts?" link to everyone, paused or not. The link's page is the same for a real and a made-up token, and every refused redeem renders one page. | `enumeration_unlock_test.exs` (the request); `accounts/sign_in_unlock_async_test.exs` (equal work on the request process); `controllers/sign_in_unlock_controller_test.exs` (the link's page, the sign-in page) | Owner-only mail (below). |

### What registration does now

`KilnCMS.Accounts.Changes.RefuseExistingAddress` runs on
`:register_with_password` **after** the password is hashed, so a known address
pays for bcrypt like a new one. If the address already has an account the
action fails with `KilnCMS.Accounts.Errors.AlreadyRegistered` and creates no
row. `KilnCMSWeb.AuthRegisterForm` and `KilnCMSWeb.AuthController` recognise
that error and answer exactly as they answer a success. The owner is mailed
"Someone tried to create a (site name) account with your address" by
`KilnCMS.Accounts.User.Senders.SendRegistrationNotice`. It carries no token,
only links to the sign-in and reset pages. The mail is budgeted per address by
`AccountThrottle` (`mail:registration_notice`, 5 per hour, the same budget as
reset and magic-link mail) and is dropped silently once spent.

### Residuals

- **Owner-only mail side channel.** A known address receives a reset, magic-link,
  registration-notice or sign-in unlock mail that a stranger's does not. The requester never
  sees it; the owner does. The per-address mail budget bounds how much
  of it anyone can cause.
- **Reset and magic-link request time is not equalised.** A known address mints
  a token, inserts it and enqueues an Oban job; an unknown address performs only
  a read. The response is identical, the work is not. Mail goes on the `mail`
  queue and is never sent inline, so the SMTP round trip is on neither path.
- **Concurrent registration race.** Two simultaneous registrations of the same
  new address can both pass the lookup; the loser may then see the
  `:unique_email` identity's "has already been taken".
- **Admin-only oracles, accepted by decision.** The team page's "Add or
  invite" form says "Member added to this site." for an address with a
  confirmed account and "Invitation sent to (address)." for any other (#2135),
  the accounts console
  searches by address, and the editor comment `author_label` falls back to an
  address when the author has no name. All three are for people who may see
  accounts anyway. `enumeration_lookups_test.exs` pins that the underlying
  resource calls give nobody else the same answer.
- **Sign-in lockout owner mail.** When attempts start being refused, the account
  owner is mailed once per window. A stranger sees the same refusal for a known
  and an unknown address.
- **Site SSO refusal reasons in server logs.** The browser gets one sentence;
  the logs still distinguish why a sign-in was refused.
- **`register_with_sso` under invite-only.** The refusal is visible only to
  someone who controls the address at the identity provider.
- **Newsletter pending address.** An address awaiting confirmation can be mailed
  the confirmation link again, with no per-address budget.
- **Passkey unknown credential.** An unknown credential skips the signature
  check a known one pays for. The credential id is a random value held by the
  authenticator, not an address a stranger can guess.
- **Timing was never measured by wall clock.** The tests assert that equal
  *work* ran (one bcrypt check on each side, via `Bcrypt.no_user_verify/1` and
  `Bcrypt.verify_pass/2`), not that equal time passed.

## Residual risks

Known and accepted, in rough order of how much they should worry an operator.
Each is a deliberate trade-off, not an oversight — but each is worth revisiting.

**1.0 review (#1535).** Each item below ends with its 1.0 verdict: *still
accepted at 1.0*, *fix before 1.0*, or *fix after 1.0*, with the reason and the
code it was checked against on `main` (v0.10.0). The maintainer accepted every
verdict on 2026-09-26; item 3 was already settled by roadmap decision 4. Each
*fix before 1.0* has an issue on the v0.12.0 milestone. Items keep their numbers
because other files cite them by number.

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
   ceiling, closed in #1133, and on by default for multi-org since #1618.**
   On a single-org deployment an org admin can still open framing — on a
   form, or on the org default — that the operator had left closed; that
   stays deliberate (the operator and the org admin are the same party, and
   the allowlist grants nothing across the tenant boundary). Once a second
   organization exists an unset `EMBED_ORIGINS_LOCKED` turns the cap on by
   itself (the organization-count verdict `TENANT_STRICT_HOST` uses, failing
   closed when the count is unknown); `EMBED_ORIGINS_LOCKED=true` forces it on
   everywhere and `false` keeps it off. With the cap on, `EMBED_ORIGINS`
   becomes the *most* a tenant may open as well as the default: a per-form or
   per-org list may narrow it but every entry must be covered by it, writes outside
   it are refused (naming the entry, never the ceiling), and the served
   header is clamped to it too, so a list saved before the cap cannot keep a
   page wider than the operator now allows (`KilnCMS.Forms.EmbedCeiling`).
   With the cap off nothing changes; with `EMBED_ORIGINS=*` the cap is a
   ceiling of everything; with `EMBED_ORIGINS` unset it is a ceiling of
   nothing. It also gives the operator the switch an org-admin compromise
   used to lack: under the cap, a taken-over admin account cannot re-open the
   overlay-and-harvest surface #562 closed beyond what the operator listed.

   **1.0 verdict (decided, #1535): still accepted at 1.0.** Verified on main:
   the default is same-origin (#562), a form's list resolves form -> org ->
   deployment in `KilnCMS.Forms.EmbedPolicy` (#1131), and the operator ceiling
   is `KilnCMS.Forms.EmbedCeiling` behind `EMBED_ORIGINS_LOCKED`
   (`config/runtime/cross_origin.exs`, #1133). What remains is a stated
   choice: an org admin decides who may frame that org's own forms, which grants
   nothing across the tenant boundary, and an operator who disagrees has a
   switch. Decided alongside #1547: `EMBED_ORIGINS_LOCKED` also defaults on
   once a second organization exists, so on a multi-org install the operator's
   `EMBED_ORIGINS` caps every tenant unless the operator says otherwise
   (#1618).
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

   **1.0 verdict (decided, #1535): still accepted at 1.0.** Nothing here is a
   bug to fix. A shared passphrase is weak by construction, and the item says
   so. The bounds it lists still hold on main: the `:unlock` bucket is 10/min
   per address (`lib/kiln_cms_web/rate_limit.ex:53`), and grants live 12 hours
   (`lib/kiln_cms/cms/content_password.ex:54`) and name a fingerprint of the
   bcrypt hash, so rotating the passphrase kills them. The 1.0 obligation is
   documentation. The pointer to `api.md` already meets it: audiences are the
   access-control axis.

3. **Unknown `Host` headers resolve to the default organization — on a
   single-org deployment.** #563 added the control; since #1547 an unset
   `TENANT_STRICT_HOST` turns it on by itself once a second organization
   exists, on every node and with no restart, so a multi-tenant deployment is
   no longer exposed by default. Since #1662 an explicit
   `TENANT_STRICT_HOST=false` no longer switches it off there either: once a
   second organization exists, unknown hosts are refused whatever the setting
   says, and Kiln logs an **error** — at boot, when the second org is created,
   and on `/editor/system` — that the setting is being ignored. There is no
   escape hatch; a host a multi-org deployment should answer on can be given
   to an organization or redirected to one at the proxy. With the control on, an unresolvable `Host` is
   refused with a bare 404 rather than served the default org, across
   everything the router serves plus LiveView mounts and the GraphQL and
   visual-editing sockets. What remains:
   - A node that misses the create's `Phoenix.PubSub` broadcast (partitioned,
     or mid-boot) stays lenient until its periodic recount, at most **30
     seconds** later (#1654; it was five minutes). The recount is one
     `count(*)` on `organizations` per node every 30 seconds, and stops once
     the node has seen a second organization. `/editor/system` shows the
     window while it is open.
   - If the organizations cannot be counted at all (boot with Postgres down),
     an unset setting fails **closed**: unknown hosts are refused until a
     count succeeds. An explicit `false` stays lenient in that state — #1662
     overrides it only on a count that actually found a second organization.

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
   unset `TENANT_STRICT_HOST` turns on once a second organization exists. The
   2026-09-27 audit closed the two gaps that were left: an explicit `false`
   is no longer honoured on a multi-org deployment (#1662, a `### Breaking`
   change in 0.12.0), and a node that missed the broadcast catches up within
   30 seconds rather than five minutes (#1654). The
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

   **1.0 verdict (decided, #1535): still accepted at 1.0.** The residual is a
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
   **On Fly.io, Railway and DigitalOcean App Platform (#1548)**, whose proxies
   publish no address range, `CLIENT_IP_HEADER` reads the proxy's own
   client-address header instead. It is honoured only while that platform's
   runtime variables are present, so a copy elsewhere is refused and logged.
   Two gaps remain: another app on the platform's private network reaches Kiln
   without the proxy and can send the header itself, and sockets see only `x-`
   headers, so the `/sign-in` form on Fly and DigitalOcean stays per
   deployment (see `docs/deploy-platforms.md`).

   Two things about `:auth` specifically, both worse for addresses many people
   share (an office NAT, or any deployment in the trap above). **One successful
   browser sign-in now spends three of its forty:** the page GET, the submit
   (#715), and the token-exchange GET the LiveView redirects to on success. A
   failed guess spends one, so the budget bites a legitimate user harder than
   the attacker it is aimed at — roughly thirteen sign-ins per minute per
   address (`:auth` is 40/min since #747, `lib/kiln_cms_web/rate_limit.ex`).
   And **the refusal reads as a wrong password**, deliberately: it is the same
   generic `AuthenticationFailed` a bad credential produces, with no 429 and no
   `Retry-After`, because distinguishing it would tell an attacker exactly when
   their window rolls. The cost is that a throttled user is told the wrong
   thing. Both are accepted rather than closed; a per-address `:auth` limit that
   is generous enough never to inconvenience a shared egress is not a limit.
   `TRUSTED_PROXIES` is what makes the buckets per-*client* and is the real
   remedy on any deployment behind a proxy.

   **1.0 verdict (decided, #1535): still accepted at 1.0 (correct the
   arithmetic).** Detection is in `KilnCMSWeb.Plugs.ClientIp`
   (`lib/kiln_cms_web/plugs/client_ip.ex:226-232`, a once-per-node warning that
   names the fix). Honouring forwarding headers without a trusted list would be
   the worse bug. The arithmetic had drifted: #747 doubled `:auth` to 40/min
   (`lib/kiln_cms_web/rate_limit.ex:28`), so a successful browser sign-in
   spends three of forty, not three of twenty — about thirteen sign-ins per
   minute per address, not six. The paragraph above now says so (#1614). The
   trade itself stays.
6. **Preview tokens bypass authorization — the signed token is the grant.**
   A preview link reads its one record with `authorize?: false`: the caller is
   anonymous, and the `Phoenix.Token` signature `PreviewToken.verify/1` checks
   is the whole authorization. It is **not** tenant-less (#1309): the token
   carries the minting org's `org_id`, every redeemer refuses it on any other
   org's host and reads with that `tenant:`, and a token that names no org is
   refused outright. Validity and expiry are the control; what remains is that
   an issued link cannot be revoked before it lapses.

   **1.0 verdict (decided, #1535): still accepted at 1.0 (rewrite the item).**
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
   for a short-lived bearer link; the item's first paragraph was rewritten to
   say so instead of "no tenant" (#1614).
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

   **1.0 verdict (decided, #1535): nothing to decide (closed).** Closed in #565
   and re-checked on main. `PublishedArtifact` reads through
   `Firing.Checks.DocumentReadable`
   (`lib/kiln_cms/firing/published_artifact.ex:103`), and the only `authorize_if
   always()` left among the four resources is `FormField`'s org-admin bypass. It
   keeps its place in the list because later items are cited by number.
8. ~~**Unauthenticated GraphQL runs with `actor: nil` *and* `tenant: nil`.**~~
   **Closed in #1614** — the premise had been stale for a while; #1614 is the
   proof. An anonymous query runs with `actor: nil`, so the read policies decide
   what is visible (published, public-audience rows only), but it does **not**
   run with `tenant: nil`. `KilnCMSWeb.Plugs.SetTenant` resolves the org from
   the `Host` in the endpoint (`lib/kiln_cms_web/endpoint.ex:187`) and sets it
   as the Ash tenant on every HTTP request
   (`lib/kiln_cms_web/plugs/set_tenant.ex:223`); `AshGraphql.Plug` copies it
   into the Absinthe context for `/gql` (`lib/kiln_cms_web/router.ex:78`), and
   the hand-written `menu` and `contentAsOf` resolvers read it from there.
   `/ws/gql` resolves its own from the connect URI
   (`lib/kiln_cms_web/graphql_socket.ex:46`), and `:strict_tenancy`
   (`config/config.exs:483`) makes a tenant-less read fail closed rather than
   span orgs.

   `test/kiln_cms_web/graphql_cross_org_test.exs` pins it over HTTP. With two
   orgs publishing under the same slugs, every anonymous-readable root field —
   the `published*` lists, the `*BySlug` and `*Translations` lookups, a lookup
   by id through `filter`, the `search*` and `autocomplete*` fields,
   `categories`/`tags`/`tagGroups` and their `*BySlug`, `menu` and
   `contentAsOf` — finds each org's content on its own host (the positive
   control) and none of org A's on org B's host; a shared slug on B's host
   answers with B's record. The anonymous GET cache (#1571) cannot carry an
   answer across: A's ETag presented on B's host gets B's full body and B's
   surrogate keys, never a `304`. And a `Host` that names no org is refused
   with a `404` once a second org exists (#1547), or served the default org's
   site — none of A's — where strict matching is forced off (residual 3).
   Mutation-checked: dropping the tenant `SetTenant` hands to Ash fails 28 of
   the 31 root-field cases on B's host — 23 show org A's content, and the five
   single lookups on a slug both orgs use find two rows and error — and
   making the `menu` and `contentAsOf` resolvers ignore the context's tenant
   fails their positive controls. The `semanticSearch*` fields are not
   covered: they need the opt-in ML build, and read through the same
   tenant-scoped actions.

   **1.0 verdict (decided, #1535 → #1614): fix before 1.0 — done (closed).**
   No code changed; the tests are the fix. It keeps its place in the list
   because later items are cited by number.
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

   **1.0 verdict (decided, #1535): fix after 1.0.** Verified unchanged on main
   (`lib/kiln_cms/cms/changes/enforce_block_field_policy.ex:140-153`). What
   remains needs an editor who may already write that document in that org. Such
   an editor can move or drop an admin-set block field by relabelling ids, or
   re-target a value stored on an id-less child. The multiset bounds the count,
   and nothing crosses a tenant or an audience, so this is integrity within an
   editor's own grant, not confidentiality. Closing it needs a new primitive:
   server-verified block identity on the write path. That is a design change to
   the block tree, too large for the contract-freeze window, and better done
   after the legacy block shape is retired (#1537).
10. ~~**Per-account throttling is per node, in memory, and keyed on
   attacker-chosen strings.**~~ **Closed in #1619.** `AccountThrottle` (#478)
   used to hold its budgets in ETS, as `KilnCMSWeb.RateLimit` held `:auth`, so a
   restart forgave every accumulated attempt and N nodes gave an attacker N
   budgets. Every `AccountThrottle` budget (sign-in, second factor, the mail and
   alert budgets) and the credential buckets of `KilnCMSWeb.RateLimit`
   (`:auth`, `:register`, `:unlock`) now count in one Postgres table,
   `throttle_counters`, through `KilnCMS.Accounts.ThrottleStore`. The item's own
   constraints still hold:
   - **Nothing on the user row.** A counter row is keyed on a SHA-256 of the
     budget's key and names no account, so a guess is not a write to a row the
     attacker chooses, and an address with no account counts exactly like one
     with an account.
   - **Bounded and expiring.** Whatever was submitted, a key is stored as 32
     bytes. A row lives for its window (one minute to six hours) plus at most
     five minutes, when an Oban cron job deletes closed windows in bounded
     batches. The table therefore holds about *(distinct keys charged per
     window) × (windows alive)*. Each sign-in attempt also costs the server a
     bcrypt verification (a refusal burns a simulated one), so sign-in rows
     appear no faster than the cluster can hash. Mail-budget rows are bounded
     per source address by the `:auth` bucket in front of them. A row costs about
     160 bytes with its indexes (measured: 100,000 rows in 16 MB), so a million
     live keys is roughly 160 MB, and each one is gone within its window.
   - **Atomic.** One `INSERT … ON CONFLICT DO UPDATE … RETURNING count` per
     charge, so a simultaneous burst from every node admits exactly the budget
     (`test/kiln_cms/accounts/throttle_store_test.exs` proves it with two `:peer`
     nodes). Windows are aligned to the database clock, so node clock skew does
     not split a window across rows.

   *Cost, measured* (Postgres 17 on Apple silicon, local socket): one upsert is
   p50 0.34 ms / p99 1.1 ms sequentially, and p50 1.1 ms / p99 5.4 ms with
   sixteen concurrent writers on a single key (the one-account attack shape),
   against 208 ms for the bcrypt verification the same attempt already pays.
   An `UNLOGGED` table measured p99 1.45 ms on that hot key and was **not**
   adopted: it is truncated after a Postgres crash and empty after a failover,
   which would bring back the "restart forgives everything" half of this item.
   A cluster-replicated in-memory counter (`:pg`/PubSub, or a Hammer backend)
   was rejected because a partition would still grant each side a full budget,
   and a full-cluster restart would still forgive everything. A local fast path
   with a shared check near the limit was rejected because the measured cost
   left nothing to optimise. Redis and Dragonfly stay out, per D1/D2.

   *Fail direction.* When the database cannot answer (the table missing during
   a rolling deploy, a lock or pool timeout), a budget is counted on the node
   in ETS instead. That is the pre-#1619 bound, never a weaker one. Failing
   open would allow unbounded guessing while only the counter is broken.
   Failing closed would let anyone who can slow one query lock every account
   out of sign-in. The fallback is logged at `:error`, at most once a minute
   per node.

   *What remains:* an attacker who spends a victim's mail budget still delays
   that victim's own reset mail until the window rolls, and every such
   suppression is still logged. That residual is unchanged, and it now holds
   cluster-wide rather than per node.

    **1.0 verdict (decided, #1535 → #1619): fix before 1.0. Fixed in #1619.**
    `AccountThrottle` and the credential `KilnCMSWeb.RateLimit` buckets now
    charge `KilnCMS.Accounts.ThrottleStore`
    (`lib/kiln_cms/accounts/throttle_store.ex`). The flood-ceiling buckets
    (`:api`, `:delivery`, `:gql`, …) stay per node on purpose: over-admitting a
    flood ceiling by the node count costs capacity, not a secret.
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

    **1.0 verdict (decided, #1535): fix after 1.0.** Every path this item
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
12. ~~**Periodic CSP re-review** as the editor adds third-party assets.~~
    **Closed by #1615 (the 1.0 review, from #1535's verdict): the reviewed
    policy is recorded here, and a change to it is a change to this item.**
    The console and public site are served, per request, with:

    | Directive | 1.0 value | Why |
    |---|---|---|
    | `script-src` | `'self' 'nonce-…'` | Per-request nonce (`put_browser_csp`). A site's code injection adds its listed origins and the `'sha256-…'` of its inline snippets, on delivery pages only. |
    | `default-src` | `'self'` | |
    | `connect-src` | `'self'` | Was `'self' ws: wss:`. Every socket Kiln's pages open (`/live` and its longpoll, `/ws/collab`, `/ws/gql`) is same-origin, and CSP3 matches `'self'` to `ws:`/`wss:` on the page's own host and port. No Kiln browser code connects cross-origin: uploads ride the LiveView channel, the presigned-upload API is for API clients, oEmbed and Unsplash resolve server-side, and `bridge.js` runs on the external front end under its own policy. Code injection adds a site's listed origins, `wss://` included (only this directive accepts one). |
    | `style-src` | `'self' 'unsafe-inline'` | **Kept.** Templates and blocks use inline `style=` attributes (focal points, column widths, chart bars), which cannot carry a nonce, and the brand tokens and custom CSS are `<style>` elements. Without script, injected CSS can restyle a page but can only fetch from the origins `img-src` and `font-src` already trust. |
    | `img-src` | `'self' data: blob:` + runtime | **Kept.** Widened by `CSP_IMG_SRC` (operator), Unsplash's thumbnail host while that integration is on, the enabled oEmbed providers' fixed thumbnail CDNs (#489), the site's own storage-profile origins (`Plugs.SiteStorageCsp`, #1559), and code injection's image list. |
    | `media-src` | `'self' blob:` + runtime | **Kept.** `CSP_IMG_SRC` (#494) and the site's own storage origins; not the thumbnail hosts. |
    | `font-src` | `'self' data:` | |
    | `frame-src` | `'self'` YouTube, Vimeo players | |
    | `object-src` / `base-uri` | `'none'` / `'self'` | |
    | `frame-ancestors` / `form-action` | `'self'` / `'self'` | Form embeds serve their own policy (`KilnCMSWeb.Embed`). |

    `test/kiln_cms_web/csp_connect_src_test.exs` asserts the served
    `connect-src` exactly, and `e2e/tests/csp.spec.js` loads the console, an
    editor, the media library, a public page and the same page on a second host
    name with no CSP violation, then shows a socket to another origin is
    refused. *Residual:* `CSP_IMG_SRC` is operator input split on whitespace
    and trusted as written; everything a tenant supplies passes
    `KilnCMS.CMS.Validations.CspOrigins` or `SiteProfiles.csp_origins/1`,
    which admit only scheme, host and port.
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

    **1.0 verdict (decided, #1535): still accepted at 1.0.** The two gaps this
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

    **1.0 verdict (decided, #1535): still accepted at 1.0.** Closed by #655,
    #675 and #775. The residual is that the re-check catches exactly what a
    fresh join would refuse, and that is the intended meaning: it is an
    authorization check. Its one data-loss consequence, publishing under an open
    room, was closed at the publish path (#1061). The bound an operator can rely
    on stays 30 seconds (`lib/kiln_cms_web/channels/socket_reauth.ex`), and
    cross-node eviction stays reasoned, not exercised, as #1060 decided.
15. ~~**Webhook deliveries have no anti-replay.**~~ **Closed (0.12.0,
    #1616).** Every delivery carries
    `x-kilncms-webhook-signature: t=<unix>,v1=<hex>`, an HMAC of
    `"<t>.<body>"`, and a `delivery_id` inside the signed body (echoed in
    `x-kilncms-delivery-id`) that stays the same across a delivery's retries.
    A receiver that rejects a `t` outside its window (five minutes is the
    documented default) and remembers the delivery ids it has seen inside that
    window cannot be replayed to. Re-stamping a captured request with a fresh
    `t` does not verify, because `t` is inside the MAC.

    ~~**Remainder.** The original body-only `x-kilncms-signature` is still sent
    during a deprecation period.~~ **Removed in 0.12.0 (#1616).** The
    body-only header, deprecated in 0.10.0, is no longer sent, so there is no
    signature left on a delivery that verifies without a timestamp. A receiver
    that verified only the old header now sees it missing and must move to the
    timestamped one (the 0.12.0 upgrade note). An admin **redelivery** is a new
    delivery with a new id and a fresh timestamp, on purpose. See
    [webhooks.md](webhooks.md#verifying-the-signature).

    **1.0 verdict (decided, #1535 → #1616): fix before 1.0 — done.** The
    timestamped header is the only signature a delivery carries
    (`KilnCMS.Webhooks.timestamped_signature/3`, sent by
    `KilnCMS.Webhooks.DeliveryWorker`), so the covered webhook contract at 1.0
    has no freshness-free signature in it. What remains is the receiver's side
    of the bargain: a receiver that skips the `t` check, or verifies nothing,
    is replayable by construction, and no sender change can fix that.

16. **An org admin's code injection is same-origin with the console when
    `KILN_CONSOLE_HOST` is unset (#1661).** Site code injection (`head_html` /
    `footer_html`, #490) runs on an org's delivery pages. By default the
    editor console answers on that same host, so an injected script can
    `fetch("/editor/…", {credentials: "same-origin"})` in the browser of any
    editor who opens the public site while signed in, and act with their
    session — including a platform admin, who is an admin on every org. On a
    single-org deployment the org admin and the operator are one party and
    this is the operator's own script. On a multi-org deployment it is one
    tenant's admin reaching other tenants' editors, and the operator's.

    The mitigation is `KILN_CONSOLE_HOST` (#740): consoles are then served
    only on hosts no tenant controls, and delivery script is cross-origin to
    all of them. Since #1688 that covers **every** organization: the bare
    console host is the default org's console and `<slug>.<console host>`
    is each other org's, resolved from the host like a tenant subdomain, so
    no org's console shares an origin with any site or with another org's
    console. Cookies stay host-only (`__Host-` in production), so a session
    on one console host is never sent to a site host or to another console
    host. Passkeys keep their RP ID (the `PHX_HOST` host) and are accepted on
    console origins under it, never on tenant site origins
    (`KilnCMS.Accounts.WebAuthn.origin_allowed?/2`). Why one host per org
    and not one shared, org-switching console host:
    [decision record 0011](decisions/0011-each-organization-gets-its-own-console-origin-under-the-console-host.md).

    It stays **opt-in**, because a console host is a DNS and TLS change
    (the host and its wildcard) that Kiln cannot make for an operator on
    upgrade. So Kiln says so: once a second organization exists and
    `KILN_CONSOLE_HOST` is unset, it warns at boot (a `KilnCMS.Config.Report`
    warning, which reaches Sentry), when the second org is created, and on
    `/editor/system` (`KilnCMSWeb.Tenant.console_shares_origin?/0`). See
    [code-injection.md](code-injection.md#read-this-before-granting-the-role).

    **1.0 verdict (decided, #1661; structural gap closed, #1688): closed
    by configuration.** With `KILN_CONSOLE_HOST` set, a multi-org
    deployment isolates every org's console. What remains is the
    unconfigured deployment, which is warned about. Its alternative is to
    treat "org admin" as equivalent to console access and staff it
    accordingly. One edge stays by design: the sign-in and account routes
    are shared (`KilnCMSWeb.Surface`), because members sign in on the site
    for gated content. So a session someone creates *on a site host* is
    same-origin with that org's code injection. It reaches the shared routes
    only, never a console route, and it is a separate session from the
    one on any console host.

17. **Queued mail carries sign-in links, sealed under `SECRET_KEY_BASE`
    (#1843).** Account confirmations, password resets, magic links and
    newsletter confirmations are queued on the `:mail` queue with their
    rendered message, and a newsletter confirmation link never expires.
    Before 1.0 that message sat in the job's args in the clear, and a mailer
    that crashed had the whole email stored as the job's error, shown on
    *Mail* and *Outgoing mail* and sent to the log and Sentry. Now the
    adapter call is guarded, so a crash is recorded by name only
    (`KilnCMS.Mail.MailerCrashError`); no mail server at all holds the mail
    with a reason instead of crashing; the subject and body travel sealed
    with `KilnCMS.Keys.Vault` (`KilnCMS.Mail.open_args/1`) and are dropped
    once the job finishes (`forget_body/1`); `KilnCMS.SentryFilter` strips
    mail bodies from every event; and the delivery panels show an error's
    first line only, with links and addresses removed
    (`KilnCMS.Mail.display_error/1`).

    What remains: anyone holding `SECRET_KEY_BASE` and read access to
    `oban_jobs` can open a pending job's message, which is the same party
    that can already mint sessions. The recipient address stays in the
    clear, in the row and in Oban's job log lines, because the delivery
    panel needs its domain. And the upgrade's scrub (`KilnCMS.Mail.Scrub`)
    reaches only the database: links that an earlier release already wrote
    to logs or Sentry stay there until the operator deletes them, and the
    1.0 upgrade notes tell them to treat those links as exposed.

**Not on this list, but named by the 1.0 roadmap: `/api/ask` lets an anonymous
caller drive LLM cost** (see *Other outbound calls* above). **1.0 verdict
(decided, #1535): still accepted at 1.0.** Generation is off by default
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
