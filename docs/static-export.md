# Static site export

Stretch issue #66. For high-traffic blogs or CDN-only delivery, KilnCMS can
export all **published** content to a self-contained static HTML site with the
`mix kiln.export.static` task. Authoring still happens in the app; the export is
a point-in-time snapshot of the public site.

## What it does

The task ([`Mix.Tasks.Kiln.Export.Static`](../lib/mix/tasks/kiln.export.static.ex)):

1. Boots the app with the endpoint listening on a loopback port.
2. Reads `sitemap.xml` (the canonical list of every published public URL — pages,
   posts, other content types, and locale variants) and crawls each URL, plus
   the home page, blog index, `sitemap.xml`, and `robots.txt`, through the real
   delivery pipeline (cache, SEO tags, enriched blocks).
3. Writes each response as `<path>/index.html` (or the file itself for
   `sitemap.xml`/`robots.txt`).
4. Copies `priv/static` (compiled assets, images) into the output so the export
   is self-contained.

## Usage

```bash
# Build digested assets first so /assets/... references resolve.
mix assets.deploy

# Export (default output: priv/static_export)
mix kiln.export.static
mix kiln.export.static path/to/out      # custom directory
mix kiln.export.static --port 4998      # custom loopback render port
```

The export reads the live database, so run it against the environment whose
content you want to publish (typically production or a clone). Set
`PUBLIC_BASE_URL` to the final site origin so canonical tags, the sitemap, and
JSON-LD point at the deployed domain (see [Domain & SSL](domain-and-ssl.md)).

## Deploy to object storage / CDN

The output directory is plain files — deploy it anywhere static:

```bash
# S3 / MinIO (mirror, deleting removed pages)
aws s3 sync priv/static_export s3://my-static-site --delete \
  --cache-control "public, max-age=300"

# Cloudflare R2 (via the S3 API) or Backblaze B2 work the same way.
# Bunny / Netlify / GitHub Pages: point the host at the directory.
```

Front the bucket with a CDN exactly as for media (see [CDN](cdn.md)). Two cache
notes:

- **HTML** — use a short TTL (e.g. `max-age=300`) or purge on re-export, since
  content changes between exports.
- **Assets** (`/assets/...`) — already digested and immutable; let the
  long-cache headers from `mix phx.digest` stand.

## Limitations

- Only published content is exported; drafts and the editor/admin are not.
- Dynamic features that need the app at request time (search, analytics view
  counting, headless APIs) are not part of the static snapshot — keep the app
  running for those, or omit them on a static-only deployment.
- Re-run the export to publish changes (or wire it into an Oban job / CI step on
  a schedule).
