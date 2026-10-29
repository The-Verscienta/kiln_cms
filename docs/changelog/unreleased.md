# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="alias-derivation-overlays"></a>

- **Overlays: run `mix ash.codegen <name>` before deploying (#1890).** The
  `KilnCMS.CMS.Content` macro adds a nullable `path_alias_derived` column to
  every content type, so it lands on your overlay's tables too, and your tree
  carries its own migrations ([overlay-contract.md](../overlay-contract.md)).
  Until the migration runs, reads of those types fail with
  `undefined_column`. The core's own tables get it from the release's
  migrations. Adding a nullable column takes no table rewrite.

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

<a id="swiftui-reader"></a>

- **A SwiftUI example (#2124).** `examples/swiftui-reader` is a Swift package
  (iOS 17, macOS 14) that reads a Kiln site the way
  [native-apps.md](../native-apps.md) describes, so a mobile team evaluating
  Kiln can see the intended path in code. It checks in the `Kiln.swift` that
  `mix kiln.export.schema --format swift` generates for a demo `recipe` type
  (`kiln/seed.exs` creates it, `bin/regenerate` regenerates it). A small
  `KilnClient` reads `/api/sync` and the `json` artifact, with
  `If-None-Match` and `?fields=`. A file mirror saves each sync page and its
  cursor in one atomic write. It restarts with `initial=true` only on
  `invalid_cursor`, keeps local data until the new snapshot ends, and retries
  everything else with `Retry-After` or jittered backoff. The two screens show
  a `:group` field's rows as a native grid, render Portable Text to an
  `AttributedString` with no web view (the plain rendition is the fallback),
  and crop images around the media snapshot's focal point, choosing a
  variant by pixel width. `swift test` decodes JSON captured from a real
  local Kiln and runs the sync loop against a stubbed `URLProtocol`. A macOS
  CI job runs it when the example or the Swift emitter changes. The docs gain
  one fix: the generated Swift and Kotlin `PortableTextBlock` is the schema's
  open node and drops `children`, `style` and `markDefs`, which
  native-apps.md now says. The api.md sync section now gives the delta
  window's real lag, 10 seconds.

<a id="field-sections"></a>

- **Sections in the Custom fields panel.** A field definition's new
  `section` (free text, shared by name) files the field under a collapsible
  heading in the content editor, at the place of the section's first field
  in `position` order; unsectioned fields render bare where they fall. A
  section starts open when its fields already hold a stored value (the first
  section, on a record with none) and whenever one has an error; each heading
  counts its filled fields, and *Expand all* / *Collapse all* sit in the
  panel's header. Toggling uses LiveView `JS` commands, so a section stays as
  the writer left it while they type elsewhere, and a collapsed section's
  inputs still submit. The fields admin sets the section with the site's
  headings as suggestions and shows it on each field; the schema export
  reports it as `x-kiln-section`. Link fields and group sub-fields carry
  none. Adds `field_definitions.section`.

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

<a id="shared-tags-and-related"></a>

- **Field localization can share tags and curated related content (#1859).**
  A content type's `localization:` option — and, for the core types,
  `config :kiln_cms, :i18n, field_localization:` — now accepts `:tags` and
  `:related` in `shared:`. When the default-locale variant publishes, every
  translation takes:
  - **its tag set, by reference.** Tags have no locale, so the tag ids are
    copied and no tag is touched.
  - **its related list, resolved per locale, in order.** Each target becomes
    its document's variant in the translation's locale; a target with none
    follows the site's fallback chain (#1579), the same rule `?fallback=site`
    uses, and one with no variant on the chain is left out.

  The copy is still `:sync_shared_fields`: versioned, optimistic-locked, and
  ignored by coverage, so a copied tag set does not make an outdated
  translation look fresh. A translation's pending working copy that holds its
  own tags or related list gets the shared value too. The #1860 write
  refusal covers both — the complete-set arguments and the `add_*` /
  `remove_*` verbs — and the editor shows both pickers read-only on a
  translation, with a link to the source. The `:localization` system actor
  gains `Tagging` `create`/`destroy` and `RelatedLink` `read`/`create`/`destroy`
  for the copy (`docs/policy-matrix.md`). No migration; a type that names
  neither behaves as before. The design is in
  [field-level localization](../field-level-localization.md#tags-and-related-content).

## Changed

<a id="portable-text-node-keys"></a>

- **The Portable Text node declares its standard keys (#2126).** The
  `portable_text_block` definition that a `rich_text` block's `body` and every
  `custom_fields_portable` value point at declared only `_type` and `_key`.
  That is lenient enough for TypeScript, whose index signature keeps the rest,
  but the Swift and Kotlin emitters decode declared properties only, so a
  generated `PortableTextBlock` kept two strings and dropped every span. It
  now declares `style`, `listItem`, `level`, `children` (spans: `_type`,
  `_key`, `text`, `marks`) and `markDefs` (`_type`, `_key`, `href`). Every
  one is optional and every object stays `additionalProperties: true`, since
  a headless write can still store any node and the schema describes what is
  served. The definition is built in the SDK
  (`Kiln.Block.JsonSchema`), so kiln_plugin gets a patch entry; no plugin
  callback changed, and the core builds it from its path dependency, so no
  SDK release is needed for KilnCMS itself. `examples/swiftui-reader`
  regenerates its models and drops its hand-written `PortableTextNode`: the
  renderer takes the generated `PortableTextBlock`.

<a id="alias-derivation-recorded"></a>

- **Whether a path alias was derived is recorded, not inferred (#1890).**
  A move re-derived the paths beneath it only where it could tell a derived
  alias from a hand-written one, and it told them apart by re-deriving and
  comparing (`KilnCMS.CMS.Slugs.underived?/2`). That breaks once a
  derivation's inputs change for a reason the job does not know about: rename
  a section's slug and every `[ancestors]` path beneath it differs from both
  the old and the new derivation, exactly as a hand-written one does, so the
  next move left those stale paths alone for good. Every content type now has
  `path_alias_derived`: `true` when `Changes.DeriveAlias` filled the alias or
  a regeneration rewrote it, `false` when anything else wrote it (the editor,
  the working copy, an import, a restore, the API). `Changes.TrackAliasDerivation`
  records it on every create and update. Re-saving an unchanged alias leaves it
  as it was, and clearing one derives it again. `SlugRegeneration` reads the
  fact and falls back to the inference only where it is `nil`.

  Rows saved before 1.7 hold `nil` and keep the old inference, including the
  pre-move chain a move job reconstructs, so nothing changes for them until
  their alias is next written. That is why the move job's `old_parent_id`
  stays for now. A blanket "assume pinned" backfill was considered and left
  out: it would have stopped every existing tree-derived path from following
  its next move. The column is internal: it is on no API surface and no action
  accepts it. Re-deriving the subtree when an ancestor is renamed, which the
  recorded fact now makes safe, is not part of this change.

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
