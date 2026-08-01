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
  Static files and `/ws/collab` are outside the control by design — see
  `docs/environment-variables.md`, which has the reasoning and a new
  multi-tenancy section. The health probes and the payment-provider webhook are
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
