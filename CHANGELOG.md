# Changelog

Notable changes to the KilnCMS core, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), interpreted for a
CMS core that downstream projects overlay:

- **major** — the overlay contract breaks. A `projects/<name>/` subproject that
  compiled against the previous version needs code changes: a renamed or
  removed `KilnCMS.CMS.Content` extension point, a changed `Kiln.Plugin`
  callback, a block schema version that isn't upcast automatically.
- **minor** — new capability, overlays keep compiling. May add migrations.
- **patch** — fixes only.

## How downstream projects read this file

Each release carries an **Upgrading** section whenever moving to it needs more
than a rebuild. That section is the contract `mix kiln.update` surfaces before
it moves your submodule pin — if a release has no Upgrading section, the update
is "bump the pin, rebuild, redeploy" and nothing else.

Write upgrade notes as imperative steps against a *deployed* instance, and call
out anything that is not reversible by rolling the pin back (a destructive
migration, a rewritten column, a dropped config key).

<!-- Releases are cut from `main`; see docs/releasing.md. -->

## [Unreleased]

### Added

- **`reading_time_minutes` alongside `word_count`** on every content type, in
  the same places: the admin show view, JSON:API and GraphQL
  (`readingTimeMinutes`). Kiln computed the word count and stopped there, so
  every consumer divided by its own words-per-minute constant and arrived at a
  different number from the one the editor showed. It is `ceil(word_count /
  wpm)` at 230 wpm, overridable with `config :kiln_cms, :reading_time_wpm`;
  a value that is not a positive integer keeps the default and warns rather than
  being interpreted, since `0` divides by zero and a negative is not a spelling
  of an intent. Rounded up, so any content at all is at least one minute and
  only genuinely empty content is zero. The editor's action bar now shows both,
  computed from the advisory panel's already-memoised body stats so it costs no
  extra walk of the block tree. One caveat, documented rather than hidden: a
  single wpm figure is an English-prose assumption, and scripts without spaces
  are counted as words rather than characters. Set it per deployment with
  `KILN_READING_TIME_WPM`. (#492)
- **`word_count` now counts Unicode whitespace**, fixing a disagreement the new
  reading time would otherwise have made visible. `KilnCMS.CMS.BlockText` split
  on `~r/\s+/` while the editor's advisory panel split on `~r/\s+/u`, so a
  non-breaking space — what `&nbsp;` decodes to, and what every paste from Word
  or Google Docs is full of — did not separate words for the calculation but did
  for the editor. `alpha&nbsp;beta gamma&nbsp;delta` counted as two words over
  the API and four in the editor. Existing counts on `&nbsp;`-heavy documents
  will go **up**. (#492)
- The `reading_time()` computed-field function now uses the same configured rate
  as `reading_time_minutes`. It had its own 200 wpm constant and ignored
  `:reading_time_wpm` entirely, so a site with both a `reading_time` computed
  field (the recipe in `docs/extending-content.md`) and the API field got two
  different numbers for one document, and reconfiguring the rate moved only one.
  Documents using that function will see their value change where it was
  computed at 200. (#492)
- **A manual delivery-cache purge.** The full-flush primitives existed but
  nothing user-facing called them, so when cache state went sideways — a config
  change, a template deploy, an external source feeding a custom block — the only
  recourse was an IEx shell on production. There is now a **Flush delivery
  cache** button on `/editor/system` (admin-only, behind a confirm, logging who
  flushed and what it dropped) and `mix kiln.cache.flush` for local use.

  Both go through a new `KilnCMS.Cache.flush_delivery/0` that clears **both**
  delivery caches — the published-record cache and the fired-artifact cache
  (`KilnCMS.Firing.Cache.clear/0`, also new). Clearing one and not the other
  leaves the site serving half-stale: the record lookups repopulate from the
  database while the fired bodies keep whatever they had.

  The page states the cost rather than presenting a free button: every request
  re-reads the database until the caches warm again, and because these are
  in-process with no shared tier, a flush covers the node that served you and
  leaves the others. On a release use
  `bin/kiln_cms rpc "KilnCMS.Cache.flush_delivery()"` — the `mix` task boots a
  second application node, which would clear its own empty caches and start
  draining production Oban queues on the way. (#483)

- **A deployment behind a proxy with `TRUSTED_PROXIES` unset now says so.** Rate
  limiting keys on `remote_ip`, which is the client's address only when a trusted
  proxy's `X-Forwarded-For` is honoured. Unset behind a proxy, every request
  carries the proxy's address and every bucket collapses into a single
  counter for the entire internet — one noisy client exhausts `:auth` (20/min)
  and `:form` (20/min) for everybody, and the per-IP brute-force protection on
  `/sign-in` and `/api/auth/sign_in` stops being per-IP. Nothing errored, and the
  deployment that most needs the control was exactly the one where it silently
  degraded. The first request carrying a forwarding header — `RemoteIp`'s whole
  default set, since a proxy that sets only `X-Real-IP` collapses the buckets
  identically — while no proxies are trusted now logs a warning naming the
  variable, once per node. The request is
  the only reliable evidence that there is a proxy in front, which a boot-time
  check cannot have. Behaviour is unchanged: honouring the header without a
  trusted-proxy list would be strictly worse, since it is spoofable. Called out
  in `.env.example`, the README and `docs/environment-variables.md`. (#564)
- `TENANT_STRICT_HOST=true` rejects a request whose `Host` matches no
  organization instead of serving it the default org (#563). Tenant resolution
  is by host — a subdomain of `TENANT_BASE_HOST`, then an org's `custom_domain`
  — and anything else has always fallen through to the default org, which is
  what makes a single-host install work and is the wrong answer on a
  multi-tenant one: a bare hostname, an IP literal, `localhost` or an
  attacker-supplied `Host` was served the default site's content, branding and
  analytics. With the flag on, an unresolvable host gets a bare 404 from the
  endpoint — across everything the router serves, plus LiveView mounts and the
  GraphQL and visual-editing sockets, which each resolve the tenant from their
  own connect URI and now refuse rather than silently scoping to the default
  org. The rejection is answered in the plug rather than raised for the error
  renderer, because the 404 template brands itself from the default org (which
  would leak the site name and logo through the rejection page itself) and
  because the rejection sits above every rate limiter and has to stay cheap.
  Static files are outside the control by design — see
  `docs/environment-variables.md`, which has the reasoning and a new
  multi-tenancy section. (`/ws/collab` was outside it too when this shipped;
  #655, below, brought it in.) The health probes and the payment-provider webhook are
  exempt, keyed on the controller rather than a path list, so turning this on
  cannot fail a deployment's own liveness check or silently drop billing events.
  The deployment's own apex is never refused either, so a missing default-org
  seed row or a Postgres restart caught mid-request cannot 404 the whole site.
  Off by default so no existing deployment changes; the app now logs a warning
  at boot when it is off and more than one organization exists.

- Content updates take `add_tag_ids` and `remove_tag_ids` alongside the existing
  `tag_ids` (#521). `tag_ids` has always been the *complete* tag set, so a
  partial write over `PATCH /api/json/<type>/:id`, GraphQL `update<Type>`, or
  the MCP `update_*` tools detached every tag it omitted — the MCP case worst,
  since a model asked to "tag this as Elixir" sends only the id it knows. The
  two merge verbs union and subtract against the current links instead, and both
  are idempotent (re-adding an attached tag and removing an unattached one are
  no-ops). Sending `tag_ids` together with either verb, or the same id in both
  verbs, is rejected rather than resolved by declaration order — and "sending
  `tag_ids`" includes sending it as `null`, which clears the set rather than
  meaning "unset", so the guard catches the generated-client shape that would
  otherwise walk straight past it. Empty merge lists carry no intent and are
  not a conflict, so a client that serializes all three keys still reaches the
  replace path. A repeated id within one list is de-duplicated instead of
  failing on the join table's unique index. The replace semantics of `tag_ids`
  are unchanged, so nothing existing has to move; the merge verbs are
  update-only (a create has nothing to merge against), and the other
  relationship arrays (`related_post_ids`, …) still replace.

- `mix docs` now builds a complete manual: the API reference for every module in
  `lib/`, the `mix kiln.*` task reference, and all 63 guides under `docs/`,
  grouped into a sidebar (Getting started, Authoring & editorial, APIs &
  headless, Operations & deployment, Security & access, and two archive groups
  for design records and point-in-time audits). The landing page is a new
  `docs/getting-started.md` onboarding path for contributors. Output goes to the
  gitignored `doc/`; run it under `MIX_ENV=dev`, which is the default. CI builds
  the docs with `--warnings-as-errors` in its own job, so a renamed guide, a
  dead cross-reference, or a moduledoc naming a function that no longer exists
  now fails a check instead of rotting quietly.
- Content analytics now keeps a **daily view bucket** alongside the all-time
  counter, so the analytics dashboard shows a 7-day / 30-day trend chart and a
  per-item view count for the selected range. The range lives in the URL
  (`/editor/analytics?range=7`), so it is shareable and survives the back
  button. The chart is server-rendered SVG with a visually-hidden data table, so
  screen readers get every value rather than a summary. Adds a migration
  (`content_view_days`). History starts at deploy — there is nothing to backfill
  from, since the previous counter stored no dates. Buckets are purged after
  `config :kiln_cms, :view_analytics, retention_days: 400`; the all-time counter
  is never purged, so the two deliberately do not sum to the same number.
- Recording a content view now emits a `[:kiln_cms, :analytics, :view]`
  `:telemetry` event (measurement `count`, metadata `type` and `content_id`),
  with a matching `kiln_cms.analytics.view.count` metric tagged by content type.
  External sinks can graph read traffic without polling the analytics tables.
  See `docs/observability.md`.
- `Kiln.Version` — a running instance can now report its release version, and
  the git SHA and build date baked in by the Dockerfile (`--build-arg GIT_SHA`
  / `BUILD_DATE`). Images built without those args still boot and simply report
  no build stamp.
- `mix kiln.update` — moves a downstream project's pinned Kiln checkout
  (submodule or fetched ref, at whatever path the project uses) to a tagged
  upstream release, reporting the changelog and any new migrations first.
  `--check` reports without changing anything. It must be run from inside the
  Kiln checkout and refuses to run anywhere else, so it cannot mistake a
  project repo's tags, migrations or changelog for Kiln's.
- An admin-only update notice showing the running version against the latest
  upstream release, plus the command to apply it. Set `KILN_PIN_PATH` to have
  that page prefix the command with a `cd` into your pin; left unset it gives
  a layout-agnostic instruction, since an image has no checkout to look in.
- `.tool-versions` is now the single source of truth for the Elixir/OTP
  toolchain. CI's seven `setup-beam` steps read it via `version-file:` instead
  of restating a loose `"1.19"`/`"27"` that resolved to whatever was newest, and
  the new `mix kiln.toolchain.check` (in `precommit` and CI) fails when the
  Dockerfile's ARGs or `mix.exs`'s `elixir:` requirement drift from it. This is
  the gate that would have caught the release image sitting on Elixir 1.18.4
  against a `~> 1.19` requirement — a build that could not succeed, green on
  every CI job because none of them builds that image.
- The update check is no longer nailed to this repo. **Forks should set
  `KILN_UPDATE_REPO=owner/name`**: left on the default they are told about
  upstream's releases, and a fork *ahead* of upstream compares as newer, so the
  page reports "Up to date" indefinitely and the fork's own security releases
  never surface. `KILN_UPDATE_RELEASES_URL` additionally repoints the API
  endpoint for GitHub Enterprise or an internal mirror. A value that isn't
  `owner/name` is rejected rather than silently replaced by the default.
- Media stored on S3/MinIO is now uploaded with `Cache-Control: public,
  max-age=31536000, immutable`, so a CDN in front of the bucket can cache
  originals and variants indefinitely. Safe because storage keys are write-once
  UUIDs. Local-adapter media already sent this header. Existing objects keep
  whatever metadata they were uploaded with — re-upload or set it bucket-side
  if you want them covered. New CDN deployment guide in `docs/media-pipeline.md`.
- Media stored on S3/MinIO is now uploaded with `Content-Disposition:
  attachment`, closing half the gap against Local-adapter media, which has
  always carried it. Rendering is unaffected — disposition is ignored for
  `<img>` and other subresource loads. As above, existing objects keep the
  metadata they were uploaded with. The companion `X-Content-Type-Options:
  nosniff` **cannot** be set as S3 object metadata and remains an operator
  task; `docs/media-pipeline.md` now documents it per CDN.

### Security

- **History anchors carry a signed position, so the chain can no longer be
  reordered or silently holed.** Two ways to move the verification baseline
  without deleting anything the chain would notice, both closed (#597, #666).

  **Reordering.** `Chain.verify/4` takes the *latest* anchor as its baseline, and
  "latest" was decided by `inserted_at` — a column written by the database and
  attested by nothing. So `UPDATE history_anchors SET inserted_at = now() WHERE
  id = <an older, shorter anchor>` made that anchor the baseline: the doctored
  versions then sat outside the anchored prefix and were never hashed, and the
  verdict was `:verified` with not a single row deleted. Anchors now carry a
  1-based per-document `sequence`, assigned at write time and inside the signed
  payload (v4), and that is what they are read in the order of. Repointing it
  breaks the signature, exactly as repointing the fold boundary does since #598.

  **Holes.** The predecessor links added in #591 catch a middle anchor removed
  while its successor survives. They do not catch it when the successor goes too
  — every surviving link still resolves. The sequence does: the run is then
  `[7, 6, 3, 2, 1]` and the gap is visible. `prev_anchor_id` also gains
  `ON DELETE RESTRICT`, which is what forces the attacker into that shape, since
  a middle anchor can no longer be removed on its own.

  Be precise about what `RESTRICT` does **not** buy, because the stronger reading
  is wrong and worth pinning: Postgres checks the constraint after the
  statement's rows are gone, so `DELETE … WHERE source_id = …` removes referrer
  and referent together and succeeds. It narrows the attack to the shape the
  sequence catches; it does not stop a wipe. Both behaviours have tests.

  **Still open, and stated rather than implied.** Deleting the *newest* anchors
  is undetectable. Nothing points at the newest one, so a shorter chain is
  indistinguishable from a younger one, and no state inside the document's own
  anchor set can tell them apart — which is why #666 stays open for a witness
  outside the database (an append-only log, retention-locked object storage, a
  transparency log). On an unsigned deployment (`KILN_PROVENANCE_PRIVATE_KEY`
  unset, the default) the sequence is an ordinary column and the whole thing is
  advisory, the same caveat the predecessor link already carried.

  Existing anchors keep verifying: `sequence` is null on them, they sort after
  every sequenced anchor (which is where they belong), a null is skipped rather
  than read as a gap, and the v3/v2/v1 payload shapes are still offered. An
  anchor that *has* a sequence is only ever checked against the v4 shape, so one
  cannot be written into an older anchor after the fact. (#597, #666)

- **A LiveView join with no URL is refused instead of skipping every router
  gate.** LiveView's channel has a catch-all for a join payload carrying
  neither `"url"` nor `"redirect"`: it matches no route, and Phoenix attaches a
  `live_session`'s `on_mount` hooks only when a route matched. So such a join ran
  none of the authoring gates — not `:current_user`, not `:assign_current_org`,
  and not `:live_editor_required` / `:live_admin_required`, which are the
  router-level RBAC for `/editor/*` and the admin console. The credential needed
  to try it is the signed `data-phx-session` blob, scraped from any page the
  caller was legitimately served — a token that outlives both the visit and a
  later demotion.

  Nothing rendered before this either, and the sweep says so: all 26 authoring
  routes refused. But 24 of them refused by *raising* — usually `KeyError` on
  `:current_user`, the assign the skipped hook was supposed to set — and two
  (`/editor/billing`, `/editor/system`) refused cleanly only because they also
  gate in their own `mount/3`. That is fail-closed by accident. Every probe cost
  an unhandled exception and a crash report, and the property held only for as
  long as every LiveView happened to read an assign the router had promised it;
  a new LiveView reading none would have mounted and rendered, ungated.

  `KilnCMSWeb.LiveRouteGuard` makes the refusal deliberate and uniform. It has to
  hang off the view rather than the `live_session`, because the router's hooks
  are precisely what does not run — what survives is the `on_mount` list declared
  by the LiveView module, so `use KilnCMSWeb, :live_view` declares it and every
  one of Kiln's views carries it. A test walks the router and fails if any `live`
  route's view does not, which also covers plugin panels: `KilnCMSWeb.PluginRouter`
  compiles third-party modules straight into the admin-gated `live_session`, so
  "plugins follow the convention" needed to be enforced rather than assumed.

  It refuses a connected join that matched no route **and whose session names a
  `live_session`** — the second half is what makes the first safe. A *sticky*
  `live_render` child is signed with no parent pid and the parent's router, which
  is what lets it outlive the parent, so by the framework's own definition it is
  a "main" session, and the JS client deliberately sends it no URL. Refusing on
  "root with no route" would 404 every sticky child, and since the client turns a
  404 into a page reload, the reload would re-render the child and 404 again — a
  loop rather than a degradation. `socket.sticky?` cannot be the exemption
  either: it is unsigned client input, so keying off it would let a scraped root
  token through by adding one field. `live_session_name` is signed, is always
  present on a root session and never on a nested one, and reads as the question
  actually worth asking — were there `live_session` hooks that should have run,
  and didn't?

  `plug_status: 404` puts the refusal in the range the channel turns into a
  client reload rather than a process crash, so a url-less probe costs no crash
  report and an honest client reloads through the router, where every gate runs.
  (A *malformed* join — say `"url" => nil` — still crashes: that happens in the
  channel before any mount hook, so it is outside what this can reach.) Every
  refusal logs at debug, matching the existing refusal in `LiveUserAuth`: a line
  per refusal is client-triggerable and therefore an unbounded write, but an
  operator investigating a stolen token can drop the level and see which views it
  was replayed against. Third-party LiveViews keep the framework behaviour:
  AshAdmin's are compile-gated to `:dev_routes`, and AshAuthentication's sign-in
  views are unauthenticated — a url-less join to one reaches no authorization it
  could not reach signed out, though it does skip `:assign_current_org` and so
  wears the default org's branding rather than the host's. (#688)

- **The session cookie is `__Host-`-prefixed in production.** It carried no
  `Domain`, which makes it host-scoped for *reads* — but RFC 6265 puts no such
  limit on *writes*. Every org is a sibling host under one registrable domain
  (`<slug>.<base_host>`), so script running on any tenant origin could set
  `_kiln_cms_key; Domain=.<base_host>`, and the browser would then send two
  cookies of that name to a sibling.

  Which one is honoured is not a race the victim might win. Plug builds its
  cookie map so the **first** pair in the header survives, and RFC 6265 §5.4
  sends longer `Path`s first — so `Domain=.<base_host>; Path=/editor` outranks
  the victim's own `Path=/` cookie on exactly the authoring routes worth taking.
  Planting the cookie in a browser with no session yet works just as well, and
  survives sign-out, because the server only ever deletes a cookie it set
  itself. The victim then browses another org inside a session the attacker
  controls. The origins that can run script are not hypothetical — a stored XSS
  on the attacker's own tenant, a dangling subdomain, and #490's per-org code
  injection, which is *designed* to run an org admin's script there.

  `__Host-` is the only mechanism that makes host-scoping structural rather than
  conventional, and it closes the hole at the source rather than at the tie: the
  browser refuses to *store* a cookie of that name unless it is `Secure`,
  `Path=/`, and carries no `Domain`, so the sibling origin's write never
  happens. That is already the shape Kiln configures, so the prefix costs
  nothing except that it cannot be used without `Secure` — and dev, test and e2e
  run over plain HTTP. It therefore rides the same `:secure_session_cookie` flag
  as `Secure` itself, in one expression, so the two cannot drift apart and leave
  the browser silently discarding every session.

  The cookie's whole shape now lives in `KilnCMSWeb.SessionCookie` rather than
  in the endpoint, because the production shape is the one no test build ever
  emits: the suite constructs `options(true)` directly, drives it through
  `Plug.Session`, and asserts the emitted `Set-Cookie` satisfies every
  precondition the browser enforces — plus that `config/prod.exs` still asks for
  the flag at all, read the way a release reads it. A non-boolean value raises
  by name instead of being coerced, since `"false"` is truthy and would
  otherwise pair `Secure` with the unprefixed name. Renaming the cookie signs
  everyone out once — see **Upgrading**. (#686)

- **The shared token preview wears the requesting site's branding too.** The
  same bare `<Layouts.public>` as the error templates below, on
  `/preview/<token>/live`: `current_org` defaults to `nil`, which resolves the
  **default organization**, so an editor sharing a draft with an external
  reviewer sent them their content wrapped in some other site's name and logo.
  The assign was already populated by the route's `:assign_current_org` hook.

  A preview link is designed to be forwarded, so branding it does reveal which
  site a draft belongs to — the right trade against the alternative it replaces,
  which was revealing a *different* site's identity. This was the last bare
  `<Layouts.public>` in the codebase. (#680)

- **Error pages now wear the requesting site's branding, not the default org's.**
  All three templates (403, 404, 500) opened with a bare `<Layouts.public>` and
  passed no `current_org`. That attr defaults to `nil`, and
  `KilnCMS.Branding.for_org(nil)` resolves the **default organization** — so a
  404 on `acme.example.com` rendered another site's `site_name` and logo. The
  whole point of white-labelling (#48) is that a tenant's visitors never see
  another tenant's identity, and an error page is still that tenant's page.

  The assign was already there, and the page was already half using it: the root
  layout read `current_org` for the `<title>`, the favicon and the brand colour
  tokens, so an error page on a tenant's host carried the right title above the
  wrong header — self-contradictory rather than uniformly wrong, which is a good
  part of why it went unnoticed. Phoenix hands the error renderer the conn that
  already passed through the router, so the resolved tenant is right there. It is read through
  a small helper rather than as `@conn.assigns[:current_org]`, because an error
  page also renders for requests that never reached `SetTenant` — an exception
  in an earlier plug, a template rendered directly — where there is no `:conn`
  assign to dereference. Those keep the operator's own defaults, which is the
  right answer and must not itself be an error. (#656)

- **`TENANT_STRICT_HOST` refusals no longer cost a database lookup every time.**
  A refused request is halted in the endpoint, above the router — and every rate
  limiter lives in a router *pipeline*, so turning strict host matching on took
  that path out of the `:delivery` ceiling and left one uncached organization
  lookup per request, metered by nothing. A scan across made-up `Host` headers
  therefore cost a round trip each, and enabling a safety control made this
  particular flood cheaper for the attacker than leaving it off.

  Host → organization resolution moves to `KilnCMS.Cache.Hosts`, a cache of its
  own, and unresolvable hosts are now cached as **misses**. They could not be
  before: in the shared content cache a flood of invented hosts would have
  inserted an entry each and evicted hot published pages, so a `nil` was
  deliberately never committed. On a separate, separately-bounded cache a flood
  evicts only other host entries. A repeated flood now costs one lookup per
  distinct host per minute instead of one per request. The negative TTL is one
  minute against the positive five, so a newly-configured host starts working
  promptly.

  A flood of *distinct* hosts still costs a lookup each, deliberately. The
  alternative considered and rejected was a per-IP budget that refuses without
  resolving: it cannot tell a flood from a legitimate request behind the same
  NAT, CDN, or collapsed `X-Forwarded-For` (the default when `TRUSTED_PROXIES`
  is unset), so it can 404 tenants that do exist — a worse failure than the
  bounded indexed-lookup load it prevents. Terminate unknown hosts at the proxy
  if that load matters.

  Second effect, unrelated to the refusal path: tenant resolution no longer
  evaporates whenever an editor saves a media item. `Cache.bust_published/0` is
  a whole-cache clear, so one media write on one site dropped every site's host
  resolution and made the next request for each of them pay a fresh lookup.
  (#659)

- **The strict-host 404 is documented as the tenant-name oracle it is.** An
  unknown host gets a plain-text 404, a known host with an unmatched path gets
  the branded HTML one, and the two are trivially distinguishable — so a
  dictionary sweep enumerates which org slugs and `custom_domain`s exist.
  `SetTenant`'s moduledoc claimed the 404 avoided "confirming which hostnames do
  exist", which was true of the status code and not of the body.

  Accepted rather than fixed, and now written down as such in the moduledoc and
  `docs/environment-variables.md`: making the two identical means either showing
  unknown hosts the branded page — reintroducing exactly the default-org leak
  the control exists to prevent — or degrading every tenant's real 404 to plain
  text, in order to hide names that are already public in DNS and in TLS
  certificates. A deployment whose tenant list is genuinely confidential should
  terminate unknown hosts at the proxy, which the deploy recipes already assume.
  (#659)

- **The collaborative-editing socket now authorizes every join against the
  document it names.** `CollabSocket` verifies a `Phoenix.Token` carrying a
  *user id* — minted once per editor session, valid for 24 hours — and
  `CollabChannel.join/3` checked only that the prototype flag was on and the
  client bundle was current. So a valid editor token was a key to
  `collab:<kind>:<id>` for **any document in any organization**: read its CRDT
  state, and push updates that land in the real collaborators' live editors.
  Each join now resolves the topic to a real document, loads it as the
  connecting user under the connection's org, and asks whether that user may
  **autosave** it.

  The gate is the write, not the read, and the distinction matters: they are
  separate scopes (`ReadableContentType` against `EditableContentType`, #332)
  and the read is the wider one — it also admits any published, public document
  to anybody at all. A room is bidirectional, and its terminal action is
  `Collab.Crdt.Checkpoint`, which persists through `:autosave` with
  `authorize?: false`. Gating on the read would therefore have let a reader
  author: an editor scoped to `editable_types: ["post"]` could join a page's
  room, type, disconnect, and have the checkpoint write it under no policy at
  all. Every refusal reports one "not found", so the channel answers no question
  a caller could not answer over HTTP anyway.

  The doc key is rebuilt from the resolved record rather than taken from the
  client's topic. Ash casts uuids leniently, so `collab:page:0F2E…` and
  `collab:page:0f2e…` named one document under two keys — two authoritative
  docs over one record, each invisible to the other's editors and each
  overwriting the other at checkpoint, and an unbounded supply of doc servers
  for anyone cycling the casing.

  Two things follow. The socket resolves its tenant from the connect URI like
  `/ws/gql` and `/ws/bridge`, so it is no longer the one socket
  `TENANT_STRICT_HOST` could not reach. And `Collab.Crdt.Checkpoint` — the
  server-side write-back for "every editor crashed before autosave fired" —
  writes under the document's own org instead of `default_org_id/0`
  unconditionally, which on any site but the default one meant it found no
  record and silently discarded the converged text. The socket also resolves
  the user at connect rather than carrying a bare id, so a token naming a
  deleted account is refused at the next connect instead of at the end of its
  24 hours. Not *immediately*: nothing evicts an established socket, so a live
  session keeps what it was granted until it drops — filed separately.

  Gated behind `:collab_prototype` (off in production) and editor sign-in
  throughout, so this was never an anonymous surface. Recorded as residual risk
  13 in `docs/threat-model.md`, now closed. (#655)

- **History anchors chain to each other by id and digest, narrowing the
  laundering route in #597.** The moduledoc claimed a doctored version "can
  never be re-blessed by a later write". It could: with database write access,
  doctor a version row, `DELETE` the anchors that expose it, wait for any
  anchoring write, and the fresh anchor — folded from genesis over the doctored
  rows, correctly signed — verified clean.

  Each anchor now records its predecessor's id **and a digest of that
  predecessor's contents** (hash, count, signature, and its own link columns),
  both inside the signed payload. `verify/4` walks the sequence and reports
  `{:tampered, "anchor chain broken: …"}` for a predecessor that is missing or
  altered, and stripping the link from a signed anchor fails its signature.

  **This does not close #597, and the issue stays open.** Deleting the *newest*
  anchors is still undetected — nothing points at the newest anchor, so a
  truncated chain is indistinguishable from a younger one, and it is exactly the
  newest anchors that cover the most recent versions. An attacker now deletes
  fewer rows rather than none. Wiping every anchor still reads as `unanchored`.
  And on a deployment with no signing key — the default — the link is advisory,
  since the digest is computed from public columns. All four limits are now
  stated in the moduledoc and `docs/editorial-consent.md`, and the truncation
  case is a characterisation test that will fail when it is closed. Closing it
  needs state the document's own anchor set cannot provide; tracked in #666.

  Anchors minted before this release keep verifying against their original
  signed shape, and that fallback is offered only when both link columns are
  null — so a link cannot be written into a pre-upgrade anchor after the fact.
  Adds a migration (two nullable columns); no backfill. (#597)

- **A malformed `TRUSTED_PROXIES` no longer takes the node down.** Entries were
  never trimmed — `split(",", trim: true)` drops empty segments, not whitespace —
  so `TRUSTED_PROXIES=10.0.0.0/8, 172.16.0.0/12` (a space after the comma) or a
  trailing newline from a mounted secret file reached `RemoteIp.init/1` as a
  malformed CIDR, which raises. That raise happened inside the endpoint, ahead of
  the router, and was never cached (the cache is written only on success), so it
  repeated on **every** request — including `/up`, so the orchestrator marked the
  container unhealthy, and ahead of `Sentry.PlugContext`, so the report carried no
  request context. Entries are now trimmed, and an unparseable list degrades to
  trusting no proxy — the same posture as leaving the variable unset, and the safe
  direction to fail in — with an error logged once per node naming the value. Found
  while adding the warning above, which is what makes it reachable: it tells
  operators to go and set this variable. (#564)

- `TENANT_STRICT_HOST` is read with `Config.Env.fetch/1` rather than `flag/2`, so
  leaving the variable unset no longer overwrites a project overlay's
  `config :kiln_cms, :tenant_strict_host, true` with `false` — which would have
  turned strict host matching off silently, in production, on the multi-org
  deployment most likely to have set it. The rule is about whether there is an
  overlay value to preserve: `flag/2` always writes, which is right where the
  surrounding block is rewritten wholesale anyway (`SMTP_TLS` inside the mailer
  config), and wrong for a standalone key an overlay may own. (#653)
- The site header on `/` and `/developers` now renders the requesting
  organization's logo and name. Both actions rendered `Layouts.app` without
  `current_org`, so the nil-defaulted attr fell through to the **default** org's
  branding — one tenant's identity served under another's hostname. The
  `current_org_id/1` raise added in #563 cannot catch this class, because the
  tenant is dropped at an attr rather than at that function — a component attr's
  `nil` default is indistinguishable from a forgotten one. Closes #662; #656 is
  the same shape on the error pages. (#662)
- **Embeddable forms no longer default to `frame-ancestors *`.** `EMBED_ORIGINS`
  unset resolved to `:all`, so out of the box any site on the internet could
  iframe `/forms/:slug/embed`. The embed page carries no ambient credentials — a
  cross-site iframe never receives the `SameSite=Lax` session cookie — but
  framing is itself the attack: any site could overlay the form invisibly and
  harvest into the org's own submissions table under its own branding, and form
  submission is deliberately CSRF-free, so nothing stood behind it. Unset now
  means same-origin only and cross-site embedding is opt-in. **Deployments that
  rely on embedding must set `EMBED_ORIGINS` — see Upgrading below.** (#562)
- A malformed `EMBED_ORIGINS` now closes the policy instead of widening it.
  Entries are validated as CSP host sources, and the whole value is discarded
  for the same-origin default — with a warning on stderr naming the offending
  entries — rather than applied in part. Two shapes mattered: a `*` mixed into a
  list (`EMBED_ORIGINS=*,https://acme.com`) used to render `frame-ancestors *
  https://acme.com`, i.e. wide open while looking like an allowlist; and an
  entry containing `;` used to append arbitrary directives to the header, since
  `frame-ancestors` is the last one emitted. (#562)
- An allowlist now keeps `'self'`. `EMBED_ORIGINS=https://acme.com` used to
  render `frame-ancestors https://acme.com`, silently withdrawing same-origin
  framing; it now renders `frame-ancestors 'self' https://acme.com`, so opting a
  partner site in never takes the CMS's own host out. (#562)

### Fixed

- **`audit_anchor_every_write` no longer reports untouched documents as
  tampered.** Turning it on made the audit surface it exists to strengthen read
  permanently red after two autosaves, with no tampering anywhere.

  Two changes, each correct alone, ran against each other in the same
  `after_transaction`. `AnchorVersion` anchors every write, including each
  `:autosave`, so a debounced save's version row was folded and signed
  immediately. `CoalesceAutosaveVersions` then merged the trailing autosave run
  into one snapshot (#32) — deleting the superseded rows and rewriting the
  survivor's diff. Both of those are rows an anchor had just committed to, and
  the chain folds the diff, so the anchored prefix could no longer reproduce and
  the row count no longer reached `version_count`. Either alone is fatal, and
  the verdict is permanent: no later publish clears it, and there is no
  supported way to re-anchor a document. It needed no unusual usage — autosave
  is on by default in the editor, so the one flag was enough.

  Coalescing now stops at `Chain.anchored_boundary/1` as well as at the last
  manual version, so it never touches a row inside an anchor's fold. Anything
  that mutates version rows should ask the same question; coalescing is the only
  such path in ordinary operation (`RestoreVersion` replays rows and writes a
  new version, it does not rewrite old ones — the one other path is the
  `mix kiln.promote_data` task, which moves version rows between tables and is
  tracked separately).

  Ordering the two hooks instead — coalesce first, anchor second — was the
  obvious-looking alternative and does not work, which is worth recording because
  it is the cheapest-looking way to "get coalescing back". Ash can guarantee the
  order (`after_transaction/3` takes `prepend?`), but the row a save destroys was
  anchored by the *previous* save, in a previous transaction. No intra-transaction
  ordering reaches it. The shipped fix is order-independent for the same reason,
  which is why it does not depend on Ash's hook order staying what it is today.

  Three details, because a wrong answer here destroys history that cannot be
  reconstructed. The boundary lookup **ignores the `audit_anchors_enabled` master
  kill switch**, unlike every other read in `Chain`: turning that switch off stops
  anchoring but does not delete the anchors already minted, and reading "no
  anchors" because the feature is off would let coalescing eat them and red the
  document the moment it came back on. It **never raises** — it runs after the
  editor's save has committed, where a raise reaches the LiveView rather than the
  changeset, so an unreadable `history_anchors` (migration not yet applied, a
  transient fault) answers `:unknown`. And **`:unknown` means "assume everything
  is anchored"**, so nothing is coalesced: skipping costs version rows, guessing
  costs history. `CoalesceAutosaveVersions` is now wrapped the same way for the
  same reason — tidying history must not cost an editor their save, which is the
  rule `Chain.anchor/2` and `extend/2` already followed.

  `history_anchors` gains the sort columns on its lookup index. `latest_anchor/3`
  is a top-1 by `(inserted_at, id)` descending, which on the filter columns alone
  makes Postgres fetch every anchor a document has and top-N sort them — and
  `anchor_every_write` mints one anchor per save, so an hour of debounced typing
  reaches ~1200 of them and this change asks for the latest twice per save.

  The cost is real and falls only where the flag is on: when every save is
  anchored, every autosave row is anchored the moment it is written, so there is
  never an unanchored pair to collapse and an hour of typing leaves one version
  row per debounce rather than one for the session. That is the honest form of
  the trade — the alternative is not "both", it is the false tamper verdict —
  and `docs/editorial-consent.md` now states it as the price of the setting
  alongside the per-save signature. With the flag off (the default) anchoring
  happens at publish, a publish is itself a non-autosave version, so the two
  boundaries coincide and coalescing behaves exactly as before. (#671)

- **The collaborative-editing doc supervisor is bounded.** Its
  `DynamicSupervisor` had no `max_children`, so nothing limited how many
  authoritative Yjs documents a deployment could hold open — and each one pins a
  Yex NIF document in memory and lingers ten minutes past its last client.
  `config :kiln_cms, :collab_max_documents` (default 500) now caps it, counted
  in documents open concurrently across the deployment rather than editors,
  since several editors on one document share one server. Over the ceiling, a
  join is refused with `unavailable` — a capacity answer, distinct from the
  uniform "not found" the authorization checks give — and the client falls back
  to solo editing with autosave, the same fallback it uses when the prototype is
  switched off. The refusal is logged at error level, because the only other
  symptom is editors quietly losing collaboration.

  Behind `:collab_prototype`, which is off in production, so this was never live
  exposure; it becomes load-bearing if collab graduates. #655 had already made
  the doc key the resolved record, so a client could no longer conjure several
  servers per document by varying the topic string — this bounds how many
  documents can be open at once, not how many ways there are to name one. (#676)

- **`entries_versions` had no index on `version_source_id`.** When the version
  tables' foreign keys were dropped, `pages_versions` and `posts_versions` got a
  single-column index to replace the lookup the FK had been providing;
  `entries_versions` — the table every **dynamic** content type shares — got
  neither. Every per-document version read filters on that column: the
  governance chain's fold and its keyset resume, the governance trail, autosave
  coalescing on every debounced save, and the version-history UI. On the dynamic
  tier those were sequential scans over every version of every entry in the
  deployment, growing without bound.

  All three tables now carry `(org_id, version_source_id, version_inserted_at,
  id)`, which covers the sort as well as the filter — that is the exact order
  the chain folds and pages in — and leads with the tenant column because every
  one of those reads is tenant-scoped. Declared through the shared
  `paper_trail` mixin, since AshPaperTrail generates the version resource's
  `postgres` block itself. The pre-existing single-column indexes on
  `pages_versions` and `posts_versions` are left in place: they are not a prefix
  of the new one, so they still serve a tenant-less read.

  Postgres truncates the generated index names to 63 characters and says so at
  migration time; the three remain distinct. (#672)

- **History anchoring no longer resumes its incremental fold with a SQL
  `OFFSET`.** `KilnCMS.Governance.Chain` folded "everything since the last
  anchor" by skipping `version_count` rows, which means "skip the first n rows
  of the *current* result set" — the anchored prefix only while no row ever
  becomes visible below the boundary afterwards. Two ordinary things break
  that: concurrent writes whose version rows commit out of stamp order, and
  wall-clock skew between app nodes, since `version_inserted_at` is stamped by
  whichever node performs the write. Either one made the fold skip the row it
  was meant to cover and fold the boundary row a second time, minting a
  correctly-signed anchor whose hash covers a sequence that never existed and
  whose `version_count` is one too high. Anchors now record the full sort key of
  the last version they covered (`last_version_at` alongside `last_version_id`)
  and the next fold resumes strictly after it — a position rather than a
  cardinality, stable under any commit order.

  **This does not clear the verdict, and #598 stays open for that.** A document
  that took a below-boundary row read `{:tampered, …}` before this change and
  reads it after: an earlier anchor committed to an ordering the version table
  no longer holds, so it can never reproduce, and verification recomputes from
  genesis. What changes is that the chain no longer records fabricated state,
  that anchoring logs an error the moment an uncovered row appears instead of
  it surfacing months later at an audit, and that the verdict now says how many
  rows sort inside the anchored range rather than reporting a bare hash
  mismatch indistinguishable from doctored content. Actually closing it needs a
  fold order assigned at write time rather than inferred from a wall clock,
  which also decides whether such a row counts as tampering or as a latecomer —
  a compliance-visible call, tracked separately.

  The boundary is inside the **signed** anchor payload (`v: 3`), because it
  steers which rows the next anchor covers. Without that, a single `UPDATE` to
  an unsigned column could repoint the resume past every future version: the
  fold would find nothing new, anchoring would silently stop, and the document
  would keep reading `:verified` while its history was rewritten freely. Anchors
  minted before this change carry no boundary and keep verifying under their
  original payload shape; they resume by the old count until their next anchor.
  The timestamp is stored rather than looked up from `last_version_id` because
  version rows are deleted in ordinary operation — autosave coalescing destroys
  superseded rows on every debounced save — and a boundary that vanished with
  its row would have made the fix inert on exactly the every-write
  configuration that needs it. (#598)

- **Artifacts fired before a surface-shape change are now migrated instead of
  serving the old shape forever.** `@format_version` was bumped 1 → 2 when
  `:json` gained `custom_fields` and `:json_ld` gained `contentLocation` (#601),
  but nothing read the field and nothing re-fired — so every document published
  before that deploy kept serving the v1 shape indefinitely while everything
  published after served v2, and a consumer could not tell which, because the
  field that would say so was never consulted. Meanwhile
  `docs/headless-consumer-guide.md` documented those keys as present on every
  surface. The bump was decorative, which is worse than not bumping: it looks
  like a migration happened. `Engine.read/4` and `Firing.Delivery.read_artifact/4`
  now compare a fetched row's version against the one the build writes; an older
  row is served **once** more and a re-fire is enqueued behind the request, so
  the second read has the new shape. That makes the field load-bearing, so the
  next bump of an **existing** surface needs only the bump — no deploy step for
  anyone to forget. A bump that *adds* a surface is still a `mix kiln.refire_all`
  job: there is no row for the new surface, so nothing is stale to detect.
  Convergence is eventual rather than next-request — the stale body is cached for
  up to an hour, so reads in between are cache hits on the old shape until the
  job lands. All three artifact readers migrate (delivery, the engine read, and
  the provenance manifest), so a document read through only one of them still
  converges. A row whose document can no longer be fired at all (an orphan left
  by a failed unpublish purge) re-enqueues a futile job per cache expiry —
  bounded and logged, tracked in #664.
  Enqueueing is best-effort and deduplicated by `FireWorker`'s existing unique
  window, so it can neither fail a read (delivery is expected to survive a
  database outage) nor turn a cache stampede into a firing stampede.
  `mix kiln.refire_all` still exists for an operator who would rather migrate a
  whole corpus at once — the lazy path only reaches documents that are read.
  (#615)

- **`KilnCMSWeb.Tenant.current_org_id/1` raises on a missing `:current_org`
  assign** instead of quietly returning the default org (#563). It is the
  quieter half of the same defect: the assign comes from `Plugs.SetTenant`
  (endpoint-level, so ahead of every pipeline) or the `:assign_current_org`
  on_mount hook, and any path that skipped both read the default org's data on a
  tenant's site with nothing to show for it. It now fails where such a path is
  cheapest to find — in test. `live_session :token_preview` was the one route
  group missing the hook and now carries it.

- **`DATABASE_SSL=True` no longer disables Postgres TLS.** The value was matched
  raw against `~w(true 1)`, so any capitalized or space-padded spelling missed
  and fell through to `false` — an operator explicitly asking for TLS got a
  plaintext connection, with credentials and every query crossing the network
  unencrypted, and no warning or boot failure to show for it. Only deployments
  that set the variable deliberately were affected; leaving it unset was, and
  remains, encrypted. **An unrecognized spelling now behaves differently — see
  Upgrading below.** (#606)
- Every on/off environment variable now goes through one parser,
  `KilnCMS.Config.Env` — seven call sites that previously shared no code, in
  five distinct parser shapes and three different unrecognized-value semantics.
  All of them are now trimmed and case-insensitive (`TRUE`, `On`, `" true "`),
  accept `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off`, treat a blank `FOO=`
  as unset, and keep the default with a warning on anything else — an
  unparseable value is never *interpreted*, in either direction. Alongside
  `DATABASE_SSL` this fixes `VISUAL_EDITING_ENABLED=False`, which used to leave
  the bridge on, contradicting the documentation. `ECTO_IPV6`,
  `KILN_UPDATE_CHECK`, `KILN_AUDIT_ANCHOR_EVERY_WRITE`, `SMTP_TLS` and
  `SMTP_TLS_VERIFY` all gain the wider spellings. One exclusion remains:
  `config/test.exs`'s `KILN_STRICT_TEST` cannot use the parser at all —
  compile-time config files are evaluated before any project module is on the
  code path. (#607)
- **`PHX_SERVER=false` no longer starts the web server.** Every string is truthy
  in Elixir, so the Phoenix generator's `if System.get_env("PHX_SERVER")` read an
  explicit `false`/`0`/`no`/`off` as a request to serve. It now honours those
  four spellings. Presence still enables — a blank `PHX_SERVER=` and an
  unrecognized value both start the server as before, because the variable is
  documented as "any truthy value" and reading a declared-but-empty one as
  "serve nothing" would be a silent outage. `KilnCMS.Config.Env.truthy?/1` is
  the one function with those semantics; everything else uses `flag/2` or
  `fetch/1`.
- A blank `DATABASE_SSL_CACERTFILE=` configured `verify_peer` against an empty
  path, so `:ssl` could not read the bundle and **every database connection
  failed at boot** — the opposite of the "encrypt but skip verification"
  fallback that branch exists to provide. Blank now reads as unset, like every
  other variable.
- `KILN_STAGING_FORCE` accepted only the literal `1`, so
  `KILN_STAGING_FORCE=true` read as *not* forced. It now uses the shared
  spelling table. `KILN_STAGING_SCRUB` is unchanged and deliberately still a
  sentinel word (`confirm`): typing `true` must not confirm a destructive
  scrub.
- The media library's responsive-variant list previews each variant inline
  instead of linking to it. The old per-variant "open" link announced itself as
  opening in a new tab, but media carries `Content-Disposition: attachment` on
  both storage adapters, so it downloaded a UUID-named file — misleading for
  sighted and screen-reader users alike. The copyable media URL now says so too.

### Upgrading

**Everyone is signed out once on deploy.** The session cookie is renamed from
`_kiln_cms_key` to `__Host-_kiln_cms_key` in production (#686). The browser
treats that as a different cookie, so every logged-in session ends the moment
the release goes live and editors sign in again. Nothing is lost — sessions hold
no state beyond the identity — but tell your editors rather than letting them
discover it, and avoid deploying mid-publish-window on a busy site.

Expect one confusing minute rather than a clean cut. A LiveView that was already
connected keeps running: it reconnects on its own signed token, which the rename
does not touch. So an editor with `/editor/...` open sees a page that still
works while every plain request from the same tab — an upload, a navigation, a
form post — has no session behind it, and a stale form post fails CSRF as a 403
rather than a redirect to sign-in. A reload fixes it.

There is no config to set and nothing to roll forward. The rename is
deliberately not a dual-read window: reading the old name alongside the new one
would keep accepting exactly the shadowed cookie the prefix exists to reject.

**Rolling the release back is not symmetric.** Nothing deletes the old
`_kiln_cms_key` — Plug only ever writes or clears the name it is configured
with — and signing out after the deploy revokes only the token in the *new*
cookie. So a pre-deploy cookie can still be sitting in a browser, with a token
that was never revoked, and a rollback starts honouring it again. On a shared or
kiosk browser that means the next visitor can land in someone else's session.
If you roll back, rotate `SECRET_KEY_BASE` in the same window: it invalidates
every cookie of either name.

Dev, test, and e2e are unaffected — they run over plain HTTP, where the prefix
cannot be relied on (Safari and any non-localhost dev host reject a `Secure`
cookie there), so they keep the bare name.

One debugging trap worth knowing: a production build's cookie now *requires*
HTTPS between the browser and whatever terminates TLS. If you port-forward into
a prod container and open it over plain `http://localhost`, the page renders but
signing in silently does nothing — the browser discards the cookie and there is
no server-side error to grep for. Reach it through the real origin instead.

**Set `EMBED_ORIGINS` before deploying if you embed forms on other sites.**
Until #562 the variable was unset on almost every deployment, because leaving it
unset meant "any site may embed" and the feature worked out of the box. It now
means "same-origin only", so an instance handing out the Embed-tab snippet will
serve iframes the browser discards the moment this release goes live. Nothing
errors: the CMS logs a healthy 200, and the only signal is a CSP violation in
your embedder's browser console.

```bash
grep -rn 'EMBED_ORIGINS' .env docker-compose.yml 2>/dev/null
```

No output means you are on the old open default. If any third-party site frames
one of your forms, list those sites before you redeploy:

```
EMBED_ORIGINS=https://acme.com,https://blog.acme.com
```

`EMBED_ORIGINS=*` restores the old behaviour exactly, if you would rather take
the change in a later window. Setting it is reversible either way — it is read
at boot, so a redeploy applies it, and no data changes.

Two related tightenings can reject a value that used to be accepted, in both
cases closing the policy to same-origin and warning on stderr: an entry that is
not a valid CSP host source (anything with a space, a quote, a `;` or a comma
surviving the split), and a bare `*` mixed into a list — write `EMBED_ORIGINS=*`
on its own if you mean "any site". Check `docker logs` after the first boot for
a line naming `EMBED_ORIGINS`.

On a multi-org deployment note the list is **deployment-wide**, not per-org, so
it must be the union of every org's embedder sites — and that union is also what
each org's forms become framable by (#648).

**Overlays that call `KilnCMSWeb.Tenant.current_org_id/1` or `current_org/1`
outside a request now raise.** The default-org fallback is gone (#563). Inside a
controller, or a LiveView in a `live_session` that mounts `:assign_current_org`,
nothing changes — the assign is there. A background job, a mix task, a test
helper or a component rendered outside a request that passed a hand-built map to
get "some org" should say `KilnCMS.Accounts.default_org/0` explicitly instead.

```bash
grep -rn 'Tenant.current_org' projects/
```

`TENANT_STRICT_HOST` itself needs no action: it defaults to off and every
deployment keeps its current behaviour. Before turning it on, check that every
host reaching the app is an org subdomain, an org `custom_domain`, or the
`PHX_HOST` apex. Health checks need no special handling — `/up` and `/ready`
are exempt.
**Check `DATABASE_SSL` before deploying, if you set it at all.** Tightening
#606 means an unrecognized value now keeps TLS *on* where it used to silently
turn it off. A deployment that reached for a libpq `sslmode` spelling —
`DATABASE_SSL=disable`, `=none`, `=require` — was getting a plaintext
connection and will now attempt TLS. Against a Postgres that cannot offer it,
that is a **failure to connect on boot** rather than a silent downgrade.

```bash
grep -rn 'DATABASE_SSL' .env docker-compose.yml 2>/dev/null
```

Unset is unaffected (encrypted, as before), and so are `false`/`0`/`no`/`off`
— use one of those if you genuinely need an unencrypted connection. Anything
else now logs a warning to stderr on boot naming the variable, so a misspelling
is visible in `docker logs` rather than silent.

The same tightening applies to `VISUAL_EDITING_ENABLED` (an unrecognized value
no longer leaves the bridge on by accident of parsing) and to `SMTP_TLS` /
`SMTP_TLS_VERIFY` (`0`/`no`/`off`/`False` now disable, where only the exact
string `false` did before). Neither can break a boot.

**Check `PHX_SERVER` too, if you set it to something false-looking.**
`PHX_SERVER=false` (and `0`/`no`/`off`) used to start the web server anyway;
they now do what they say. If a deployment has been relying on that — the
variable set to a false spelling while still expecting HTTP — the release will
boot, migrate, and serve nothing, and the Docker healthcheck cannot tell the
difference. Set it to `true`, or leave it to `bin/server`. A blank
`PHX_SERVER=` still starts the server, unchanged.

```bash
grep -rn 'PHX_SERVER\|KILN_STAGING_FORCE' .env docker-compose.yml 2>/dev/null
```

`KILN_STAGING_FORCE` now accepts the full spelling table, so a value that was
previously ignored (`true`, `yes`, `on`) now genuinely skips the
ephemeral-name check on `mix kiln.staging.scrub`. It still cannot scrub
anything on its own — `KILN_STAGING_SCRUB=confirm` is required either way.

## [0.1.0]

First tagged release. Everything before this point shipped untagged on `main`;
downstream projects pinned arbitrary SHAs, and there was no way for a deployed
instance to say which Kiln it was running.

This release adds no features of its own — it establishes the version baseline
that `mix kiln.update` compares against.

### Upgrading

If your project pins a SHA from before this tag, your first update is the only
one that can't be described by a changelog diff. Before moving the pin:

1. Check `git log --oneline <your-pinned-sha>..v0.1.0` in `kiln/upstream` to
   see what you're taking on.
2. Diff the migrations you haven't run:
   `git diff --stat <your-pinned-sha>..v0.1.0 -- priv/repo/migrations`.
3. Take a database backup (`scripts/backup.sh`) — pre-baseline pins predate the
   upgrade-notes contract, so nothing guarantees those migrations are reversible.

After this release, `mix kiln.update --check` does all of the above for you.

[Unreleased]: https://github.com/The-Verscienta/kiln_cms/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.1.0
