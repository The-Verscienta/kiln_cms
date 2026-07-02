# Performance & Usability Audit — July 2026

> **Status (2026-07-02): CLOSED.** All HIGH and MEDIUM findings are fixed — the
> highs plus 14 mediums landed in PR #254; the remainder (P-M6, P-M8,
> broadcast_preview-when-unsubscribed, U-M3, U-M4, U-M5, U-M8) shipped with it
> too. The follow-up branch completed the rest: full server-side search +
> keyset "Load more" pagination for the editor/media/trash lists and the media
> picker (U-M2/P-H2/P-H3 tail), and the LOW items — trashed-media bound,
> webhook dispatch DB filter, backfill-task selects, bulk reference-edge
> rebuild + batched block-indexer hash reads, snapshot-aware history replay,
> local-timezone timestamps, localized blog dates/plurals/byte units, search
> palette media deep-links, media filter over alt/caption with a11y labels +
> live region, untitled-draft sweep (AshOban trigger), webhook-dot sr-only
> text, session-aware `<html lang>` + switcher `aria-current`, and
> `scope="col"` headers. Only the search-palette FTS watch item ("acceptable,
> watch it") remains as-is by design.

Scope: current `main`-equivalent code (branch `claude/happy-darwin-6c4a55`, clean at e118963).
Method: four parallel evidence-based reviews (data-layer performance, web/runtime
performance, admin/editor UX, accessibility & error states), with high-severity claims
spot-verified against source. Fixes from the June 2026 audits (#111–#231) were confirmed
present and are not re-reported.

Severity: **High** = data loss, unbounded work on a hot path, or a user hard-blocked.
**Medium** = degrades noticeably at realistic scale or trips users regularly.
**Low** = polish / latent.

---

## Performance

### High

**P-H1. Full event-log read on every collaborative block edit.**
`lib/kiln_cms/history.ex:86-93` — `next_seq/2` reads the *entire* `:for_document`
event stream (no limit, every row carrying a full `payload` incl. block contents) just to
take `List.last(events).seq + 1`. It is called from `KilnCMS.Collab.apply_op/4`
(`lib/kiln_cms/collab.ex:37`) on **every** add/remove/update/reorder op, and the log is
append-only with no compaction — O(n) full-payload transfer per edit, O(n²) over a
document's life. The `(document_type, document_id, seq)` unique index already supports a
`sort(seq: :desc) |> limit(1)` (or DB-side `max(seq)`). The read-then-insert is also racy
for two concurrent editors; a DB-side `max(seq)+1` fixes both.

**P-H2. Content editor mount loads ~1000 full records including block JSONB trees.**
`lib/kiln_cms_web/live/content_editor_live.ex:85-97,184-188` — mount loads 500 media
items plus `siblings/3`, which fetches up to 500 **complete** sibling records (blocks
JSONB and all) to render `{title, id}` `<select>` options. All of it sits in every open
editor's LiveView heap. Mount also runs 7+ sequential queries before first paint. Fix:
`Ash.Query.select` id/title for siblings; defer media/siblings to `assign_async` or
load-on-picker-open.

**P-H3. Content index holds full block trees for 500 × N-types rows, refetched wholesale.**
`lib/kiln_cms_web/live/editor_live.ex:34-50` — needs title/slug/state/updated_at but
loads every attribute (incl. `blocks`) for up to 500 rows *per content type*; no
`stream/3`; `visible_items` re-filters (with per-row `String.downcase`) on every
debounced keystroke; `load_items` refetches **all types** after every publish/unpublish
click (line 180). Same full-select pattern in `trash_live.ex:48-50`. Note: there is not a
single `Ash.Query.select` anywhere in `lib/` — heavy columns (`blocks`, `search_text`,
384-dim `embedding`) ride along on every list read.

### Medium

**P-M1. Missing indexes on real query paths** (all confirmed absent from migrations):
- `scheduled_at`/`state` on content tables — the every-minute `publish_scheduled`
  scheduler (`lib/kiln_cms/cms/content.ex:285-298`) seq-scans every content table, per
  minute, forever. Partial index: `(scheduled_at) WHERE scheduled_at IS NOT NULL AND
  state IN ('draft','in_review')`.
- `(state, published_at)` — the `:published` read (`content.ex:89-104`) behind the blog
  index and JSON:API/GraphQL feeds sorts unindexed. Partial index
  `(published_at DESC) WHERE state = 'published'`.
- `reference_edges (to_type, to_id)` — the re-fire invalidation walk
  (`lib/kiln_cms/firing/references.ex:70`) full-scans; the only index leads with `from_*`.
- Reverse-lookup FKs: `content_links.target_id` (incoming-links), `taggings.tag_id`
  (Tag page/post-count aggregates loaded on every TaxonomyLive mount),
  `pages/posts.category_id`, `.author_id`, `.featured_image_id` (search facets, media
  reverse relationships).

**P-M2. `:search` / `:search_semantic` actions unpaginated on the public API.**
`lib/kiln_cms/cms/content.ex:452-518` declares no pagination/limit, yet both are exposed
as JSON:API routes and GraphQL lists (`content.ex:169-170,186-190`); same for MediaItem
`:search`. A call to `/api/posts/search` returns every match; for the semantic action, an
`ORDER BY embedding <=> $1` **without LIMIT cannot use the HNSW index** — full-scan
cosine distance over every embedded row. Add `pagination` (as `:read`/`:published` have)
or a hard limit in the prepare. Related latent bug: `Search.hybrid/3` legs
(`lib/kiln_cms/search.ex:200-205`) do `Ash.read!` then `Enum.take(50)` — put the limit in
the query.

**P-M3. Inline live preview rendered twice per render, on every event.**
`content_editor_live.ex:1626,1633` both call `preview_article` (mobile + desktop copies);
`preview_html/1` converts the whole block form → typed structs → per-block render →
sanitizes every rich-text block, re-executed on every debounced `validate`, every
presence diff, every collaborator cursor event. Compute once into an assign in
`handle_event("validate", ...)`. Similarly `broadcast_preview/1`
(`content_editor_live.ex:230-234,583-599`) builds and broadcasts the full block payload
per keystroke even when no pop-out preview is open — skip when nobody subscribes.

**P-M4. No cache-stampede protection on the delivery hot path.**
`lib/kiln_cms/cache.ex:54-66` — plain get-then-compute; after `bust_published/0` (any
media edit) all concurrent requests for a hot page each run the full fetch+enrich
pipeline. Use `Cachex.fetch/4` (deduplicates concurrent fallbacks). Same in `fetch/3`
used by the sitemap.

**P-M5. Uploaded media served without `max-age` despite immutable UUID keys.**
`lib/kiln_cms_web/endpoint.ex:40-43` — Plug.Static for `/uploads` uses default
`cache_control_for_etags: "public"`, forcing a revalidation round-trip per image per page
view. Keys are UUIDs (`lib/kiln_cms/storage.ex:56-63`) so
`public, max-age=31536000, immutable` is safe.

**P-M6. TipTap/ProseMirror shipped to every public visitor.**
`assets/js/app.js:28` imports `rich_text.js` (`@tiptap/core`, `@tiptap/starter-kit`) into
the single bundle loaded by the public root layout. No esbuild splitting/second
entrypoint. Split an `editor.js` entrypoint or dynamic-`import()` inside the hook.

**P-M7. Media library: full 500-row refetch per variant-job broadcast.**
`lib/kiln_cms_web/live/media_live.ex:167-169,273-282` — every finished variant job
broadcasts to all open MediaLive sockets, each re-querying 500 rows (10-file upload → 10
full refetches per viewer). Grid is not a `stream`. Use `stream_insert` with the id the
broadcast already carries.

**P-M8. Synchronous libvips re-encode in the LiveView process; no pixel-dimension cap.**
`media_live.ex:53-69,176-205` + `lib/kiln_cms/image_processor.ex:37-52,79-95` —
metadata-strip fully re-encodes each of up to 10×10MB uploads inline in
`handle_event("save")`, blocking the socket; `validate_upload` has no width×height bound,
so a small PNG can decompress to a multi-GB pixel buffer inside a web process. Reject
above a max pixel count; consider moving the strip into the variant worker.

**P-M9. Analytics dashboard: unbounded read + Elixir aggregation + N+1 lookups.**
`lib/kiln_cms_web/live/analytics_live.ex:13-21,50-56` — `list_views!` (the `:top` read
has no limit) loads one row per ever-viewed item, `Enum.sum_by` computes the total in the
BEAM, then `decorate/1` issues up to 50 sequential `get_record` queries. Limit 50 in the
read, DB aggregate for the total, one batched `id in ids` read per type. No index on
`content_views.views` for the `:top` sort.

**P-M10. Sitemap rebuild loads up to 50k full records.**
`lib/kiln_cms_web/controllers/sitemap_controller.ex:37-52` — all attributes (blocks,
embedding, search_text) selected to emit slug/locale/updated_at. The 5-minute TTL bounds
frequency, not the per-rebuild memory spike (and it is stampede-unprotected, see P-M4).
Add a `select`.

### Low

- **Blog index runs an unused COUNT(*) per request** —
  `lib/kiln_cms_web/controllers/content_controller.ex:95-100` passes `count: true`; only
  `more?` is used. Drop it.
- **Trashed-media list unbounded** — `media_live.ex:264-266` has a sort but no limit,
  unlike its siblings.
- **Webhook dispatch filters in Elixir** — `lib/kiln_cms/webhooks.ex:31-33` reads all
  endpoints then filters `active && event in events`; fine while small, belongs in the query.
- **Backfill mix tasks materialize full tables** — `lib/mix/tasks/kiln.embed_all.ex`,
  `kiln.meili.reindex.ex`: use `Ash.stream!` + select + `Oban.insert_all`.
- **Per-row loops in firing** — `references.ex:48-58` destroy/upsert per edge;
  `block_indexer.ex:73-78` one embedding read per block. Bulk when block counts grow.
- **Time-travel replay folds the whole log** — `history.ex:64-70` fetches events *after*
  the cutoff too (`filter_upto` trims in Elixir) and ignores snapshots as starting points.
- **Search palette** runs 3 FTS queries synchronously per 150 ms keystroke
  (`search_palette_live.ex:26-43`) — GIN-indexed and admin-only; acceptable, watch it.

### Verified clean (performance)

Delivery path (per-key cache, ETag/304, `stale-while-revalidate`, off-path bounded view
tracking); artifact API (cache-only reads, 503+Retry-After backfill); GraphQL complexity
limits + JSON:API pagination defaults; Bumblebee as supervised `Nx.Serving` with
batching; media variants in Oban; Hammer/ETS rate limiting with pruning; pgvector
HNSW/trgm/tsvector indexes all present; Oban triggers use `where` + keyset pagination;
pool sizing documented.

---

## Usability

### High

**U-H1. No unsaved-changes protection for non-draft content (data loss).**
`content_editor_live.ex:465-476,1288` — autosave and the Saving/Saved indicator run only
`if draft?`. Editing **published / in_review / archived** content, nothing tracks
dirtiness: "← All content", the Preview link, or closing the tab silently discards every
edit. There is no `beforeunload` handler anywhere in `assets/` (verified). Add a
dirty-form guard hook + indicator for all states.

**U-H2. Custom-field validation errors are invisible (editor hard-stuck).**
`lib/kiln_cms/cms/changes/apply_custom_fields.ex:137-143` adds errors on
`:custom_fields`, but `custom_field_input` (`content_editor_live.ex:691-767`) renders raw
inputs with no error output, and the Custom fields `<details>` (line 1517) is collapsed
by default. The editor sees only "Please fix the errors below" with nothing highlighted;
draft autosave says "Couldn't autosave — check for errors" with equally nothing to check.
Related a11y defect on the same inputs: labels are sibling `<label>`s with no `for`/`id`
association (also `field_definition_live.ex:213-220,323-330`), so they have no accessible
name either. Render `:custom_fields` errors per definition, auto-`open` the section on
error, associate labels.

**U-H3. Archive is an unconfirmed one-way door.**
`content.ex:272-279` defines no transition out of `:archived` (verified), and bulk
"Archive" (`editor_live.ex:100-126,207-220`) fires immediately — only Delete gets the
two-step confirm. One click archives an entire selection with no way back in UI *or*
state machine. Add an `unarchive` transition + button; route bulk archive through the
confirm strip.

**U-H4. Media grid is mouse-only — keyboard users cannot add alt text.**
`media_live.ex:463-470` — the only way to open the detail drawer (alt/caption editor,
URL copy, variants) is `phx-click` on a bare `<img>`: not focusable, no role, no keydown
(verified). The only focusable per-tile control is Delete — a keyboard/screen-reader user
can delete an image but never describe it. The image picker
(`content_editor_live.ex:980-996`) already wraps its thumbs in `<button>` — copy that.

### Medium

**U-M1. Delete-confirm wording contradicts soft-delete reality.**
`editor_live.ex:357-360` says "Permanently delete… This can't be undone" but the destroy
is AshArchival soft-delete, restorable from `/editor/trash` for 30 days. Media gets it
right ("Moved to trash"). Reword; and **bulk publish/unpublish also run with zero
confirmation** (`editor_live.ex:100-126,330-340`) — one click can take a whole site live
or offline; reuse the confirm strip with the count.

**U-M2. Hard 500-item window everywhere, silently truncated, client-side search only.**
`editor_live.ex:14-16`, `media_live.ex:15-17`, `content_editor_live.ex:29-31` (picker +
siblings), `trash_live.ex:13-15`. Item #501 is unreachable — search won't find it and
there's no "showing 500 of N" notice or next page. At scale editors conclude content has
vanished. Server-side search + keyset pagination (fixing this also fixes P-H2/P-H3).

**U-M3. List filter/search/status state is not in the URL.**
`editor_live.ex:72-75`, `media_live.ex:47` — no `handle_params`/`push_patch`; refresh,
back button, or sharing a link resets filters and loses your place.

**U-M4. Scheduled publishing: timezone ambiguity and zero post-save visibility.**
`content_editor_live.ex:1574-1578` — bare `datetime-local` stored as
`:utc_datetime_usec`: a non-UTC editor's wall-clock entry publishes hours off. After
saving, nothing anywhere says "Scheduled for …" — the state still reads "draft". Label or
convert the timezone; add a Scheduled badge in header + list.

**U-M5. Upload failures report a count, never a reason or filename.**
`media_live.ex:176-196,284-308` — server-side rejections (e.g. corrupt image) collapse to
"2 uploads failed." Collect `{client_name, reason}` and list them.

**U-M6. No LiveView sets `page_title` — every admin tab reads "KilnCMS".**
Zero occurrences in `lib/kiln_cms_web/live/` (verified by grep). Title is the screen
reader's page-change announcement on live navigation (WCAG 2.4.2), and tabs/history are
indistinguishable. Assign per mount; record title in the content editor.

**U-M7. Rate-limit 429 returns raw JSON on browser HTML pipelines.**
`lib/kiln_cms_web/plugs/rate_limit.ex:16-21` — wired into `:browser_auth` (sign-in) and
`:delivery` (all public pages). Visitors see bare, un-gettext'd JSON. Branch on format;
render a small HTML page for browser pipelines.

**U-M8. TipTap slash-menu is invisible to assistive tech and hijacks keys silently.**
`assets/js/rich_text.js:66-198,212-217` — menu is `role="listbox"` on `document.body`,
but the textbox never gets `aria-haspopup`/`aria-expanded`/`aria-activedescendant`;
Arrow/Enter/Tab are captured while open with no announcement. The block inserter
(`app.js:49-178`) does this correctly — mirror it. Toolbar labels are also hardcoded
English.

**U-M9. Only 404 is branded — 500/403 render bare plain text.**
`lib/kiln_cms_web/controllers/error_html.ex:17-19`; `error_html/` contains only
`404.html.heex`. Add a dependency-light `500.html.heex` (and 403).

### Low

- **Raw state atoms leak**: `content_editor_live.ex:1266-1268` renders `{@record.state}`
  ("in_review") and `:451` flashes the raw atom, though `state_label/1` exists.
- **UTC timestamps with no timezone hint** across trash/media/analytics/version-history
  (`Calendar.strftime(_, "%Y-%m-%d %H:%M")`); public blog dates are English-only
  (`%B %-d, %Y`) even on `/fr/…`; `humanize_bytes` hardcodes units/decimal separator.
- **gettext bypasses**: "No categorys yet." + naive `pluralize/2`
  (`taxonomy_live.ex:280-282,374-375`); bulk flash interpolates the raw English verb
  (`editor_live.ex:114-122`); `content_controller.ex:132` `"Search"`; hardcoded picker
  empty-state (`content_editor_live.ex:972-974`); analytics strings.
- **Search palette media hits don't deep-link** — `search_palette_live.ex:128-135`
  navigates to bare `/media`; pass the id and open the drawer.
- **Related-content picker is a native `<select multiple>`**
  (`content_editor_live.ex:1506-1513`) — ⌘-click UX, unsearchable 500 options;
  inconsistent with the checkbox tag picker beside it.
- **Media library filter matches filename only** (`media_live.ex:277-282`) while the
  picker's placeholder promises alt/caption too; both media search inputs are
  placeholder-only (no label/aria-label), and filter changes aren't announced.
- **"New page/post" instantly persists "Untitled…" records** (`editor_live.ex:62-70`) —
  abandoning leaves orphan drafts; consider periodic cleanup.
- **Webhook active dot is color-only** (`webhook_live.ex:219-223`) — add sr-only text.
- **`<html lang>` ignores session admin locale** (`root.html.heex:2` vs session-based
  admin locale); admin locale switcher lacks `aria-current` (public one has it).
- **Table headers lack `scope="col"`** (`analytics_live.ex:94-97`,
  `core_components.ex:544`).

### Verified clean (usability)

Flash feedback on success *and* failure across all 11 LiveViews with humanized errors;
delete confirmations on every single-item destructive action; `phx-disable-with`
double-submit protection; exemplary collab UX (presence roster, per-field locks,
conflict banner); upload progress/limits/per-entry errors with ARIA; consistent empty
states; focus-trapped modals with Escape/focus-return; keyboard alternative + aria-live
for drag-reorder; skip link, landmarks, `motion-safe`, focus-visible rings; branded 404;
disconnect/reconnect messaging.

---

## Suggested attack order

1. **P-H1** (one-line query fix, hot collab path) and **U-H4** (swap `<img>` for the
   existing button pattern) — small, high value.
2. **U-H1/U-H2/U-H3** — the three data-loss/hard-stuck editor traps.
3. **P-M1 indexes** — one migration, benefits every list/feed/scheduler.
4. **P-H2/P-H3 + U-M2 together** — introduce `Ash.Query.select` + streams + server-side
   search/pagination for editor/media/trash lists in one pass.
5. **P-M2** (API pagination), **P-M4** (`Cachex.fetch`), **P-M5** (uploads max-age),
   **P-M6** (JS split) — each independent and small.
6. Remaining mediums, then lows opportunistically.
