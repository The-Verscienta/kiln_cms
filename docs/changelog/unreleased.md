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

## Added

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

## Changed

<a id="related-links-ordered"></a>

- **`related_links` lists curated related content in the order the editor
  set; the `related_<type>s` relationship itself stays unordered.** Since
  1.5 the editor keeps the related list's order in each `kind: :related`
  link's `position` (#2025), but only the editor read it back. The
  `related_links` projection (JSON:API `fields[<type>]=related_links`,
  GraphQL `relatedLinks`, MCP write echoes) now sorts by it too, with one
  read of the links per site for a whole page of records. Including
  `related_<type>s` (JSON:API) or selecting `related<Type>s` (GraphQL) still
  returns the records in no particular order, now documented: Ash orders a
  many-to-many by its destination, and `ContentLink` is not unique on
  `(source_id, target_id)`, which a sort reaching the join row needs. The
  shape of `related_links` is unchanged.
  (#TBD)

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
