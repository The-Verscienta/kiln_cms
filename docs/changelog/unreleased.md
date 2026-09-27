# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="if-your-overlay-compiles-with-warnings-as-errors-check-its-block-migrate-chains-first"></a>

- **If your overlay compiles with `--warnings-as-errors`, check its blocks'
  `migrate` chains first.** This release warns at compile time when a
  `Kiln.Block`'s `migrate` steps skip a version, run backwards, overshoot the
  declared `version`, or start two steps at the same version. Under
  `mix compile --warnings-as-errors` that warning fails the build, so an
  overlay's CI can go red on upgrade with no change of its own. Compile the
  overlay against this release once; for each block the warning names,
  declare the missing `migrate` step. A block with a gap already has stored
  data its renderer cannot read correctly, and the upcaster now refuses to
  mark it current
  ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642)).

<a id="a-new-throttlecounters-table-holds-the-auth-budgets-run-migrations-as"></a>

- **A new `throttle_counters` table holds the auth budgets; run migrations as
  usual.** `bin/migrate` (or the release's own migrate step) creates it. No
  configuration changes. The order does not matter on a rolling deploy: until
  the table exists, each node counts its budgets locally, as every release
  before this one did, and logs that it is doing so at most once a minute.
  Counts are not carried over from the old in-memory tables, so every budget
  starts empty on upgrade, exactly as it did after any restart. An Oban cron
  job in the `default` queue prunes closed windows every five minutes. (#1619)

<a id="a-site-whose-code-injection-snippet-opens-a-websocket-to-its-vendor-must"></a>

- **A site whose code-injection snippet opens a websocket to its vendor must
  now list that `wss://` origin under Connections.** The stock `connect-src`
  no longer carries `ws: wss:` (see Security), and an `https://` source does
  not admit a `wss://` URL, so a chat or live-analytics widget pasted into
  Settings → Code injection that talks to its vendor over a websocket is
  refused by the browser after the upgrade — look for a `connect-src`
  violation naming a `wss://` URL in the public site's console. Add that
  origin (e.g. `wss://relay.widget.example`) to the Connections list; the
  field now accepts `wss://` origins, and only that field does. A snippet that
  only `fetch`es or beacons needs nothing
  ([#1615](https://github.com/The-Verscienta/kiln_cms/issues/1615)).

<a id="before-upgrading-make-every-webhook-receiver-verify-x-kilncms-webhook-signature"></a>

- **Before upgrading, make every webhook receiver verify
  `x-kilncms-webhook-signature`.** From this release a delivery no longer
  carries the body-only `x-kilncms-signature`, so a receiver that checks only
  that header rejects every delivery (or, if it treats a missing header as
  "unsigned, accept", stops verifying at all). Switch each receiver to the
  timestamped header first — both headers have been sent on every delivery
  since 0.10.0, so the switch needs no coordination with the upgrade. Use
  `verifyWebhook` from the JS client, `KilnClient.Webhook.verify/4` from the
  Elixir client, or the procedure in `docs/webhooks.md`: split the header into
  `t` and `v1`, reject a `t` more than 300 seconds from your clock, and compare
  `v1` in constant time with the HMAC-SHA256 of `"<t>.<raw body>"` under the
  endpoint's secret. Deliveries already queued when you upgrade go out with
  the new headers only
  ([#1616](https://github.com/The-Verscienta/kiln_cms/issues/1616)).

## Breaking

<a id="webhook-deliveries-no-longer-send-x-kilncms-signature"></a>

- **Webhook deliveries no longer send `x-kilncms-signature`.** The body-only
  HMAC, deprecated in 0.10.0, proved a delivery's origin but not its
  freshness: a captured request replayed to a receiver that checked only that
  header verified forever. `x-kilncms-webhook-signature: t=<unix>,v1=<hex>`
  (added in 0.10.0) is now the only signature, which closes threat-model residual risk
  15 for every receiver that verifies. `KilnCMS.Webhooks`' `signature/2` and
  `signature_header/0` are gone with it; `timestamped_signature/3` and
  `verify/4` are unchanged. The JS and Elixir client helpers already verified
  only the timestamped header and need no change
  ([#1616](https://github.com/The-Verscienta/kiln_cms/issues/1616)).

## Added

<a id="release-candidates-are-opt-in-everywhere-mix-kilnupdate-pre"></a>

- **Release candidates are opt-in everywhere: `mix kiln.update --pre`.** A
  `vX.Y.Z-rc.N` tag sorts above every earlier final release, so before the
  first one is pushed, each place that picks "the newest release" now skips
  pre-releases (#1541). `mix kiln.update` defaults to the highest *final*
  release; `--pre` lets a candidate count, and `--to v1.0.0-rc.1` names one.
  A pin already on a candidate is not downgraded by a plain update, and moves
  on once the final release ships. At a pre-release target the task prints
  the `[Unreleased]` changelog section's Breaking and Upgrade notes, since a
  candidate is tagged with its changes still there. `release.yml` pushes the
  exact image tag for a candidate but moves `latest` only for a final release,
  and a pre-release `client-js-v*` tag publishes to npm under `next`, not
  `latest`. `Kiln.Updates` already asked `releases/latest`, which excludes
  releases marked as pre-releases; a candidate published *without* the flag is
  now refused as `{:error, :prerelease}` instead of being offered as an
  update. `docs/releasing.md` gains "Cutting a release candidate".

## Changed

<a id="a-block-whose-migrate-steps-skip-a-version-now-warns-at-compile-time"></a>

- **A block whose `migrate` steps skip a version now warns at compile time;
  from Kiln 2.0 it is an error.** ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642))
  `Kiln.Block.MigrationChain`, a Spark verifier on the `Kiln.Block` DSL,
  checks that the `migrate` steps carry every version from 1 to the block's
  declared `version` — and names a step that runs backwards, one that
  overshoots the declared version, and two steps starting at the same version.
  Nothing in the DSL required this before, so it is a warning rather than an
  error: a block module that compiled on 0.11 still compiles. Under
  `mix compile --warnings-as-errors` it does fail the build, which is
  intended — every core block's chain is clean, and an overlay block with a
  gap has stored data that can never reach the shape its renderer reads.
  Declare the missing step. The warning becomes a compile error in Kiln 2.0.

<a id="every-surface-carries-one-label-covered-internal-or-experimental"></a>

- **Every surface carries one label: covered, internal or experimental.**
  The README's stability table and `docs/overlay-contract.md` now hold the
  same table, word for word, and `test/kiln_cms/docs/surface_labels_test.exs`
  fails when the copies differ, when a row of the contract's *Covered surfaces*
  table or an entry of its *Not covered* list is missing from the matching
  row, when an endpoint in the API guide's surfaces table has no label, or
  when one surface carries two. The README had been missing five of the
  contract's internal entries. Features that ship switched off — AI assist,
  the SEO generator, provenance, experiments, oEmbed, demo mode, compliance,
  referrer analytics, SSO, two-factor auth and the per-site integrations — are
  now labelled *supported when enabled* rather than lumped in with the
  experimental ones. Three promises move. **Newly covered:** the documented
  environment variables, and `mix kiln.update` (with its documented flags),
  `mix kiln.plugins.doctor` and `mix kiln.search.check`, the tasks the
  contract tells an overlay's CI to run. **Newly internal**, closing two of the
  contract's known soft spots: `to_markdown/1` on a block module, which is
  probed rather than declared on `Kiln.Block.Renderer` and has no test for an
  overlay's implementation, and a hand-rolled `@behaviour` when a callback is
  added — the `use` form is what the additions promise covers. Every other
  `mix kiln.*` task is labelled internal too; a release that needs you to run
  one names it in its upgrade notes. (#1542)

## Fixed

<a id="a-429s-retry-after-is-rounded-up-never-0"></a>

- **A 429's `retry-after` is rounded up, never 0.** The per-IP rate limiter
  truncated the time left in its fixed window to whole seconds, so a client
  refused in the window's last second was told `retry-after: 0` and retried
  straight back into the closed window. The docs publisher honours the header:
  it spent all three retries within a few milliseconds and failed the v0.11.0
  docs sync a moment before the window reopened. The plug now rounds the same
  way `AccountThrottle.retry_after_seconds/1` already did for the second-factor
  budget — up, and never below one. `scripts/publish_docs.exs` also waits at
  least a second on any 429 and retries up to five times, since a full sync
  (~3 requests a guide) is larger than the `:api` bucket and keeps talking to
  sites that haven't picked this fix up.

<a id="the-block-upcaster-refuses-a-gap-in-the-migrate-chain"></a>

- **The block upcaster refuses a gap in the `migrate` chain instead of
  stamping the block current.** ([#1642](https://github.com/The-Verscienta/kiln_cms/issues/1642))
  `KilnCMS.Blocks.Upcaster` walked every version from a stored block's
  `_version` to head and, where no `migrate` step existed, bumped `_version`
  anyway. The data was never transformed but was marked current, so no later
  run — lazy or the #1537 backfill — would ever migrate it. The upcaster now
  follows the declared steps and refuses when one is missing: the block comes
  back exactly as stored, `_version` included, with nothing half-applied.
  The new `try_upcast/2` and `try_upcast_block_map/1` return
  `{:error, %{kind: :missing_migration, detail: ...}}` for callers that
  report (the backfill's refusal report is the intended consumer);
  `upcast/2` and `upcast_block_map/1` keep their map-returning contract for
  read and delivery paths, which render the stored shape and log a warning
  rather than crash.

## Security

<a id="auth-budgets-now-hold-across-nodes-and-restarts"></a>

- **Auth budgets now hold across nodes and restarts.** Every
  `AccountThrottle` budget (password sign-in, the TOTP and recovery-code
  budget, the reset and magic-link mail budgets, the owner alerts) and the
  credential rate-limit buckets (`:auth`, `:register`, `:unlock`) used to count
  in each node's ETS. On N nodes an attacker got N budgets, and a deploy forgave
  every attempt. They now count in one Postgres table through
  `KilnCMS.Accounts.ThrottleStore`: one `INSERT … ON CONFLICT DO UPDATE …
  RETURNING` per charge, keyed on a SHA-256 of the key, windowed on the
  database clock, and pruned by an Oban cron job. Measured locally, a charge
  costs 0.34 ms at p50 (1.1 ms at p50 with sixteen writers on one key), against
  the ~208 ms bcrypt verification the same sign-in already pays. Nothing is
  written to the user row, so an unknown address still throttles exactly like a
  known one. If the database cannot answer, a budget falls back to counting on
  the node, which is the old bound and never a weaker one. The fallback is
  logged. A charge made inside a transaction now raises instead of being
  silently refunded by a rollback. The registration budget is therefore charged
  in `before_transaction`, so a registration that fails on a taken address
  still pays. Flood-ceiling buckets (`:api`, `:delivery`, `:gql`, …) stay per
  node on purpose. This closes threat-model residual 10. (#1619)

<a id="the-browser-csps-connect-src-is-self-alone-no-websocket-to-any"></a>

- **The browser CSP's `connect-src` is `'self'` alone — no websocket to any
  other host.** It had been `'self' ws: wss:` since the first skeleton commit,
  which let any script that got past `script-src` open a websocket to any host
  — an exfiltration channel, which is what `connect-src` exists to close. Every
  socket Kiln's own pages open is same-origin (`/live` and its longpoll
  fallback, `/ws/collab`, `/ws/gql`), and CSP3 matches `'self'` against
  `ws:`/`wss:` on the page's own host and port, so the scheme sources only ever
  admitted *other* hosts. No browser code in Kiln connects cross-origin:
  uploads ride the LiveView channel, the presigned-upload API is for API
  clients, oEmbed and Unsplash are resolved server-side, and `bridge.js` runs
  on the external front end under that site's own policy. A new Playwright
  spec (`e2e/tests/csp.spec.js`) drives the console, an editor, the media
  library, a public page and the same page on a second host name with zero
  CSP violations, and shows a socket to another origin is now refused. The
  same pass reviewed `style-src 'unsafe-inline'` (kept: templates use inline
  `style=` attributes, which cannot carry a nonce) and the runtime
  `img-src`/`media-src` widening (kept: every source is operator
  configuration, a fixed provider list, or the site's own bucket origin);
  threat-model residual 12 now records the reviewed policy
  ([#1615](https://github.com/The-Verscienta/kiln_cms/issues/1615)).

<a id="the-audience-checkboxes-on-editor-accounts-edit-the-site-membership"></a>

- **The audience checkboxes on `/editor/accounts` edit the site membership, not
  the deprecated global column.** They wrote only `User.audiences`, which grants
  access solely through the no-membership fallback 0.12 deprecates. For any
  account holding a membership, which includes every account
  `mix kiln.deprecations --migrate-audiences` moves, a tick saved and changed
  nothing, and no console page edited `OrgMembership.audiences` at all. They now
  write the account's membership on the site the page is served from, in their
  own form beside the platform role, and the console no longer writes
  `User.audiences`. An account with no membership there gets one on the first
  save with the tier it already holds, so it changes what the account reads and
  never what it authors; a membership-less account edited from another site is
  first carried onto the default org, so a legacy editor keeps its tier there.
  See [Paid memberships](../memberships.md#editing-audiences-from-the-console).
  (#1646)

<a id="paying-for-a-membership-no-longer-demotes-a-legacy-editor"></a>

- **Paying for a membership no longer demotes a legacy editor.** Billing gives
  a buyer a `:viewer` membership on each org they paid on. For an account with
  no memberships at all, whose tier comes from `User.role`, that first
  membership ended the no-membership fallback: buying on the default org made a
  legacy editor a viewer there, and buying on another org left it with no tier
  and no audiences on the default org. The recompute now first gives such an
  account a default-org membership carrying its standing role, any live
  temporary role with its expiry, and its `User.audiences`, then adds the paid
  membership. The console's audience checkboxes already took this step (#1646);
  both now share `KilnCMS.Accounts.LegacyAffiliation`. Billing's membership
  writes are also upserts now, so two recomputes racing for one account no
  longer collide on the unique index.
  See [Paid memberships](../memberships.md#the-first-paid-membership).
  (#1649)
