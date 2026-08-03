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

## Alt text and usage tracking

`MediaItem.alt` has always existed and has always been optional, which means it
is missing on exactly the images nobody thought about. Two things address that
(#403).

### Alt text is enforced at publish, not at upload

Off by default:

```elixir
config :kiln_cms, :media, require_alt_text: true
```

With it on, `:publish` and `:publish_scheduled` are refused when the document
contains an image block whose `alt` is blank, and the error names every
offending image at once so an editor can fix them in one pass.

**It checks the alt that actually renders** — the *block's* `alt` field. That is
what the image block's renderer and `KilnCMSWeb.BlockComponents` emit; the
library item's `MediaItem.alt` is the editor's default when inserting an image,
not what ships. Checking the library row instead would get it wrong in both
directions: refusing a page whose block carries a perfectly good description
because the library row is blank, and publishing a page that renders `alt=""`
because some library row happens to be filled in. An image pasted in by URL,
with no library item at all, is checked the same way.

Publish rather than upload, deliberately: what matters is whether the
*published page* is readable. A required field on upload blocks a bulk import,
has nothing sensible to say about decorative images, and makes every item
already in the library retroactively invalid.

**`decorative` is an answer, not an omission.** A divider, a texture, an image
that only repeats the sentence beside it — those correctly have *no* alt text,
which HTML spells `alt=""`. The flag on the media item records that as a
decision, so a blank block alt is accepted when the block points at an item
marked decorative. Without somewhere to say it, "deliberately silent" is
indistinguishable from "nobody got round to it".

Editing an *already published* document does not re-run this check — the gate is
on the publish actions. Tightening that is tracked separately.

### "Used by"

The media detail drawer lists the documents that reference an item, and the
delete confirmation says how many there are, so an editor can see what a delete
or a replace affects before doing it.

This reads the same `Firing.ReferenceEdge` graph the re-fire wave already
maintains, extended to record `content -> media` edges — an exact answer from one
indexed lookup rather than a scan of every document's block tree. Media is a
reference *target* only: a media item is not a document, has no artifacts and
never fires, so it is never a `from_type`.

Three reference sites are tracked: image-shaped block fields (any field named
`…media_id` or `…image_id`), a document's `featured_image_id`, and `:media`
custom fields. Edges are rebuilt from scratch on every fire, so removing a
reference removes the usage.

> **Published references only.** Edges are written when a document **fires**,
> which happens on publish — so an image used only by never-published drafts
> reports as unused. Deletes are soft (AshArchival), so a restore covers the
> mistake either way.

The drawer lists at most 25 referrers plus a total, because a site logo can be
referenced by every document on the site and each one costs its own fetch.

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

### Security headers

Local-adapter responses carry two defense-in-depth headers, set by
`secure_upload_headers/2` in `KilnCMSWeb.Endpoint` on every `/uploads/*`
request. S3-served media bypasses Phoenix entirely, so it has to get them
elsewhere — and only one of the two can ride along on the object:

| Header | Local | S3 | Where it comes from |
|---|---|---|---|
| `Content-Disposition: attachment` | ✅ | ✅ | object metadata at `PUT` ([`Storage.S3`](../lib/kiln_cms/storage/s3.ex)) |
| `X-Content-Type-Options: nosniff` | ✅ | ⚠️ **you configure this** | CDN or bucket response headers |

Neither header affects rendering: disposition is ignored for `<img>` and other
subresource loads, and every media URL Kiln emits is a subresource. They matter
only when someone navigates directly at a media URL, where together they stop a
stored file from being interpreted as active content rather than served as a
download.

**`nosniff` is not settable as S3 object metadata.** S3 persists a fixed set of
system headers (`Content-Type`, `Content-Disposition`, `Cache-Control`,
`Content-Encoding`, `Content-Language`, `Expires`); anything else you attach is
returned prefixed as `x-amz-meta-*`, which no browser acts on. Add it at the
edge instead:

| CDN | Where |
|---|---|
| CloudFront | Response headers policy → *Security headers* → `X-Content-Type-Options` (the managed `SecurityHeadersPolicy` includes it) |
| Cloudflare / R2 | Rules → Transform Rules → *Modify Response Header* → set `X-Content-Type-Options: nosniff` |
| Bunny | Edge rules → *Set Response Header* |
| nginx in front of MinIO | `add_header X-Content-Type-Options nosniff always;` |

Two S3-specific caveats on the disposition header, both absent on the Local
adapter, where it is a per-request plug:

* It is written **once, at upload time**. Changing it later does not follow
  from a deploy — you have to rewrite the existing objects
  (`aws s3 cp s3://bucket s3://bucket --recursive --metadata-directive REPLACE`).
* `url/1` emits a plain public URL, not a presigned one, so there is no
  per-request `response-content-disposition` override to reach for.

The practical consequence: pasting a media URL straight into the address bar
downloads the file instead of displaying it — on both adapters. That is the
intended behavior, not a misconfiguration. To eyeball a stored image, view it
in the media library at `/media`, which renders it as an `<img>`.
