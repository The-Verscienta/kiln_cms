# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="a-reference-custom-field-can-carry-link-fields-details-on-each-connection"></a>

- **A reference custom field can carry link fields: typed details on each
  connection, such as the quantity of each ingredient a recipe connects.**
  Workstream R3 of [relationships-plan.md](../relationships-plan.md). A link
  field is a `FieldDefinition` owned by the reference field (new nullable
  `link_of_id`) instead of a content type, coerced by the same rules as any
  custom field (`required`, `default`, `:select`), and limited to the plain
  types. Each snapshot gains an added `"link"` map
  (`{"id", "type", "slug", "title", "link": {"quantity": 500}}`), and the
  connection's `ContentLink` edge carries the same map as its `metadata`,
  written in the same transaction, so the two copies cannot disagree. A
  connection with no link value has no `"link"` key, so a reference without
  link fields stores exactly what it did. Link values merge per connection:
  an item that leaves one out keeps what that connection stored. Renaming a
  link field moves its values in both copies, deleting one removes them.
  `custom_filter[ingredients.link.role]=main` (and GraphQL `customFilter`)
  matches a record when some connection's value matches, read from the
  edges under R6's both-ends read rule, so a link value cannot reveal a
  draft target. The editor shows one input per link field on each connected
  record's row; the fields admin adds them under the reference as "Details
  on each connection". The schema export types the `"link"` object and lists
  the names as `x-kiln-link-fields`. A curated link's `metadata` stays a
  free map.
  ([#PR](https://github.com/The-Verscienta/kiln_cms/pull/PR))

<a id="custom-filter-relationship-operators-has-has-all-has-none-count"></a>

- **`custom_filter` filters through relationships: `has`, `has_all`, `has_none`
  and `count` on a reference field, and `has`/`has_all`/`has_none` on `tags`
  and `related_<type>s`.** Workstream R6 of
  [relationships-plan.md](../relationships-plan.md), on JSON:API
  (`custom_filter[ingredients][has][]=<id>`) and GraphQL (`customFilter:
  {ingredients: {has: [...]}}`). `has` matches a record holding any of the
  ids, `has_all` every one, `has_none` none of them, and `count` compares how
  many targets it holds (`eq`/`gt`/`gte`/`lt`/`lte`). They read the
  relationship's `content_links` edges (or taggings) through their indexes,
  never the jsonb snapshot, so `eq`/`in` keep their meaning. A target the
  reader may not read does not exist for the filter: a draft never matches
  and is never counted for an anonymous caller, so a filter cannot reveal that
  a draft exists. The gate is the target type's own read policy, as
  `Ash.can/3` derives it for the actor. The plan sketched the built-ins under
  `filter[tags][has]`, but AshJsonApi and AshGraphql own that grammar and take
  no new operators, so they sit in `custom_filter` beside the reference ones
  (a custom field named `tags` keeps the name). Measured on 600k edges: the
  set operators take about a millisecond in the database, and `count` about
  5 µs per record it scans. A rewrite of the gate that the measurement
  prompted took a full `count` scan from 5.3 s to 135 ms.
  ([#2003](https://github.com/The-Verscienta/kiln_cms/pull/2003))

<a id="a-reference-custom-field-can-hold-a-list-of-references-multiple-true-with"></a>

- **A reference custom field can hold a list of references (`multiple: true`),
  with optional `min_items` / `max_items`.** Workstream R1 of
  [relationships-plan.md](../relationships-plan.md). The value is an ordered
  list of the same `{"id", "type", "slug", "title"}` snapshots a single
  reference stores, the shape a media gallery already has (#1992). Each item
  must resolve to a record of the target type the writer can read, in one
  read for the whole list. A record listed twice is refused, naming it. A
  lone id is a one-item list, and blanks drop out, so an emptied list clears
  the field. The bounds apply to a list that holds items; `required` still
  asks for at least one. Flipping the flag reshapes stored values as it does
  for a gallery: one becomes a one-item list, a list keeps its first item and
  the other items' edges are deleted. The fields admin warns before a
  narrowing save and edits the bounds. Each item has its own `ContentLink`
  edge at its `position`, and reordering rewrites the positions. Each item is
  also a re-fire edge (R0, #1998). `custom_filter` `eq` on a list means
  "contains this id", `not_eq` "does not contain", and `in` "contains any". The
  schema export types the field as an array of snapshots and reports the
  bounds as `x-kiln-min-items` / `x-kiln-max-items`. They are not
  `minItems` / `maxItems`, because a value stored before a bound was
  tightened may fall outside it. The editor gets a small ordered list with
  an add select, and the search picker follows in R9. Single references keep
  their 1.0 shape.
  ([#2000](https://github.com/The-Verscienta/kiln_cms/pull/2000))

<a id="a-reference-custom-field-can-link-to-several-content-types-targettypes"></a>

- **A reference custom field can link to several content types
  (`target_types`).** Workstream R2 of
  [relationships-plan.md](../relationships-plan.md). A `:reference` field
  names its one type in `target_type`, as before, or several in the new
  `target_types` list; exactly one of the two is set, and every name must be
  a compiled or dynamic type on the site, once. Each stored snapshot already
  names its own `"type"`, so a value is self-describing, and a list of
  references (R1) may mix types. A write to a field with several types must
  name each item's type, `{"id", "type"}`; a bare id is refused, and so is a
  type the field does not allow, naming the item. The id is looked up among
  that type's records only. A field with one type keeps accepting a bare id.
  The `ContentLink` edges and the re-fire edges (R0, #1998) take each item's
  own type, and `custom_filter` keeps matching on the id. The schema export
  reports every reference field's allowed types as `x-kiln-target-types`, an
  annotation rather than an `enum`, and the TypeScript export comments them
  on the field. In the fields admin, *Links to* becomes a set of checkboxes:
  one ticked type is saved as `target_type`, several as `target_types`. The
  editor's reference picker (R9) searches every allowed type, shows each
  result's type, and keeps each pick's type through reorders and saves. The
  typed GraphQL interface over the allowed types is R7. No existing field
  changes.
  ([#2004](https://github.com/The-Verscienta/kiln_cms/pull/2004))

<a id="the-editor-fills-a-reference-custom-field-from-a-search-picker-instead-of-a"></a>

- **The editor fills a reference custom field from a search picker instead of
  a select of up to 500 records.** Workstream R9 of
  [relationships-plan.md](../relationships-plan.md), first part. Typing
  searches the target type by title on the server, as the editor and in their
  site, one page of 20 at a time with "Show more", so there is no cap and a
  record the editor may not read is never offered. An empty search lists the
  most recently edited records. Results and connected records show their
  title, type and state, and each connected record links to its own editor in
  a new tab. A list of references (R1) adds several in a row, reorders by
  dragging a row's handle or with its up and down buttons, and removes rows; a
  single reference holds one record and offers the search again once it is
  removed. A full list stops offering more. A stored reference the editor
  can no longer read stays in place, marked unavailable, rather than being
  dropped on the next save. The search is a combobox: arrow keys move through
  the results, Enter picks, Escape closes, and Enter never submits the page.
  The value is still written into the content form, so saving, the working
  copy and the stale-edit check behave as they do for any other field.
  Several target types (R2), per-link fields (R3) and the reverse list (R4)
  add to the same picker later.
  ([#2002](https://github.com/The-Verscienta/kiln_cms/pull/2002))

<a id="the-reference-picker-can-create-a-record-and-connect-it-in-one-step-add-new"></a>

- **The reference picker can create a record and connect it in one step: "Add
  new *Type*" next to the search.** Workstream R9 of
  [relationships-plan.md](../relationships-plan.md), "Create and connect".
  Each target type the editor may create gets an "Add new" action under the
  search; it opens a small form inline with the title and the type's
  required fields that have no default, nothing else. The record is created
  as the editor through the type's own create action, so it is an ordinary
  draft and the type's policies apply, and it is connected as if it had been
  picked: added to the end of a list, or filling a single reference. The row
  shows its Draft badge and a link to open it. The connection is part of the
  document's unsaved change like any pick, so the working copy and the
  stale-edit check are untouched; abandoning that change leaves the new
  draft in the content list. The action is hidden when the type's
  `can_create_*?` helper (new `ContentTypes.can_create?/4`) refuses, when
  the field is full or locked, and for a type with a required media,
  reference or plugin-typed field and no default, which the small form
  can't fill. Enter in the form creates instead of saving the page, and
  Escape closes it.
  ([#2005](https://github.com/The-Verscienta/kiln_cms/pull/2005))

<a id="computed-field-builder"></a>

- **Computed fields have a formula builder: pick a recipe and fill in the
  blanks, or write the formula with value and function palettes, and see the
  result live on your own content.** Custom fields → *Computed* used to be a
  single text box for a `{{ … }}` template, which only someone who already
  knew the syntax could fill. It now opens in a **Recipe** view: twelve common
  computations (reading time, word count, a value with a label, combine
  values, URL slug, shortened text, first non-empty value, total, multiply,
  percentage, *if … then …*, days between dates), each with dropdowns over
  the document's values and the type's other fields. The **Formula** view is
  the template with buttons that insert a value or a function at the caret and
  every function listed with what it does. Both preview the result against the
  type's five most recently edited documents. The formula language gains
  conditions (`if`, `equals`, `greater_than`, `less_than`, `contains`,
  `is_empty`, `and`, `or`, `not`), `replace`, and dates (`days_between`,
  `year`, `format_date`). Nothing new is stored and there is no migration: a
  recipe writes an ordinary `compute` formula, and editing a field opens the
  recipe view only when the formula is exactly a recipe's output, so a formula
  changed by hand is never rewritten. Three evaluation rules change for
  existing formulas, each of which used to store a wrong value rather than
  none: an interpolated template whose expressions are all blank is now blank
  (`{{ size }} EU` on a record without a size was "EU"); `product` is blank
  when a factor is missing (it used to skip it, so price × no quantity was the
  price); and `default` sees a filled list or map value (a gallery, a
  reference) as filled. Affected computed values change on the next save or
  fire. See docs/extending-content.md, "Computed fields".
  ([#2006](https://github.com/The-Verscienta/kiln_cms/pull/2006))

<a id="kilncmsdev-now-publishes-kilns-security-policy-at-security-and-a-security"></a>

- **kilncms.dev now publishes Kiln's security policy at `/security`, and a
  security notice per published GitHub advisory at
  `/security-notices/<ghsa-id>`, with a feed.** A new workflow,
  `publish-security.yml`, runs `scripts/publish_security.exs` daily, when a
  release is published, and when `.github/SECURITY.md` changes on `main`.
  The page is `SECURITY.md`, with its relative links pointed at GitHub, plus
  the list of notices. Each notice is an entry of a `security_notice`
  content type whose custom fields are `package`, `affected_versions`,
  `patched_versions`, `severity`, `advisory_id`, `cve_id`, `published_on`
  and `advisory_url`. `package` is `kiln_cms` for the core and a plugin's
  Hex name for a plugin's notice, so the plugin registry (#1447) can share
  the type and its feed at `/security-notices/feed.xml`. A withdrawn advisory
  is not published, and the script never unpublishes a notice. The type is a
  one-time setup on the site; the script names any field it is missing.
  `SECURITY.md` and the README link to the page and the feed. Nothing
  changes for a self-hosted instance: the script and workflow publish to
  kilncms.dev only. The per-site `security.txt` this issue also asked for
  shipped in 1.1.0 (#1881).
  ([#1873](https://github.com/The-Verscienta/kiln_cms/issues/1873))

<a id="tags-tag-groups-and-categories-send-webhooks-tagcreated-tagupdated-tagdeleted"></a>

- **Tags, tag groups and categories send webhooks: `tag.created`,
  `tag.updated`, `tag.deleted`, and the same for `tag_group` and
  `category`.** A receiver that caches taxonomy can now invalidate on a change
  instead of polling. Each create, edit or delete sends one event after it
  commits, to endpoints of the term's site that selected it. None is in the
  default subscription, so existing endpoints receive nothing new until an
  admin opts in. The payload is `id`, `slug`, `name`, `updated_at` (plus
  `tag_group_id` for a tag); an `updated` adds `previous_slug` when the slug
  changed and `previous_tag_group_id` when a tag moved group, and a `deleted`
  is the record as it was. Deleting a tag or tag group sends no event for the
  records the delete cascades to. A taxonomy delete is not a retraction: it is
  not retried for a day or sent to auto-disabled endpoints. The console does
  not mark `tag.created` as "includes unpublished content". Taxonomy events
  skip automation rules and federation, and trigger the optional CDN purge. A
  new dynamic content type may not be named `tag`, `tag_group` or `category`,
  so those event names always mean taxonomy; an existing type with such a name
  can still be edited. See docs/webhooks.md, "Taxonomy events".
  ([#1965](https://github.com/The-Verscienta/kiln_cms/issues/1965))

<a id="release-adopt-image-backend"></a>

- **A release can adopt imported images: `bin/kiln_cms rpc
  'KilnCMS.Release.adopt_image_backend()'`. System → Image backend labels it
  and the Mix task, each with a dry run first.** The page listed
  `mix kiln.media.adopt_image_backend` and a raw `rpc` call one under the
  other, unlabelled, so an operator pasted both into a release's shell, where
  there is no Mix. The `rpc` call printed nothing, and the org ID's inner
  quotes were easy to lose to a `docker exec` or `ssh -C` wrapper, which fails
  as a bare `CompileError` whose cause is only in the server's log.
  `KilnCMS.Release.adopt_image_backend/1` is the task for a release, like the
  importers beside it: it prints the task's report, returns refusals instead of
  raising, and refuses under `eval`, since each adopted row enqueues a job.
  For the default site it takes no org, so its command has no inner quotes;
  `org: "<uuid>"` names another.
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))

<a id="media-field-gallery"></a>

- **A media custom field can hold a gallery: an ordered set of images rather
  than one.** The fields admin now asks what a media field holds, *a single
  item* (the default, and what every existing field stays) or *a gallery*
  (`FieldDefinition.multiple`). A gallery stores a list of the same
  `%{"id", "url", "alt"}` snapshots a single media field stores, in the order
  the editor arranged them. In the editor it is a strip of thumbnails, filled
  from the library drawer's multi-select (click order is gallery order),
  with buttons on each tile to move it or remove it. Writers may send a list
  of ids or snapshots; a lone id is a one-image gallery, repeats are kept
  once, and one id that does not resolve fails the field. `custom_filter` on
  a gallery matches by containment (`eq` = holds this image, `in` = holds any
  of them), every image counts as a media usage, and the JSON schema export
  types the field as an array. Flipping the setting on a field that already
  has values reshapes them: a single image becomes a one-image gallery, and a
  gallery keeps only its first image (as does retyping a gallery away from
  media), which the fields admin warns about before the save; published
  documents of the type re-fire to pick up the new shape. A single media
  field handed a stale gallery list keeps its first image, so drafts and
  versions saved before the switch still publish and restore. Additive migration: one `boolean` column defaulting to
  `false`.
  ([#1992](https://github.com/The-Verscienta/kiln_cms/pull/1992))

<a id="propagation-records"></a>

- **Every publish and withdrawal is measured end to end: one propagation
  record per transition, `mix kiln.propagation` for p50/p95, and a telemetry
  event to graph it.** The path forward's first claim, that a correction
  reaches everything a site serves within N seconds, had no N. The webhook
  fan-out now opens a `propagation` record for each `published`,
  `unpublished`, or trashing of a live document, with the number of
  endpoints it was sent to. Each delivery points back at it. The record
  settles once every delivery has a 2xx or has been given up on, and the CDN
  purge (when `KILN_CDN_PURGE_URL` is set) has been acknowledged or has
  failed. Settling stamps the transition-to-last-endpoint and
  transition-to-purge latencies and emits
  `[:kiln_cms, :propagation, :complete]`, summarised in
  `KilnCMSWeb.Telemetry`. `KilnCMS.Propagation.percentiles/2` and
  `mix kiln.propagation` report p50/p95 over a window, counting lost and
  still-open transitions apart. `docs/benchmarks.md` describes the method and
  has the table for the first measurement. A migration adds the
  `propagations` table (pruned after 90 days) and
  `webhook_deliveries.propagation_id`.
  ([#1927](https://github.com/The-Verscienta/kiln_cms/issues/1927))

## Fixed

<a id="variant-worker-backend-errors"></a>

- **A variant job no longer takes an image backend's failed or rate-limited
  read for a deleted original.** `VariantWorker` treated every failed read of
  the original as "removed, nothing to do" and completed. For a file on disk
  that is usually true; for an image backend, a remote API, it is usually a
  timeout, a 5xx or a rate limit. An adopted row then kept no dimensions or
  variants, and since it was no longer an imported link, nothing enqueued it
  again. A read refused with `{:rate_limited, retry_after_ms}`, the shape
  Kiln's own budgets use, now snoozes the job, which doesn't spend an attempt,
  so a large adoption paces itself under a backend's API budget. Any other
  failed read of a backend-held original is retried, unless the backend says
  `:not_found`. Reads from Kiln's own storage are unchanged.
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))

<a id="regeneration-pixel-cap"></a>

- **Regenerating variants skips images over the pixel cap instead of
  re-reading each original on every run.** An image recorded over
  `max_pixels` (50 MP) can never be given variants: its job reads the
  original and refuses it, as the transform route refuses it from the same
  recorded size. The missing-only run still enqueued it every time, and for
  an image backend's item each of those reads is an API download. A 52.9 MP
  photo adopted from a Sanity import cost one on every run. `Regeneration.run/2`
  now counts such images in `over_pixel_cap` without enqueuing them, and
  `mix kiln.media.regenerate_variants` reports the count.
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))

<a id="graphql-published-queries-without-offset-return-their-page-fields-hasnextpage"></a>

- **GraphQL `published*` queries without `offset` return their page fields
  (`hasNextPage`, `hasPreviousPage`, `pageNumber`, `lastPage`) again: an
  omitted `offset` now means `0`.**
  ([#1883](https://github.com/The-Verscienta/kiln_cms/issues/1883))

<a id="renaming-a-document-now-re-fires-the-documents-that-point-at-it-through-a"></a>

- **Renaming a document now re-fires the documents that point at it through a
  `:reference` custom field, and their fired artifacts carry its new slug and
  title.** A `:reference` field's value was mirrored as a backlink (#1594) but
  never became an edge in the re-fire graph (decision D13), which only read
  block references, block media, the featured image and `:media` fields. So
  publishing a rename re-fired nothing, and every referrer's `:json` artifact
  kept the title and slug stored when the referrer was last saved. The edges
  are now written on every fire, single and list values alike, with media
  snapshots (which carry a `"url"`) still recorded as media. Firing also reads
  the target's current slug and title for the fired copy of the value, when
  the target is published; an unpublished target keeps the stored label, so no
  draft title reaches a public artifact. The stored `custom_fields` value and
  its `%{"id", "type", "slug", "title"}` shape are unchanged, and so is what
  the delivery APIs return for it. Existing referrers get their edges the next
  time they fire. No migration.
  ([#1998](https://github.com/The-Verscienta/kiln_cms/pull/1998))

## Security

<a id="bandit-1130-fixes-eef-cve-2026-105660-a-client-could-choose-connhostconnport"></a>

- **bandit 1.13.0 fixes EEF-CVE-2026-105660 (a client could choose
  `conn.host`/`conn.port` via the HTTP/1 request target) and the HTTP/2 DoS
  EEF-CVE-2026-105659, so the endpoint speaks HTTP/2 again.**
  ([#1991](https://github.com/The-Verscienta/kiln_cms/pull/1991))

<a id="phoenix-showcase-advisories"></a>

- **The `examples/phoenix_showcase` template's lock clears 23 Hex advisories
  (phoenix, phoenix_live_view, bandit, plug, mint, hpax, lazy_html), and CI
  now audits it.** The headless LiveView example is not part of the release
  image, but it is offered as the starting point for a decoupled frontend, so
  a copy inherited its lock: phoenix 1.8.8, phoenix_live_view 1.2.5, bandit
  1.12.0 (five advisories, among them EEF-CVE-2026-105659 and
  EEF-CVE-2026-105660), plug 1.20.2, mint 1.9.0 (nine), hpax 1.0.3 and
  lazy_html 0.1.11. The lock moves to phoenix 1.8.15, phoenix_live_view
  1.2.12, bandit 1.13.1, plug 1.20.3, mint 1.11.0, hpax 1.1.0 and lazy_html
  0.1.13; no `mix.exs` requirement changed. Nothing in CI built the example,
  which is how it went stale, so the Dependency audit job now runs
  `mix hex.audit` in `examples/phoenix_showcase` too.

