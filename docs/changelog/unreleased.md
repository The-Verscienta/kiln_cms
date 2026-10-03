# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="reference-edges-backfill"></a>

- **The upgrade writes a link edge for every stored `:reference` custom field
  value; after restoring a pre-1.1 backup, run `mix kiln.links.backfill`.**
  A data migration (`BackfillReferenceLinks`) inserts one `content_links` row
  per `:reference` value already stored, in one `INSERT … SELECT` per content
  table, so it needs no step from you. It is idempotent: a backup restored
  from before the upgrade, or `custom_fields` rewritten outside the
  application (a raw SQL import), is brought back in line by
  `mix kiln.links.backfill`
  (`bin/kiln_cms eval 'KilnCMS.Release.backfill_reference_links()'` in a
  release), which also deletes edges no stored value implies.

  The schema migration before it replaces `content_links`' unique index with
  one that includes the new `field` column, built `CONCURRENTLY`. If that
  build is interrupted, drop the invalid
  `content_links_unique_field_link_index` and migrate again.
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

## Added

<a id="the-content-list-filters-and-saves-views"></a>

- **The content list filters by author, category, tag, language, update date
  and review health, sorts by update, publish date or title, and saves a
  filter as a named view.**
  The console's list offered status, type and a title search, sorted by last
  update, while the search API already faceted on author, category and tags
  ([content organization plan](../content-organization-plan.md), §3). The list
  now filters on all of those plus language, an update-date range, review
  health ("review due", "due soon", "expired") and "scheduled to publish", and
  sorts by last update, last publish or title. The everyday facets sit beside
  the search box; the rest open from **More filters**, and each active facet
  shows as a chip with its own remove button.

  All of it stays in the URL, as status and search already did: a link, a
  refresh and the back button keep the filter, and a value that cannot be valid
  (a deleted category, a malformed date) reads as absent rather than failing.

  **Views.** Five built-in views — *All content*, *My drafts*, *Needs review*,
  *Scheduled* and *Review due* — sit above the list, and **Save view** stores
  the current filter under a name (`KilnCMS.CMS.SavedView`). A saved view is
  private to its owner; an admin can share one with every editor on the site,
  and only an admin can rename or delete a shared view. Views are per site.

  **Speed.** Each page of the list used to sort the whole site's content to
  keep 51 rows (about 7 ms at 30,000 posts, growing linearly). Three new
  indexes per content table, on `(org_id, updated_at, id)`, `(org_id, title,
  id)` and `(org_id, published_at DESC NULLS LAST, id DESC)`, serve the three
  orders directly (0.03 ms on the same data), and paging continues from a
  keyset per content type, so *Load more* never repeats or skips a row under
  any sort. The indexes are built `CONCURRENTLY`, so a large table keeps
  taking writes while the migration runs. An overlay's own content types get
  them from `mix ash.codegen` in the overlay, as with any index the content
  macro adds; until then their rows list exactly as before, only sorted in
  memory.
  ([#1854](https://github.com/The-Verscienta/kiln_cms/pull/1854))

<a id="reference-fields-are-also-link-edges"></a>

- **`:reference` custom fields are also `ContentLink` edges: *Linked from* in
  the editor, broken-reference warnings, and `incoming_links` on the API.**
  A `:reference` field stored a snapshot of its target
  (`%{"id", "type", "slug", "title"}`) in the `custom_fields` jsonb and
  nothing else, so "what links here" meant scanning every content table, a
  trashed target left the snapshot pointing at nothing, and the graph the
  rest of Kiln reads could not see the relation.

  The snapshot is unchanged — same shape, same meaning, still written on
  every save. Beside it, every **live** reference value now has a
  `ContentLink` row (`kind: :reference`) carrying three new attributes:
  `field`, the custom field it came from, and `source_type` / `target_type`,
  both ends' content type names. The edges are reconciled from the stored
  value after any write that moved it — a save, a version restore,
  *Publish changes*, an unpublish folding a working copy — and renaming or
  deleting a field definition moves or deletes its edges with its values. A
  reference held in a published record's working copy has no edge until it
  is published.

  What uses them:

  - the editor's Settings panel lists **Linked from** — every record whose
    links point here, curated related content and references alike, with a
    link to each — and **Unpublish** asks first when anything does;
  - a referrer whose target was trashed or purged shows **Broken
    references** under its custom fields, where the snapshot alone made the
    field look filled in;
  - the read API serves them through the existing `content_links` and
    `incoming_links` includes, now with `field`, `source_type` and
    `target_type`; `CMS.list_backlinks/2` and `KilnCMS.CMS.ContentLinks`
    answer the same in code.

  Reference edges are kept out of `related_<type>s`, which stays
  editor-curated related content. Array references and retiring the snapshot
  are not part of this; the design record is
  `docs/content-organization-plan.md` §4 (decision D20).
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

<a id="field-level-localization"></a>

- **Field-level localization: a field can be shared across a document's
  locale variants, or inherited along the site's fallback chain when empty.**
  Content stays one record per locale. What is new is a per-field mode, as
  the v0.12 design check (`docs/field-level-localization.md`, Design A)
  proposed: `:localized` (the default, and what every field did before),
  `:shared` (one value for the document, owned by the default-locale variant
  and copied into every translation when that variant publishes) and
  `:fallback` (an empty value is filled from the first variant along the
  site's chain that has one).

  Custom fields opt in on the Fields screen; block fields with a new
  `localized:` option on `Kiln.Block`'s `field`; an overlay type's record
  attributes with a new `localization:` option on `use KilnCMS.CMS.Content`;
  and the core types' record attributes with
  `config :kiln_cms, :i18n, field_localization:`. Nothing changes until one of
  them does.

  The copy is a versioned write on each translation (the internal
  `:sync_shared_fields` action), held until *Publish changes* on the source's
  working copy, and written into a translation's own pending working copy too.
  Inherited values are filled in the fired artifacts, on the public page and
  in the search text, never written back to the row; the `:json` artifact
  names them under `inherited_fields`, and JSON:API and GraphQL serve them
  through a new `inherited_fields` / `inheritedFields` field only when asked
  for. The editor shows a shared field read-only on a translation and an empty
  fallback field's inherited value as its placeholder. Translation coverage
  ignores the copy, XLIFF leaves shared fields out, the schema export
  annotates the modes, and saving the fallback chain re-fires the translations
  that can inherit. Every existing response keeps its shape for a type that
  opts nothing in.
  ([#1327](https://github.com/The-Verscienta/kiln_cms/issues/1327))

## Fixed

<a id="concluding-an-experiment-now-refuses-a-winner-that-is-not-one-of-its-own"></a>

- **Concluding an experiment now refuses a winner that is not one of its own
  variants.**
  `:conclude` took `winner_variant_id` as a `:uuid` argument and wrote it
  straight to the attribute, so the type was the only gate: a non-uuid was
  refused and any well-formed uuid was accepted and stored — one belonging to no
  variant at all, or to a variant of a different experiment on the same site.

  Nothing mis-read it. `Promotion` looks the winner up among *this* experiment's
  arms and answers `:winner_missing`, so no wrong copy was ever written into a
  document. The cost was the row, and the row could not be corrected:
  `winner_variant_id` is `writable? false`, the state machine has no
  `concluded → concluded` transition, and `:update` refuses anything but a
  draft — so all three remedies were shut and nothing short of SQL took the bad
  id back out.

  What it left behind contradicted itself. The Promote button renders on
  `state == :concluded and winner_variant_id`, so it was offered and could never
  succeed, while `winner?/2` matched no row so no `winner` badge showed. The
  page said both "there is a winner to promote" and "no arm won", and the only
  way out was to archive the experiment. The dangling id also shipped in the
  `experiment.concluded` payload, to webhook endpoints, automation rules and
  federation, where nothing could tell it from a real one.

  Ordinary use never produced one. `mix kiln.experiment conclude --winner NAME`
  resolves the name among the experiment's variants and raises on one that is
  not there, and the editor's `<select>` is built from `@experiment.variants` —
  whose options cannot even go stale, because `RefuseWhenRunning` freezes the
  arms for as long as the conclude form is on screen. The action was the only
  layer without the check, which is the layer a crafted LiveView event and any
  other caller of the `conclude_experiment/3` code interface reach.

  `Validations.WinnerIsAVariant` now refuses it, on `field: :winner_variant_id`.
  Concluding with no winner is unchanged — it is a real choice, and the common
  outcome for a test that found no difference. The check reads the arms as the
  system actor with `authorize_with: :error` so it fails closed: a refused read
  answers `[]` under a filter policy, which would otherwise read as "not an arm"
  and refuse a perfectly good winner.
  ([#1851](https://github.com/The-Verscienta/kiln_cms/pull/1851))

## Security

<a id="content-links-readable-only-when-both-ends-are"></a>

- **A content link is readable only by someone who may read both of its ends;
  `incoming_links` no longer names the drafts that link to a published page.**
  `ContentLink`'s read policy was `authorize_if always()`, so that published
  content could load its links. It also meant
  `GET /api/json/pages/:id?include=incoming_links` returned, to anyone, the
  ids of the unpublished records linking to a published page — a draft's
  existence, which the read API otherwise promises never to reveal (a draft
  answers 404, not 403). With every `:reference` value now an edge too, that
  would have grown with every reference field.

  An edge is now returned only when the reader may read its source **and**
  its target. `Checks.LinkEndsReadable` re-reads both ends under the reader's
  own authorization rather than restating the content read policy, the way
  `Checks.DocumentReadable` already does for fired artifacts. Editors and
  admins see every edge of their site, as before; a published-only reader
  sees the links between published records, as before. The join read behind
  `related_<type>s` is unaffected — the related records were, and are,
  filtered by their own policy.
  ([#1594](https://github.com/The-Verscienta/kiln_cms/issues/1594))

