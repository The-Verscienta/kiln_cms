# CDN integration for media

Phase 6 issue #42. KilnCMS serves user-uploaded media (originals + generated
image variants) through the pluggable `KilnCMS.Storage` adapter. This guide
covers putting a CDN in front of that media in production so delivery is fast,
cheap, and offloaded from the app.

## How media URLs are built

Callers never hardcode a host — they call `KilnCMS.Storage.url/1`, which the
active adapter resolves:

| Adapter | `url/1` returns | Configured by |
|---------|-----------------|---------------|
| `KilnCMS.Storage.Local` (default) | `<base_url>/<key>` → `/uploads/<key>` | `:base_url` (default `/uploads`) |
| `KilnCMS.Storage.S3` (prod) | `<public_base_url>/<key>` | `S3_PUBLIC_BASE_URL` |

So **the CDN base URL is just `S3_PUBLIC_BASE_URL`** — point it at your CDN
hostname instead of the raw bucket endpoint and every media URL the app emits
(in HTML, JSON:API, GraphQL, and the editor) flows through the CDN. The key is
appended to it, so it must already include any bucket path segment.

```bash
# Object storage holds the bytes…
S3_BUCKET=kiln-media
S3_ENDPOINT_HOST=s3.eu-central-1.backblazeb2.com   # provider-specific
# …but this is the host the public sees — your CDN in front of the bucket:
S3_PUBLIC_BASE_URL=https://cdn.example.com
```

This is intentionally distinct from `PHX_HOST` / `PUBLIC_BASE_URL` (the *site*
origin used for canonical tags, the sitemap, and webhook URLs — see
[`docs/domain-and-ssl.md`](domain-and-ssl.md)). Media lives on its own origin so
it can be cached and scaled independently of the app.

## Cache headers

Upload keys are UUID-named and image variants are immutable — the bytes at a
given key never change. So media is served with a long, immutable
`Cache-Control`, letting the CDN and browsers cache it indefinitely:

- **S3 adapter** — the header is written onto each object at upload time
  (`cache_control` in `KilnCMS.Storage.S3`), default
  `public, max-age=31536000, immutable`. Override with `S3_CACHE_CONTROL`.
- **Local adapter** — the `/uploads` `Plug.Static` mount sets the same
  `cache_control_for_etags`, so even the single-node fallback is CDN-friendly.

Because keys are unique per upload, there is no cache-invalidation problem:
replacing media produces a new key (and URL), so a purge is never required. If
you ever need to override (e.g. shorter TTL during a migration), set
`S3_CACHE_CONTROL`.

## Deployment recipes

### CDN in front of an S3-compatible bucket

1. Make the bucket public-read at the bucket level (see `KilnCMS.Storage.S3`
   moduledoc; only set `S3_ACL=public_read` if your provider needs per-object
   ACLs).
2. Create a CDN distribution with the bucket (or its website/S3 endpoint) as the
   origin:
   - **Cloudflare** — a proxied CNAME / R2 custom domain; enable "Cache
     Everything". With R2, `S3_PUBLIC_BASE_URL` is the R2 custom domain.
   - **AWS CloudFront** — origin = the bucket; `S3_PUBLIC_BASE_URL` = the
     CloudFront domain (or your CNAME).
   - **Bunny / Fastly / Cloud CDN** — pull zone with the bucket as origin.
3. Set `S3_PUBLIC_BASE_URL` to the CDN hostname and redeploy. Trust the origin
   `Cache-Control` (don't let the CDN override TTLs down).
4. Serve over HTTPS; if the CDN supports HTTP/2/3 and Brotli, enable them.

### Provider notes

- The app talks to the bucket for **writes/reads** via `ex_aws` using
  `S3_ENDPOINT_HOST` etc.; the CDN only ever sees **public GETs**. These are two
  different hosts and that's expected.
- MinIO/dev: no CDN — `S3_PUBLIC_BASE_URL` is just the MinIO bucket URL
  (`http://localhost:9000/<bucket>`).

## Verification

```bash
# Upload a file via the editor, copy its URL, then:
curl -sI "https://cdn.example.com/<key>" | grep -i -E 'cache-control|age|x-cache|cf-cache-status'
```

Expect `cache-control: public, max-age=31536000, immutable` and, on a second
request, a cache HIT (`x-cache: Hit` / `cf-cache-status: HIT`).

## Future work

- Signed URLs for private/draft media (everything today is public-read).
- On-the-fly CDN image resizing as an alternative to pre-generated variants.
