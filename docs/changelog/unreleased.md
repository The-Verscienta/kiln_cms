# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="media-resnapshot-upgrade"></a>

- **Optional: run `mix kiln.media.resnapshot --apply` once after deploying.**
  A `:media` custom field's stored value gains `width`, `height`,
  `mime_type`, `focal` and `variants` when its record is next saved; this
  re-takes every stored value now, through the content write path (versioned,
  `updated_at` and the lock kept, no webhook). Without `--apply` it is a dry
  run that reports what it would write. In a release, the task's work is
  `KilnCMS.Media.Resnapshot.run/2` over `bin/kiln_cms rpc`. Fired artifacts
  need nothing: they re-fire on their next read (`format_version` 3), or at
  once with `mix kiln.refire_all`.

## Breaking

<a id="provenance-default-upgrade"></a>

- **Provenance is on by default (#1929).** `KILN_PROVENANCE_ENABLED` now
  defaults to `true`. What that means for an install upgrading to 1.7:
  - **With a key mounted** (`KILN_PROVENANCE_KEY_FILE` or
    `KILN_PROVENANCE_PRIVATE_KEY`): every fire from now on stores a signed
    manifest. Run `mix kiln.refire_all` (`KilnCMS.Firing.Sweep.run()` over
    `rpc`) to sign what was fired before.
  - **With no key:** nothing is refused. Artifacts are served `unsigned`, the
    verify endpoint says so, and platform admins see a strip on the console
    overview naming `KILN_PROVENANCE_KEY_FILE`. Either mount a key and set that
    variable, or press *Generate a key* there (stored encrypted, as `/setup`
    does on a new install), then re-fire.
  - **To keep the pre-1.7 behaviour,** set `KILN_PROVENANCE_ENABLED=false`:
    no manifests, and every `/api/provenance/*` endpoint `404`s.
  The release's migrations add `published_artifacts.manifest` (nullable) and
  the `provenance_settings` table. Both are additive.

## Added

<a id="provenance-on-by-default"></a>

- **Provenance on by default, with a public verify endpoint (#1929).**
  Provenance signing existed since #340 but was off by default, and its
  manifests were derived from the live body each time they were asked for, so
  "verify" compared a body with itself. Now:
  - **Every fire stores its manifest** (`published_artifacts.manifest`), made
    by `KilnCMS.Provenance.sign_fired/4` from the body as it will read back.
    One RSA signature per surface, the key resolved once per fire. A signing
    failure leaves the artifact unsigned; it never fails the fire.
  - **`GET /api/provenance/verify/:type/:slug`** checks the served body
    against that stored manifest: `verified`, `tampered` (a changed body or a
    changed manifest, against a key this instance holds), `unsigned` (nothing
    stored) or `unverifiable` (a key it no longer holds, never reported as
    tampering). Anonymous, `public, max-age=60`, any `?surface=`, and covered
    by the API contract. The manifest endpoint now serves the stored manifest.
  - **`/setup` generates a signing key** unless one is mounted:
    `KilnCMS.Provenance.Settings`, one row, encrypted under `secret_key_base`
    like the database DKIM key, platform-admin only, with no rotate action. A
    mounted key always wins; when one replaces the generated key, the generated
    key is listed as retired automatically, so what it signed keeps verifying.
  - **The share signed is measured**: `KilnCMS.Provenance.coverage/1`, `mix
    kiln.provenance.coverage`, and `kiln_cms.provenance.coverage.*` telemetry
    every five minutes ([benchmarks.md](../benchmarks.md#provenance-share-of-published-artifacts-signed)).
  See [provenance.md](../provenance.md#on-by-default).

<a id="plain-text-breaks"></a>

- **A plain-text rendition can keep its paragraph breaks.** A `:text` field
  delivered as plain text (`deliver_plain`, #2037) read as one line:
  `KilnCMS.PlainText.from_html/1` collapses every run of whitespace, so a
  three-paragraph description came out as one. A new option under it in the
  fields admin, "Keep paragraph breaks" (`plain_breaks` on `FieldDefinition`,
  off by default), delivers that field through
  `KilnCMS.PlainText.from_html_paragraphs/1` instead: a blank line (`"\n\n"`)
  between block elements — paragraphs, headings, quotes, lists, table rows —
  and a newline for each `<br>` and list item, whitespace inside a line
  collapsed as a browser shows it. Text with no markup keeps the newlines it
  was typed with. List items carry no marker. The key, the string type and
  every other field's value are unchanged; the schema export marks such a
  field `x-kiln-plain-breaks: true`. Cleared with `deliver_plain`, and
  flipping it re-fires the type's published documents.

<a id="swift-schema-export"></a>

- **Swift models from the schema export.** `mix kiln.export.schema --format
  swift [--out Kiln.swift]` writes one standard-library-only file for a native
  app: a `public struct … : Codable, Hashable, Sendable` per content type,
  block, shared definition and inline object (a `:group` row, a media
  snapshot), nested under the struct that holds it. Swift names are
  `lowerCamelCase`, with `CodingKeys` keeping the JSON keys exact. A nullable
  or non-required key is an optional. A string `enum` becomes a
  `String`-backed enum with `unknown(String)`. The block union is `public
  indirect enum Block`, switching on `_type`, and the content types are
  `Document`, switching on `type`; both have `.unknown(type:)`. Open maps are
  `[String: JSONValue]`, with `JSONValue` bundled in the file. `format`,
  bounds and `const` pins are dropped, as in the `.d.ts`. Both emitters now
  read the document through one shared walker, `KilnCMS.SchemaExport.Walk`,
  and the `.d.ts` output is byte-for-byte unchanged. When `swiftc` is on
  `PATH`, the test suite compiles the output and decodes a real fired
  artifact with it ([native-apps.md → Swift models](../native-apps.md#swift-models)).

<a id="kotlin-schema-export"></a>

- **Kotlin models from the schema export.** `mix kiln.export.schema --format
  kotlin [--package com.example.kiln] [--out Kiln.kt]` writes one
  kotlinx.serialization file for an Android or JVM app, on the same shared
  walker and with the same naming and nesting as the Swift output. Each
  content type, block, shared definition (`MediaSnapshot`) and inline object
  (a `:group` row) is a `@Serializable public data class`. Kotlin names are
  `lowerCamelCase`, with `@SerialName` keeping the JSON keys exact. A nullable
  or non-required key is nullable with a `= null` default. A string `enum` is
  a `@JvmInline value class` over `String` with a constant per listed value,
  so any value decodes. The block union is `sealed interface Block` with a
  bundled `BlockSerializer` that switches on `_type` and keeps an unknown type
  as `Block.Unknown(type, raw)`, and the content types are `Document`,
  switching on `type`. The serializers name every member's serializer
  directly, so there's no reflection for R8 to break. Open maps are
  `JsonObject`, integers are `Long`, and the file bundles `KilnJson`
  (`ignoreUnknownKeys = true`) to decode with. `--package` defaults to `kiln`
  and is refused for other formats. When `kotlinc`, `kotlin` and
  `KOTLINX_SERIALIZATION_CLASSPATH` (the runtime jars) are all present, the
  test suite compiles the output with `-Werror` and decodes a real fired
  artifact with it ([native-apps.md → Kotlin models](../native-apps.md#kotlin-models)).

<a id="option-labels"></a>

- **Display labels on `:select` options.** A new `option_labels` map on a
  field definition names what an editor reads for each option — the stored
  value stays the code, so filters, delivery and API clients are unchanged.
  The editor's single select, the multiple select's tag picker (its chips
  and suggestions), and select link fields and group sub-fields show labels,
  and a write naming a label (case-insensitively) stores its value — so an
  editor can type "Clear heat" into a tag picker. In the fields admin an
  option's line takes `value | Label`, and a label may hold commas. Labels
  are pruned to the current options and cleared off a field that is no
  longer a select; one longer than a line is refused. Adds
  `field_definitions.option_labels` (default `{}`).

<a id="string-lists"></a>

- **A `:string` field can hold a list of phrases.** With `multiple: true` its
  value is a JSON list of strings — symptoms, indications, synonyms,
  services — for lists too large or too free for a select's vocabulary. The
  editor shows one input per item, edited in place, removed with × and
  dragged to reorder, and an add box: Enter adds an item, and pasting
  several lines adds one item per line (an item written with line breaks is
  split the same way on write). Items are trimmed, blanks and repeats
  dropped, bounded by `min_items` / `max_items`, and a JSON-encoded list sent
  as a string is refused. `custom_filter` asks whether the list contains an
  item; the schema export carries an array of strings. A `names_record` list
  names the record by each item — the alias leg now matches each element of
  a list, not its JSON text. `mix kiln.fields.convert` targets it, and
  `--lines` reads a plain-text source as one item per line. The editor's list
  events are now `list_item_add` / `list_item_remove` / `list_item_reorder`
  for this and the multiple select alike.

<a id="multiple-select"></a>

- **A `:select` field can hold several terms.** With `multiple: true` its
  value is a JSON list of strings, edited in a tag-style picker: chips with
  ×, drag to reorder, and a text box that adds on Enter or comma and
  suggests the options. `min_items` / `max_items` bound it, as for a
  gallery. `allow_custom: true` opens the vocabulary: editors add new terms,
  `options` become suggestions (and may be empty), and the picker also
  suggests the terms already used on the type. A new term does not join
  `options`. A JSON-encoded list sent as a string is refused rather than
  stored as one term. `custom_filter` asks whether the list contains a term;
  JSON:API, GraphQL and the schema export carry an array of strings, and
  single selects are unchanged. Flipping `multiple` reshapes stored values
  as it does for a gallery; retyping a `:text` field into one does not wrap
  its JSON strings. `mix kiln.fields.convert` now also targets a multiple
  select: its report lists the distinct terms with counts and the ones not
  yet options, and every report counts the published records a run writes
  ([field-conversion.md](../field-conversion.md)). Adds two columns to
  `field_definitions` (`allow_custom`, `format`), both with defaults.

<a id="rich-text-fields"></a>

- **Rich text on `:text` custom fields.** A `:text` field's new `format` is
  `:rich` by default: the editor shows TipTap with a short toolbar
  (paragraphs, bold, italic, links, lists) over the stored HTML, which is
  sanitized on write to the rich-text block's allow-list. Text with no
  markup, JSON data, and markup the sanitizer removes nothing from are
  stored byte for byte, and a field holding JSON data
  keeps the textarea; opening a record never rewrites its value. `format:
  :plain` keeps the textarea and stores the text as typed. The value stays
  an HTML string, so `deliver_plain` and API clients are unaffected; the
  schema export marks a rich field `contentMediaType: text/html`.

<a id="governance-what-readers-saw"></a>

- **"What readers saw" on the governance trail
  ([#1928](https://github.com/The-Verscienta/kiln_cms/issues/1928)).** The
  detail view at `/editor/governance/:type/:id` gains one row per publish or
  withdrawal, newest first: its approver (for a scheduled transition, whoever
  last set the schedule), its propagation record from 1.4 (the CDN purge's
  enqueue and acknowledgement or failure, and every webhook endpoint's
  delivery time or terminal failure, each with its gap from the transition),
  its `?as_of=` link and the history chain's verdict on that version. The
  JSON export carries the rows as `transitions`; the CSV export as rows of
  kind `transition`, with six columns appended (`cdn_purge`,
  `cdn_enqueued_at`, `cdn_settled_at`, `endpoints`, `as_of`, `chain`) that
  every other row leaves empty, so a sheet reading the first eight by
  position still lines up. A propagation record carries no version id; each
  transition takes the first record of its kind opened between its own write
  and the next transition's (`KilnCMS.Propagation.for_document/3`, read as the
  webhooks system actor and failing closed). A restore of a document trashed
  while live is a row too. Past the delivery ledger's 30 days the row counts
  the endpoints whose rows were pruned instead of claiming there were none.
  Alongside: `webhook_deliveries` gains a nullable `failed_at`, stamped when a
  delivery is given up on, so a later recovery stamp or the payload scrub no
  longer moves the reported give-up time (`WebhookDelivery.given_up_at/1`,
  also used by the lost-retractions panel); and point-in-time delivery now
  treats `archive_scheduled` as a withdrawal, where it used to keep serving
  the last publish. The guide's end-to-end screenshot of one real correction
  is still to come: it needs staging data.

<a id="bylines"></a>

- **Public bylines
  ([#2044](https://github.com/The-Verscienta/kiln_cms/issues/2044)).** A
  `:reference` custom field can say what its targets are to the page in
  schema.org terms: `schema_org_property: :author` or `:contributor`, the
  *What they are to the page* step of a relationship in the fields admin
  (additive migration: one nullable column on `field_definitions`). The
  fired `:json_ld` main node then carries one `Person` (`name`, profile
  `url`) per target under that property, in the field's order, from the
  resolved values: a renamed target is named by its current title, and one
  an anonymous reader could not open is left out. Kiln's own pages read the
  same byline (`KilnCMS.Firing.Bylines`): their inline JSON-LD names those
  people, and the "By" line links them ("By Ada Lovelace and Alan Turing ·
  With Grace Hopper", `public-byline` classes); without an `author` field
  they keep naming the console user. An Event carries neither property.
  Setting or clearing the option re-fires the type's published documents.
  `ProfilePage` joins the schema.org allowlist and fires with its person as
  `mainEntity`. The guide is
  [docs/author-profiles.md](../author-profiles.md): an `author` type,
  authors and contributors fields, and the profile's article lists.

<a id="link-filter-target"></a>

- **A link-field filter tied to particular targets
  ([#2044](https://github.com/The-Verscienta/kiln_cms/issues/2044)).**
  `custom_filter[<field>.link.<name>]` matched a record when *some*
  connection of the field carried the value, so asking for the posts where
  an author is the photographer also returned the posts where anyone else
  was. A `target` key beside the operators now narrows every operator in
  that condition to the connections pointing at the given ids:
  `custom_filter[contributors.link.role][eq]=photographer&custom_filter[contributors.link.role][target]=<id>`.
  It takes one id or a list (at most 100, each a UUID), needs an operator
  beside it, and keeps the both-ends read gate, so a draft target still
  matches nothing for an anonymous reader. GraphQL's `customFilter` takes
  the same shape. Without `target`, link filters mean what they did.

<a id="private-fields"></a>

- **Private custom fields and a `:user` field type
  ([#2044](https://github.com/The-Verscienta/kiln_cms/issues/2044)).** A
  `FieldDefinition` with `private: true` (additive migration: one boolean
  column, default false) holds a value for the site's editors and admins
  only. It is left out of every fired artifact
  (`KilnCMS.Firing.CustomFields`, for every caller, visual-editing previews
  included) and out of every content read below editor
  (`Preparations.MaskPrivateFields`, beside the reference mask and skipped by
  the same rule). Nothing public is derived from it: computed fields cannot
  read it, slug and SEO patterns read `[field:<name>]` as empty, the
  provenance manifest ignores a private `ai_disclosure`, and the schema
  export leaves it out. Below editor, `custom_filter` / `custom_sort` treat
  it as unknown (decided by the caller's tier even on `authorize?: false`
  delivery reads), so a value cannot be probed. Only plain top-level types
  can be private, and `searchable`, `names_record`, `deliver_plain` and a
  `:fallback` localization are refused beside it. Flipping it re-fires the
  type; the per-site map of private names (`PrivateFields.all/1`) is cached
  with the type registry and dropped with it after commit. The new core
  `:user` type stores a console account's id, validated against the site's
  people (`Scoping.users_with_tier/2`), and is always private; the editor
  picks from the same roster, and the fields admin offers *Private* on every
  type that can be.

<a id="live-blog-posting"></a>

- **`LiveBlogPosting` in schema.org output
  ([#2046](https://github.com/The-Verscienta/kiln_cms/issues/2046)).**
  `LiveBlogPosting` joins the allowlisted Article family, so a compiled type
  (`schema_org_type:`) or a dynamic one (`/editor/types`) can declare it. Its
  node keeps `headline`, `articleBody` and the CreativeWork dates, and gains
  `coverageStartTime` / `coverageEndTime` from the type's first
  `datetime_range` field (with none, coverage starts at `published_at` and
  stays open) and `liveBlogUpdate`: one `BlogPosting` per update, newest
  first, capped at 50 (`config :kiln_cms, KilnCMS.Firing.LiveBlog,
  max_updates:`). An update is any record pointing at the story through a
  `:reference` field with another side (`inverse_label`); the story type's
  first reverse field is its update stream. No new resource, no migration.
  Only published, public, unlocked updates are fired, read from their live
  values, so a members-only update never leaks through a public story and an
  unpublished one drops out the next time the story fires. The served page's
  inline JSON-LD (`KilnCMSWeb.StructuredData`) carries the same properties.
  Publishing an update does not itself re-fire the story yet: the reference
  edge runs update → story, so the story picks up a new update on its next
  fire.

<a id="news-sitemap"></a>

- **A Google News sitemap, `/news-sitemap.xml`
  ([#2045](https://github.com/The-Verscienta/kiln_cms/issues/2045)).** Each
  `<url>` carries `<news:news>`: the publication name (the site's branding
  name), its language (the record's locale as an ISO 639 code, `zh-cn` /
  `zh-tw` for Chinese), `news:publication_date` and `news:title`. Only
  articles published in the last 48 hours, newest first, at most 1,000 URLs,
  as Google News asks. A type opts in by declaring the schema.org type
  `NewsArticle` (the Content macro's `schema_org_type:` or the dynamic type's
  setting); `robots.txt` lists the route once one has. Like the feeds, only
  published `audience: :public` records appear. Per org, cached for five
  minutes under the `:probe` rate limit, and dropped by
  `KilnCMS.Cache.bust_sitemap/1` with the main sitemap, so an unpublished
  article is gone on the next request.

<a id="headless-draft-mode"></a>

- **Headless draft mode: a preview token opens its draft on JSON:API and the
  fired-artifact read
  ([#1887](https://github.com/The-Verscienta/kiln_cms/issues/1887)).** A
  front end that renders pages from the plain reads could not render a
  shared draft in its own templates: a token unlocked only `GET
  /preview/:token` (a thin JSON) and the stega-annotated visual-editing
  read, so verscienta.com redirected reviewers to Kiln's generic preview
  page. Presented as `x-kiln-preview-token` (or `?preview_token=`), the token
  is now a read grant for its one record on `/api/json` and on `GET
  /api/content/:type/:slug`. `KilnCMSWeb.Plugs.PreviewGrant` verifies it once,
  pins it to the serving site and puts a `KilnCMS.CMS.PreviewGrant` in the Ash
  context's `:shared` key; the new `Checks.PreviewGrant` in both content read
  policies (the lock one included) admits `id == grant.id` on the primary
  read only. No `authorize?: false`: `by-slug`, the `/published` twins,
  search and writes are unchanged, and GraphQL and `/mcp` ignore the token.
  `LinkEndsReadable` carries the grant into its re-read, so `include=` keeps
  the draft's edges to published documents and drops those to other drafts.
  The artifact route renders the working copy live, on any surface, with
  `?fields=`/`?expand=`, uncounted and without experiments. A presented
  token that does not verify is a `404 invalid_preview`, never the anonymous
  read. For a live document with unpublished edits, JSON:API under the token
  answers the working copy (`Preparations.PreviewWorkingCopy`), the
  reference masking honours the grant, and `?expand=` follows the working
  copy's references. The token is read on `GET`/`HEAD` only; a write ignores
  it. Responses under a token are `private, no-store` and every response of
  an honouring route `Vary`s on the header, while GraphQL and search, which
  ignore the token, keep their caching. A token read is charged to a new
  `:preview_api` bucket (120/min), the visual-editing read included, which
  now goes through the same plug. `preview_token`, `unlock` and `passphrase`
  join `password` in Phoenix's `filter_parameters`, and Sentry events drop
  the token and grant headers and mask them in the raw query string, which
  `Sentry.PlugContext` copied verbatim (`SentryFilter`). `/preview/:token`,
  its live view and the bridge socket verify through the same
  `PreviewGrant.verify/2`. `Engine.fire/2` takes `surfaces:` for a preview,
  so a live read renders only the surface it serves. A database outage under
  a token is a `503`, not `invalid_preview`. Docs: `docs/api.md` →
  "Headless draft mode".

<a id="change-feed-server"></a>

- **A public change feed, server side (2.1 of
  [#2050](https://github.com/The-Verscienta/kiln_cms/issues/2050)).**
  `KilnCMS.Delivery.Feed` broadcasts one event per published content change
  on the site's `feed:<org_id>` topic over native `Phoenix.PubSub`:
  `published` (a publish, or a restore straight onto the delivery path),
  `updated` (an edit to live content) and `withdrawn` (an unpublish, an
  archive of a live document, or a trash of one). It is a consumer of
  `KilnCMS.Webhooks.dispatch/4`, the funnel the webhooks use, so it hears
  exactly the transitions webhook receivers do — drafts, `archived`
  tombstones, taxonomy and release events stay off it. An event carries
  identifiers only: `type`, `id`, `slug`, `locale`, `published_at`,
  `affected` (identity of the published documents that embed this one) and
  `public` (fail-closed: `false` for a members-only or locked document, `nil`
  when the payload cannot say). Never content: a client fetches through the
  existing cached delivery routes. Each broadcast emits
  `[:kiln_cms, :delivery, :feed, :event]`. Subscribe in-process with
  `KilnCMS.Delivery.Feed.subscribe/1`; the SSE and channel transports are
  2.2.

<a id="plugin-safe-fetch"></a>

- **`Kiln.SafeFetch` (`kiln_plugin` 1.3): plugins get a covered, SSRF-safe
  way to fetch a URL they didn't write (#2047).** A plugin that fetches a URL
  from content or settings — a feed poller, a link unfurler — had to reach
  past the overlay contract to `KilnCMS.SafeFetch`, and a plugin shipped as a
  Hex dependency couldn't reach it at all. `Kiln.SafeFetch` in `kiln_plugin`
  offers `get/2`, `head/2`, `post/3` and `request/3`; inside a KilnCMS build
  every call goes to `KilnCMS.SafeFetch`, so the address is checked and
  pinned, redirects are followed only on request and re-checked per hop, and
  the body is capped. Only the documented options pass through: `:req_options`,
  which could replace the pinned connection, is dropped. With no core loaded
  every call is an error unless `config :kiln_plugin, :safe_fetch` names a
  stand-in for the plugin's own tests, and that key is ignored whenever the
  core is present. Covered from this release (`docs/overlay-contract.md`); a
  plugin should require `{:kiln_plugin, "~> 1.3"}`.

<a id="fields-convert"></a>

- **`mix kiln.fields.convert` moves JSON-in-text values into a `:group`
  field.** Lists kept as JSON strings in `:text` fields (Verscienta's
  `dosages`, `safety_warnings`, …) can now become validated group rows:
  `mix kiln.fields.convert herb dosages --to dosage_rows [--map dose=amount]`.
  It accepts a JSON array of objects, a single object, and either encoded
  twice; applies `--map` key renames; and coerces every row through the
  group's own rules (`Changes.ApplyCustomFields`, through a new internal
  `:convert_custom_field` content action, as the `:field_conversion` system
  actor). A dry run by default. Its report counts converted, empty and
  already-converted records, and lists each invalid one by id and slug with
  the reason: unparseable (prose) or the coercion error and its path
  (`dosage_rows[2].unit`). `--report out.json` saves the report as a file.
  Nothing is written while any record is invalid unless `--skip-invalid` is
  given. The source field is never touched (expand/migrate/contract), and a
  re-run skips records whose group already has rows unless `--overwrite` is
  given. Each write is versioned, keeps `updated_at` and the lock, sends no
  webhook, and re-fires a published record. A live record's pending working
  copy is converted with it. In a release:
  `bin/kiln_cms rpc 'KilnCMS.Release.convert_field(...)'`. Guide:
  `docs/field-conversion.md`.

<a id="media-snapshot-for-apps"></a>

- **Media in delivered content carries dimensions, MIME type, focal point and
  variants.** A `:media` custom field's stored value (single, or each item of
  a gallery `multiple` field) was `%{"id", "url", "alt"}`: a native app could
  not lay out before the image loaded, pick a size, or crop around the focal
  point. It now also carries `width`, `height`, `mime_type`, `focal`
  (`{"x", "y"}`, or `null` for non-images) and `variants` — each rendition's
  `label`, `width`, `height`, `format` (MIME type), `url`, `bytes` and
  `cropped` (`true` for the focal-aware `card` crop and a video poster, which
  are not interchangeable by width). `id`, `url` and `alt` are unchanged. The
  fired `:json` artifact adds the same object as `media` on `image` blocks and
  on each gallery image, so one decoder reads both
  (`KilnCMS.Media.Snapshot`, documented in `docs/api.md`, "Media in delivered
  content"). The delivery schema and its `.d.ts` spell the shape out.

  Variants are derived after the upload, so a snapshot taken first holds
  `"variants": []` and `null` dimensions. Firing now re-reads every item a
  document shows, and a media write that changes the shape (the variant
  worker finishing, a moved focal point, new alt text) re-fires the published
  documents pointing at it; the variant worker now records each rendition's
  `bytes`. The stored value is refreshed by the next save, or by the new
  `mix kiln.media.resnapshot` (dry run by default, `--apply` to write; through
  a new internal `:resnapshot_media` content action, versioned, keeping
  `updated_at` and the lock, as the `:media` system actor).

  The `:json` artifact `format_version` is now 3, so an older artifact
  re-fires on its next read; `mix kiln.refire_all` gets there faster.

<a id="fields-trims-the-fired-json-artifact-a-guide-to-kiln-in-a-native-app"></a>

- **`?fields=` trims the fired `json` artifact; a guide to Kiln in a native
  app.** `GET /api/content/:type/:slug?fields=title,slug,custom_fields.price`
  returns only the named top-level keys and custom fields, for clients on
  constrained networks that don't run GraphQL. `id` and `type` are always
  kept, as is `expanded` with `?expand=`; unknown names are ignored; at most
  50 names; `surface=json` only (`400 invalid_fields` otherwise); works with
  `?as_of=`. The `ETag` of a fieldset response is a digest of the filtered
  body, so it moves only when a kept value does — a republish that changed
  only `blocks` still `304`s a `?fields=title` revalidation — and every
  spelling of one fieldset shares it. `x-kiln-fields` echoes the canonical
  spelling (sorted, de-duplicated) so clients can share one CDN entry. A
  response without `fields` is unchanged, byte for byte and in its `ETag`.
  `/api/sync` still embeds the whole artifact.

  New page [native-apps.md](../native-apps.md): persisting the sync cursor,
  restarting with `initial=true` only on `invalid_cursor`, backoff and the
  per-IP rate limit, iOS/Android background-refresh limits, ETags for
  single-record refresh, `?fields=`, webhooks as the push path for apps with
  a backend, and typed models from `GET /api/schema`.

<a id="rich-text-fields-as-portable-text"></a>

- **A rich `:text` custom field can also be delivered as Portable Text.** A
  new per-field toggle in the fields admin, "Also deliver as Portable Text"
  (`deliver_portable` on `FieldDefinition`, off by default, beside
  "Also deliver as plain text"), adds a `custom_fields_portable` map beside
  `custom_fields`: each flagged field's HTML as the Portable Text tree a
  `rich_text` block's `body` holds — paragraphs, headings, quotes, nested
  lists, marks and links — so a native app renders a field's prose with the
  code that renders a block's body, and needs no web view for it. This is
  the structured rendition the mobile-delivery plan asked a `:rich_text`
  field type for; with `:text` rich by default since #2099, no new type is
  needed. `custom_fields` itself is never rewritten.

  Opt-in rather than always on for `format: :rich`: Portable Text spells out
  every span, so it is several times the size of the HTML it comes from, and
  every web client and every rich field that already renders HTML would
  carry it for nothing on every artifact and sync item. The conversion is
  `KilnCMS.Blocks.PortableText.from_html/1` after the rich-text sanitizer,
  then `sanitize_body/1` — not `from_html_faithful/1`, which refuses
  whatever it would lose: a delivered rendition must always be there, and
  the HTML beside it stays the full value. Markup-free text becomes one
  paragraph per blank-line-separated run; JSON data stored as text is
  `null`.

  Where it appears: the fired `:json` artifact (so `GET
  /api/content/:type/:slug`, its `?fields=`, and every `/api/sync` item)
  whenever the type flags a field; the `custom_fields_portable` calculation
  on JSON:API and GraphQL (`customFieldsPortable`), on request; and the
  delivery schema, where each value is `$ref`'d to the shared
  `portable_text_block`, so the `.d.ts` types it as `Array<PortableTextBlock> | null`.
  Computed at fire time; flipping the toggle, or switching the field to
  `format: :plain`, re-fires the type. Cleared on plain and non-`:text`
  fields and on link and group sub-fields (a group's rows are delivered
  whole); refused on a private field.

<a id="a-text-custom-field-can-also-be-delivered-as-plain-text"></a>

- **A `:text` custom field can also be delivered as plain text.** A new
  per-field toggle in the fields admin, "Also deliver as plain text"
  (`deliver_plain` on `FieldDefinition`, off by default), adds a
  `custom_fields_plain` map beside `custom_fields`: each flagged field's value
  with HTML tags removed, entities decoded and whitespace collapsed
  (`KilnCMS.PlainText.from_html/1`). It is for clients that cannot render the
  HTML fragments importers put into `:text` fields — a native app no longer
  needs a browser engine's HTML parser to show a paragraph. `custom_fields`
  itself is never rewritten.

  Where it appears: in the fired `:json` artifact, and so in
  `GET /api/content/:type/:slug` and every `/api/sync` item, whenever the
  type flags a field (absent otherwise, so other types' payloads are
  byte-identical); as the `custom_fields_plain` calculation on JSON:API
  (`fields[page]=…,custom_fields_plain`) and GraphQL (`customFieldsPlain`),
  served only on request like `inherited_fields`; and in the delivery schema
  (`GET /api/schema`, the `.d.ts`) as a closed object of nullable strings.
  Flipping the toggle re-fires the type's published documents. Not carried:
  the other fired surfaces (`:web`, `:llm`, `:json_ld` render text already),
  the public HTML page, feeds and CSV export, and a reference's link fields
  (the toggle is cleared on them, as on every non-`:text` type).

<a id="group-custom-field"></a>

- **A `:group` custom field holds structured rows: one object, or a list of
  them, keyed by typed sub-fields, with every bad key reported by its path.**
  Lists of records — an herb's dosages, its drug interactions — used to be
  JSON strings in `:text` fields, which the schema export called strings and
  every client parsed on its own. A group's sub-fields are `FieldDefinition`
  rows owned through the new `group_of_id` (scalar types only, one level
  deep, like R3 link fields), each key is coerced by its sub-field's rules,
  an unknown key is refused, and errors name their path
  (`Unit (dosages[2].unit) is required`). `multiple` makes it repeating rows
  with `min_items`/`max_items`. Renaming or deleting a sub-field moves or
  purges its key in every stored row. The schema export types a group as a
  closed object (an array of them when `multiple`), and
  `/api/json/type-definitions?include=field_definitions.group_fields` lists
  the sub-fields. Groups are defined through the code interface or the API
  for now; the editor shows an existing group read-only, and the row editor
  follows. The migration adds one nullable column.
  ([#2036](https://github.com/The-Verscienta/kiln_cms/pull/2036))

<a id="group-field-editor"></a>

- **Group fields are edited in the admin and the content editor.** The fields
  admin offers `:group` as a field type, asks whether it holds one set of
  values or repeating rows (with optional row bounds), and lists the group's
  sub-fields under it as "Fields in each row" — added, edited, ordered and
  deleted in place with the plain types, as a reference's link fields are.
  The content editor replaces #2036's read-only row count: a single group is
  one fieldset of its sub-fields' inputs, and a repeating one is a list of
  rows with "Add row", remove, move up/down and drag-to-reorder (the shared
  `Sortable` hook). Rows post by position and are folded back into the
  ordered list the write coerces, so a row edit is dirty and autosaves like
  any other field edit; a blank row just added stays on screen through an
  autosave. Each path error (`Unit (dosages[2].unit) is required`) shows
  next to its row and sub-field, and `min_items`/`max_items` disable the
  add and remove buttons while the save still enforces them. Also fixed on
  the way: a server-side edit of one custom field (a gallery's remove, a
  reference list's reorder) on a form no change event had filled yet showed
  every other custom field blank, and the next save posted those blanks.
  ([#2053](https://github.com/The-Verscienta/kiln_cms/pull/2053))


<a id="overlay-refire"></a>

- **`KilnCMS.Firing.refire/3` re-fires named records for an overlay (#2048).**
  An overlay sometimes knows a fired artifact is stale when Kiln doesn't: an
  article's card was built at fire time from another install's API, and that
  install's signed webhook says the card's source changed. Until now the only
  ways in were `mix kiln.refire_all` (operator tooling) and
  `FireWorker.enqueue_backfill/1` (internal). `KilnCMS.Firing.refire!(type,
  ids, actor: KilnCMS.SystemActor.new(:overlay), tenant: org_id)` is covered:
  each id gets the normal fire job, which fires it as a publish would and
  cascades to every document embedding it through the reference graph, then
  — as an edit of live content does — drops its delivery cache and dispatches
  `<type>.updated`, which reaches webhooks, automation, federation and the CDN
  purge. It dispatches after the fire, so whatever refetches on the event gets
  the new body. A document that isn't published fires nothing. It is a generic
  `:refire` action on `Firing.PublishedArtifact` with a code interface on the
  `Firing` domain, admitting the `:overlay` system actor and the org's editors
  and admins; it returns how many fires were queued, and a refire already
  pending for an id is not queued twice.

## Changed

<a id="media-snapshot-def"></a>

- **One `$defs` entry for the media snapshot.** `GET /api/schema` and `mix
  kiln.export.schema` used to repeat `Media.Snapshot`'s shape wherever it is
  delivered: a `:media` field, a `:media` gallery's items, an `image` block's
  `media`, each gallery image's `media`. Every one is now a `$ref` to
  `#/$defs/media_snapshot`. A JSON Schema validator accepts exactly what it
  accepted before. The `.d.ts` and Swift emitters each produce one
  `MediaSnapshot` type, where they used to produce an anonymous copy per use.
  A nullable use is `anyOf: [{"$ref": …}, {"type": "null"}]`, the only way
  2020-12 expresses a nullable `$ref`. The old `["object", "null"]` type list
  stays beside it, so a generator that predates `anyOf` gets a loose but true
  type instead of a broken one. `kiln-types` before this release writes
  `Record<string, unknown> | null`; the next one reads the pair (its
  CHANGELOG). The hoist happens over the assembled document rather than in
  `Kiln.Block.JsonSchema`, whose per-block schemas are still validated on
  their own by the block suite and `mix kiln.plugins.doctor`.

<a id="related-links-ordered"></a>

- **Related content comes back in the order the editor set: JSON:API
  `include=related_<type>s`, GraphQL `related<Type>s` and `related_links`.**
  Since 1.5 the editor keeps the related list's order in each `kind:
  :related` link's `position` (#2025), but only the editor read it back:
  Ash sorts a many-to-many by its destination, and a sort that reaches the
  join row needs the join resource unique on `(source_id, target_id)`, which
  `ContentLink` is not — reference edges share the table. The curated rows
  now have a join resource of their own, `RelatedLink`: the same table, no
  migration, narrowed by a base filter (`kind = 'related' AND field IS
  NULL`). `related_<type>s` goes through it sorted by `position`, a `limit`
  takes the first of that order for each parent, and `related_links` (MCP
  write echoes included) follows. The `related_<type>_ids` arguments are
  unchanged; they write an unsorted private twin, `curated_<type>s`, over the
  same join, because `manage_relationship` can't take that sort. One
  narrowing: a payload link (R8) of another `kind` between two records of
  the same type used to appear among their related records, and no longer
  does, in the relationship or its `has`/`has_all`/`has_none` filters —
  related content is the curated links only.
  ([#2061](https://github.com/The-Verscienta/kiln_cms/pull/2061), [#2064](https://github.com/The-Verscienta/kiln_cms/pull/2064))

<a id="single-media-picker"></a>

- **A single media custom field is picked from the library drawer, with a
  thumbnail, instead of a dropdown of filenames.** The dropdown listed only
  the editor's recent media window, so an older image could not be chosen at
  all, and it offered no preview, search or Unsplash import. The field now
  shows the current image with **Choose from library** (or **Replace**) and
  **Remove**, the featured image's shape, and the drawer opens in
  single-select mode. The thumbnail comes from the stored snapshot, so an
  image outside the window still shows. The form posts the same id as
  before, so writes and the API are unchanged; the controls follow the
  gallery's rules (writers only, not on a shared field of a translation, and
  a pick lands only in the field the drawer was opened for).
  ([#2054](https://github.com/The-Verscienta/kiln_cms/issues/2054) · [#2055](https://github.com/The-Verscienta/kiln_cms/pull/2055))

<a id="fired-artifacts-are-gzipped"></a>

- **Fired artifacts are gzipped: their `ETag` is now weak (`W/"…"`) and
  `If-None-Match` is compared weakly.** Bandit skips compression for any
  response carrying a strong `ETag`, so `GET /api/content/:type/:slug` was
  never gzipped by Kiln, whatever the client's `Accept-Encoding`. The tag
  keeps its value and gains a `W/` prefix, and `If-None-Match` now uses the
  weak comparison the cached JSON:API/GraphQL/search responses already use
  (`KilnCMSWeb.Plugs.PublicCache`): `W/` ignored, a comma-separated list
  matches if any tag does, `*` matches. A client still holding the old,
  strong form revalidates to a `304`; one that compares tags itself sees each
  document's tag change once and refetches it one time. ETags are opaque, so
  this is not a contract change. A passphrase-unlocked document still has no
  `ETag` and is never `304`ed. ([#2041](https://github.com/The-Verscienta/kiln_cms/pull/2041))

<a id="ml-stack-nx-1"></a>

- **The opt-in ML stack (`KILN_ML=1`) moves to Bumblebee 0.8, Axon 0.9 and
  Nx/EXLA 1.0.** Axon 0.8.1 drew two redundant-clause warnings from Elixir
  1.20's type checker on every ML build (`Axon.pop_node/1`,
  `Axon.ModelState.transform_to_parameters/1`); Axon 0.9 fixes both, and only
  Bumblebee 0.8 accepts it, on Nx 1.0. `nx` and `exla` carry
  `override: true`: `image` (through 0.72.0) still declares optional
  `~> 0.12` requirements on both, and Kiln uses none of image's Nx functions.
  Bumblebee 0.8 no longer needs `progress_bar`, so its lock entry and the
  `decimal` override it forced are gone. The default lean build is unchanged.
  Checked with the semantic-search suite, plus the real `bge-small-en-v1.5`
  embedding and `bge-reranker-base` reranker run through `Nx.Serving`.
  ([#2067](https://github.com/The-Verscienta/kiln_cms/pull/2067))

## Fixed

<a id="similar-content-custom-fields"></a>

- **Similar content reads a page's searchable custom fields.** The editor's
  Similar content panel (near-duplicates and tag suggestions) built its
  vectors from the block tree only, so a record's custom fields never reached
  it, and a page whose text lived in its fields was told to "add some
  content". `KilnCMS.Search.BlockIndexer` now embeds the fields flagged
  `searchable` (the same text `search_text` carries, #1585) as one more input
  under the key `"custom-fields"`, on both the in-memory draft path and the
  stored index. Unflagged and private fields stay out. Drafts see it at once;
  published documents on their next fire (`mix kiln.refire_all` sweeps them).
  ([#2096](https://github.com/The-Verscienta/kiln_cms/pull/2096))

<a id="tailwind-macos-resign"></a>

- **`mix setup` and `mix assets.build` work on macOS 27.2.** macOS 27.2
  (arm64) SIGKILLed the tailwind 4.3.0 standalone binary at launch: exit 137
  with no output, even for `--help`, so `mix assets.build` failed with
  "`mix tailwind kiln_cms` exited with 137". The binary is a Bun executable
  whose ad-hoc linker signature does not cover the payload Bun appends, and
  `codesign --verify` rejects every release from 4.3.0 to 4.3.3, but 4.3.1
  and later happen to launch. tailwind moves to 4.3.3 (and the `:tailwind`
  hex package to 0.5.2, which also lifts `:httpc`'s header limit for its own
  download), and `mix assets.setup` now re-signs the binary ad hoc
  (`codesign --force --sign -`) on macOS when `codesign --verify` fails, so
  a later release that macOS kills is covered too. Linux, CI and the Docker
  build are untouched.

<a id="httpc-header-limit-local"></a>

- **`mix setup`, `mix assets.setup` and `mix deps.compile` work on OTP 29.1.1,
  loading the CI/Docker `httpc` header-limit patch into Mix's VM only.**
  OTP 29.1.1 (inets 9.8) caps `:httpc` response headers at 10240 bytes by
  default, and tailwind, rustler_precompiled (y_ex) and elixir_make
  (lazy_html, vix) download from GitHub without raising it, so a fresh local
  setup failed with `{:header_too_long, {:max, 10240}}` whenever GitHub's
  redirect headers ran over. The three aliases now run
  `rel/docker/httpc_header_limit.escript` (the one #2062 and #2063 use) with
  `OUT=_build/httpc_patch/<md5 of the stock beam>/`, once per OTP install, and
  load the result into the running Mix VM. The OTP install is never written
  to, `iex`/`mix phx.server`/tests run the stock `httpc`, and a release still
  copies stock inets. On an OTP without the 10240 default the step does
  nothing.
  ([#2080](https://github.com/The-Verscienta/kiln_cms/pull/2080))

<a id="after-commit-effects"></a>

- **A release that rolls back no longer announces or notifies what it undid;
  post-publish broadcasts, notifications, audit anchors and cache busts wait
  for the release to commit.** A release publishes every item inside one
  transaction, so each item's `after_transaction` hooks ran before anything
  committed. The calendar, collab-room, task-pin and GraphQL-retraction
  broadcasts went out early and went out even when a later item rolled the
  release back. A workflow notification, or an audit anchor that lost a
  race, could fail the whole go-live: a failed statement aborts the
  transaction, and the hook's rescue cannot undo that. Cache evictions ran
  before the commit, so a reader in between could re-cache the old page.
  Those effects now go through `KilnCMS.AfterCommit`, which holds them until
  the release commits and drops them when it rolls back. The Oban jobs (fire,
  webhooks, embeddings) and the `published_version_id` pointer still commit
  with the release, as before. Duplicating a record with its links, promoting a
  dynamic type, and the tasks a publish completes get the same treatment.
  The published-content and type-registry busts (`BustContentCache`,
  `BustTypeRegistry`) moved from `after_action` to after the commit on every
  write, not only inside a release: busted inside the transaction, a reader
  could re-cache the old page or type set for a full TTL.
  ([#2072](https://github.com/The-Verscienta/kiln_cms/pull/2072))

<a id="vector-scan-env-replaces-compiled-mode"></a>

- **`KILN_VECTOR_SEARCH_EXACT` / `KILN_HNSW_EF_SEARCH` no longer crash-loop a
  deployment whose compiled config sets the other `vector_scan:` mode.**
  Runtime config is deep-merged over compiled config key by key, so
  `KILN_VECTOR_SEARCH_EXACT=true` over a project's
  `vector_scan: [ef_search: 150]` became `[ef_search: 150, exact: true]`, and
  `KilnCMS.Repo` refused to boot with "vector_scan sets both ef_search and
  exact", although only one variable was set (the mirror case failed the
  same way). The env var now writes its whole mode (`[ef_search: nil,
  exact: true]` or `[ef_search: N, exact: false]`), so it replaces the
  compiled one. Setting both variables at once is still refused.
  ([#2019](https://github.com/The-Verscienta/kiln_cms/issues/2019) · [#2060](https://github.com/The-Verscienta/kiln_cms/pull/2060))

## Security

<a id="ash-tenancy-advisories"></a>

- **ash 3.37.1 and ash_postgres 2.15.2 fix EEF-CVE-2026-115627,
  EEF-CVE-2026-115635 and EEF-CVE-2026-114214; Kiln was not exposed.**
  The three advisories, published 2026-10-25, failed the dependency audit
  on every PR. EEF-CVE-2026-115627: a lateral-joined `many_to_many` (one
  with a sort or limit) built its join-resource query without the read
  action, so attribute multitenancy never filtered the join rows. The sorted
  `related_<type>s` relationships load that way, but the destination read
  kept its tenant filter, so another site's records never appeared. A
  foreign-org join row could only add records of the reader's own site, and
  Kiln's writes can't produce one: `manage_relationship` resolves both ends
  under the tenant, and payload links locate both ends in the writing site.
  A test now plants such a row and checks it is ignored (it fails on
  ash_postgres 2.13.1). EEF-CVE-2026-115635 needs `return_skipped_upsert?`
  and EEF-CVE-2026-114214 needs a `through:` relationship, and Kiln uses
  neither. ash_sql moves to 0.8.4. The bump adds one migration, ash
  functions v7, which redefines `ash_required/2` in place (same signature
  and return type), so it is safe under expand/contract.
  ([#2091](https://github.com/The-Verscienta/kiln_cms/pull/2091))

<a id="bandit-jose-ash-advisories"></a>

- **bandit 1.14.0, jose 1.11.13 and ash 3.37.2 fix the twenty advisories
  published 2026-10-26.** bandit 1.13.0 had eleven, all reachable on a
  deployment because bandit is Kiln's HTTP server: HTTP/2 flow control,
  SETTINGS, HPACK, header-list and body-timeout resource exhaustion, HTTP/1
  chunked-body memory amplification, quadratic `content-length`/port
  parsing, WebSocket fragment and post-close issues, and request smuggling
  through bare LF/CR in chunk extensions (EEF-CVE-2026-108525, -108529,
  -109584, -110314, -110499, -111101, -111103, -113436, -114213, -114216,
  -115269). 1.14.0 also advertises a default HTTP/2 `max_concurrent_streams`
  of 500 and a 256 KiB header list, and rejects malformed HTTP/1 request
  lines and absolute-form targets with 400. jose 1.11.12 had eight
  (EEF-CVE-2026-65625 to -65632). Kiln signs its own tokens with HS256,
  which none of them touch; the RSA, ECDSA and JWE fixes cover SSO's
  verification of an identity provider's tokens. ash 3.37.2 fixes
  EEF-CVE-2026-96581: under attribute multitenancy an upsert on the primary
  key, or on an `all_tenants?` identity, could read, overwrite and move
  another tenant's record. Kiln was not exposed: every one of its upserting
  create actions upserts on a named, tenant-scoped identity and none
  accepts the primary key, and the two runtime upserts target
  `OrgMembership`, which is not multitenant.
  ([#2094](https://github.com/The-Verscienta/kiln_cms/pull/2094))

<a id="image-debian-packages"></a>

- **The release image's Debian packages are current again, and stay so.**
  The runner stage is pinned to a dated `debian:trixie-*-slim` tag, and the
  release workflow builds with the GitHub Actions layer cache. With the
  runner's instructions unchanged, every release replayed the cached
  `apt-get` layer from the first build after the last tag bump, so
  v1.6.0-rc.1 shipped weeks-old packages: Trivy counts 87 fixable OS
  findings, 20 of them HIGH (curl, expat, libvips, librsvg, libheif, liblzma,
  ca-certificates). Three changes. The runner moves to
  `trixie-20261020-slim`. Its first `RUN` now `apt-get upgrade`s, since
  `apt-get install` never moves a package the base already ships
  (`libssl3t64`, `liblzma5`, `ca-certificates`). And the stage is named
  `runner` so `release.yml` rebuilds it with `no-cache-filters: runner`:
  the builder, where the cost is, stays cached. A fresh runner scans at zero
  fixable findings. The builder stays on `bookworm-20261005-slim`, the
  newest date `hexpm/elixir` publishes for Elixir 1.20.4 / OTP 29.1.1; it
  ships nothing but the release tarball. Self-built images get the same
  fix on their next uncached build (`docker build --no-cache`, or
  `--no-cache-filter runner`).
  ([#2097](https://github.com/The-Verscienta/kiln_cms/pull/2097))
