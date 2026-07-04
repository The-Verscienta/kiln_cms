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
