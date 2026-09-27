# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="before-upgrading-to-10-let-queued-webhook-and-newsletter-jobs-from-before-012"></a>

- **Before upgrading to 1.0, let queued webhook and newsletter jobs from before
  0.12 drain, and move accounts off the legacy audiences fallback;
  `mix kiln.deprecations` says what is left.** Nothing changes in 0.12 itself.
  1.0 removes what 0.12 deprecates (#1543), and two of those removals would
  strand data rather than break a compile. First, 1.0 no longer runs webhook
  delivery, newsletter send or newsletter mail jobs enqueued without an
  `org_id` (anything a release before multi-tenancy queued, and the pre-ledger
  webhook shape). Second, 1.0 no longer reads `User.audiences` for an account
  with no organization membership, so such an account loses its gated
  content. `mix kiln.deprecations` lists both and exits non-zero while either
  is non-empty, so it can gate an upgrade script; in a release, run
  `bin/kiln_cms eval 'KilnCMS.Release.deprecations()'`. Let the jobs drain (or
  cancel them), and run `mix kiln.deprecations --migrate-audiences` to give
  each listed account a membership on the default organization carrying its
  audiences and standing role
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

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

<a id="an-unknown-option-to-use-kilncmscmscontent-now-warns-at-compile-time-instead-of"></a>

- **An unknown option to `use KilnCMS.CMS.Content` now warns at compile time
  instead of being silently ignored.** The macro read its options with
  `Keyword.get/3` and never looked at the rest, so a typo (`exerpt?: true`) or
  an option an overlay made up compiled clean and did nothing. It would also
  start doing something the day a release added an option by that name. Any
  key outside the options the macro reads now raises a compiler warning at the
  overlay's own `use` line, naming the key and the accepted set. It is a
  warning, not an error, so no overlay that compiles today stops compiling;
  2.0 makes it an error
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

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

## Security

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

## Deprecated

<a id="published-on-use-kilncmscmscontent-is-deprecated-and-removed-at-10"></a>

- **`published?:` on `use KilnCMS.CMS.Content` is deprecated, and removed at
  1.0.** The option has been ignored since every content type gained the
  `:published` read (#300); it is now a compiler warning at the overlay's
  `use` line. Remove it. `mix kiln.gen.content --published` no longer writes
  it; the flag still adds the `list_published_*` interface, and the core
  `Post` no longer passes it
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

<a id="the-editorpagesid-and-editorpostsid-editor-routes-are-deprecated-and-removed-at"></a>

- **The `/editor/pages/:id` and `/editor/posts/:id` editor routes are
  deprecated, and removed at 1.0; use `/editor/content/page/:id` and
  `/editor/content/post/:id`.** Both still open the editor, and each visit logs
  a warning naming the replacement (a route has nowhere to carry
  `@deprecated`). Nothing in the core links to them any more: workflow mail,
  task mail, the notification bell and the inbox now link pages and posts
  through `/editor/content/`, like every other type. Mail sent before this
  release still carries the old links, which is why they last until 1.0
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

<a id="the-useraudiences-fallback-for-an-account-with-no-organization-membership-is"></a>

- **The `User.audiences` fallback for an account with no organization
  membership is deprecated, and removed at 1.0.** Such an account reads gated
  content through the global `User.audiences` column, on every site. That is
  the pre-multi-tenancy model, and the one gap in the per-org audience rule.
  It still grants access, and now logs a warning once per account per boot.
  `mix kiln.deprecations` lists the affected accounts, and
  `--migrate-audiences` gives each a default-organization membership carrying
  its audiences, standing role and any live temporary role, the same step
  (`KilnCMS.Accounts.LegacyAffiliation`) billing and the console's audience
  checkboxes take. See the Upgrade notes
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

<a id="webhook-and-newsletter-jobs-enqueued-without-orgid-and-pre-ledger-webhook-jobs"></a>

- **Webhook and newsletter jobs enqueued without `org_id`, and pre-ledger
  webhook jobs, are deprecated, and not run by 1.0.** `Webhooks.DeliveryWorker`,
  `Newsletter.SendWorker` and `Newsletter.MailWorker` still run them against
  the default organization, and log a warning each time. Every job this
  release enqueues carries `org_id`. Let the queue drain before upgrading to
  1.0; see the Upgrade notes
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).
