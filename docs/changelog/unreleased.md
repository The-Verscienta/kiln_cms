# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="run-mix-kilnblocksbackfill-once-after-deploying"></a>

- **Run `mix kiln.blocks.backfill` once after deploying. It is safe on the live
  site, and it rewrites stored blocks — rolling the pin back does not undo
  it.** In a release image: `bin/kiln_cms eval
  'KilnCMS.Release.backfill_blocks()'`. It rewrites every block tree still stored in a pre-typed shape — rows nobody has
  saved since the typed-block storage flip, on every content type and in
  working copies — to the typed shape at rest, and converts rich text still
  held only in `legacy_html` to Portable Text where that is faithful. **It can
  run after deploy, against the live site**: each row is a compare-and-swap
  that skips a row an editor saves meanwhile, and it touches no `updated_at`,
  version history or cache. It is idempotent and resumable (run it again to
  finish an interrupted pass), and `--dry-run` shows what it would do. **It
  rewrites data, and rolling the pin back does not undo it**: older releases
  read the typed shape fine, but the legacy maps are gone, so take the backup
  you would before any data migration. A row it cannot convert without losing
  something is listed by table, id and block path and left untouched, and the
  task exits non-zero; so does a rich-text block it had to leave in
  `legacy_html`. Those rows keep reading exactly as they do today — fix them
  in the editor before 1.0, which drops the legacy read path. Then run
  `mix kiln.refire_all`: a converted rich-text block's fired `:json` artifact
  carries its prose in `body` and no longer in `legacy_html`.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

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

<a id="mix-kilnblocksbackfill-rewrites-legacy-shaped-stored-blocks-to-the-typed-shape"></a>

- **`mix kiln.blocks.backfill` rewrites legacy-shaped stored blocks to the
  typed shape.** `KilnCMS.CMS.BlockBackfill` finds every table with a
  `{:array, BlockUnion}` column from the attribute type — pages, posts, dynamic
  entries and every overlay type, `blocks` and `working_blocks` — and walks it
  in keyset batches. Per stored element it recognises the pre-flip
  `KilnCMS.CMS.Block` map, a bare `_type` map outside the union envelope, a
  block behind its head `_version` (the declared `migrate` chain runs, the
  same one the lazy read uses), legacy children inside a `columns` block, and
  rich text held only in `legacy_html`. It refuses — reports, does not write —
  a row that would lose data on conversion (a legacy `data` key, `content` or
  `children` the typed block has nowhere to keep, decided by running the
  legacy mapping both ways rather than by a second table of keys), a block
  type this build does not have, or a value that fails the union's stored
  cast. `legacy_html` is converted only when a reader could not tell: same
  words with the same breaks, and the same text under every mark, link,
  heading, list item, quote, code block and table cell; otherwise the block
  keeps it and is reported. It writes through Ecto, not an Ash action, for the
  reason `KilnCMS.Keys.Reencrypt` does, and because Ash elides a write whose
  new value compares equal to the loaded one — and a legacy row loads as the
  typed tree it would be rewritten to. Version history is not rewritten: its
  rows are folded into the governance hash chain. The conversion was run over
  a corpus of every stored shape (`test/support/legacy_block_corpus.ex`),
  checking each rewritten tree renders on `:web` and `:json` as the stored one
  did; the fixes it found are under Fixed.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

## Changed

<a id="public-delivery-the-previews-and-the-in-context-editor-render-from-the-typed"></a>

- **Public delivery, the previews and the in-context editor render from the
  typed blocks, not through the legacy block shape.** A new
  `KilnCMSWeb.BlockComponents.view_blocks/1` builds the maps `render_block/1`
  takes straight from the typed structs; delivery adds its media and form
  enrichment on top of the same maps every preview renders, so the two cannot
  drift. Nothing in the core calls `TypedBlocks.to_legacy/1` any more. Rich
  text renders through the block's own `:web` serializer — Portable Text first,
  sanitized `legacy_html` only where there is no body. Two visible
  differences on the public page: each block now carries the `data-block-id`
  anchor `render_block/1` documents (delivery's enrichment used to drop the
  id), and an image with no media-library item shows its own alt text instead
  of `alt=""`. The in-context editor's HTML compatibility path and the nested
  columns editor now write Portable Text whenever it holds the HTML
  faithfully, and the starter home page, the beta-round seeds, `seeds.exs` and
  the example overlay's import write typed blocks with Portable Text instead of
  legacy params that stored `legacy_html`.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

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

## Fixed

<a id="a-hard-line-break-in-a-paragraph-heading-quote-or-list-item-is-delivered-as-br"></a>

- **A hard line break in a paragraph, heading, quote or list item is
  delivered as `<br/>`.** `KilnCMS.Blocks.PortableText.to_html/1` rendered the
  editor's hardBreak as a bare newline everywhere but table cells, and a
  browser collapses a newline to a space — so Shift+Enter in the editor showed
  as one run-on line on the site and in every fired `:web` artifact. Found by
  the #1537 backfill corpus: it was the one thing a `<br>` in stored
  `legacy_html` could not survive conversion with.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

<a id="paragraphs-inside-a-quote-or-a-list-item-no-longer-run-together-when-saved-as"></a>

- **Paragraphs inside a quote or a list item no longer run together when saved
  as Portable Text.** A Portable Text block is one run of spans, and the
  TipTap conversion concatenated a blockquote's or list item's paragraphs with
  nothing between them — "one" and "two" became "onetwo". They are joined with
  a line break now, as table cells already were; a list or heading inside a
  quote keeps its text too, a line each, instead of being dropped. Found by
  the #1537 backfill corpus.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

<a id="a-legacy-columns-block-reads-as-a-typed-columns-block-and-an-unmapped-legacy"></a>

- **A legacy `columns` block reads as a typed `Columns` block, and an unmapped
  legacy block keeps the type name it was stored under.** The legacy→typed
  mapping had no `columns` clause, so a pre-flip columns block was an opaque
  `Custom` to search, references and the fired artifacts, and rendered as
  columns only because delivery converted it straight back. And a legacy type
  whose name was never an atom in the running build came back as
  `legacy_type: "custom"`, its real name gone from every typed read — and,
  once rewritten, from the row. Both found by the #1537 backfill corpus.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))

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

<a id="the-legacy-block-bridge-is-deprecated-for-removal-at-10"></a>

- **The legacy block bridge is deprecated for removal at 1.0:
  `KilnCMS.CMS.TypedBlocks.to_legacy/1`, `from_legacy/1`, `RichText.legacy_html`
  and the legacy `KilnCMS.CMS.Block` write shape.** `to_legacy/1` and
  `from_legacy/1` carry `@deprecated`, so a caller gets a compile warning:
  render from typed blocks (`KilnCMSWeb.BlockComponents.view_blocks/1`), and
  read stored blocks with `TypedBlocks.to_typed/1`, which accepts everything
  `from_legacy/1` did. `KilnCMS.CMS.Block` carries `@moduledoc deprecated:`:
  passing `blocks` as `%{type: :heading, content: …, data: …}` still casts
  until 1.0 — write `%{"_type" => "heading", "text" => …}`. The rich-text
  block's `legacy_html` is marked `deprecated` in the exported block JSON
  Schema, so typed clients see it at codegen time; read `body`. It is still
  rendered and round-tripped for blocks `mix kiln.blocks.backfill` could not
  convert, and dropped at 1.0 — convert those blocks before then. Version
  history keeps being read in whatever shape it was written.
  ([#1537](https://github.com/The-Verscienta/kiln_cms/issues/1537))
