# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

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

## Security

<a id="bandit-1130-fixes-eef-cve-2026-105660-a-client-could-choose-connhostconnport"></a>

- **bandit 1.13.0 fixes EEF-CVE-2026-105660 (a client could choose
  `conn.host`/`conn.port` via the HTTP/1 request target) and the HTTP/2 DoS
  EEF-CVE-2026-105659, so the endpoint speaks HTTP/2 again.**
  ([#1991](https://github.com/The-Verscienta/kiln_cms/pull/1991))

