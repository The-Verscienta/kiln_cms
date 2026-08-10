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

- **Claim checking is per site, and has a page** (#857). `KilnCMS.Compliance`
  was configured entirely in `config.exs`, which is the wrong grain on a
  multi-org install: a claims vocabulary is a statement about one publication's
  voice and jurisdiction, and `require_at_publish` is a hard publish refusal.
  One clinic deciding that "cures" cannot ship refused every other site's
  publishes on the same instance, and a tenant that wanted the panel off could
  not turn it off either.

  Each site now has a `KilnCMS.CMS.SiteCompliance` row — the panel switch, the
  publish gate, the required disclaimer, whether the deployment's rules apply,
  and its own phrase list with a severity — edited at **Claim checking**
  (`/editor/compliance`, admin only). `KilnCMS.Compliance.Settings` resolves
  that row over the existing `config :kiln_cms, KilnCMS.Compliance`, so a site
  that saves nothing inherits exactly what it inherited before and a
  single-tenant install needs no change.

  The page is also the answer to the feature being invisible: it shipped off,
  and the editor renders no Compliance panel while it is off, so nothing in the
  admin UI said it existed. A site that has not opted in now gets an explainer
  and one button, the way `/editor/links` does for outbound link checking.

  If the settings row cannot be read at all, the advisory switches fall back to
  the operator config and the **publish gate is forced off**: that is the one
  axis where guessing wrong turns a transient read error into a site that
  cannot publish, and it would be refusing on rules nobody could confirm.
### Fixed

- **A one-click translation honours the acting editor's field grants** (#1157).
  Duplication and translation are the two creates that carry *another record's*
  values, and only duplication asked what the editor was allowed to write.
  `Changes.EnforceFieldGrants` deliberately skips creates — sound for a document
  written from scratch, not for one arriving pre-filled — so an editor granted
  only `title` on a type minted a translation carrying its `seo_title`,
  `excerpt`, `audience` and custom fields, every one of which is refused when
  they try to save it on the source.

  `slug` is exempt for a reason of its own: the `[slug, locale]` identity is
  what pairs a translation to its source, so dropping it would not narrow the
  copy but sever it. Both surfaces now report what didn't travel, the way
  Duplicate has since #929.

- **The block envelope is no longer mistaken for a restricted field**, which was
  silently costing every non-admin translation its block ids. `_type`,
  `_version` and `id` share the stored map with a block's authored fields but
  are the union's own bookkeeping. Asking a *field* policy about them answered
  "no" for every non-admin, so those keys were overwritten with `nil`.

  Nulling `id` defeated `keep_ids?: true`: an admin's translation preserved the
  source's block ids and **everyone else's did not**. Those ids are persisted,
  and they are what the XLIFF vendor round-trip matches trans-units on (#502) —
  without them it falls back to matching on position, which is wrong the moment
  either side is reordered. Nulling `_version` rewrote a block's stored schema
  version to the current head, so a block still awaiting its upcast would never
  receive it; inert today, since the only migration in the tree is idempotent
  with the field's own default.

  The visible symptom was the flash: a plain editor duplicating a plain page was
  told their role could not set `heading._type`.

- **Taking a backup now needs a platform admin, and is re-checked when the
  button is pressed** (#1160). `BackupLive` did no tier check of its own, and
  `Backups.enqueue/1` takes no actor and authorizes nothing — so the route's
  `:live_admin_required` was the only gate, and it runs once, at mount. An admin
  whose role was revoked mid-session kept triggering backups for the life of the
  socket.

  It was also the wrong question. `:live_admin_required` is an *effective
  per-org* admin, while a backup is a `pg_dump` of the whole instance covering
  every tenant — so a user granted admin on one site could take one. The panel
  now asks the global question instead, and asks it again in the handler. The
  slug-regeneration console's `apply`, whose worker likewise authorizes nothing,
  gained the same re-check at its own (correctly per-org) tier.

  The overview's stale-backup warning strip moved to the same gate. It links to
  the backup panel, so leaving it on the per-org tier would have reported on the
  whole instance's infrastructure to an admin of one site and sent them to a
  page that turns them away.

- **404 capture no longer evicts real misses before attacker junk** (#920). At
  the per-org cap a new path evicts the least-requested row, and the tie among
  equal counts was broken by `last_seen_at` **ascending** — so the oldest
  one-hit row went first. That is a genuine miss recorded weeks ago, while the
  rows that caused the cap are the newest and were chosen last: a flood at the
  `:delivery` bucket's 300/min cleared every real row in under twenty minutes
  and then held the table, denying the feature the cap exists to keep
  available. The tie is now broken newest-first, so a flood can only displace
  itself.

  The eviction read also had no supporting index, so once an org was at the cap
  every anonymous 404 on a new path seq-scanned and sorted the whole table — up
  to 5,000 rows, on the public delivery path, against the pool that renders
  pages. It now has one, and the index's column **directions** match the sort:
  an all-ascending index leaves Postgres an incremental sort that degenerates
  into a full sort under exactly the flood this is about.

  The junk filter read only the last dot-separated piece of a path's basename,
  so `/.env` was dropped while `/.env.local` was recorded — and with it
  `/.ssh/id_rsa`, `/.aws/credentials`, `/.svn/entries`, `/.DS_Store`,
  `/.htaccess`, `/wp-admin` and `/actuator/health`, each spending a capped slot
  on a probe. Any path segment beginning with a dot is now junk, as are the
  scanner roots; `/wp-content` stays recordable, because after a WordPress
  migration those misses are real inbound links.

- **The ActivityPub inbox no longer fetches an actor it has no use for** (#966).
  Authenticating an inbound activity needs the sender's key, which lives in the
  sender's actor document, so a ~200-byte unauthenticated POST bought an
  outbound HTTPS GET of up to 128 KB aimed at any host the caller named — even
  for a `Like` or an `Announce`, which this phase accepts and drops. Only a
  `Follow` or `Undo{Follow}` addressed to this site's actor is fetched now, and
  fetched documents are cached for ten minutes in a capped, least-recently-
  written instance, so repeats from one actor cost one request.

- The content editor no longer offers **Duplicate** or **Create translation** to
  an actor who may open a record without being able to write it. Both fork the
  record's payload into a new draft, and both were the only write affordances in
  the editor with no `may_write?` gate; both handlers now refuse server-side as
  well, so a replayed event cannot reach the copy. (#922)

## [0.5.0] - 2026-08-09

### Added

- **A white-labelled site installs under its own icon, and its offline page
  carries its own name** (#629). The editor PWA already installed under each
  org's name and colour; the two assets that stayed stock KilnCMS were the
  install icons and `priv/static/offline.html`.

  A site now sets an **App icon URL** under `/editor/branding`. The server
  fetches it on save and measures it (`KilnCMS.Branding.AppIcon`): a square PNG
  or JPEG of at least 512×512, with the format read from the decoded bytes
  rather than the URL's extension. Only a measured icon is ever declared,
  because `icons[].sizes` is a claim Chromium's installability check believes —
  a manifest that mis-states it does not degrade, it removes the install prompt
  with nothing said anywhere. An icon that fails verification is still saved
  (a briefly-down CDN should not discard what an admin typed) but is not
  declared, and the form says which of the reasons it was.

  The offline fallback moved from `priv/static/offline.html` to
  `KilnCMSWeb.OfflineController`, so it carries the site's name and brand
  colour. It stays entirely self-contained — no stylesheet, script, image or
  font — because it renders from the service worker's cache exactly when
  nothing can be fetched.

  Two things here are easy to get backwards, and are documented at more length
  in `docs/mobile-admin-spike.md` §5.1: a verified icon is declared `any` and
  the stock **maskable** entry is withdrawn while one is in use (a maskable
  icon is cropped, and Android *prefers* one for the home screen, so leaving
  the stock entry would put the KilnCMS flame on a white-labelled home screen);
  and PNG/JPEG is narrower than the media library on purpose, because
  `apple-touch-icon` has no fallback and iOS ignores a WebP.

- **The governance dashboard says whether history is actually being witnessed**
  (#731). `chain_checkpoints.witness_error` was written on every failed
  publication and surfaced nowhere, so the only way to learn a deployment had
  been silently unwitnessed for weeks was `mix kiln.audit.checkpoint` or a log
  line from whenever it started — a healthy dashboard and an unwitnessed one
  looked identical.

  `/editor/governance` now leads with a witness panel: the configured adapter,
  the last checkpoint (sequence, what it covers, when it was published), and the
  count of checkpoints the sink has never accepted, dated by the oldest so the
  outage has a start. A document's trail names the checkpoint witnessing it and
  at what anchor position.

  "Off" and "broken" read differently on purpose. Checkpointing disabled, or no
  sink configured, are deliberate postures and get a neutral note; only a
  configured sink refusing publications is shown as a warning. A document no
  checkpoint covers gets no badge at all — that is the ordinary case for
  anything published since the last checkpoint, and a badge on every one of them
  would teach an operator to stop reading badges.

- **XLIFF 2.0 export/import for translation vendors** (#502). `/editor/translations`
  can now send content out as XLIFF 2.0 — the format Smartling, Lokalise,
  Crowdin, Phrase, memoQ and Trados all read — and apply the file that comes
  back. Tick rows, pick a target locale, **Export**; upload the returned file
  with **Import XLIFF**. A direct vendor-API connector is now a thin plugin on
  top of this seam instead of a second content pipeline.
  See [docs/localization-workflows.md](docs/localization-workflows.md).

  Trans-unit ids are built on **identity, not position** — a block's stable
  uuid and a Portable Text block's `_key` — so a file that comes back after the
  source has been reordered still lands every string. Map-array items, table
  cells and nested `columns` children are addressed by index (the last because
  they are raw maps with no readable id, #865/#954), and a unit whose path
  contains one says so in the report rather than passing as an identity match.
  Every id is a valid `xsd:NMTOKEN`, which `unit/@id` requires — a tool that
  validates on ingest rejects the whole document, not the offending unit.

  Nothing is applied silently: every unit id in the returned file is reported
  as `applied`, `unchanged` or `unknown`, plus the ones the vendor left empty
  and the ones whose match depended on ordering. An empty `<target>` never
  clears a field — a partial delivery is normal mid-job — and the whole-record
  positional fallback is all-or-nothing, because mixing it in per unit is what
  puts a paragraph in the wrong block.

  A returned file can reword an anchor but **cannot retarget a link**: hrefs
  travel into `<originalData>` as translator context, and the importer restores
  links from the `markDefs` the record already holds. Marks a file invents are
  filtered out rather than stored dangling. The reader handles what a real CAT
  tool sends back: re-segmented units (including the `<ignorable>` whitespace
  between sentences), `<sc>`/`<ec>` spanning codes, `<mrk>` annotations, and a
  rebound namespace prefix.

  **Which fields are prose is now declared on the block field**, so a plugin
  block (D18) gets the same round trip as a core one:
  `translatable: false` for an identifier-ish `:string`,
  `translatable: [:question, :answer]` for the keys of an `{:array, :map}`
  field, and `translatable: :unsupported` for text this exporter cannot
  round-trip safely (`rich_text.legacy_html`, `custom.content`) — which the
  export *reports* rather than dropping quietly. `:string` and `:rich_text`
  are prose by default, so most fields need no annotation.

- **Events: "what's on, soonest first"** (#766). An event-shaped content type —
  one carrying a `datetime_range` field (#480) — now has a paginated delivery
  index ordered by each document's **next occurrence**, at `/<plural>` (HTML)
  and `/<plural>/index.json`. Both take `?from=`/`?until=`/`?page=`; a bare date
  is read as a local day in the deployment's event timezone. Details in
  [docs/events.md](docs/events.md).

  Same filter as the `.ics` routes, for the same reason: published **and**
  `audience: :public`, one locale, unlocked. An anonymous listing that widened
  any of that would be a leak rather than a listing.

  "Next occurrence" is a function of `now()`, so it is stored: a
  `next_occurrence_at` column written on save and advanced by an hourly Oban
  sweep (`KILN_OCCURRENCE_SWEEP_CRON`, default `50 * * * *`). **That interval is
  how stale the listing may be** — an event that has finished keeps its place
  until the next run — so shorten it on a site whose events turn over during the
  day.

  What it deliberately does not do: only the *next* occurrence is stored, so a
  window starting in the future selects documents whose next date falls inside
  it, not every recurrence inside it. Making a single occurrence addressable in
  its own right is a different feature and is named as such in the docs.

- **Feed syndication is a per-site setting** (#719). `/editor/feeds` lists every
  content type a site has and lets an org admin say, per type, whether it appears
  in the site's Atom and JSON feeds and whether its entries carry the rendered
  body rather than a summary.

  Both used to be `config :kiln_cms, :feeds` only, which is the wrong grain for a
  multi-tenant install: compiled types like `post` are shared by every
  organization on a deployment, so an operator enabling `full_content: ["post"]`
  for one tenant's newsletter handed *every* tenant's complete articles to any
  anonymous scraper — and no tenant admin could opt out, because the switch lived
  in a file they cannot edit. `exclude:` inverted the same way.

  The config keys still work as the operator-level default beneath a site's own
  settings, so nothing changes for a deployment that does not open the page. An
  empty saved list means *none*, which is deliberately not the same as never
  having saved: that is what lets a site turn full content off while the
  deployment default has it on. `entry_limit` stays deployment-wide — it bounds
  server work, not a publishing choice.

  "In feeds" is the switch ActivityPub already read, so taking a type out of a
  site's feeds also stops announcing it to the fediverse; the page says so. If
  the settings row cannot be read at all, feeds fall back to summaries only
  rather than to the config, so a transient fault cannot re-enable full text for
  a site that turned it off.

- **Content experiments — A/B testing published content** (#499, phase 1).
  An experiment holds two or more **variants** of part of a published document —
  a headline, a CTA block — and measures which converts. `mix kiln.experiment`
  creates, starts and concludes them; `/editor/experiments` is phase 2. Design
  and rationale in [docs/content-experiments-plan.md](docs/content-experiments-plan.md).

  **No visitor is tracked.** Kiln has no visitor cookie and `docs/data-flows.md`
  promises it will not grow one, so assignment splits along the two surfaces:
  the built-in site assigns statelessly (a reload may show a different arm, so a
  same-page goal — a form submission — is what it can attribute), and headless
  callers pass `?variant_key=`, own stickiness themselves, and get a
  `Vary: X-Kiln-Variant-Key` response they can cache per arm.

  A variant is a **sparse patch**, keyed by field name and by a block's stable
  `_id` — so it survives block reordering, and "this one changes the CTA" stays
  reviewable rather than being a whole-document fork to diff.

  Five invariants, each with a test named after it. A variant is never fired, so
  it cannot reach a feed or Meilisearch; it never writes the document, so it
  cannot reach tsvector or embeddings; it is applied **after** the SEO assigns
  and JSON-LD are built, so `<title>`, the meta description, the canonical URL
  and the schema.org graph stay canonical; it lives on its own resource, so it
  cuts no version and triggers no re-fire. In short: **a variant changes what a
  human reads, never what a machine indexes.**

  Off by default via `KILN_EXPERIMENTS_ENABLED`, and the deployment gets a say
  because a page under a running experiment is served `private, no-store` — with
  the usual `public, max-age=60` a CDN would cache one arm and hand it to every
  visitor, which is a 100/0 split reported as 50/50. That cost is inherent to
  server-side A/B testing and is stated rather than hidden.

- **ActivityPub federation: a Kiln site as a fediverse actor** (#491, phase 1).
  A site can be followed from Mastodon, and its published content arrives in
  followers' timelines: WebFinger, an actor document, an outbox, HTTP
  Signatures both directions, and `Create`/`Update`/`Delete` delivered to
  followers on publish/edit/unpublish. `mix kiln.federation enable` turns it on
  and prints the handle; see [docs/federation.md](docs/federation.md).

  **Off unless said twice.** `KILN_FEDERATION_ENABLED` for the deployment (off
  ⇒ every route 404s, the `KilnCMS.Provenance` posture) *and* a per-site row.
  Federation is an egress decision, not an editorial one — it makes the server
  sign and POST to hosts chosen by strangers who followed the site — so an
  operator whose policy forbids it can say so once, centrally.

  Only published, `:public`-audience, default-locale content of types that
  already syndicate a feed federates. An audience-gated record is published
  *and paywalled*; three locales are three rows and would notify every follower
  three times for one article; and a type an operator kept out of the site's
  feed was not volunteered to the fediverse either.

  The actor's origin is **pinned at enable time**, not derived per request:
  an actor id is its permanent name in the fediverse, and deriving it from the
  site's current base URL would silently rename the actor the day a
  `custom_domain` was added, orphaning every follower with no way for them to
  learn the new one. Disabling keeps the identity so re-enabling restores the
  same handle and key.

  Inbound is `Follow` and `Undo{Follow}` only, each authenticated by an HTTP
  Signature checked against a key fetched from the actor named in the activity
  — a signature over one's own key claiming someone else's `keyId` is refused,
  which is what stops anyone subscribing any account's server to the firehose.
  Unsupported activities get a 202 and are dropped rather than a 4xx that would
  make the sender retry for days. Delivery is a ledger with 12 retries backing
  off to six hours, and a follower whose instance stays dead is dropped rather
  than disabled — there is nobody on the other side to notice a disabled row.

- **Reusable content fragments.** A `fragment` block embeds another document's
  body inline — define once, embed everywhere, edit the fragment and every page
  carrying it updates (#479). This is the Regular Labs / WP reusable-block /
  Contentful-reference idea, and it finishes the `:reference` field type the
  block DSL declared but stubbed.

  It is **inlined, not rendered**: `KilnCMS.CMS.Fragments.expand/3` replaces the
  block with the target's tree before any surface renderer runs (decision A3
  taken literally), so all four fired surfaces plus search text, reading time
  and the a11y report see one flat tree and need no knowledge of fragments.

  The re-fire wave needed no new machinery — `ref` is a DSL `:reference`, which
  `Firing.References` already extracts into a `ReferenceEdge`, so publishing a
  fragment re-fires everything embedding it. That is the feature's one ordering
  constraint: expansion runs *after* the edge rebuild, which reads the raw tree.
  Expand first and the edge disappears, quietly turning this into a one-shot
  copy.

  Delivery **fails closed**: a target that is missing, unpublished, archived, in
  another org, or gated to an audience the reader doesn't hold expands to
  nothing — a placeholder would leak its existence. A fired artifact is expanded
  with its **host's own** audience and nothing wider, because every artifact
  consumer (the headless endpoint, feeds, static export, the newsletter)
  resolves the host through a `:public`-only filter and then serves the body
  verbatim. And the re-fire wave now busts each referrer's *delivery* cache too
  — that cache is keyed on the referrer's own slug, which nothing else touches
  when the target changes.

  Cycles and runaway nesting are bounded at expansion time — an ancestry list
  seeded with the host, a depth cap, per-expansion memoization and a fetch
  budget — because a cycle needs two documents pointing at each other, either
  write is individually fine, and depth alone bounds depth rather than breadth.

  Write-time derivations (`search_text`, `word_count`, `reading_time_minutes`)
  and the editor's preview/SEO/a11y panels still run over the raw tree, so
  fragment text is not yet in the host's search index — tracked separately. See
  [Extending the content model](docs/extending-content.md).

- **JSON Schema / TypeScript export of block definitions.** The last unshipped
  "one definition fans out" item from the v2 plan (#430). `GET /api/schema`
  serves a draft-2020-12 JSON Schema describing what
  `GET /api/content/:type/:slug?surface=json` returns — the `_type`-discriminated
  block union plus one document schema per content type — and
  `mix kiln.export.schema` writes the same document, or a `.d.ts` built from it,
  for a build step. Typed clients had nothing to generate against for block
  payloads; now they do.

  Per **site**, not per deployment: dynamic content types and custom fields are
  organization-scoped, so an admin adding a field changes the schema with no
  redeploy. Container blocks `$ref` back into the union, so nesting is typed all
  the way down — something the storage union cannot express.

  It describes the **read** surface. Delivery projects rather than mirrors (an
  `image`'s `media_id` never reaches the payload; a `video`'s `media_id`/`url`
  pair is delivered as one resolved `src`), so blocks whose `:json` render
  diverges from their fields declare the difference through the new optional
  `c:Kiln.Block.Renderer.json_schema/0` — next to the render it describes, and
  covered by a conformance test that renders every registered block against its
  own exported schema. The authoring shape stays where it was, in the OpenAPI
  document at `/api/json/open_api`. See [§ Schema discovery](docs/api.md#schema-discovery-typed-clients).

  `Kiln.FieldType` gains an optional `json_schema/1` for the same reason on the
  custom-field side: a type whose `cast/2` result diverges from its editor
  widget — `:recurrence` renders one text input but stores a list — declares
  the shape it actually delivers instead of being guessed at.
- **Bulk content import/export, and a WordPress (WXR) importer.** Kiln had no
  "get my content in or out" path — the mix-task inventory could scaffold code
  and move rows between internal types, but structured export existed only for
  GDPR and governance trails. Three tasks close that (#487):

  ```
  mix kiln.import.wordpress export.xml --dry-run
  mix kiln.export.content --type post --out posts.json
  mix kiln.import.content posts.json
  ```

  The WordPress importer maps posts and pages to content types, converts the
  body HTML to typed blocks, resolves both taxonomies, sideloads referenced
  images into the media library, and — the part that makes a migration survive
  contact with search engines — **turns every old permalink into a redirect**.
  With #472's 404 capture, that completes the "switch from WordPress" path.

  Everything is written through the types' ordinary Ash create actions and the
  workflow state machine, never raw inserts: slug generation, custom fields,
  sanitization, tenancy and policy all apply, and an imported live post fires
  and versions exactly like a hand-authored one. An import can therefore never
  produce content its operator was not allowed to create.

  `--dry-run` runs the whole plan with no writes, through the same code path as
  a real run, so it cannot describe something the run would not do. Re-running
  is safe: an existing `(slug, locale)` is skipped, which also makes resuming
  after a partial run cheap. There is deliberately **no overwrite mode** —
  silently replacing edits an author made after the first import is not
  recoverable through any UI.

  Two failure modes are reported rather than left to the database. A slug held
  by a **trashed** record is named as such (`destroy` is a soft delete, so the
  row and its unique index survive while the ordinary read hides it) instead of
  surfacing a bare "slug has already been taken". And an image that cannot be
  fetched costs you the image, not the post — the block keeps the source URL
  and the failure is listed.

- **`KilnCMS.Blocks.Html`** reads legacy HTML back into Portable Text and typed
  blocks — the direction `Blocks.PortableText` did not go. It routes through
  TipTap JSON rather than building PT directly, so marks, nested lists, tables
  and link `markDefs` come from the one implementation delivery, search and the
  editor already agree on. It handles the two habits any HTML of WordPress
  vintage has: `wpautop` (classic bodies have no `<p>` tags at all — parsing
  them literally yields one enormous paragraph) and Gutenberg's `<!-- wp: -->`
  comment delimiters. `[caption]` becomes an image caption, `[embed]` becomes
  an embed block, and other shortcodes are removed rather than left as literal
  `[gallery ids="1,2"]` text in the middle of a sentence.

### Changed

- **A translation now keeps the source's block ids** (#502). `create_translation!`
  used to mint fresh ids for the copy. A locale variant is the same document in
  another language, every consumer of a block id is already scoped to one record
  (collab locks, version folds, experiment patches, the fired `_id`), and shared
  identity is what lets an XLIFF trans-unit address a paragraph across the pair.
  **Duplicate** is unaffected — a duplicate is a different document and still
  mints fresh ids. Translations created before this release match by position on
  import, and are reported as having done so.

  One consumer was *not* record-scoped: the visual-editing consoles resolved a
  record by slug alone and then matched the clicked block by id, so on a
  multi-locale site a click on a French page could open — and save into — the
  English record. Both now pin the default locale, and the presentation console
  refuses a payload naming a record other than the one it loaded. Editing a
  non-default locale in place still needs the locale in the route.

- **The media ingest pipeline is one module.** Sniff → size-cap → strip →
  store → `MediaItem` → enqueue derivation lived twice inside
  `KilnCMSWeb.MediaLive` (direct upload, Unsplash import); the importers are
  the third caller, and it is a sequence where a divergence is silent rather
  than loud — a path that forgets `strip_metadata/2` still produces a working
  image, it just ships the photographer's GPS coordinates with it.
  `KilnCMS.Media.Ingest` now owns it, and `MediaLive` keeps only the
  LiveView-shaped edges. No behaviour change to uploads.

  Its new `store_url/2` is the only part that touches the network, and it goes
  through `KilnCMS.SafeFetch` — importers hand it URLs from a file a user
  uploaded, which makes it the most content-chosen fetch in the system.
  `SafeFetch` resolves the host once, checks the answer, and connects to that
  *literal address* with SNI pointed back at the real name, so the name cannot
  be re-resolved to `169.254.169.254` between the check and the connection;
  redirects are refused rather than followed, and the body is capped. Uploads
  are otherwise unchanged, including the localized per-file failure messages.

- **WebP/AVIF variants, quality settings, and bulk regeneration.** Kiln's image
  pipeline wrote derivatives in the *source* extension — a JPEG upload yielded
  JPEG thumbnails — and passed no quality setting at all. Now every variant is
  written once per output format: the source's own, plus each configured
  alternate (#473). WebP is on by default (25–35% smaller than JPEG at equal
  quality); AVIF is opt-in, because encoding it costs roughly an order of
  magnitude more CPU per image, which is a real bill on a bulk run.

  ```elixir
  config :kiln_cms, :image_variants,
    formats: [:webp], webp_quality: 82, avif_quality: 50, jpg_quality: 82
  ```

  Quality covers the lossy formats only — libvips has none for PNG — and is
  clamped to `1..100`, because a rejected write produces *no* variant and an
  unclamped `System.get_env/1` string would empty the library rather than
  degrade one format.

  Variant keys still name exactly one file: the **bare label** is the source
  format — the `<img src>` fallback, and how every map written before this is
  keyed — and alternates take a `<label>.<format>` suffix, each carrying its own
  `content_type` for `<picture>`. A source format that is also a configured
  alternate is written once, not twice under two keys.

  Delivery renders `<picture>`. `Media.Presentation.srcset/1` stays
  source-format-only and `sources/1` returns one `srcset` per alternate, most
  efficient first — because a browser picks from a `srcset` on width alone, so
  mixing encodings there would hand a WebP-less client a WebP, while `<picture>`
  is the one construct where it is told what it is choosing. An item with no
  alternates renders exactly the `<img>` it did before.

  Alternates include a **full-size** encoding, which is load-bearing rather than
  an extra: a matching `<source>` *replaces* the `<img>`'s srcset instead of
  adding to it, so without a candidate at the original's width every content
  image would quietly render smaller on exactly the browsers this feature exists
  to serve.

  **Bulk regeneration** (`mix kiln.media.regenerate_variants`, and a Regenerate
  variants button in `/media`) rolls a configuration change out over media
  uploaded before it — the Regenerate Thumbnails analogue, needed again every
  time a width or quality changes. It enqueues onto the throttled `:media` queue
  at the lowest priority (so a bulk run can't leave new uploads thumbnail-less
  for hours), deduplicates per item, and reclaims the storage the replaced
  variants held — every other deletion path reads the current map, so without
  that one run over a large library would orphan tens of thousands of files.
  Originals are never rewritten: published snapshots point at them by key. See
  [Media pipeline](docs/media-pipeline.md).

- **Editor-managed navigation menus.** `/editor/menus` builds ordered trees of
  links — "Main navigation", "Footer" — and `GET /api/menus/:key` serves them to
  a front end (#466). Kiln had no navigation resource at all: categories are
  flat, so every headless consumer had to hard-code its nav. This was the
  biggest functional hole in the Drupal-core comparison.

  Items link to content **by reference**, and the URL is computed at read time
  from the target's current published path — so renaming a slug moves the
  navigation with it and never leaves a dead link. Items can also carry an
  external URL (sanitized through the same `safe_href/1` policy rich-text links
  use, so a `javascript:` trap can't be stored) or be a plain heading.

  A menu is **per locale**, sharing a `key` across variants, like content
  itself: labels, ordering and *which items exist* all differ between locales,
  which a per-item translations map can't express. A missing locale variant is a
  miss, not a fallback to English.

  Delivery drops what a reader can't see: an item pointing at unpublished or
  audience-gated content — or one an editor switched off — is omitted along with
  its children, so a dropped section takes its links with it rather than
  promoting them. That is why the stored rows are deliberately absent from the
  auto JSON:API and GraphQL surfaces: serving them raw would publish the label
  and target id of an unannounced page. `GET /api/menus/:key` and the `menu`
  GraphQL query both resolve. Depth (counting the subtree a move carries),
  cycles and cross-menu parenting are refused at write time. See
  [Navigation menus](docs/navigation-menus.md).

### Fixed

- **A field-granted editor is no longer offered a billed AI run the save will
  refuse** (#868). The editor gated "Suggest with AI" on `Ash.can?({record,
  :autosave})`. Per-field grants are enforced by
  `KilnCMS.CMS.Changes.EnforceFieldGrants`, which is a **change**, and
  `Ash.can?` builds its changeset with *empty input* — while the change only
  raises a violation for an attribute that was actually supplied. So no field
  was ever supplied during the check, no error was ever added, and every
  field-granted editor passed a gate the save would then reject field by field.

  An editor holding `field_grants: %{"page" => ["title"]}` saw the button, spent
  the organization's LLM budget, and got `seo_title` / `seo_description` /
  `seo_keywords` refused one at a time on the next save. The control and its
  handler now ask the question the change asks — may this actor change *these
  fields* on *this type* — mirroring the change's tier condition, so an admin
  carrying a grants entry is exempt exactly as the policy bypass makes them.

  **Block assist** carried the identical hole and is closed with it: it bills
  its own budget and writes prose into a block, so a grant without `blocks`
  meant a billed run the save then refused. The gate is *any* of the fields the
  feature writes, not all of them, because each SEO card is accepted on its own
  — an editor granted one field can take that card and save cleanly — and the
  per-card accept re-checks, so a queued or replayed one after a grant narrows
  mid-session is refused rather than written into the form.

- **The editor's tag picker no longer detaches tags it never showed you**
  (#638). Tags were written with the complete-set `tag_ids` argument, so a
  checkbox that was not rendered was not submitted and `append_and_remove` read
  the omission as "detach me". The picker now submits `add_tag_ids` /
  `remove_tag_ids` (added to the resource in #636) diffed against what it
  actually rendered, so removal is bounded by what was on the page: a tag
  attached out of band — by a collaborator, an API call, an automation — after
  the page loaded now survives the next save instead of being silently dropped.

  Autosave carried the identical defect and was never named in the issue, which
  made it the worse of the two: it fired on a debounce with nobody pressing
  anything.

  The workarounds this retires go with it — the hidden empty-string sentinel
  that made an all-unchecked group distinguishable from an untouched one, and
  `normalize_tag_ids/1`, which existed only to strip it back out. The "Also
  attached" section stays, but as information and a control rather than as the
  thing standing between a scoped-away tag group and data loss.

- **A navigation subtree that goes missing can be got back** (#900). Two editors
  re-parenting at the same time can commit a parent cycle — the placement
  validation walks the ancestor chain with plain reads outside any lock, so
  under READ COMMITTED each validates against pre-commit state and neither sees
  the other's write. The read path does not loop: it descends from the roots and
  emits each item under its single parent, so the cycle's members and everything
  nested under them simply **vanish** from the served menu *and* from the
  builder's own tree, with no error and no row deleted. The editor's only signal
  was a section disappearing, with nothing to click — the items aren't rendered,
  so they can't be selected, edited or outdented back. Adding to them fails too:
  the depth check bounds its ancestor walk rather than following the cycle
  round, so every new child under one is refused as *is nested too deeply*.

  The builder now lists them under **Detached items** with a *Move to top level*
  action that breaks the cycle by making the item a root; its children come back
  with it, and nothing else moves. Only the top level is offered, because the
  item is unreachable precisely when no parent of it is trustworthy. This covers
  any cause of orphaning — a restore, direct SQL, a `parent_id` pointing into
  another menu — not only the race, which stays open and is documented.

- **Changing a nested heading's level in a Columns block now takes effect**
  (#893). The per-child level `<select>` had no `name`, and a `phx-change` on a
  form-associated element routes through LiveView's `pushInput`, which
  serializes the form filtered to the changed input's name and reads
  `phx-value-*` off the **form** rather than the element. With an empty name
  neither the chosen level nor the block/child/field identifiers arrived, so the
  handler could not match and H1→H3 silently did nothing. The sibling text
  inputs work because `phx-blur` is not a form binding and goes through
  `pushEvent`, which does carry `phx-value-*` — that asymmetry is what hid it.

  The select now carries its identifiers in its `name`, outside the `form[...]`
  namespace so it still stays out of the content changeset the way the nameless
  inputs do. Covered by an end-to-end test, because that is the only layer where
  the bug existed: an ExUnit `render_change` supplies params directly and passes
  against the broken markup too.

- **The collab-editor flake is checked for, not just fixed** (#1067). Filed as a
  presence race in `CollabPersisterTest` — one failure in three full-suite runs,
  never in isolation — it turned out to be a VM-global one:
  `:collab_prototype` is `Application.get_env/2`, re-read on every editor mount,
  and an `async: true` test flipping it off turned collaboration off for every
  concurrent test that mounted an editor. PR #1090 fixed the one offender; this
  makes the next one impossible.

  A static check now fails if any `async: true` module writes that flag, and the
  two collab live-view files assert it is on before their own assertions run —
  so the failure says which class of problem it is instead of presenting as a
  broken election. The three lines the issue suggested hardening are hardened
  too: they sampled a single render where presence is eventually consistent,
  and they poll now.

- **Referrer suppression now actually suppresses** (#1073). #620 hid a
  low referrer count behind `"< n"` and pulled a second category into `hidden`
  so the low one was not the sole unknown. Brute-forcing every assignment
  consistent with the published breakdown *plus the view total shown beside it*
  found that most of them had exactly one solution: the partner was chosen as
  the **smallest** of the others, which bounds it above by every published exact
  — and whenever the residual falls under the threshold the partner must be
  zero, which recovers the hidden count exactly. `direct: 3` with four genuine
  zeros gave the count away outright.

  The partner is the **largest** of the others now, so it is bounded below by
  every published exact and unbounded above and the residual splits many ways.
  Where no partner makes it ambiguous — a handful of views against genuine zeros
  — the whole breakdown is hidden, zeros included, because a published `0` is a
  term in the equation rather than a courtesy. Both the dashboard and the export
  read the same decision, as they have since #777.

  The property is now a test rather than an argument: it brute-forces the
  assignments a reader who knows the algorithm could construct and asserts there
  is more than one, across every small breakdown and at three thresholds. It
  fails on the old algorithm.

  The cost is exactness on the lowest-traffic days, which
  `docs/environment-variables.md` states next to
  `KILN_ANALYTICS_LOW_COUNT_THRESHOLD`.

- **Turning off full-content feeds now empties the cached feed bodies on every
  node** (#1078). #719's `bust_feed_policy/1` already reached the cluster, so the
  *policy* — the value deciding whether whole article bodies go out to anonymous
  subscribers — was consistent everywhere. The cached feed **documents** were
  not: `bust_all_feeds/1` was node-local, so on a two-node deployment roughly
  half of all `/feed.xml` fetches went on serving complete article text,
  rendered under the old policy, until the five-minute TTL.

  It could not use the existing broadcast, which names keys: a prefix scan's
  matching keys differ per node, and a node that never served
  `/blog/category/news/feed.xml` has no key for the writer to name. So
  `KilnCMS.Cache.ClusterBust` gained `broadcast_prefix/1`, which carries the
  rule instead and lets each node run its own scan. Receivers stay as dumb as
  they were — a string and "forget what starts with this", not a name for the
  thing being invalidated.

- **The tag-suggestion threshold is measured now, and the old one was inert**
  (#1086). #851 shipped `suggest_tags/2`'s cosine-distance ceiling with a
  derived `0.25`, reasoned from bge-small's published behaviour on *sentence
  pairs*, and said in as many words that it wanted calibrating against a real
  embedder — which `KilnCMS.StubEmbedder` cannot stand in for, so no test could
  tell a good suggestion from a bad one.

  Measured against the shipped model over a labelled corpus (eight documents,
  thirty-five tags, a human label on all 280 pairs), that band does not transfer:
  a tag label against a whole-document centroid is not a sentence pair. An
  unrelated tag sits at 0.35 and up; a wanted one can sit at 0.43. `0.25` kept
  **3 of 27** tags a person would tick, so the panel was empty for most
  documents — which reads to an editor as a broken feature, not as "nothing is
  close".

  The default is now **0.35**: 21 of 27 wanted tags kept, 10 of 253 unwanted
  admitted, about four suggestions per document under the panel's own limit of
  five. The bands overlap, so it is a judgement about which error to make, and
  `docs/rag.md` records the measurement and the reasoning.

  `near_duplicates/2`'s `0.1` was measured on the same corpus and holds — a
  reworded copy sits at 0.04, another document on the same subject at 0.19-0.21
  — but it is a config key (`:near_duplicate_threshold`) now rather than a
  literal, because it is a property of the model and an operator who changes the
  model had no way to change it.

  The corpus and the recorded distances are `KilnCMS.TagSuggestionCorpus`, so
  the shipped value is pinned by tests that need no model; the harness that
  produced them re-runs against any configured embedder with
  `mix test --include calibration`.

- **A content type's default SEO description now reaches every surface that
  renders one** (#1102). #805 let a type default its `seo_title` /
  `seo_description` from a `[token]` pattern, resolved at render time — but only
  for the delivered HTML page. Eight other surfaces kept rendering the record's
  stored column, so the same document carried a meta description on its own page
  and an empty `<summary>` in the feed that linked to it: RSS/Atom/JSON Feed, the
  `.ics` `DESCRIPTION`, the event index's `index.json`, `llms.txt`, auto-posted
  social text, the ActivityPub `Note`, the fired `:json_ld` artifact and the
  preview payload.

  Two new public calculations, `effective_seo_title` and
  `effective_seo_description`, carry the resolved value; the stored columns still
  say exactly what a human typed, which is what the editor's SEO panel, the
  analyzer and the export read them as. Headless consumers get both. Each
  calculation declares the data its own tokens need, so `[category]` and
  `[field:<name>]` resolve on reads that pin a column set — where they used to
  expand empty with nothing to explain why.

  The fired artifact was the sharpest case: `KilnCMSWeb.StructuredData` documents
  itself as mirroring the fired producer's rule, and the two emitted different
  `description` for one document — permanently, because re-firing re-read the
  same column. It now re-fires to agreement. Artifacts fired before this change
  keep their old description until that document is published again or re-fired
  (`mix kiln.refire_all`).

  A pattern still only ever fills a blank: it never outranks an author's own
  excerpt, it stays out of a paywall teaser's visible body copy, and on a teaser
  the two tokens needing columns the paywall-safe select omits go quiet rather
  than widening that select. See [docs/seo.md](docs/seo.md).

- **The form builder showed `%{value}` instead of the value it was refusing.**
  Splode interpolates an error's `vars` only inside `Exception.message/1`, and
  the builder read `.message` off the struct — so a rejected setting reported
  which field was wrong but never which entry. Affects every validation message
  in `/editor/forms/:id`.

- **The embed page now sends `Vary: Accept-Language`.** It renders through
  gettext and is served `Cache-Control: public`, so a shared cache could hand
  the first visitor's language to everyone for the cache window. Published HTML
  already did this.

- **Two separators in the form builder rendered as nothing.** `class="divider"`
  is a DaisyUI class, and this repo has no DaisyUI (`docs/design-language.md`).


- **The sitemap escaped three characters where the feeds escaped five** (#502).
  Its copy of the XML escaper let a C0 control byte through, and one of those
  makes the whole sitemap unparseable rather than one URL. All three
  serializers now share `KilnCMS.Xml`.


- **A headless two-factor pending token is now single-use exactly, not
  best-effort** (#743). The record of a redeemed blob was a node-local `Cachex`
  entry, so a replay landing on a node that had not seen the redemption was
  accepted — and, less obviously, two requests arriving *together* on a single
  node both resolved the blob before either recorded it and both received a
  bearer token. Nothing rejects a reused TOTP code, so they only had to be
  simultaneous.

  The record is now a `KilnCMS.Accounts.Token` row keyed on the blob's `jti`, so
  the INSERT is the check: concurrent redemptions race at Postgres and the loser
  is refused. It survives restarts, needs no new table, and is swept by the
  nightly expired-token job that resource already runs.

  A claim that cannot be *recorded* (a database outage, as opposed to losing the
  race) now answers `503 sign_in_unavailable` — "try again in a moment" —
  instead of telling the client its sign-in expired and to start over, which
  would have been wrong advice and a wasted trip through the password throttle.

  No other API change — `pending_token` is the same opaque string with the same
  five-minute lifetime.

- **A client-chosen payload shape no longer crashes any editor LiveView**
  (#764, completing the sweep #894 started). A `handle_event/3` payload is
  arbitrary client JSON, so `%{"id" => id}` constrains the key and never the
  value — `String.trim/1`, `Integer.parse/1` and an Ash primary key all have no
  clause for a list, a map, an integer or `nil` and raise. #894 shipped the
  mechanism (head guards plus a catch-all appended to every Kiln LiveView) and
  guarded a first handful; the remaining ~200 payload-binding clauses across 32
  views now guard too, as does `/media?id[]=1` — the last of the URL-reachable
  reads, which put a list where a primary key goes.

  A guard is a claim about the shape, and three of them were wrong the first
  time: the inline editor's `"update_block"` takes a TipTap *document* as well
  as a string, and the block editor's `"reorder"` takes a list. Those are now
  stated rather than assumed, and a list is refused where it used to be written
  into a block body without normalisation.

  `KilnCMSWeb.MalformedPayloadTest` keeps it that way: it reads the LiveView
  sources and fails on a handler that binds a client value without saying what
  shape it expects, so the next one inherits this rather than joining a list.

- **The site name rendered twice in the browser tab.** The layout appended the
  brand-name suffix whether or not there was a page title to append it to, so
  any page that set none — the site home page, the delivery 404, and every
  AshAuthentication page — read `Acme Docs · Acme Docs` on a white-labelled
  site (#559). Those pages now carry their own titles, and the suffix is only
  appended when there is one, so a page that is ever missed reads as the bare
  brand name instead.

- **`safe_href/1` accepted `/\evil.com`.** A backslash is a slash for `http(s)`
  under the WHATWG URL spec, so a link that read as a same-origin path resolved
  off-site in every browser — the `//host` escape the policy already blocked,
  wearing a different hat. Now rejected wherever a link href is stored: rich
  text, portable text, legacy HTML, and the new menu items.

- **Duplicate content.** A **Duplicate** button on every content-list row and in
  the content editor's header clones a record into a new draft of the same
  locale and lands the editor in it — the "copy this page and tweak it" motion
  Yoast Duplicate Post exists for (#471). The copy carries the authored payload
  (blocks with fresh stable ids at every depth, excerpt, SEO title/description/
  image, audience, custom fields, category, featured image, tags, related
  content) and leaves behind everything that identifies or tracks the source:
  the slug is regenerated through the type's slug pattern (so "Guide" duplicates
  to `guide-copy`, then `guide-copy-2`), the workflow starts at `:draft` with no
  schedules, and the copy gets its own paper-trail rather than inheriting the
  source's.

  Two things deliberately do **not** travel. The **focus keyphrase**
  (`seo_keywords`) stays with the source: it is a per-URL SEO target, so two
  records chasing one keyphrase cannibalize each other — and since the default
  slug chain is keyphrase → title, carrying it would also mint the copy a slug
  with no relation to its title. **Incoming** links stay with the source too —
  other records linked to *it*, not to a draft copy of it.

  Curated relations are cloned as `ContentLink` rows rather than through the
  `related_<type>_ids` argument, so a link's `kind`, `position`, `label` and
  `metadata` survive: that argument is a bare id set, and re-managing it would
  flatten the payload data-carrying relations exist to hold and collapse two
  links to one target under different kinds into one.

  `KilnCMS.CMS.Duplication` runs the type's ordinary `:create` action as the
  acting user, so create policies apply exactly as they would to a hand-authored
  document — and because duplication is the one create that carries *another
  record's* values, it also honours per-field write grants, which
  `Changes.EnforceFieldGrants` otherwise skips on creates. `audience` is exempt
  from that filter: dropping it would fall back to the attribute default
  (`:public`), which is strictly *less* restrictive than the source. The payload
  mechanics it shares with one-click translations now live in
  `KilnCMS.CMS.ContentCopy`.

- **404 capture, paired with redirects.** `/editor/redirects` grows a **404s**
  tab listing the paths delivery couldn't serve, most-requested first, each with
  a one-click "Create redirect →" that drops the path into the form above (#472).
  That pairing is the whole point: Kiln's redirect table was manual-entry only,
  so after a migration off WordPress you had to guess what broke. Creating the
  redirect clears the counter, so the list reads as a work queue rather than an
  archive.

  `KilnCMS.CMS.MissedPath` is a **counter** table, not a request log — one row
  per `(path, locale)`, upserted atomically, so a crawler hammering one dead URL
  adds one row rather than ten thousand. That keeps delivery's deliberate
  "resolve misses quietly, no log noise" stance intact.

  The path recorded is the one delivery resolved against — routed and
  percent-decoded, empty segments collapsed — not the raw request target, so the
  one-click redirect writes a rule that actually fires and `/café-gone` doesn't
  become several rows.

  It stores paths and nothing else: no IP, user agent, referrer or actor. Since
  anonymous traffic writes it, three bounds apply — probe-shaped requests
  (`/wp-login.php`, `/.env`, asset extensions) are never recorded; a per-site cap
  where a new path **evicts the least-requested row** rather than being refused,
  so one cheap flood can't pin the table full of junk and deny the feature; and a
  nightly AshOban trigger that purges rows 30 days after their last hit. Writes
  run off the request path in a supervised task. Turn the whole thing off with
  `config :kiln_cms, :missed_paths, enabled: false`. The staging scrub purges the
  table; see [Data flows](docs/data-flows.md).

- **The editor PWA's web app manifest is localized.** `name`, `description` and
  both shortcut labels are translated, so the install dialog, app list, splash
  screen and long-press shortcut menu appear in the editor's language. The root
  layout links `/manifest.webmanifest?locale=<locale>` and the controller reads
  the locale from the URL — a manifest is fetched once per install, so
  translating against the *request's* locale from one URL would have named the
  installed app after whichever locale happened to fetch first (#630).

  `short_name` stays untranslated: it is the operator's brand name, a proper
  noun. Note that Android labels the home-screen icon from `short_name`, and iOS
  ignores the manifest entirely, so the icon caption itself is unchanged.

  The install `id` deliberately does **not** vary by locale, despite the issue
  suggesting it. A manifest whose id doesn't match an installed app's is not
  treated as a rename — the whole update is discarded — so a per-locale id would
  have permanently frozen icons, `theme_color`, `scope` and every future
  branding change for anyone who had already installed under a non-default
  locale. It would also have been unstable under `default_locale`, an
  operator-facing setting.

- **Auto-complete-on-publish is now configurable.** Publishing a piece of
  content still completes its open editorial tasks — that was unconditional
  since #501 — but a site can change the default and an individual task can
  override it (#818).

  The per-task half is the one neither setting serves alone: a follow-up task
  deliberately outliving the publish it hangs off. `Task.auto_complete_on_publish`
  is a **three-valued** field, where `nil` means "whatever the site is set to"
  rather than "no". So flipping the site setting moves every task that hasn't
  been pinned, instead of only affecting ones created afterwards.

  The site default lives on `/editor/tasks`, stated for every editor (the task
  rows explain what publishing will do to them) and changeable only by an admin
  — the resource policy draws that line, not the route, the same way
  `/editor/links` does. The per-task override is a select in the content
  editor's Assignment panel.

  **No behaviour change on upgrade.** The migration adds a nullable column with
  no default, so every existing task inherits, and a site with no settings row
  resolves to the shipped `true`. Read the pair through
  `KilnCMS.CMS.TaskSettings` rather than either half directly — it owns the
  precedence and resolves an absent row without writing one.
- **`mix kiln.audit.checkpoint --audit` walks the checkpoint run's predecessor
  links, and its structural half now runs without a witness.** Each
  `chain_checkpoints` row signs its predecessor's id and a digest of its
  contents; nothing walked them. A checkpoint rewritten in place while keeping
  its sequence number was caught only by its own signature failing — which on an
  unsigned deployment it does not (#732).

  Contiguity and the link walk read `chain_checkpoints` alone, so they now run on
  every deployment, including the default one that publishes nowhere. Previously
  the whole audit exited early without a sink, which made both checks dead code
  on exactly the deployments where they are the only structural evidence there
  is. The missing-witness case is still a failure and still exits non-zero.

  Read the walk for what it is: `Checkpoint.digest/1` is an unkeyed hash over
  public columns, so an attacker who rewrites a row can recompute every digest
  after it, and the newest checkpoint has no successor to record its digest at
  all. It catches a careless edit, and it makes a careful one expensive — the
  cascade forces a rewrite of every *published* object downstream, turning one
  witness mismatch into many. It does not replace the witness.

- **Editorial claim checking.** A **Compliance** panel in the content editor
  flags the phrases a regulator or a house style guide would want a second look
  at — "FDA approved", "no side effects", "guaranteed results" — plus an
  optional check that a configured disclaimer is present. Built on the existing
  advisory framework as a third lens rather than a private panel, so it shares
  the body walk, the severity vocabulary and the rendering (#377). See
  [Editorial claim checking](docs/compliance.md).

  **Off by default, behind two switches.** `enabled` turns the panel on;
  `require_at_publish` then turns an `:error`-severity match into a refused
  publish (`KilnCMS.CMS.Validations.ComplianceClaims`). It is read *through*
  `enabled`, so setting it alone is inert. Most publications want the panel
  long before they want a gate.

  The gate covers every path that can put text on the public site: `:publish`,
  `:publish_scheduled`, an `:update` to an already-live record, and a version
  restore (which force-changes fields in a `before_action`, so a plain
  validation never sees them). All are scoped to the claims *that write
  introduces*, so switching the gate on doesn't make existing pages
  un-editable. Note it costs a block-tree walk and a scan on every write to a
  published record — unlike the alt-text gate it also reads the SEO fields, and
  Ash's `where:` has no "any of these changed".

  Three judgement calls worth knowing, all argued in the doc. The check is an
  editor advisory rather than the background agent #377 sketched, because a
  claim is a judgement about meaning and every honest implementation ends up
  asking a human — who is already in the editor. The shipped rule pack omits
  bare curative vocabulary ("cures", "heals"), which is the vocabulary a health
  CMS most obviously wants and also the vocabulary with the most legitimate uses
  — where that line falls is the operator's call, and a shipped guess means
  every install starts by switching the panel off. And negation is deliberately
  not handled: "does not cure cancer" is reported, because a negation window
  would suppress "not only clinically proven, but…" just as readily.

  Phrases match on whole-word boundaries — as a substring, `cures` matches
  *manicures*, *procures* and *secures*.

- **Beta testing program.** [Beta user testing](docs/beta-testing.md) documents
  the Phase 9 editor-UX beta: the surface under test, seven guided scenarios, a
  session notes form, and a feedback → issue → fix triage loop. A **Beta
  feedback** issue form files one finding per issue, labelled `beta`, capturing
  severity, area, build and tester so a fix can be confirmed with the person who
  found it (#59).

  The thing that shapes the whole program is that access is gated on **two**
  axes, not one. The router decides which pages open (nineteen are admin-only),
  and Ash policy separately decides which actions run — and `publish` is
  admin-only, so **an editor cannot publish**. A beta round therefore can't be
  one person alone at a keyboard: the draft → in_review → published loop needs
  two seats, which is the workflow under test anyway. Scenarios are split
  accordingly.

- **"Add to release" from the content editor.** The Settings tab now carries a
  **Release** panel: queue the record you're editing into a content release,
  see which release it's already in (with a link to it), and take it back out.
  Releases previously could only be filled from the content list's bulk action,
  which is the wrong shape for "this one piece belongs in Friday's launch"
  (#836).

- **Content releases are bounded.** A release is capped at 500 items by default,
  configurable via `config :kiln_cms, KilnCMS.CMS.Releases, max_items:` alongside
  `transaction_timeout_ms:`. The go-live transaction is what makes a release
  atomic, and it holds row locks on every item for its duration — so an
  unbounded release built by a bulk "select all" could hold those locks until
  the timeout aborted it, *after* the wait. The console shows slots used and
  warns at 80% rather than only refusing at the cap (#837).

- **Content releases: bundled, atomically published groups of changes.** A
  release is a named bundle of publishes and unpublishes that ships as one
  coordinated change — the Contentful Launch / Sanity Releases analogue. Kiln's
  per-item `scheduled_at` could only line up N identical timestamps and hope;
  a campaign touching a landing page, three posts and a fragment now goes live
  as a unit at 09:00, or not at all (#500). See
  [Content releases](docs/content-releases.md).

  Three things are the substance of it:

  - **The transaction is genuinely all-or-nothing.** Publishing N items through
    the normal per-item actions means N state transitions, N artifact fires and
    N webhook dispatches — which sounds uncoverable by a transaction. But every
    side effect of Kiln's publish path is a *database write*: the webhook ledger
    row and its Oban job, the artifact fire job, the automation dispatch job, the
    audit-chain anchor rows. The POSTs and renders happen later, in workers, off
    the same repo. So the whole bundle runs inside one `Repo.transaction`, and a
    failure on item 7 rolls back items 1–6 **and** everything they queued. No
    observer ever sees a half-live campaign; the release lands in `failed` naming
    the item that broke, and the site is untouched.

  - **Composing a release and shipping one are different privileges.** Editors
    create releases and fill them; scheduling, publishing and rolling back are
    admin-only, mirroring "editors submit for review, admins publish". A release
    must not become a route around the publish approval step — and since the
    worker necessarily publishes unauthorized, the admin who claimed it is
    recorded and acts as the author of every item's version.

  - **"Already true" is skipped, not failed.** If someone publishes one of the
    pages by hand before the release fires, that item is marked `skipped` rather
    than aborting the launch — and a later rollback leaves it alone, because the
    release didn't put it there. A genuinely impossible transition (archived,
    trashed, type retired) is still a hard failure.

  Also: a **preview as of the release** at `/preview/release/:token`, shareable
  with people who have no editor account, rendering each document exactly as
  go-live will; **group rollback**, restoring each item's captured prior version
  and workflow state in reverse; release chips on the editorial calendar; and
  `release.published` / `release.rolled_back` webhook and automation events.

  A record may appear in at most one unshipped release, enforced by a partial
  unique index rather than an application check — two editors adding the same
  page to two releases at once is exactly the race check-then-insert loses.

- **Event content: schedules, recurrence, and calendar output.** Kiln has no
  `Event` resource, and that is the design — an event is a content type carrying
  a **`datetime_range`** field, composed at `/editor/types` like any other.
  Everything downstream keys on the presence of that field rather than on a
  hardcoded type name, so a venue's "Gig", a clinic's "Workshop" and a school's
  "Open Day" are three types with three field sets and one calendar mechanism
  (#480).

  Two new field types: `:datetime_range` (start, optional end, IANA zone,
  all-day) and `:recurrence` (an RRULE subset plus skipped dates).

  Three decisions are the substance of the feature:

  - **Local wall time plus a zone, not a UTC instant.** This is deliberately not
    how the rest of Kiln stores time. `published_at` is a UTC instant because for
    an editorial timestamp the moment *is* the fact; an event is the opposite.
    "The doors open at 19:00" is a fact about the local clock, and storing UTC
    silently moves the gig the next time a government changes its DST rules —
    `18:00Z` becomes a 20:00 concert, while `19:00 Europe/London` stays a 19:00
    concert. Expansion is wall-clock for the same reason, so a weekly event holds
    its local time across a DST boundary; the *duration* recurs, not the end
    instant.

  - **An unsupported RRULE part is rejected, never ignored.** `FREQ` (daily,
    weekly, monthly, yearly), `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY`,
    `BYMONTHDAY`, `BYMONTH` and `WKST` are honoured; `BYSETPOS`, `BYWEEKNO`,
    `BYYEARDAY`, `BYHOUR`, `BYMINUTE` and `BYSECOND` are refused at the form. An
    editor who writes a rule Kiln cannot honour should find out then, not from a
    subscriber asking why the calendar is wrong. Expansion is always windowed and
    always capped, because `FREQ=DAILY` with no `UNTIL` has infinitely many
    occurrences.

  - **A calendar ships the rule, not expanded occurrences.** `/calendar.ics`,
    `/<plural>/calendar.ics`, `/<plural>/tags/<tag>/calendar.ics` and
    `/<plural>/<slug>/calendar.ics` serve RFC 5545 iCalendar carrying `RRULE`
    and `EXDATE`. A client understands rules, so this is both smaller and more
    correct: it keeps showing occurrences past whatever window Kiln happened to
    expand. **Published *and* `audience: :public` only** — a subscribed calendar
    is fetched by an anonymous client on a timer, forever, so gated content is
    filtered out explicitly rather than left to a read policy staying shaped as
    it is today.

  A type declaring one of the schema.org Event types also fires an `Event` JSON-LD
  node with `startDate`, `endDate` and an `eventSchedule` holding the RRULE. The
  timezone database is now `tz` rather than `tzdata`, which runs a runtime HTTP
  updater — the wrong shape for a codebase that gates all egress.

  Not included, and tracked separately: an occurrence-sorted paginated delivery
  index. See [events.md](docs/events.md).

- **Rich embed cards: server-side oEmbed metadata.** An embed block stored a URL
  and rendered `<figure data-url="…"></figure>` — no title, no thumbnail, no
  provider. A headless consumer got a naked URL, which in practice meant nothing
  rendered at all. Kiln now resolves metadata against a curated provider list
  (YouTube, Vimeo, SoundCloud, Spotify, CodePen, Flickr, TED, Bluesky) and
  renders a card: link, title, provider, optional thumbnail (#489).

  **Off by default; enabling it is egress.** `OEMBED_ENABLED=true` makes the
  server issue an outbound request when an editor saves a document containing an
  embed a provider claims. `OEMBED_PROVIDERS` can *narrow* the list; adding one
  is a code change, because a provider is a host this server dials.

  Three decisions are the security of the feature:

  - **A registry, not oEmbed discovery.** Discovery means fetching the embedded
    page and following a `<link rel="…oembed">` — i.e. letting *content* choose
    which host the server talks to, from a field any editor can type. The
    endpoint is a constant per provider; the URL only selects which of them is
    asked.
  - **The provider's `html` is discarded, not sanitized.** Rendering it means
    trusting a third party with script execution on the delivery origin, or
    maintaining a sanitizer for markup whose purpose is to do what sanitizers
    strip. Cards are built from escaped scalars. The two framed hosts keep the
    canonical-iframe rewrite they already had, and remain the only thing that
    produces an `<iframe>`.
  - **Thumbnails are checked against that provider's own CDN**, on the way in
    *and* on any write, because these are ordinary block fields an editor or a
    headless caller can set. `img-src` widens to exactly that list, and only
    when the feature is on.

  Resolution runs in an Oban worker, never the save — a provider having a bad
  afternoon must not become Kiln having one — and writes through a dedicated
  `:set_oembed_metadata` action so it cuts no version, emits no `updated`
  webhook, and does not bump `lock_version` into an editor's next autosave.
  Artifacts are re-fired deliberately, and only for a published document.

  **This required changing what an embed block stores.** The save path used to
  run `safe_embed_url/1`, which knows two hosts and *rewrites* them — so a
  stored embed URL was a canonical player URL or the empty string, and every
  other URL an author pasted was destroyed on save. Storage now keeps what the
  author typed (absolute `http(s)` only); whether a URL may be *framed* is a
  render-time question both surfaces already asked. An embed block therefore
  round-trips its URL for the first time, and a paste of a non-video link is no
  longer silently thrown away.

  A second review round caught four things worth naming, because each was
  invisible from the unit tests:

  - **The card still never reached the public site.** `enrich_block/3` had no
    embed clause, so delivery built `%{type, content}` with no title and the
    card branch rendered an empty div — while the fired artifact and every
    preview showed the card correctly. The one surface that matters was the one
    surface still inert.
  - **The worker destroyed concurrent edits.** It read the block list, spent
    seconds on an outbound request, then wrote that list back — with the
    optimistic lock deliberately off, so an editor's additions during the fetch
    vanished with no error. Since `:autosave` is one of the enqueuing actions,
    that collision was the normal case. It now fetches first, re-reads, and
    applies metadata to whatever is stored *now*, matching on block id and URL.
  - **Changing an embed's URL kept the previous target's card.** Ash merges an
    embedded block by id, so an edit that changes only `url` keeps the old
    title and thumbnail — and a "has no title yet" check never re-resolved. A
    `resolved_url` field now records what the metadata describes; a mismatch
    suppresses the card everywhere (render, search, the LLM surface) *and*
    re-enqueues.
  - **Oban's default uniqueness includes `:completed`**, so a URL changed
    within a minute of the last resolve would never re-resolve at all.

  Also fixed while here: `safe_embed_url/1` concatenated the video id into a URL
  without checking its character set — every render path escapes it, so it was a
  latent hazard rather than a live one, but "the id is whatever was in the path"
  made that escaping the only line of defence.

- **Broken outbound links: a scheduled sweep and a site-wide report** — the
  other half of the link checker (#474), and the half with teeth. A citation's
  domain lapses, a linked article is taken down, a video is removed; nothing
  says so, and the page keeps sending readers into a 404 on somebody else's
  server.

  **Off by default, per site.** `/editor/links` → *Turn on outbound checking*,
  org-admin only. Turning it on is the decision that makes this server issue
  requests to third parties on a schedule, and some deployments cannot do that
  at all. The sweep is scheduled everywhere (`KILN_LINK_CHECK_CRON`); with no
  site opted in it reads one settings row per org and stops.

  **Very little is called broken, on purpose.** The web answers a checker
  differently from a browser — bot walls 403, paywalls 401, CDNs 429, and a
  great many hosts refuse `HEAD` outright. Only 404, 410 and a redirect chain
  that never lands are reported. Everything else in the 4xx range, and any
  address the SSRF guard refuses, is `:undetermined` and never shown to anyone.
  This is the internal half's rule (*"I could not resolve it" is not "it is
  broken"*) under worse conditions.

  A 5xx, a timeout or a name that will not resolve is `:transient` and has to
  fail **three consecutive checks** before it is reported. A dead domain arrives
  that way rather than as a definite verdict, which is deliberate: DNS fails for
  a minute far more often than forever, and the counter is what tells a lapsed
  domain from a bad afternoon. Any success resets it.

  `HEAD` goes first because it costs the far end nothing, and a 403/404/405/406
  answer to it is re-asked with `GET` rather than believed — some servers really
  do serve one to `HEAD` and the page to `GET`. That doubles traffic for some
  broken links, which is the right way round.

  **Manners, since this is outbound traffic in somebody's name.** Requests are
  paced per **remote host** (`KilnCMS.Links.Throttle`, one per host every two
  seconds), not per site or per job — the thing being protected is someone
  else's server, and it does not care which tenant is pointing at it. A job that
  hits a full bucket snoozes rather than sleeps, so one busy domain cannot stall
  the queue. Healthy links are re-checked weekly, not nightly. The user-agent
  identifies Kiln and carries a URL, and deliberately carries **no version**: a
  link checker announces itself to every site an author has ever cited, and a
  build number there is a permanent broadcast of what to try
  (`KILN_LINK_CHECK_USER_AGENT` sets your own).

  **`KilnCMS.SafeFetch` gained `head/2` and `:max_redirects`.** Following a
  redirect is the one thing that module refused to do, because a followed
  redirect is a fresh DNS resolution the address pin never sees. It now follows
  them **by hand** — every hop is a full re-validate and re-pin — and credential
  headers are dropped when the host changes. Handing the chain to the HTTP
  client instead would resolve hops 2..n past every check, and one open redirect
  on a trusted host would be a straight path back to the metadata service.
  `:truncate_body` is the other new option, and it is not cosmetic: without it a
  page larger than the byte cap comes back as an error and reads exactly like a
  dead link.

  Findings persist (`KilnCMS.CMS.ExternalLink`, one row per `{document, url}`)
  because a sweep over everything has no editor open to report into. The report
  inverts that grain and lists one row per URL with every document to open,
  since an author fixes the link once and then visits each page. Reconciliation
  is a single rule — rows not seen by the latest sweep are deleted — which
  covers "the link was removed", "the document was unpublished", "the document
  was deleted" and "the type was archived" without four hooks that each have to
  remember. The delete runs only after a scan that reached the end.

  Scanned: published records only; rich-text annotations (including inside table
  cells), an `embed` block's URL, a `claim` block's `source_url`. Not scanned:
  image and gallery URLs, which point at Kiln's own storage — checking those
  would be this deployment asking itself whether its own files exist, over the
  network, nightly. See [`docs/link-checking.md`](docs/link-checking.md).

- **Broken internal links are flagged in the editor** — the deterministic half
  of the link checker (#474). An author links `/blog/the-thing`; later it is
  renamed, unpublished or deleted, and nothing says so. The link keeps rendering
  and quietly 404s for every reader.

  Two findings, deliberately not one: an `:error` when nothing resolves the path
  in any state, and a `:warning` when the target exists but is not published.
  Delivery cannot tell those apart — both are a 404 to a visitor — but they need
  opposite actions, and collapsing them sends an editor hunting for a typo in a
  link that is perfectly correct. Both name the offending paths, because "3
  broken links" is a search task rather than advice.

  **A path covered by a redirect is not reported.** A published rename leaves a
  `KilnCMS.CMS.Redirect` behind and delivery serves a 301; flagging that reports
  a working feature as a fault, which is the fastest way to make an advisory
  panel something authors learn to ignore.

  `KilnCMS.Links.Internal` mirrors delivery's own resolution order — flat
  `/<prefix>/<slug>`, then the multi-segment path alias, then the redirect
  table — because a checker with its own idea of what resolves reports links
  that work and misses links that don't. It differs in exactly one way, on
  purpose: it looks in every state, so it can distinguish "not published yet"
  from "gone".

  Advisory checks are pure functions, and resolving a link is a query per path,
  so `Kiln.Advisory.Context` gains a **`facts`** map: answers a caller computed
  for the checks, on whatever schedule suits it. A check reading a fact reports
  `:n_a` when it is absent rather than inventing a verdict — a document whose
  links were never checked is not a document whose links are fine. The editor
  recomputes them only when the *set of linked paths* changes, so nothing here
  runs on a keystroke.

  **External link checking is not part of this** — it needs outbound requests,
  per-domain throttling and a per-org opt-in, and ships as its own entry above.

  **The design constraint is that "I could not resolve it" is not "it is
  broken".** The resolver only reports a link broken inside a namespace it owns
  — `/<content-prefix>/<slug>`, or a path an alias or redirect matches — and
  says `:unknown` for everything else, which is never shown. The router serves
  far more than content (`/`, `/blog`, `/search`, `/feed.xml`, every plugin
  route) and enumerating that here would be a second copy of the router. One
  `:error` grades a document Poor, so guessing the other way would have marked
  every page on the site as failing over a single "read more on our blog" link.

  Three things the review caught, each of which would have produced exactly that
  false-positive flood: locale-prefixed URLs (`/fr/blog/x`) resolved as nothing,
  because `Plugs.SetLocale` strips that segment before the router sees it and
  the resolver did not; no default-locale retry, which delivery performs in two
  places, so every link in a translated document on a partially translated site
  read as broken; and a failed query being reported as a broken link rather than
  as unknown. A fourth was a hard crash — the editor passed an `Organization`
  struct where a uuid was required, which reaches a Cachex key and raises on
  `String.Chars`.

  One bug caught by dialyzer: every dynamic content type shares the `Entry`
  table, so resolving a slug without also filtering on `type_definition_id`
  would have let one type's URL resolve against another's content.

- **A `gallery` block, and an `accordion` block that deliberately fires no
  structured data.** Two gaps, one of which was actively producing wrong
  markup (#482).

  **`gallery`** is an ordered set of images with per-image alt text and
  captions, a layout hint (`grid`, `masonry`, `carousel`, resolved through an
  allowlist so no user string reaches a `style`), and one **`ImageGallery`**
  JSON-LD node describing the collection rather than N unrelated images. The
  `image` block holds one image and nothing held a list; a `columns` block could
  fake a grid but carried no gallery semantics, so editors got inconsistent
  crops and hand-placed captions. Editor UX is multi-select from the media
  library — images land in the order they were clicked — plus drag-to-reorder
  *and* keyboard move up/down, because a gallery is only an ordering and an
  editor who cannot reorder it cannot use it.

  **`accordion`** renders the same `<details>/<summary>` panels as `faq` and
  contributes **nothing** to the `@graph`. That is the entire point: `faq`
  always fires `FAQPage`, so an editor reaching for "a thing that collapses" — a
  specification table, a changelog, a set of terms — was publishing a claim that
  the page is a list of questions and answers, and answer engines act on that
  claim. The split is by meaning, not by looks. `faq` is unchanged and remains
  the right block for genuine Q&A.

  Both go through the publish, tracking and safety paths a block is *supposed*
  to go through, which for a block holding a list is not automatic — each of
  these was a silent gap rather than a crash:

  - Gallery image urls are sanitized on the write path. A gallery's urls sit one
    level down inside an `{:array, :map}` field, where the `image` block's own
    clause could not see them — they were the one image src that would have
    reached storage unfiltered.
  - The alt-text publish gate (#403) checks **each** image. It tests for a
    top-level `alt` field, so a fifty-image gallery with nothing described would
    have published while a single undescribed `image` block beside it was
    refused.
  - Media reference edges are recorded per image, so usage counts, re-fire on
    media change, and delivery cache busts all work. The extractor matches field
    names ending in `media_id`; a gallery has none, so it would have recorded no
    edges at all.
  - Delivery batch-loads gallery media in the same single query as image blocks,
    so every image gets its `srcset`, intrinsic dimensions and focal point.

  Three things were fixed in passing, all found by the tests written for this:

  - `srcset` building moved into `KilnCMS.Media.Presentation`. Its rule —
    cropped variants such as `card` are excluded, because a `srcset` is a set of
    interchangeable renderings of the same image and a crop is a different
    picture — is easy to get wrong and was one private function away from being
    reimplemented.
  - The block serializer property test had silently covered only 6 of 13 block
    types: its generator is hand-written, so a new type joined the registry and
    the totality guarantee quietly stopped applying to it. It now covers every
    core type and fails when one is missing. Widening it also showed the
    property asserted a *narrower* contract than `Kiln.Block.Renderer` declares
    — a container block legitimately returns a list of nodes.
  - The block upcaster's string→atom map had fallen five types behind, so `faq`,
    `how_to`, `claim`, `form` and `divider` each resolved to the wrong module's
    migration chain. Harmless only because no block has yet declared a version
    above 1; the first `migrate` step on any of them would simply not have run.
  - **Editing rows on a saved record deleted the document's other blocks.**
    `AshPhoenix.Form.params/1` returns only *touched* fields, so on a form
    loaded from a record it carries no `blocks` key — and `validate/2` rebuilds
    the sub-forms from the keys it is handed. Writing one block's rows back
    therefore dropped every block that was not mentioned. Adding an image to a
    gallery on a saved page would have taken the rest of the page with it. The
    image picker already carried the full block set through for exactly this
    reason; the row buttons now do too.
  - Delivery and the alt-text publish gate both fed block `media_id` values
    straight into a uuid-column filter. Ash rejects a non-uuid at query build,
    so a single junk id written by an import or an API call took the published
    page down with a 500 — and turned "this image has no alt text" into an
    unactionable crash in the editor.
  - **An image block's own alt text was being discarded on the live site.**
    Delivery took `MediaItem.alt` unconditionally whenever the library row
    resolved, while the fired artifact, the previews and the publish gate all
    use the block's alt — which `Validations.MediaAltText` documents as "what
    ships". An image described for its placement, pointing at a library row
    nobody had filled in, passed the gate and then shipped `alt=""`. The block's
    alt now wins, with the library row as the fallback behind it.

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


- **The remaining auth pages no longer render another tenant's branding.**
  `/password-reset/:token`, `/confirm_new_user/:token`, `/magic_link/:token`
  and `/sign-out` are now routed through thin Kiln wrappers
  (`KilnCMSWeb.AuthLive`), which puts them under `use KilnCMSWeb, :live_view`
  and so under the url-less-join guard from #688 (#701).

  They were the last views outside it, because `AshAuthentication.Phoenix`
  ships them and a library module cannot use Kiln's macro. A `/live` join
  carrying no URL matches no route, so it skipped their
  `{LiveUserAuth, :assign_current_org}` hook and left `:current_org` unassigned
  — and `Layouts.brand_or_unbranded/1`, which fails closed on exactly that,
  never ran, because the channel takes the layout from the matched route too.
  `Branding.for_org(nil)` answered with the **default organization**, so a
  password-reset page joined that way on a tenant host drew another site's name
  and logo. No authorization was involved (these pages are unauthenticated by
  design); the leak was identity, which is what #48 exists to prevent.

  Wrapping refuses the join outright rather than trying to render it correctly.

  `/sign-out` is worth knowing about separately: `sign_out_route/3` emits a
  `DELETE` to the auth controller **and** a `live` route in its own
  `live_session`, and only the first is visible at the call site. It reads as
  controller-only and is not, so its live half had a replayable session like
  every other page here. `KilnCMSWeb.LiveJoinWithoutUrlTest`'s exemption list is
  now empty, which is what keeps that true as views are added.

- **A client-chosen payload shape no longer crashes an editor LiveView.** A
  `handle_event/3` payload is arbitrary client JSON and `handle_params/3` has a
  controller's shape freedom, so `%{"q" => q}` constrains the key and never the
  value — `String.trim/1` and `Integer.parse/1` have no clause for a list or a
  map and raise (#764). The authenticated sibling of #751.

  Two mechanisms, which only work together: a `when is_binary(…)` guard on the
  clause heads that would otherwise raise inside their bodies, and a catch-all
  `handle_event/3` that `KilnCMSWeb.MalformedEvent` appends to every Kiln
  LiveView so an unmatched event is a no-op. A guard without the catch-all just
  moves the crash from the body to the head. It has to be `@before_compile`:
  a catch-all injected at the top of a module shadows every real handler in it.

  The three cases reachable by a **crafted link** rather than a pushed event —
  `/editor?q[a]=1`, `/media?q[a]=1`, `/editor/analytics?range[]=7` — now read
  through `KilnCMSWeb.Params`, so a wrong shape is absent rather than coerced.

  `KilnCMSWeb.CollabChannel` is separate: `handle_in/3` had no catch-all and
  `Base.decode64/2` was called on an unguarded `"update"` value, so one
  malformed frame killed that client's channel process and dropped its editor
  to a rejoin mid-edit. It now guards the payload and ignores unknown frames.
  The document room itself survives either way — each client gets its own
  channel process, and `Collab.DocServer` monitors its channels rather than
  linking them.

- **`KILN_STRICT_TEST=true` ran the test suite without strict tenancy, and said
  nothing.** The flag was matched as `== "1"` while
  `docs/environment-variables.md` teaches `true`/`1`/`yes`/`on` for every other
  boolean, so the documented spelling compiled the suite **fail-open** (#646).
  It now accepts the same spellings as everything else, through the standalone
  `config/strict_test_flag.exs` — `config/test.exs` is evaluated before any
  project module is on the code path, so it cannot call `KilnCMS.Config.Env`,
  and `test/test_helper.exs` reads the same snippet instead of carrying a second
  copy of the comparison.

  An unrecognized value now **warns on stderr** rather than passing silently for
  an unset one. That distinction is what the flag's failure mode demands: a
  quiet misparse leaves the strict leg selecting `--only strict_tenancy` against
  a fail-open build, which runs zero tests and exits 0 — indistinguishable from
  never having invoked it, and impossible for any test to catch, since the
  strict-tagged file is excluded.

  The whole failure class here is silence. `--only strict_tenancy` kept
  selecting the tagged tests and they kept passing, against precisely the
  configuration they exist to catch, so a contributor working on epic #336's
  multi-tenancy could believe they had exercised the strict build and had not.

- **Every `config/runtime.exs` line anchor in `docs/environment-variables.md`
  points at the right line again, and a test keeps it that way.** The document
  cites its source by line number for each variable, so any insertion shifts
  every anchor below it at once — and nothing checked them, because
  `mix docs --warnings-as-errors` verifies cross-references between docs and
  *modules*, not offsets into source. 54 were wrong; `TOKEN_SIGNING_SECRET`
  pointed at a Bandit documentation URL, and the branding rows at a comment
  block.

  This has been re-filed three times (#610, #645, #657), which is itself the
  symptom: it was correct when written every time, and wrong by the commit. The
  new test resolves every anchor against the current source and carries its own
  self-check, so the next insertion fails the build instead of the reader.

- **A rate-limited request now answers the same error envelope as everything
  else it sits in front of.** `{"errors": [{"status", "code", "detail"}]}` was
  described in a comment as *"the standard error envelope shared across the
  headless surfaces"* and then written out eight times. The per-IP 429 was the
  one clients hit most and the one that carried least: `{"errors":
  [{"detail": "Too many requests"}]}`, with no `status` and no `code`, so a
  client branching on `errors[].code` fell through to its unknown-error path on
  the single refusal that has a defined recovery — and `POST
  /api/auth/sign_in/verify` could answer 429 in two different shapes for the
  same URL, depending on whether the per-IP bucket or the per-account budget
  refused it. It now answers `code: "too_many_requests"` with the numeric
  `status`, next to the `retry-after` it already sent. The HTML denial page for
  browser navigations is unchanged.

  `GET /api/visual-editing/:type/:slug` likewise answered an envelope-*shaped*
  body with two of the three fields missing, and now answers the envelope.

  Behind both: `FormController`'s copy interpolated the status it was handed
  instead of normalizing it through `Plug.Conn.Status.code/1`, so an atom
  status would have answered `"status": "unprocessable_entity"` where the
  others answer `"422"`. Nothing passed it an atom, so no client saw that one —
  it was a divergence waiting for the next error case added to that controller.

  Every headless surface now renders through `KilnCMSWeb.ApiError.send/4`, and
  a source scan fails the build when a module writes the envelope by hand, so
  the convention is enforced rather than described. `docs/api.md` now also
  names the three shapes that deliberately differ (JSON:API's richer entries,
  form field errors, `/api/resolve`'s verdict) and the two that are known gaps
  (#750). (#744)

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

### Security

- **Promoting a dynamic type no longer leaves its documents unwitnessed for a
  checkpoint interval** (#849). Promotion re-attests a document's history
  anchors under the compiled type (#704), but `Checkpoint.witnessed_head/3`
  resolves entries by `{resource_type, source_id}` — so from the moment
  promotion committed until the next scheduled checkpoint, a promoted document
  had no witness coverage, and a truncation of its newest anchors inside that
  window would not have been caught. Silent, because nothing reports an absent
  entry. Promotion now mints a checkpoint over the re-attested heads.

  Minted **after** the transaction commits, not inside it: minting publishes to
  an immutable witness sink, and committing to heads a rollback could take away
  would leave a published object attesting a state that never existed — the
  exact fingerprint `Checkpoint.publish/2` already treats as an attack. A mint
  failure is logged and does not fail the promotion, since the data move has
  already committed and the scheduled checkpoint still covers those heads.

  The old `("entry", …)` checkpoint entries are deliberately left untouched.
  Their Merkle leaves commit to `resource_type`, so re-keying them — the fix
  the issue first suggested — would invalidate every stored proof against its
  published root, and they are a true record of what that chain's head was
  under the old type. Superseding history is not the same as rewriting it.

- **A form's embed allowlist is now the form's, not the deployment's** (#648).
  `EMBED_ORIGINS` has no tenant dimension, so on a multi-org instance it had to
  be the *union* of every org's embedders — and that union was what every org's
  forms became framable by. An operator allowlisting `https://partner-a.com` for
  one site also authorised it to frame every other site's forms, which is the
  overlay-and-harvest attack #562 closed, one tenant boundary over. The builder's
  Embed tab could not be accurate either: it answered a deployment-wide question,
  so an admin checking "may my embedders frame this?" before pasting a snippet
  got an approximation of the answer.

  Forms carry an `embed_origins` allowlist, set in the Embed tab, and the embed
  page's `frame-ancestors` comes from it. Three states: **use the deployment
  default** (unset — unchanged behaviour, and the whole single-org story),
  **this site only** (closed for this form whatever the deployment allows), and
  **only these sites**. A form's list *replaces* the deployment's rather than
  extending it, so an org can also narrow below what another org needed added
  globally. The tab's banner and allowlist line now read the policy that will
  actually be served for that form, read back out of the rendered directive so
  they cannot name an origin the header does not grant.

  Entries are validated on save with the same predicate as the per-site CSP
  additions in Code Injection (`KilnCMS.CMS.Validations.CspOrigins`): a full
  origin, no keyword sources, no bare `*`, and nothing that could end the
  directive or the header. A bad entry is **refused, naming itself**, rather
  than dropped — a shorter allowlist than the admin typed is indistinguishable
  from a deliberate one. `EMBED_ORIGINS` keeps its own looser grammar and its
  fail-closed parsing; nothing about a single-org deployment changes.

  **On a multi-org deployment, set the allowlist per form and leave
  `EMBED_ORIGINS` unset** — a form that has not been given one still inherits
  the deployment's, so the shared union governs every untouched form exactly as
  before. `docs/threat-model.md` records what that leaves open.

- **A CSP source may no longer wildcard a public suffix.**
  `KilnCMS.CMS.Validations.CspOrigins` accepted `https://*.com`, which is
  syntactically a leftmost-label wildcard and semantically every `.com` site —
  a bare `*` wearing a hat, in the validation that refuses bare `*`. A wildcard
  now needs at least two labels after it (`https://*.acme.com`). Affects the
  per-site Code Injection lists as well as the new embed allowlist; a stored
  value in the old shape keeps working until the next save of that settings
  form, which then refuses it.

- **A form's embed allowlist survives duplication.** `duplicate_form` copied a
  hand-written list of attributes that had already drifted (the autoresponder
  fields were never copied), so a duplicate lost `embed_origins` and silently
  fell back to the deployment-wide allowlist. It now copies every attribute the
  create action accepts.

- **Webhook delivery now goes through `KilnCMS.SafeFetch`** (#753). The address
  pinning that closes the DNS-rebinding window — resolve once, connect to the
  literal, keep SNI and certificate hostname verification aimed at the real
  name, restore the `Host` header, follow no redirects — existed twice: once in
  `SafeFetch` and once in the `Webhooks.DeliveryWorker` it was extracted from.
  Fifteen lines of TLS options that fail *open* when mistyped, in two places,
  with `SafeFetch`'s own moduledoc claiming there should be one. There is now
  one, and the worker also picks up the streaming byte cap it never had — with
  truncation, so a receiver that answers 200 with a large body stays a delivered
  200 rather than becoming a permanent failure the cap invented.

  The ledger's `last_error` vocabulary is unchanged. `SafeFetch` writes for its
  own callers and prefixes differently, so each of its shapes is *translated*
  rather than wrapped — wrapping read `delivery failed: request failed:
  %Req.TransportError{…}`, the documented wording with somebody else's inside
  it.

  **An IPv6 endpoint could never be delivered to.** The pinned host was
  bracketed by hand *and* by `URI.to_string/1`, producing
  `https://[[2606:2800::1]]/x` — so a webhook to any endpoint whose DNS answer
  is IPv6 failed with a transport error that named nothing. It affected oEmbed,
  link checking, federation and social posting too, since all of them share this
  path. Found by writing the pinning test #753 asked for; the round-trip is now
  asserted. The `Host` header for an IPv6 *literal* URL keeps its brackets as
  well, so `[2606:2800::1]:8443` is no longer sent as an ambiguous
  `2606:2800::1:8443`.

  `SafeFetch` gained the test suite the issue names — the refusal of private and
  link-local addresses, the pinned connection's TLS options asserted as values
  (a `Req.Test` round trip cannot see them; the plug adapter never opens a
  socket), the byte cap holding against a lying `content-length`, and
  `decode_body: false` meaning the caller always gets bytes.


- **`mix kiln.audit.verify` can now fail a run it previously passed, and no
  longer calls a chain "intact" when its attestation stops short of the head.**
  A chain can have anchors that verify *and* a newer one that does not;
  verification can then only hold the document to the newest attested anchor's
  prefix, so versions past that point are anchored by a row nothing attests
  (#811). That is what an attacker with INSERT **and** DELETE on
  `history_anchors` produces: delete the verified head, doctor only the versions
  it covered, re-insert an unsigned anchor refolded over the doctored rows.

  A chain where **nothing** verifies is reported on the same terms, for a
  sharper reason: `Chain.anchor_digest/1` covers neither `key_id` nor
  `sequence`, so a single `UPDATE ... SET key_id` makes every anchor of a
  document unjudgeable while leaving every link and sequence number intact — a
  cheaper primitive than the DELETE, landing on the same silent line.

  Both shapes are equally what an honest deployment produces when its signing
  key goes away between publishes. They are identical inside the table, so this
  is **reported** rather than called tampering, and the verdict ladder is
  unchanged.

  **The exit code splits on whether a signing key is configured.** A deployment
  that could have signed and did not now fails the run — if you audit in CI with
  a key configured and unsigned anchors present, that job will start failing.
  One with no key configured is describing its operator's own choice and does
  not. Neither is settled here; the checkpoint witness (#666) is.

  The governance dashboard shows the same fact on the trail, in place of the
  "History intact (anchor unsigned...)" badge it showed unconditionally.


- **Demoting, offboarding or erasing a user now drops their live sockets.**
  Authorization on every socket ran **once** — at connect, and at join for
  channels — and was never revisited. `CollabChannel.handle_in("update", …)`
  re-checks nothing; it only needs the `doc_server` its join resolved. So an
  account that was demoted to `:viewer`, removed from an organization, had its
  `editable_types` / `readable_types` / audiences narrowed, or was erased kept
  everything its live sockets already held — on every joined channel, for as
  long as the tab stayed open. Every HTTP surface refused it immediately; the
  sockets did not. `grep -rn "Endpoint.disconnect" lib/` returned nothing.

  That was tolerable while the collab socket was inert. #655 made the join the
  security boundary, which made "evaluated once, never again" load-bearing —
  and offboarding an editor mid-session is exactly the case an operator assumes
  is covered.

  Two halves had to be true, and neither was. **The sockets could not be
  dropped at all:** `GraphqlSocket.id/1` returned `nil`, which is Phoenix's way
  of saying a socket is never disconnectable; `BridgeSocket` is a raw transport
  with no `id/1` callback; and nothing set a `live_socket_id`, so `/live` was
  undroppable too. Only `CollabSocket` had a usable id, and nothing used it.
  **And no action fired an eviction.** All four are now reachable, from one
  topic built by one function so the broadcaster and the listeners cannot drift
  onto different strings — a mismatch would fail silently, in the direction of
  not evicting.

  Evicting is not re-authorizing. The client reconnects immediately and that
  reconnect runs the full authorization it always did, so the effect is "prove
  it again" — the cheapest correct answer to a changed grant, and it costs
  nothing on the CRDT hot path. Nothing tries to tell a widened grant from a
  narrowed one either: that comparison is subtle, its failure mode is silent,
  and being wrong in the permissive direction is the bug.

  It is prompt rather than complete: it fires on the actions wired to it, so a
  change nobody remembered to wire in is still invisible to a live socket. The
  backstop is periodic re-authorization inside the channel, filed as #775. (#675)

- **An editor can no longer clear an admin-set block field by omitting it.**
  `EnforceBlockFieldPolicy` (#51) stopped an editor *setting* a restricted field
  — `KilnCMS.Blocks.Quote` declares `field :featured, editable_by: [:admin]` —
  but not clearing one. A block with no id reads as new, where a restricted
  field must equal its declared default; omit the field and the cast supplies
  exactly that default, so the write looked like a no-op and silently reset what
  an admin had set. Block ids cannot round-trip on the headless path: `blocks`
  is not `public?`, so a client never reads the tree it would be preserving.

  A **wholly id-less** tree that omits such a field is now refused when any
  stored block of that type holds a non-default value for it, and the error says
  to send the block ids. The rule only ever refuses — it never permits a write
  that used to fail, and never writes a value nobody submitted.

  Both alternatives were tried and rejected. Pairing id-less blocks with stored
  ones by position looks like identity and is not: it handed the featured slot
  to whatever new content landed in that position, and refused an editor merely
  inserting a block above a featured one. Carrying the value forward silently
  writes something the client never sent. "Wholly" id-less matters for the same
  reason — a tree carrying any id shows the client can round-trip them, so a
  block without one there is genuinely new and is judged as before.

  A page with nothing restricted set behaves exactly as it did, which is why
  this is narrower than requiring ids on every write. Still open, and now
  recorded rather than implied: reusing the id of another block **of the same
  type** moves an admin-set field off the block that had it, and an empty
  `block_tree` deletes the block outright. Both are about which block an id
  names rather than what a field may hold. (#566)

- **Registration, password-reset and magic-link forms are bounded per client
  address.** #715 closed this for the sign-in submit: AshAuthentication's forms
  are LiveComponents calling `AshPhoenix.Form.submit/2` in-process, so the
  credentials arrive as a `/live` event, pass no router pipeline, and no plug
  can reach them. The same argument covered three more forms and none was
  wired.

  Registration was the sharp one: one websocket replaying `submit` was
  **unlimited account creation** — a bcrypt hash and a confirmation mail per
  event, from a single address, with nothing counting.
  `register_with_password` carried `RegistrationEnabled`, `HashPasswordChange`
  and `GenerateTokenChange`, and no budget of any kind. It is worth knowing that
  all four forms render on all three of `/sign-in`, `/register` and `/reset` —
  `Components.Password` emits the sign-in block unconditionally and hides the
  rest with a CSS class — so which page a caller is on bounded nothing.

  Registration now charges a new **`:register`** bucket, tighter than `:auth`
  and separate from it: sharing would let a burst of legitimate sign-ups lock
  *sign-in* for everyone behind one office NAT. It gets no per-*account* budget,
  because there is no account yet and the address is attacker-chosen — keying on
  it would let anyone deny a specific address its first registration.

  Reset and magic-link requests charge `:auth`, alongside the sign-in they sit
  beside. The per-address mail budget already capped the mailbomb; what was
  uncapped was the request rate, and each one is a database read plus a token
  mint. This also makes `docs/threat-model.md`'s `/register` and `/reset` rows
  honest again — after #715 they were true only of the GETs.

  Registration has a second door, which review caught: `auth_routes` also
  generates `POST /auth/user/password/register` as the non-JS fallback, and it
  ran through the pipeline's `:auth` plug at **20/min** — four times the stated
  ceiling — while the action's charge saw no client-IP context and did nothing.
  So a scripted client got the looser limit *and* spent the sign-in bucket
  doing it, which is the coupling `:register` exists to prevent. That path now
  charges `:register` **instead of** `:auth`; charging both would leave the
  coupling in place.

  A refused registration also rendered nothing at all — `AuthenticationFailed`
  is a forbidden-class error, which `AshPhoenix.Form` surfaces as no field
  error, so the Register button appeared to do nothing. It now carries an
  `:invalid`-class error on the email field, because a registration refusal has
  no secret to keep: it says only that the caller's own address is out of
  budget, which they know.

  Each of the three needed a different hook, which is why they are three
  modules over a shared `KilnCMS.Accounts.ClientIpBudget`: a create takes a
  `change`, the magic-link request is a read and takes a `prepare`, and the
  reset is a *generic* action with neither, so its charge wraps the run. All of
  them charge from `before_action` rather than the callback body, because those
  run per changeset build and `AshPhoenix.Form.validate/2` builds one per
  keystroke on a `phx-change` form — a charge there would lock a user out while
  they typed their password. A test walks the whole seam for each form, from the
  rendered page through to the bucket. (#724)

- **The OpenAPI document and Swagger explorer are no longer served in
  production by default.** Both shipped unauthenticated in *every* environment
  — unlike `/dev/dashboard`, `/dev/mailbox`, `/admin` and the GraphQL
  playground, which are all behind `dev_routes`. Since #330 the surface they
  describe includes the **write** routes, so the document is a complete,
  machine-readable map of the mutation API: which actions exist, what they
  accept, what they return.

  Disclosure rather than access — every route it documents is still enforced by
  the Ash policies and the API key's access scope, so serving it granted
  nothing. What it removed was the guesswork, and it sat beside a GraphQL
  endpoint whose introspection production already disables for exactly that
  reason. The inconsistency was the bug.

  `config :kiln_cms, :api_docs` follows the same posture: on in dev and test,
  off in a production build, and back on with `API_DOCS_ENABLED=true` for an
  operator publishing a public API. Disabled, both paths answer **404**, not
  403 — a 403 confirms the route exists and is merely closed, which is the one
  thing a closed docs endpoint should not volunteer.

  The explorer's relaxed CSP, which allows `https://cdnjs.cloudflare.com` for
  its bundle, is a second and smaller reason not to ship it to production; it
  now goes with it.

  Review caught the gate being walked past: `Phoenix.Router` decodes each path
  segment to pick a route but leaves `conn.path_info` raw, so
  `/api/json/%73waggerui` matched the `forward` while missing a literal
  comparison in the plug — serving the whole explorer with the flag off. It
  compares decoded segments now, and a test covers five encoded spellings, the
  sub-paths under the explorer, and every HTTP verb.

  **Upgrading:** if you rely on `/api/json/open_api` or `/api/json/swaggerui`
  from a production deployment, set `API_DOCS_ENABLED=true`. Nothing else
  changes; the content routes are unaffected, and a test pins each one's
  expected status rather than merely that it is not a 500. (#567)

- **A bracketed query parameter no longer 500s a public route.** Plug's query
  decoder hands the caller the *type* as well as the value — `?q=x` is a
  binary, `?q[]=x` a list, `?q[a]=x` a map — and a `%{"slug" => slug}` function
  head constrains the key, never the value. Ten public, unauthenticated entry
  points passed one of those straight into a parser with no clause for it, so
  `GET /api/content/page?as_of[]=2020-01-01` answered **500** where `?as_of=`
  answers a documented 400. Neither `FunctionClauseError` nor
  `Protocol.UndefinedError` is a `Plug.Exception`, so each request was also one
  error-tracker event: an anonymous report generator, the same shape #700 was
  worth fixing on its own.

  Two ways of forgetting, which is why a sweep found four times what the issue
  named. A bare parser (`Integer.parse/1`, `DateTime.from_iso8601/1`) raises on
  both shapes. `to_string/1` quietly *absorbs* the list — `to_string(["x"])` is
  `"x"` — and raises only on the map, so a site could look exercised and still
  be one bracket from a 500.

  `KilnCMSWeb.Params.string/3` is now the reader: a value the client sent in a
  shape the parameter does not have reads as **absent**, which is what every
  one of these already had a documented fallback for. `?as_of=` is the
  exception and keeps its guard on the parser, because reading it as absent
  would serve the live document to a compliance reader asking what it said on a
  date — worse than the crash.

  Covered: fired artifacts (`as_of`, `limit`, `locale`, `surface`), related
  content, search, ask, resolve, provenance, visual editing, the on-site search
  and blog pages, form submissions, newsletter subscribe, and the collab
  socket's `token` — that last one read **before** any authentication. A test
  drives every one through the real router in all three shapes; it fails 16
  ways against the old code.

  `Params.integer/4` covers the other half — the bounded numeric parameters
  that were each a hand-rolled `Integer.parse(to_string(…))` plus a range
  match. And because a helper every call site must *remember* is the same
  "convention enforced nowhere" #744 was filed about, a source scan fails the
  build when a controller or channel reaches for `to_string/1` on a request
  parameter, with a self-check proving the scan can fire.

  One behaviour change worth naming: `?q[]=hello` used to search for `hello`,
  by accident of `to_string/1`. It now searches for nothing, because `?q[]=` is
  not a spelling of `?q=` and one request meaning two things depending on which
  helper the handler reached for is the drift worth removing. (#751)

- **The two sign-in gates no longer carry their own copy of the pending-token
  plumbing.** Not a bug fix — a prediction. #726 unified the code *check* into
  `KilnCMS.Accounts.SecondFactor`, so the browser prompt and the headless
  `POST /api/auth/sign_in/verify` could not disagree about what counts as a
  valid submission. Everything *around* it was still written twice: the mint,
  the resolve, the five-minute lifetime, and the charge → verify → forgive
  ordering. Four places for the next hardening on that step to land on
  whichever door its author was looking at, which is what #726 itself was.

  The ordering is the sharp one. `AccountThrottle`'s moduledoc names
  check-then-count as the bug class it exists to prevent, and the correct order
  was enforced by prose in two files. Getting it backwards fails *silently* —
  still refusing wrong codes, just with an unbounded budget.

  Now `KilnCMS.Accounts.PendingSignIn` owns the blob for both, taking a mode:
  `:session` signs (the browser's blob lives in the encrypted session, so the
  client never sees it) and `:encrypted` encrypts (the headless client holds
  it, and the payload carries the first-factor JWT — signing would publish the
  credential the second factor exists to withhold). Distinct salts keep the two
  non-interchangeable, and each mode carries only the fields its own door has:
  a `jti` for single use, which the browser gets free by deleting the session
  key, and the remember-me intent, which a headless client has no cookie for.
  `SecondFactor.check/2` owns charge → verify → forgive, so the ordering is a
  property of the module rather than of two call sites.

  `AuthController.sign_pending/4` and `verify_pending/2` are gone. The second
  of those was called from `TwoFactorController`, which is the cross-controller
  reach into a sibling's private plumbing this replaces. No behaviour change.
  (#745)

- **A password that stops at the code prompt no longer clears the account's
  sign-in budget.** #478 bounds guesses per account and clears the counter on a
  successful password, which is right when the password *is* the sign-in. For a
  2FA account it was the hole: the password succeeds, so the counter reset on
  every attempt, and the per-account bound simply did not apply to the one
  attacker it most needed to.

  Someone holding a stuffed password for an account they cannot pass could loop
  `POST /api/auth/sign_in` unboundedly — the only remaining limit was the per-IP
  `:auth` bucket, which is the axis #478 exists *because* attackers rotate. Each
  pass also mints and stores a token row nobody will ever hold: `User` sets
  `store_all_tokens?`, so the JWT is written before the controller learns the
  account owes a code, and an abandoned exchange leaves it live for its natural
  lifetime. Nothing turns those rows into a credential today (they are AES-GCM
  encrypted in a blob the caller cannot read), but they were unbounded growth in
  `tokens` for an account of the attacker's choosing, and a store of live
  credentials that a later tokens-table read or `secret_key_base` compromise
  would upgrade a password-only position into.

  The counter is now held until `SecondFactor.check/2` sees the second factor
  actually land, and cleared there. An account with no second factor is
  unchanged — its password still clears the counter, because for it the
  password is the whole sign-in. The visible cost is that abandoning the code
  prompt ten times inside one window is refused for the tail of it, which is
  the same bargain every other account here already makes.

  This does not stop the rows being written; it bounds how many an attacker can
  cause. Not minting until the second factor verifies is the deeper fix and
  fights `require_token_presence_for_authentication?` — still open on #742's
  own terms. (#742)

- **A second-factor lockout now tells the owner.** #478 mails an account owner
  when their *password* is being guessed at. #714 added the equivalent budget
  for the *second factor* and mailed nobody, which is backwards on signal
  strength: reaching the code prompt requires a signed pending token, and that
  token is only minted once a **first factor has already succeeded**. A
  second-factor lockout is not "someone is guessing at your account" — it is
  "someone got in far enough to be asked for a code".

  It was worse than an unwired notification. The password alert *could not* fire
  in that scenario either: to keep grinding codes an attacker must keep minting
  pending tokens, which means re-running the first factor, and that step
  succeeds — so `ThrottleSignIn` forgave the sign-in counter every time and its
  budget was never reached. Net: in the one case where a primary credential was
  provably in someone else's hands, the owner received nothing at all. (#742,
  above, closes that reset, so both alerts now fire on this attack. This one
  still rings first, because the second-factor budget is the tighter.)

  `KilnCMS.Accounts.SecondFactor.check/2` now fires the alert for **both**
  sign-in gates — the browser prompt and the headless
  `POST /api/auth/sign_in/verify`. Shared rather than written out per
  controller because it is three coupled pieces (the charge, the alert, the
  deny shape), and a gate that quietly stopped alerting would look exactly like
  a working one; that is #726 in miniature.

  The copy is careful about two things the obvious wording gets wrong:

  - It does **not** say "someone has your password".
    `AuthController.success/4` is the callback for every registered strategy,
    so a magic link and an SSO assertion reach the code prompt exactly as a
    password does. For those users the compromised credential is their mailbox
    or their identity provider, and a mail telling them to change their Kiln
    password would leave the actual hole open. The mail names all three.
  - It does **not** assume an attacker. The budget is shared with the settings
    forms (#727), so an owner who fumbles five codes regenerating their recovery
    set and then signs in normally trips this with nobody attacking them — the
    likeliest trigger in practice. "If that was you" comes second, before the
    intrusion paragraph rather than after it.

  Its once-per-six-hours budget is separate from the password alert's, so the
  weaker signal cannot suppress the stronger one in exactly the order an attack
  produces them. The refusal is logged when the mail goes and when it is
  suppressed, and a delivery failure hands the claimed window back rather than
  swallowing six hours of alerts along with the one mail.

  A lockout confined to `/editor/settings`, with no sign-in attempt after it,
  still notifies nobody — the person there holds a session rather than a first
  factor, so it is different news and wants different copy. Filed as #757.
  (#728)

- **The three TOTP actions on `/editor/settings` are now budgeted, so a stolen
  session can't grind the six digits that gate them.** #714 bounded the second
  factor at `POST /sign-in/verify`; the other actions that check the same code
  — `disable_totp`, `regenerate_totp_recovery_codes` and `confirm_totp`, all
  LiveView events — were charged nothing at all. A LiveView event passes no
  router pipeline, so they did not even get the per-IP `:auth` bucket, the gap
  #715 closed for the sign-in submit. An attacker with a stolen session cookie
  could push the event in a loop and grind 10^6 at socket speed; on a hit,
  `disable_totp` nulls `totp_secret` and empties the recovery hashes.

  `confirm_totp` belongs on that list for a reason worth stating, because it
  reads like enrolment and looks exempt. It is not scoped to an enrolment in
  progress: run against an account that is **already** enrolled, it validates
  against the *live* secret and mints a fresh recovery-code set, invalidating
  the owner's — the same prize `regenerate_totp_recovery_codes` gives, from a
  differently-named door, while `totp_secret` and `totp_confirmed_at` stay put
  so the owner's authenticator keeps working and nothing looks wrong.

  All three now charge `AccountThrottle.consume_second_factor/1` — five per
  account per fifteen minutes, and deliberately the **same** bucket
  `/sign-in/verify` uses, so an attacker cannot exhaust one prompt and pivot to
  another for a fresh five. The charge is declared on the Ash action rather
  than in the `handle_event` clauses, so a fourth caller inherits the bound
  instead of missing it, and it lands in a `change` body rather than a
  `before_action` hook, because a hook never runs for the invalid changeset a
  wrong code produces — and a wrong code is the only one worth charging.

  The forms now say "too many attempts — try again in N seconds" rather than
  "that code isn't valid", which is the opposite advice.

  Two things this does *not* do. It bounds guessing only: `setup_totp` still
  clears `totp_confirmed_at` with no code at all, removing the second factor
  without guessing anything — filed as #754. And it hands a stolen session a
  small denial-of-service it did not have, since five wrong codes here deny the
  real owner `/sign-in/verify` for the rest of the window — strictly less than
  what holding the session already grants. (#727)

- **`POST /api/auth/sign_in` no longer skips the second factor.** A 2FA-enabled
  account's password alone returned a full user JWT here — the credential for
  JSON:API, GraphQL and the headless REST surface, carrying that user's real
  role — while the browser flow diverted the same account to `/sign-in/verify`.
  That made TOTP optional in practice rather than in policy: there is no point
  bounding six digits at one prompt (#714) while a door next to it does not ask
  at all. Every mitigation on a second factor is worth what the weakest path
  that skips it is worth (#726).

  The headless flow now mirrors the browser one. Correct credentials for a 2FA
  account answer **`200`** with `{"two_factor_required": true, "pending_token":
  …, "expires_in": 300}` and **no bearer token**; the new
  **`POST /api/auth/sign_in/verify`** exchanges that pending token plus a TOTP
  or recovery code for the `201` the first call used to give. Accounts with no
  second factor are unchanged — one call, `201`, token.

  Three details are load-bearing rather than incidental. The pending blob is
  **encrypted**, not signed: the browser's equivalent can be signed because it
  lives in the encrypted session cookie, but this one is handed to the client,
  and signing it would publish the first-factor JWT it carries in a payload
  anyone can decode — reopening the same hole in a shape that looks fixed. It is
  **single-use**, because the request most likely to end up in a log is a
  successful one, and a replayable success is a credential with a five-minute
  tail. And the code is charged the **same per-account bucket** the browser
  prompt charges, because a budget an attacker can double by alternating
  endpoints is not a budget.

  Said precisely, what the second factor withholds is the caller's *access* to
  the token, not its existence: `Strategy.action/3` mints and stores it before
  anything looks at whether 2FA is on. `docs/threat-model.md` states it that way
  round, because "no token is issued" would tell an incident responder there is
  nothing to revoke.

  Two things found in the same pass and fixed here: pasted codes containing
  whitespace (`123 456`, what every authenticator app copies) were accepted at
  sign-in but rejected by the enrolment and disable forms — normalization now
  lives in `Totp.valid?/3`, below all three callers; and `Retry-After` was
  computed with truncating division, so a refusal with under a second left told
  a conforming client to retry immediately.

  Passkeys were checked in the same pass and are **not** a bypass: every Kiln
  passkey is registered *and* asserted with user verification required, so the
  ceremony clears the bar TOTP is there to set, and there is no headless passkey
  route in any case. `docs/threat-model.md` now records that as policy rather
  than leaving it to be inferred.

  This changes the response contract of an existing endpoint — see
  **Upgrading**.

- **History anchors verify as a chain, not just at the head.** Three ways to
  move the verification baseline without deleting anything the chain would
  notice, all closed (#597, #666).

  **The foundation: every anchor's signature is now checked, not only the
  baseline's — and an anchor that cannot be judged floors the whole chain.**
  While only the head was checked, every other anchor's attested columns were
  freely rewritable, and those columns are exactly what any structural invariant
  is computed from. Merely *skipping* an unjudgeable anchor was the same hole one
  column over: the digest chain covers neither `key_id` nor `sequence`, so
  `UPDATE … SET signature = NULL` on a non-head anchor made it invisible to the
  sweep, after which it could be renumbered into the baseline position with
  nothing objecting. A chain containing an anchor nobody can vouch for now reads
  `:unsigned` or `:unverifiable`, never `:verified`.

  **That means some deployments will see a verdict change without anything being
  wrong.** An instance that turned signing on partway through its life has
  anchors from before it, and those are genuinely unattested — such a document
  now reads `:unsigned` where the head alone read `:verified`. That is the
  honest answer, not a regression; it is the same answer a fully keyless
  deployment already got. The floor never *softens* anything either: the hash
  comparison needs no key, so real tampering is still reported as `TAMPERED`
  even with no signing key configured at all.

  Cost is one signature verification per anchor, measured at ~72 µs — about
  150 ms for a document with 2 000 anchors. Audit paths only: the governance page
  and `mix kiln.audit.verify`. Nothing on the delivery path verifies a chain, but
  note the fleet sweep is now O(total anchors) rather than O(documents), so it is
  not something to put on a tight cron on an `anchor_every_write` deployment.

  **Reordering.** `verify/4` takes the *latest* anchor as its baseline, and
  "latest" was decided by `inserted_at` — a column written by the database and
  attested by nothing. So `UPDATE history_anchors SET inserted_at = now() WHERE
  id = <an older, shorter anchor>` made that anchor the baseline: the doctored
  versions then sat outside the anchored prefix, were never hashed, and the
  verdict was `:verified` with not a single row deleted. Anchors now carry a
  1-based per-document `sequence`, inside the signed payload (v4), and that is
  the order they are read in.

  It is **`NOT NULL` and unique**, and both matter. A nullable position would
  have been the same hole one column over — nothing attests an *absent* value,
  so nulling the newest positions would have rolled the baseline back just as
  the timestamp rewrite did. Unique because assigning it is a read-then-write in
  `after_transaction`: without the constraint two concurrent mints pick the same
  number, and the run reads `[2, 2, 1]` — a permanent, unrepairable false tamper
  verdict on a document nobody touched. With it, the loser's insert fails into
  the existing rescue as a logged skip.

  **Holes.** The predecessor links added in #591 catch a middle anchor removed
  while its successor survives. They do not catch it when the successor goes too
  — every surviving link still resolves. On a signed deployment the signature
  sweep does, because the attacker has to rewrite the survivor's link columns to
  get there and those are signed. On an unsigned one, where that is free, the
  position gap is what is left. `prev_anchor_id` also gains `ON DELETE
  RESTRICT`, which forces the attacker into that shape.

  Be precise about what `RESTRICT` does **not** buy: Postgres checks the
  constraint after the statement's rows are gone, so `DELETE … WHERE source_id =
  …` removes referrer and referent together and succeeds. It narrows the attack;
  it does not stop a wipe. Both behaviours have tests.

  **Still open, and stated rather than implied.** Deleting the *newest* anchors
  is undetectable — and so is *hiding* them, since rewriting `resource_type` or
  `source_id` takes them out of the set the query returns, which is the same
  attack with `UPDATE` instead of `DELETE`. (Worth knowing because "revoke
  `DELETE` from the application role" is the usual advice and it does not cover
  this.) Nothing points at the newest one, so a shorter chain is
  indistinguishable from a younger one, and no state inside the document's own
  anchor set can tell them apart — which is why **#666 stays open** for a witness
  outside the database (an append-only log, retention-locked object storage, a
  transparency log). `docs/governance-dashboard.md` now tells operators to export
  the head digest on a schedule if the property has to actually hold. On an
  unsigned deployment the structural checks still run and still report, but treat
  them as advisory: they raise the cost of a forgery, they do not attest
  anything.

  Existing anchors are backfilled in write order and keep verifying — they were
  signed before the column existed, so both the v4 and v3 payload shapes are
  offered and each anchor matches exactly one. Their positions are therefore not
  covered by their own signatures; what holds them in place is that
  `version_count` must rise with position — on columns the signature sweep has
  established are attested, which is why an anchor it cannot judge floors the
  chain rather than being skipped. A short early anchor cannot be promoted to the
  baseline. (#597, #666)

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

### Upgrading

**The occurrence backfill runs itself** (#766) — no step to perform, but worth
knowing it happens. The migration adds `next_occurrence_at` and cannot fill it
(the value is the recurrence engine's output, not a function of other columns),
and the hourly sweep will not fill it either, because it visits rows whose
occurrence has **passed** and a `NULL` has not passed anything. So booting
enqueues a one-off backfill job on the `:default` queue.

What that means on your first deploy after upgrading: one background pass over
your event-shaped content, writing only the rows whose value changes. It is
deduplicated for a day at the database level, so a rolling deploy queues one job
across all replicas. Nothing else reads the column — the `.ics` routes, the
feeds and the document pages are unaffected either way — so the blast radius is
the new `/<plural>` and `/<plural>/index.json` routes only.

Set `KILN_OCCURRENCE_BACKFILL_ON_BOOT=false` if you would rather run
`mix kiln.occurrences.backfill` (or `bin/kiln_cms eval
'KilnCMS.Events.Backfill.run()'`) at a time you choose. Reversible by rolling
the pin back — the column is additive and nothing else reads it.

**`POST /api/auth/sign_in` can now answer `200` instead of `201`, and any client
that branches on the presence of `token` will read that as a failure.** For an
account with two-factor authentication enabled, the password alone no longer
returns a bearer token (#726) — the response is `200` with
`{"two_factor_required": true, "pending_token": …, "expires_in": 300}`, and the
token comes from a second call to `POST /api/auth/sign_in/verify` carrying that
pending token plus a TOTP or recovery code. **Branch on the status code.**

Nothing changes for an account without a second factor: one call, `201`, token.
So the blast radius is exactly your scripts that sign in as a 2FA-enabled user —
check for those before deploying, because the failure is silent on the client
side (a `200` with no `token` reads as a malformed response, not as an auth
error). For unattended server-to-server use, move those callers to an **API
key**: keys carry no second factor by design and are unaffected by any of this.

Two smaller contract notes on the same endpoint:

- Errors from both steps now carry a stable machine-readable `code` alongside
  the existing `detail`: `invalid_credentials`, `missing_parameters`,
  `pending_expired`, `invalid_code`, `too_many_attempts`. Purely additive.
- Send `code` as a **string**. A JSON number is no longer reported as a missing
  parameter, but a leading zero still makes the integer form wrong half the
  time.

No migration, no config, and rolling back is symmetric — the old endpoint simply
resumes issuing tokens on the password alone, which is the bug.

**Rolling back past the history-anchor sequence migration is a one-way door for
the audit surface.** `history_anchors.sequence` is inside the signed payload of
every anchor minted after the upgrade (#666), so `mix ecto.rollback` past it
drops the column and makes all of those anchors report
`{:tampered, "anchor signature does not verify"}`. Rolling *forward* again does
not heal it — the column comes back empty. Nothing else in the release depends
on it, so if you need to roll back for an unrelated reason, roll back the
application and leave this migration applied.

The migration backfills the column before the `NOT NULL` lands, so it runs on a
populated table. It does take an `ACCESS EXCLUSIVE` lock on `history_anchors`
for its duration — brief on a publish-only deployment, longer on one running
`audit_anchor_every_write`, which mints an anchor per save.

**It will not stop your deployment coming up.** If some anchor names a
predecessor that no longer exists — the hole #597 exists to detect — the foreign
key is still added and still protects every new write, but as `NOT VALID`: the
existing rows are what it cannot vouch for. The migration warns, names the count,
and prints the query that lists them. Turning a detection into a failed boot is
how detections get switched off, so it deliberately does not. Once the rows are
accounted for, `ALTER TABLE history_anchors VALIDATE CONSTRAINT
history_anchors_prev_anchor_id_fkey;` marks the constraint good.

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

**Integer-valued variables are now bounded at 2³¹-1** (#1091), which affects
`BACKUP_KEEP_DAYS`, `BACKUP_STALE_AFTER_HOURS`, `KILN_READING_TIME_WPM`,
`KILN_EXPERIMENTS_STICKY_DAYS` and `KILN_ANALYTICS_LOW_COUNT_THRESHOLD`. Elixir
integers are arbitrary-precision, so a mistyped digit —
`BACKUP_KEEP_DAYS=144444444444444` for `14` — used to parse cleanly and be
honoured as a four-billion-year retention. Such a value now keeps the **default**
and warns on stderr naming the bound, in line with every other unrecognized
read. The bound is not a claim about a sensible retention; every real value for
every variable this reads is smaller by orders of magnitude. No action needed
unless you deliberately set one above the bound, in which case the effective
value changes from what you typed to the default — check `docker logs` after
the first boot.

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

[Unreleased]: https://github.com/The-Verscienta/kiln_cms/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.5.0
[0.1.0]: https://github.com/The-Verscienta/kiln_cms/releases/tag/v0.1.0
