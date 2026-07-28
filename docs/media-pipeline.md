# Media pipeline

Uploads are validated from their **bytes** (allowed raster formats only, a
decompression-bomb pixel budget), re-encoded with **all metadata stripped**
(EXIF/GPS/device — privacy #215), and stored in object storage (local dev or
S3/MinIO). A background worker (`Media.VariantWorker`) then derives the
processing outputs; originals of non-raster uploads are simply served as-is.

## Derived variants

| label    | kind                    | size            |
|----------|-------------------------|-----------------|
| `thumb`  | downscale (same aspect) | 400w            |
| `medium` | downscale (same aspect) | 1024w           |
| `card`   | **focal-aware crop**    | 800×450 (16:9)  |

Downscales never upscale; the crop is skipped when the source is smaller than
its box. Public delivery builds responsive `srcset`s from the downscales plus
the original — **cropped variants are excluded** (a different aspect ratio in
an `srcset` would let the browser pick the wrong framing); consumers ask for
crops by label from the `variants` map (JSON:API/GraphQL expose it).

## Focal point

Every image carries a focal point (`focal_x`/`focal_y`, fractions of the
dimensions, default center). Editors set it by **clicking the preview** in the
media library (`/media`); changing it regenerates the focal-aware crops, and
public delivery emits `object-position` on image blocks so any theme cropping
via `object-fit` keeps the subject in frame. Both fields ride the public media
APIs for headless consumers.

## In-admin editing

The media detail panel offers **rotate left/right** and **flip
horizontal/vertical** (`Media.Transform`). Edits write the result under a
**new storage key** and repoint the item — the previous file is deliberately
kept, because published content embeds media snapshots captured at write time
and fired artifacts keep serving the old URL until re-publish. The focal point
is carried through the geometry (rotating the image rotates the point), and
variants regenerate from the edited original.

## Production storage & CDN

Development uses the Local adapter (`priv/uploads`, served by the app's own
`Plug.Static` mount). Production should serve media from object storage with a
CDN in front, so image bytes never touch the app.

Switch adapters by setting `S3_BUCKET`; `S3_PUBLIC_BASE_URL` then becomes
required (the app refuses to boot without it) and is the **CDN hostname** —
every media URL the CMS emits, original and variant alike, is that base plus
the storage key. Non-AWS stores also need `S3_ENDPOINT_HOST`. Full table:
[`environment-variables.md`](environment-variables.md#optional--object-storage-s3-compatible).

### Caching contract

Uploads carry `Cache-Control: public, max-age=31536000, immutable`, written as
object metadata at `PUT` time by [`KilnCMS.Storage.S3`](../lib/kiln_cms/storage/s3.ex),
so the CDN and the browser both see it on every GET.

Caching that hard is safe because **storage keys are write-once UUIDs**. A blob
is never overwritten in place: an in-admin edit writes a new key and repoints
the item (above), and regenerated variants get fresh keys too. A URL therefore
always denotes the same bytes — there is no invalidation step to run after an
edit, and no CDN purge to wire up.

### Putting a CDN in front

The pattern is the same everywhere: make the bucket readable, attach a CDN to
it on a hostname you control, and set that hostname as `S3_PUBLIC_BASE_URL`
(including the bucket path, if the provider's URLs carry one).

| Store | CDN | `S3_PUBLIC_BASE_URL` |
|---|---|---|
| Cloudflare R2 | R2 custom domain (Cloudflare CDN is automatic) | `https://media.example.com` |
| AWS S3 | CloudFront distribution with the bucket as origin | the distribution domain, or your CNAME |
| Backblaze B2 / Wasabi | Cloudflare, Bunny, or Fastly in front of the bucket endpoint | your CDN hostname |
| MinIO (self-hosted) | your existing reverse proxy / CDN in front of MinIO | `https://media.example.com/<bucket>` |

Public read is configured at the **bucket** level, not per object — that is
what R2, B2, Wasabi and modern AWS all expect. Only set `S3_ACL=public_read`
for a bucket that still relies on per-object canned ACLs.

Leave the CDN's own cache TTL on "respect origin headers"; the `max-age` above
is already the intended lifetime. If you also enable the CDN's image resizing,
note that Kiln has already derived the variants listed at the top — the two
will duplicate work.

Finally: if the CDN hostname differs from the site's own origin, add it to
`CSP_IMG_SRC` (space-separated, read in `config/runtime.exs`) or the browser's
`img-src` policy will block every image.
