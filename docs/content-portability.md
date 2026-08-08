# Content portability — import and export

Getting content **in** from another system, and **out** of this one (#487).

Three mix tasks:

| Task | Direction |
|---|---|
| `mix kiln.import.wordpress <file.xml>` | WordPress WXR export → Kiln |
| `mix kiln.export.content` | Kiln → portable JSON envelope |
| `mix kiln.import.content <file.json>` | portable JSON envelope → Kiln |

All three take `--actor EMAIL` and `--org SLUG`, and both importers take
`--dry-run`.

## Always dry-run first

```bash
mix kiln.import.wordpress export.xml --dry-run
```

A dry run performs every read — resolving slugs, matching taxonomy, deciding
what each record becomes — and no writes, then prints the same report a real
run prints. It shares the collision check with the real run, so the two cannot
disagree about what already exists.

It is a plan, **not a validation**. No changeset is built, so a record the
create action would ultimately reject is still counted as importable — a dry
run can over-report. Media is the reverse: it fetches nothing, so it reports
what it `would_import` rather than what is reachable.

## Migrating from WordPress

```bash
# 1. In WordPress: Tools → Export → All content. You get a .xml (WXR) file.
# 2. Look before you leap.
mix kiln.import.wordpress wordpress.xml --dry-run

# 3. Try a slice of it for real.
mix kiln.import.wordpress wordpress.xml --limit 20

# 4. The rest. Re-running is safe: what already exists is skipped.
mix kiln.import.wordpress wordpress.xml
```

### What maps to what

| WordPress | Kiln |
|---|---|
| `post` | Post |
| `page` | Page |
| `content:encoded` | typed blocks (`rich_text`, `image`, `embed`) |
| `<category domain="category">` | Category (one per record — the first) |
| `<category domain="post_tag">` | Tags |
| `attachment` referenced by a body image or `_thumbnail_id` | Media library item |
| `_thumbnail_id` | `featured_image_id` |
| `<link>` (the old permalink) | a Redirect at that path |
| `wp:status` `publish` | published, through the state machine |
| `wp:status` anything else | draft |
| `wp:post_date_gmt` | `published_at`, restored after the publish transition |

### Deliberate decisions worth knowing

**A `future` (scheduled) post lands as a draft**, with its date intact.
Importing it as published would put it live before the author intended, and
this importer has no scheduling story — the one case where guessing costs more
than asking.

**Only referenced attachments are imported.** A WordPress media library is
usually far larger than the content that survives a migration; pulling all of
it turns a ten-minute import into an hours-long one for assets nobody asked
for. Body images and featured images are fetched; orphans are not.

**An unreachable image does not cost you the post.** The block keeps the
source URL (so it renders, hotlinked) and the failure is listed in the report
for you to re-upload.

**Multiple categories collapse to one.** WordPress allows many, Kiln has one.
The first is kept.

**Redirects are built from the permalink's path**, not the whole URL — the old
host is by definition not this one. An old home page (`/`) is skipped: pointing
the new site's root at one imported post would break it.

**Publication dates are restored.** `published_at` is not an authored field —
the `:publish` transition stamps `utc_now` — so the importer puts the source
date back afterwards. Without that, a decade of archives all land in one
arbitrary-ordered second and feeds and sitemaps inherit it. The restore mints
one extra version per record, which is an honest record that the import set it.

**Media variants are generated asynchronously, by a running app node.** The
importer enqueues `VariantWorker` jobs; it does not wait for them. If you run
the import in a one-off container with nothing else consuming the `media`
queue, the jobs sit `available` and imported images render full-size until a
node picks them up. Run the import where the app is running, or drain the queue
afterwards.

### What is not imported

Comments, users, widgets, menus, theme settings, plugin data and post
revisions. WXR carries some of them; none map onto anything here without an
editorial decision a mix task should not be making silently. The imported
record is the current version, and its history starts at the import.

### Authors

Every author in the file is listed in the report — login, display name and
email — with a marker showing whether it resolved to a Kiln user:

```
Authors (1 mapped, 1 unmapped):
  -> jo "Jo Example" <jo@old.example.com>
   ~ sam "Sam" <sam@old.example.com>
```

Resolution order:

1. `--author-map login=kiln@email` (repeatable, and it also accepts the source
   *email* on the left)
2. otherwise the source author's own email, matched against a Kiln user — right
   far more often than not when both systems served the same people

An author that resolves to nobody is **not** an error: the record is attributed
to `--actor`, exactly as before. It is reported so you can decide whether that
matters before the content is live.

The create always runs under `--actor`, so an import can never mint content a
mapped author was not allowed to create; only the attribution moves afterwards,
through a narrow action that fires no webhooks.

## The portable JSON envelope

```bash
mix kiln.export.content --out content.json
mix kiln.export.content --type post --state published --out published-posts.json
```

```json
{
  "kiln_export": { "version": 1, "exported_at": "...", "types": ["post", "page"] },
  "records": [
    {
      "type": "post", "title": "...", "slug": "...", "locale": "en",
      "state": "published", "blocks": [ ... ], "category": "news",
      "tags": ["guides"], "seo_title": "..."
    }
  ],
  "media": [ { "id": "...", "url": "...", "filename": "...", "alt": "..." } ]
}
```

**References travel by slug, not by uuid.** A uuid is meaningless in the target
database, so an envelope full of them would import as content with every
relationship dropped. Media is the exception — it travels by manifest entry,
which the importer resolves to a URL and sideloads.

`blocks` is the typed-block tree in its storage shape, which is what a create
action accepts on the way back in. An export the importer cannot load is a
report, not a backup.

### What an envelope does not carry

Workflow history, versions, anchors, view counters, comments and form
submissions. Those describe what happened to the content *on this site*; they
are not the content, and replaying an anchor into another system as though it
had happened there would be actively wrong. See `mix kiln.audit.checkpoint` and
the governance exports for that ground.

Media **bytes** are not embedded either. An envelope with base64 images is
unusable at any real site's scale, and the importer sideloads from the
manifest — which does mean **the source must still be reachable** when you
import, or `--skip-media` will keep the blocks pointing at it.

### Scale

The WXR parser reads the whole file into memory and hands it to `xmerl`, which
expands it to a charlist first — roughly **16 bytes per source byte** before the
document tree is built on top. That puts the practical ceiling somewhere around
50 MB of XML on a normal box; past that you will hit an OOM kill with no partial
progress. WordPress's exporter can split a large site into several files, and
that is the supported way to import one — the importer is safe to run once per
file, because re-running skips what already landed.

Media sideloading is serial and runs before any record is written, so a site
with thousands of images spends a long time apparently doing nothing. `--limit`
is the way to try a slice first.

### Uses

- Moving a site between Kiln instances
- Seeding a staging environment from production content
- A portable copy that does not depend on this database
- Org-level content portability for the managed offering (#334)

## Re-running, and what happens on a collision

Matching is by `(slug, locale)` — the identity the database enforces.

| Situation | `--on-conflict skip` (default) | `--on-conflict error` |
|---|---|---|
| A live record has the slug | skipped | reported as failed |
| A **trashed** record has the slug | reported as failed | reported as failed |
| Nothing has the slug | created | created |

The trashed case is called out because `destroy` is a soft delete: the row and
its unique index survive while the ordinary read hides it. Without the check
the importer would plan a create and the database would refuse it with a bare
`slug: has already been taken`, which points at nothing. Restore the record or
purge it, then re-run.

**There is no overwrite mode.** A second import silently replacing edits an
author made after the first one is not recoverable through any UI. Content sync
is a different problem from content migration, and conflating them is how
people lose work.

## Authorization

Every read and write runs under `--actor`'s own policies. An export contains
exactly what that user could have read through the UI, and an import can only
create what they could have created by hand. Neither is a way around
authorization — an export endpoint that bypassed policy would be the most
efficient exfiltration primitive in the system.

Media sideloading fetches URLs that came from a file someone uploaded, so it
goes through `KilnCMS.SafeFetch` — the same path as oEmbed resolution. That
resolves the host once, checks the answer, and connects to that *literal
address* with SNI pointed back at the real name, which is what stops a name
being re-resolved to `169.254.169.254` between the check and the connection.
Redirects are refused rather than followed (a followed redirect is a fresh
resolution the pin never sees), and the body is capped.

## Extending to another source

`KilnCMS.Portability.Import` takes a source-neutral shape.
`KilnCMS.Portability.WXR` produces it from WordPress; a Ghost or Drupal
importer only has to produce the same shape to get the dry run, the conflict
policy, the media sideloading, the redirects and the report for free.

`KilnCMS.Blocks.Html` is the shared HTML → blocks adapter, and is deliberately
the only place HTML is read back into structure.

## Related

- [media-pipeline.md](media-pipeline.md) — what happens to a sideloaded asset
- [redirects](../lib/kiln_cms/cms/redirects.ex) — how an imported permalink resolves
- #472 — 404 capture, the other half of the migration story
