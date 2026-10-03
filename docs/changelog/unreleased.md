# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="the-sync-apis-first-page-stays-under-15-ms-p95-from-10-concurrent"></a>

- **The sync API's first page stays under 15 ms p95 from 10
  concurrent clients, where it took 31–57 ms.**
  `GET /api/sync?initial=true&limit=100` was the one headless read besides
  search that missed the v1.0 "p95 under 50 ms" metric (#1546). Profiled,
  most of a request was CPU: each page decoded 100 stored artifacts only to
  encode them again for the response. Under concurrency, the page's
  `sync_exposures` bulk upsert locked the same 100 rows for every request,
  so requests queued on each other while holding a pool connection.

  Three changes, none to what a page says. The fired-artifact cache now keeps
  each body's JSON beside it, written in the same ETS insert and evicted with
  it, and a sync page embeds that as a `Jason.Fragment`. A page reads which of
  its documents are already recorded as disclosed and writes only the rest
  (or a row whose dynamic type was renamed), so serving a page again takes no
  row locks; exposure rows are never deleted, so the tombstone guarantee is
  unchanged. A cold page reads its artifacts in one query per content type
  instead of one per document, through a new `PublishedArtifact` read action,
  `:for_documents`, with the same policies as `:get_surface`.

  Re-measured with `scripts/benchmarks/api_latency.sh`: server p95 from 10
  clients went from 34–47 ms to 4–14 ms, and the in-process profile from
  13.6 ms and 4.3 queries a request to 3.3–6.5 ms and 2. A golden test checks
  that a page's bytes are what encoding the stored artifacts gives, cold and
  warm. The artifact cache's entry cap went from 10,000 to 20,000, since each
  artifact is now two entries; it still holds 10,000 artifacts, at up to
  twice the memory. Figures and method in
  [`benchmarks.md`](../benchmarks.md#sync-initial-page-after-1713).
  ([#1713](https://github.com/The-Verscienta/kiln_cms/issues/1713))

## Added

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

