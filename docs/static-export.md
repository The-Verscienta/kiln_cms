# Static / edge export of fired artifacts

Export Kiln's immutable, pre-rendered artifacts to a **static directory tree**
you can `rsync` to a CDN, bake into an edge cache, or ship to an air-gapped host
([#353](https://github.com/The-Verscienta/kiln_cms/issues/353); the salvaged,
useful kernel of the "hybrid rendering" idea — see
`docs/differentiator-opportunities.md`).

## Why this is different from a bolt-on SSG

Kiln's firing engine already produces immutable per-surface artifacts
(`:web`/`:json`/`:json_ld`) with a dependency graph that **re-fires dependents
precisely on change** — this *is* static generation, with better invalidation
than a generic SSG. The only missing piece was an *output surface*. Static
export is exactly that: it copies the already-fired artifacts out. It does
**not** re-render, and it does **not** fork the CMS — the live CMS stays
authoritative; the export is a snapshot. Overlaps with #341 (DB-outage-resilient
delivery): the same immutable artifacts underpin both.

## Using it

### Mix task

```
mix kiln.export.static <out_dir> [--surface web,json,json_ld] [--base-url URL]
```

```
mix kiln.export.static ./_static
mix kiln.export.static /var/www/edge --surface web
mix kiln.export.static ./_static --base-url https://cdn.example.com
```

### Background / admin / cron trigger

`KilnCMS.Firing.StaticExportWorker` runs the same export off-request. Configure a
destination and enqueue it from an admin action, a release task, or a cron entry:

```elixir
config :kiln_cms, KilnCMS.Firing.StaticExport,
  output_dir: "/var/www/edge",
  surfaces: [:web, :json, :json_ld]
```

```elixir
Oban.insert(KilnCMS.Firing.StaticExportWorker.new(%{}))
# …or override the destination per job:
Oban.insert(KilnCMS.Firing.StaticExportWorker.new(%{"out_dir" => "/tmp/snapshot"}))
```

With no `output_dir` configured (and no `out_dir` arg) the worker is a logged
no-op, so it's safe to schedule a cron entry before picking a destination.

## Output layout

```
<out>/
  index.json                                     # export manifest
  content/<type>/<locale>/<slug>/
    web.html                                      # :web surface — the fired HTML body
    json.json                                     # :json surface — structured intent
    json_ld.json                                  # :json_ld surface — schema.org graph
```

- `<type>` is the **public** content type (`page`, `post`, or a dynamic type's
  name); `<locale>` is always present.
- The bodies are byte-for-byte what the headless API serves at
  `GET /api/content/<type>/<slug>?surface=…` — no re-render.
- `index.json` lists every exported document (`type`, `slug`, `locale`, `path`,
  `surfaces`, plus the run's `generated_at`/`base_url`), so an edge deploy can
  diff and prune deterministically.

## Scope & follow-ons

Phase-1 slice:

- **Read-only.** Only already-fired artifacts are exported; a published document
  that has never been fired is skipped and counted (publish/backfill first).
- **No pruning.** Existing files are overwritten; content deleted since a prior
  export is not removed — diff `index.json` to reconcile. A `--prune` mode is a
  natural follow-on.
- **Whole-site export.** Incremental export (only artifacts fired since a
  watermark, driven by the firing broadcast) is a Phase-2 optimization for large
  sites; the dependency graph already makes it tractable.
- **Admin UI button.** The worker is the programmatic trigger today; a one-click
  "Export static site" admin affordance is a small follow-on.
- The `:web` surface is the fired HTML **body** (the same bytes the `?surface=web`
  API returns), suited to an edge cache or a frontend that composes its own
  layout — not a fully-laid-out standalone page (that would require re-rendering
  the site layout, which this deliberately avoids).
