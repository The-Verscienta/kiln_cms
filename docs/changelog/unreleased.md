# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="memberships-can-notify-other-systems-membershipactivated-and-membershipcanceled"></a>

- **Memberships can notify other systems: `membership.activated` and
  `membership.canceled` webhook events.** They fire when a paid membership starts
  or stops granting access — not on renewals or dunning retries — so a
  subscribed endpoint can provision a hosted account, sync a CRM, or revoke
  either without talking to the payment provider. The event is enqueued in the
  same transaction as the access change and delivered after it commits, with
  retries and an `event_id` to dedupe on. The payload carries the member's
  email; `docs/data-flows.md` records the flow. Opt-in per endpoint.
  ([#334](https://github.com/The-Verscienta/kiln_cms/issues/334))

<a id="one-click-deploy-templates-for-render-railway-flyio-and-digitalocean"></a>

- **One-click deploy templates for Render, Railway, Fly.io and DigitalOcean.**
  `render.yaml` (with a Deploy to Render button), `fly.toml`, `.do/app.yaml`
  and a Railway recipe each run the published image at a pinned tag, with
  Postgres 17 and pgvector and with media kept across restarts. The steps,
  costs and caveats for each are in `docs/deploy-platforms.md`, including
  what none of them solves yet: no platform documents its proxy's address
  range, so per-IP rate limiting behind one is per-deployment until a
  follow-up reads the platform's client-IP header. None has yet been deployed
  end to end; the page says so.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

<a id="kilnmediaroot-a-stable-directory-for-local-media"></a>

- **`KILN_MEDIA_ROOT`: a stable directory for local media.** Unset, the Local
  storage adapter writes under the release's own `priv/uploads` — in the image
  `/app/lib/kiln_cms-<version>/priv/uploads`, a path that moves with every
  version, so no volume could be mounted to keep uploads across an upgrade or
  a PaaS restart. Set, public files go to `<dir>/public` (served at
  `/uploads`, which now reads the adapter's root per request instead of a
  compiled-in path) and private ones to `<dir>/private`. The in-app backup and
  `scripts/backup.sh` default `MEDIA_DIR` to it, the image creates
  `/app/media` owned by `nobody`, and boot reports a directory the app cannot
  write to. Ignored under S3.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

## Changed

<a id="the-dependency-audit-also-reads-hexs-own-advisory-feed"></a>

- **The dependency audit also reads Hex's own advisory feed.** `mix deps.audit` reads
  mirego's mirror of the Elixir advisory database, and on 2026-09-18 that
  mirror knew none of the 89 advisories — six CRITICAL, all in
  `ash_authentication` — that Hex's own feed listed against the v0.9.0 lock,
  so the gate passed green. `mix hex.audit` reads Hex's feed and now runs
  beside it in `mix precommit` and in the `Dependency audit` CI job. Both stay:
  the two databases are maintained separately and neither is a superset of the
  other. An advisory with no fixed release is acknowledged in the `:hex`
  section of `mix.exs`, not skipped.

<a id="string-lengths-are-counted-in-codepoints-as-postgres-counts-them"></a>

- **String lengths are counted in codepoints, as Postgres counts them.** Ash 3.33 refuses to
  compile until a project chooses how `max_length`, `min_length` and
  `string_length` count. Kiln picks `:codepoints`, the count Postgres uses, so
  a length validated in Elixir agrees with one enforced atomically in the
  database, and a field's `max_length` bounds the bytes actually stored. The
  old count was graphemes, where one grapheme can carry any number of
  combining characters; a value that only passed because of that gap is now
  rejected with the same validation error as any other over-long string.

## Fixed

<a id="mix-setup-stops-early-with-the-real-reason-when-the-checkouts-path-has-a-space"></a>

- **`mix setup` stops early, with the real reason, when the checkout's path has
  a space.** Only one dependency cannot compile under such a path:
  `picosat_elixir`, whose Makefile uses absolute paths as make targets. It used
  to fail late, with an error telling you to install gcc and make. The docs said
  every native dependency failed there, and that removing `igniter` crashed the
  compiler. Neither is true, and the docs now say what is. The upstream fix is
  [bitwalker/picosat_elixir#14](https://github.com/bitwalker/picosat_elixir/pull/14),
  not yet released.
  ([#1321](https://github.com/The-Verscienta/kiln_cms/issues/1321))

<a id="buttons-links-badges-and-fields-that-rendered-unstyled-now-look-like-what-they"></a>

- **Buttons, links, badges and fields that rendered unstyled now look like what
  they are.** The console's component kit borrows DaisyUI's class names without
  the dependency, and a dozen templates still used DaisyUI classes the kit never
  defined — so they compiled, rendered, and styled nothing. "Turn on outbound
  checking" on `/editor/links` read as plain text: `<.button class="…">`
  replaced the component's own `btn btn-primary` classes instead of adding to
  them, which also stripped mail settings' "Unsuppress". The same shape was
  behind the social accounts "Remove" button (`btn-error`), sixteen `class="link"`
  anchors that Tailwind's preflight had reduced to body text, borderless date and
  note fields in the editor's task form (`input`, `textarea`), status pills on
  experiments, federation and governance (`badge-*`, now `<.badge>`), the error
  on a passphrase-protected page (`alert`), and oversized `btn-xs` buttons. The
  kit gains `.link` and `.field-label` for the call sites that already used them,
  and a test now fails on any DaisyUI-named class in the web layer that
  `assets/css/app.css` does not define.

<a id="a-paas-health-check-no-longer-gets-a-redirect-and-phxhost-falls-back-to-the"></a>

- **A PaaS health check no longer gets a redirect, and `PHX_HOST` falls back
  to the platform's hostname.** `force_ssl` answered a platform's
  plain-HTTP probe of `/up` with a 301, which a platform that counts only 2xx
  reads as a failed deploy; `/live` and `/up` now answer over plain HTTP
  (`/ready`, which carries queue depths, still redirects). With `PHX_HOST`
  unset or blank the host is now `RENDER_EXTERNAL_HOSTNAME`,
  `RAILWAY_PUBLIC_DOMAIN` or `<FLY_APP_NAME>.fly.dev` before `example.com`, so
  a fresh deploy's editor connects; a blank `PHX_HOST` used to become an empty
  host.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

## Security

<a id="every-advisory-published-against-the-090-dependency-set-is-fixed-including-six"></a>

- **Every advisory published against the 0.9.0 dependency set is fixed, including six CRITICAL in `ash_authentication`.** The lock behind v0.9.0 carried
  89 open advisories across 17 packages: 6 CRITICAL, 23 HIGH, 28 MEDIUM, 32
  LOW. The CRITICAL ones were all in `ash_authentication` 4.14.1 and
  `ash_authentication_phoenix` 2.17.1: a revoked session was still accepted
  because the `jti` was never checked on read (CVE-2026-86533), the
  remember-me guard read a session key nothing wrote, so a remembered sign-in
  could replace the session (CVE-2026-76949), magic-link tokens could be
  replayed through a check-then-use race (CVE-2026-82761),
  `require_confirmed_with` was not enforced on the action and failed open
  (CVE-2026-85500), and an OAuth2 sign-in attached to an existing account
  without comparing emails (CVE-2026-88952). Among the HIGHs: session
  fixation because the session id was not renewed on sign-in, a
  purpose-limited JWT accepted as a bearer token, a confirmation token
  accepted on any record, a sign-in token minted for one resource accepted by
  another, and superlinear base62 decoding in API-key sign-in. Every one is
  closed by `ash_authentication` 4.15.0 and `ash_authentication_phoenix`
  2.17.4. Kiln already used the sign-out confirmation page that 2.17.x makes
  the default, and its two-factor pending-sign-in tokens keep their own `jti`
  ledger, so no route, form or session shape changed. The rest of the set is
  fixed by moving every affected package to its patched release within its
  existing constraint — `ash` 3.33.6 (a filter injection through a forged
  keyset cursor), `ash_postgres` 2.13.1 (`rename_tenant` reporting success on
  failure), `ash_phoenix` 2.3.25 (a nil tenant in the subdomain hook),
  `ash_admin` 1.3.2 (stored XSS, atom exhaustion, cookie shadowing from a
  sibling subdomain, path traversal in uploads), `ash_graphql` 1.12.0
  (cross-tenant subscription disclosure, complexity-limit bypass), `bandit`
  1.12.5 and `mint` 1.10.0 (connection-pinning and memory-exhaustion DoS),
  `html_sanitize_ex` 1.5.5 (quadratic backtracking in the CSS scrubber),
  plus `ash_sql`, `ash_oban`, `ash_paper_trail`, `postgrex`, `igniter`,
  `phoenix_live_view` and `ymlr` — and by two constraint bumps: `ash_ai` to
  `~> 1.0` (an EEx evaluation of prompt content that was remote code
  execution, an identity-tool filter that took operator maps, an MCP origin
  check that a spoofed `X-Forwarded-Proto` bypassed, and leaked provider
  errors; its one breaking change, `req_llm` becoming optional, was already
  anticipated by declaring `req_llm` directly) and the dev-only `usage_rules`
  to `~> 1.2`. `mix hex.audit` reports the lock clean.

