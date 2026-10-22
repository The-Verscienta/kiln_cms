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
