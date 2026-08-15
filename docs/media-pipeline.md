# Media pipeline

Uploads are validated from their **bytes** (allowed raster formats only, a
decompression-bomb pixel budget), re-encoded with **all metadata stripped**
(EXIF/GPS/device — privacy #215), and stored in object storage (local dev or
S3/MinIO). A background worker (`Media.VariantWorker`) then derives the
processing outputs; originals of non-raster uploads are simply served as-is.

The library also holds **documents** (PDF, #481) — see below; everything
through "Alt text and usage tracking" describes the image side, which is
unchanged.

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

## Modern formats (#473)

Every variant is written **once per output format**: the source's own format,
plus each configured alternate. WebP is on by default; AVIF is opt-in because
encoding it costs roughly an order of magnitude more CPU per image, which is a
real bill on a bulk regeneration.

```elixir
config :kiln_cms, :image_variants,
  formats: [:webp],     # add :avif to opt in
  webp_quality: 82,
  avif_quality: 50,     # AVIF's scale isn't JPEG's — 50 ≈ WebP 80
  jpg_quality: 82
```

Quality applies to the **lossy** formats only. There is no `png_quality`:
libvips has no quality knob for PNG (it has `compression`) and `Image.write`
discards `:quality` for it outright, so offering the setting would mean a
config value that silently does nothing. A quality outside `1..100`, or a
non-integer (`System.get_env/1` returns strings), falls back to the default
rather than being passed through — a rejected write produces *no* variant, so
the alternative to clamping is a config typo emptying the library.

Keys in the `variants` map name exactly one file. The **bare label** is the
source format — that is the `<img src>` fallback, and it is how every map
written before #473 is keyed — and alternates take a `<label>.<format>` suffix:

```
thumb        image/jpeg   /uploads/…-thumb.jpg
thumb.webp   image/webp   /uploads/…-thumb.webp
card         image/jpeg   /uploads/…-card.jpg
card.webp    image/webp   /uploads/…-card.webp
full.webp    image/webp   /uploads/…-full.webp
```

`full` is a full-size re-encode written in the **alternate formats only** — the
source-format equivalent is the original itself. It exists because a matching
`<source>` *replaces* the `<img>`'s srcset rather than adding to it: without a
candidate at the original's width, a WebP-capable browser could never reach
anything wider than the largest downscale, and every content image would
quietly render smaller than it did before.

Each entry carries its own `content_type`, which is what a `<picture>`
`<source type=…>` needs. A source format that is *also* a configured alternate
(a WebP upload with WebP variants) is written **once**, under the bare label —
two identical files under two keys would double storage and put the same bytes
in a `<picture>` twice. Animated sources (GIF) get no alternates: variants are
already flattened stills, so transcoding would spend encoder time producing a
second still of an image whose animation is the point.

An unknown format name in config is dropped rather than raising — a typo should
cost the site its WebP variants, not its uploads. A format whose encoder is
missing from the libvips build fails that one write and leaves the rest,
including the source-format fallback.

A failed **full-size** write is additionally *recorded*, on the item's
`variant_failures` map (#1000) — full-size only, for now: a failed
`thumb.avif` is still logged and nothing more, so an item can still be
re-enqueued on every run when a responsive label's encoder is missing (#1036). Without that record, "no `full.webp`" is
ambiguous: it means either "the write has not happened yet" — which a
regeneration should repair — or "this source can never be encoded to WebP",
which it should leave alone. A 17000px panorama is past libvips' 16383px WebP
ceiling and will never gain one, and re-decoding it on every run is the standing
tax `Regeneration` exists to avoid. The map is rewritten on every run rather
than merged, so a libvips upgrade that gains an encoder, or a re-crop that
brings the source under the ceiling, clears it. It is not part of the headless
surface.

### Delivery renders `<picture>`

`KilnCMS.Media.Presentation` exposes the two halves separately, and the split is
the point:

* `srcset/1` — the **source-format** downscales plus the original. A browser
  picks from a `srcset` on width alone, so mixing encodings there would hand a
  WebP-less client a WebP, and offer two entries at the same width to choose
  between arbitrarily.
* `sources/1` — one `srcset` per **alternate** encoding (a key with a format
  suffix), each tagged with its `type`, **most efficient first** (AVIF, then
  WebP). That ordering is the whole contract of `<picture>`: the browser takes
  the first `type` it supports and stops looking. A WebP *upload* therefore gets
  no `<source>` at all — its variants are already the `<img>` fallback, and
  offering them again would only drop the original from consideration.

A format is offered **only when its ladder reaches the item's own width**
(#919). The replacement semantics above cut both ways: a `<source>` whose
alternates stop short of the original does not merely miss the top rung, it
takes the original out of consideration for every browser supporting that
format. `full.<format>` normally carries that rung, and a write that fails is
dropped with only a log line — so a 17000×2000 panorama whose `full.webp`
exceeds libvips' WebP dimension limit would otherwise keep emitting
`<source type="image/webp" srcset="…thumb 400w, …medium 1024w">`, and every
WebP-capable browser would upscale a 1024px render of it.

Suppression is not free, and costs more than the codec: blocks render
`sizes="(max-width: 768px) 100vw, 768px"`, so a 2x display wants ~1536px and
picks the **original** off the `<img>` ladder — a full-resolution download where
the buggy `<source>` served a 1024px WebP. It is still the right trade (it is
what every WebP-less browser already gets, and the alternative is a visibly
upscaled image), but the real remedy is making sure `full.<format>` exists.
The check is per format, so losing WebP's top rung does not cost AVIF its
`<source>`.

Image and gallery blocks render a `<picture>` wrapping the existing `<img>`. An
item with no alternates produces no `<source>` elements, so the markup degrades
to exactly the `<img>` that was there before.

### Bulk regeneration

A configuration change only ever reaches images uploaded after it. To roll it
out over the existing library:

```bash
mix kiln.media.regenerate_variants          # only what's missing (a format rollout)
mix kiln.media.regenerate_variants --all    # everything (a quality/width change)
```

Admins can do the same from **`/media` → Regenerate variants**.

Both enqueue `KilnCMS.Media.VariantWorker` on the throttled `:media` Oban queue
rather than processing inline, and at the **lowest Oban priority** — `:media`
is a concurrency-3 queue shared with upload processing and video probes, and
jobs are otherwise fetched in id order, so an un-deprioritised bulk run would
sit ahead of every subsequent upload for hours. The admin button runs the scan
itself in a supervised task, because Oban's unique inserts are one transaction
per row and a large library would otherwise block the LiveView past its
heartbeat.

Jobs are unique per item for an hour, keyed with a `"source" => "regenerate"`
marker so they dedupe against *other regeneration runs* only: Oban's default
unique states include `:completed`, so without it every image uploaded in the
previous hour would collide with its own upload job and be silently skipped.

Each run replaces the variant map wholesale and then **deletes the blobs the old
map named** — every other deletion path in Kiln reads the *current* map, so
without that a single run over a large library would orphan tens of thousands
of files nothing could ever find again. **Originals are never rewritten** —
published snapshots and fired artifacts point at them by key.

"Missing only" means *nothing a run would add*, not *has every format*: an
animated GIF (which gets no alternates by design) and an image narrower than
every responsive target (which produces no variants at all) both count as
current, or the rollout mode would re-decode them on every run for ever.

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

## Documents (#481, #808)

The media library also accepts **documents** — PDF in v1, joined by office
formats and zip archives in #808 — uploaded through the same `/media` picker
(`.pdf`/`.docx`/`.xlsx`/`.pptx`/`.doc`/`.xls`/`.ppt`/`.zip` alongside the
image extensions), byte-validated by `KilnCMS.DocumentProcessor` the same way
images are by `ImageProcessor` (a magic-byte check, never the client's
claimed filename/MIME — deny-by-default). A document has no `width`/`height`
(that's the library's own image/document discriminator: `content_type
LIKE 'image/%'`, with a `NULL` content_type defaulting to "image" for
backward compatibility with rows written before #481) and no responsive
variants.

### Office documents and zip archives (#808)

`.docx`/`.xlsx`/`.pptx` are recognized as OOXML: a zip signature (`PK\x03\x04`)
plus an internal `[Content_Types].xml` entry and a format-specific main part
(`word/document.xml`, `xl/workbook.xml`, `ppt/presentation.xml`) — that
combination is what distinguishes an Office document from an arbitrary zip,
which is accepted too (as plain `.zip`) when the zip signature matches but
`[Content_Types].xml` doesn't. Legacy `.doc`/`.xls`/`.ppt` are recognized by
the OLE2 compound-file signature plus the application's own root stream name
(`WordDocument`, `Workbook`, `PowerPoint Document`).

Because a zip's own central directory can *declare* whatever
compressed/uncompressed sizes it likes, `DocumentProcessor` reads that
declared metadata via `:zip.list_dir/1` — which touches only the central
directory, never any entry's compressed data — and refuses the upload as a
decompression bomb before anything is stored: over 500 MB of declared
uncompressed content, a declared compression ratio past 100:1, or more than
10,000 entries. Nothing in the validation path ever inflates archive
content.

**Office/zip uploads are not metadata-stripped.** #807's qpdf-based strip
only understands PDF; it cannot open a zip or an OLE2 file at all, so
`KilnCMS.Media.Ingest` stores these formats as uploaded, the same posture A/V
had before #820. A `.docx` still carries its author/revision history and a
legacy `.doc`/`.xls`/`.ppt` still carries the authoring machine's path — a
real gap, tracked separately rather than assumed away.

### PDF metadata stripping (#807)

An uploaded PDF is rewritten without its **`/Info` dictionary** (title, author,
creator, producer), its **XMP metadata stream**, and every **per-object
`/Metadata` packet and `/PieceInfo` dictionary** before the blob is stored —
the document-library counterpart to the EXIF stripping images get. Outlines,
form fields, attachments and page content are untouched.

The per-object half needs saying, because it is the half that is easy to miss
(#918). `--remove-info --remove-metadata` clears the two *document-level*
fields and nothing else — a page-level XMP packet and a `/PieceInfo` private
blob both survive them, and `/PieceInfo` is where Illustrator, InDesign and
Acrobat park the author name and the authoring machine's filesystem path
(`C:\Users\jane\...`). qpdf has no flag for it, so the strip runs in two
passes: dump the object dictionaries with `--json-output`, prune those keys,
and apply the result with `--update-from-json`.

**qpdf is required, and a PDF that cannot be stripped is refused.** This is a
deliberate departure from how ffmpeg is treated (see below): a missing ffmpeg
costs you *enrichment* — no duration, no poster — while a missing stripper
costs you a *privacy guarantee*, and a control that silently does not apply is
worse than no control, because the operator believes it did. The editor sees
"PDF metadata stripping isn't available on this server" rather than a
misleading "unsupported format".

### A/V metadata stripping (#820)

An MP4 or M4A is remuxed through `ffmpeg -map_metadata -1 -map_chapters -1 -c
copy` before it is stored: a **stream copy**, so the bitstreams pass through
untouched and only the container's metadata atoms are dropped. Cheap enough to
run on every upload.

What that removes, on the file type where the recording is most likely to be
personal:

- `©xyz` GPS coordinates, which iOS writes on every phone recording
- `com.apple.quicktime.model` / `.software` — device and OS version
- creation-date atoms, often in local wall-clock
- the original filename, in some encoders' `©nam`
- editing-application metadata from the export

**Unlike the PDF strip above, this is best-effort by default, and that is a
weaker guarantee.** The argument in the previous section — that a control which
silently does not apply is worse than no control — applies here too, and the
only reason the default differs is that ffmpeg is optional today: requiring it
would stop A/V upload working on every deployment that does not have it, on
upgrade, with no warning. That is a migration, not a default.

So the behaviour is stated exactly rather than implied:

| ffmpeg | `REQUIRE_AV_METADATA_STRIP` | Result |
|---|---|---|
| present, remux succeeds | either | stripped |
| present, remux fails | `false` (default) | stored as it arrived, logged at `:warning` |
| present, remux fails | `true` | upload refused |
| present, **no temp space** | either | **upload refused** |
| absent | `false` (default) | stored as it arrived, logged at `:warning` |
| absent | `true` | upload refused |

Note the middle rows: having ffmpeg is not the same as the strip succeeding.
A container ffmpeg cannot remux under `-c copy` (pcm_s16le audio in MP4, from
some screen recorders) fails the same way a missing binary does, and the
default stores it. The log line names which of the two happened, because
telling an operator to install ffmpeg on a host that already has it sends
them after the one thing that is not broken.

And note the row that ignores the setting entirely (#1100). The strip writes a
second full copy of the upload to the temp filesystem while the original is
still there, so peak usage is roughly **twice the file** — a gigabyte for one
500 MB video, three gigabytes for three of them at once. When that runs out,
ffmpeg fails with `No space left on device`, and under the default every row
above would have stored the file **unstripped**: the privacy guarantee lapsing
precisely under disk pressure, which is when nobody is looking at it.

So a full temp disk is refused whatever the setting says. Every other failure
in the table is a standing property of the host or the file — ffmpeg is absent,
or this container will never remux — where storing the upload is the better of
two bad answers, because the alternative is that it can never be uploaded at
all. A full disk is neither: it is transient, retrying works, and the editor is
told exactly that. Free space up, or point `TMPDIR` at a larger filesystem.

The check runs *before* ffmpeg starts, but it cannot be the whole answer —
concurrent uploads can each see enough room and then exhaust the disk together
— so an ENOSPC that happens anyway is recognised in ffmpeg's output and
refused identically. If free space cannot be measured at all (no `df`, or
output we cannot parse), the strip proceeds rather than refusing: refusing on
an unknown would be an outage in exchange for a guess, and the ENOSPC path
still catches the real thing one step later.

**If you rely on the privacy guarantee, set `REQUIRE_AV_METADATA_STRIP=true`
and install ffmpeg.** That gets you the same contract PDFs already have. The
`:warning` exists so the gap is visible in logs rather than assumed away — but a
log line is not a control, and nobody should treat the default as one.

**A password-protected PDF is refused**, with `is password-protected, so its
metadata can't be removed — upload an unlocked copy`. qpdf cannot open a
user-password-encrypted file, so it cannot strip one, and storing it unstripped
would defeat the guarantee above. This is a real narrowing: such a file was
storable before #807 and opens fine in every reader, so a signed contract or a
bank statement has to be unlocked before it can be added to the library. It is
the one refusal here the uploader can act on, which is why it gets its own
message rather than the generic "couldn't have its metadata removed".

**Owner-password-only PDFs are not affected** — the "restrict printing/editing"
export that opens with no password anywhere. Encryption is classified from the
strip *failure*, not probed up front, because `qpdf --is-encrypted` exits 0 for
those too: probing would have refused a large class of ordinary documents and
told the uploader to remove a password that does not exist.

Three operational notes:

- **qpdf ≥ 11.10** is required — `--remove-info`/`--remove-metadata` arrived in
  that release. `KilnCMS.DocumentProcessor.available?/0` checks the
  *capability*, not just that a `qpdf` binary exists, because Debian bookworm's
  11.3.0 would pass the latter and fail every strip. The release image runs
  **Debian trixie** (qpdf 12.2.0) for exactly this reason.
- **The prune covers stream objects and nested dictionaries**, not just page
  dictionaries. qpdf's JSON gives a stream object a different shape from a
  plain one, and image and Form XObjects *are* streams — which is where a
  placed asset's original XMP (photographer, GPS) and Photoshop's `/PieceInfo`
  live. `/Metadata` and `/PieceInfo` are also legal at any depth, so the prune
  recurses. The object dump is written to a file rather than read from stdout:
  qpdf merges stderr into stdout, and any file whose xref it reconstructs
  prints `WARNING:` lines first, which would otherwise break the JSON parse on
  exactly the files most likely to need the prune.
- **Streams are copied, not decoded** (`--decode-level=none`). A ≤25 MB PDF can
  hold a FlateDecode stream that inflates to tens of gigabytes, and qpdf's
  default `generalized` decode level would expand it — a decompression bomb by
  another name, and the reason the 30-second cap used to be reachable at all.
  Nothing in the strip inspects stream contents, so decoding them was only ever
  cost. If the cap *is* hit, the qpdf process is killed by pid: closing an
  Erlang port shuts the pipes without signalling the child, which used to leave
  an orphan burning CPU and then writing an unreferenced file into the temp dir
  minutes after the upload had already been refused.
- **Not exiftool.** `exiftool -all=` on a PDF writes an incremental update that
  marks the metadata deleted while leaving the original bytes in the file,
  recoverable by anything that reads it with a parser rather than a viewer. It
  looks like it worked. qpdf rewrites the document.

Existing PDFs uploaded before this are **not** retroactively stripped; re-upload
one to strip it.

A document is placed on content with the **`file` block** (title,
description, and a download link) — separate from the `image` block, which
never renders a document.

### Bounding ffmpeg

Four limits, covering different failure modes:

| Limit | Bounds |
|---|---|
| `-probesize` / `-analyzeduration` | how far ffmpeg may scan before deciding what a file is |
| `-nostdin` | blocking forever on input that will never arrive |
| `-timelimit` | **CPU** seconds, via `setrlimit` |
| wall-clock deadline | elapsed time, by killing the OS process |

The last one is not redundant with `-timelimit` (#1100). A `-c copy` remux is
I/O-bound: it burns almost no CPU, so the rlimit essentially never fires while
a stalled disk can hold the process for hours. And nothing outside ffmpeg could
stop it either — neither `System.cmd/3` nor the enclosing Oban job timeout,
because closing an Erlang port shuts the pipes but sends the child no signal.
Only the OS pid a port hands back can be signalled, which is what
`KilnCMS.ExternalCommand` exists to do. It is shared with the qpdf path, which
needed the same thing first (#918).

Two minutes, and that number is doing two jobs: a 500 MB stream copy finishes
inside 100 seconds even at 10 MB/s, so anything past it is stuck rather than
slow — and because the strip runs inline on the LiveView handling the upload,
it is also the longest an editor's media page can be blocked.

### Gated documents

A document (not an image — v1 scopes the gate to the document library the
issue asked for) can be restricted to a consumer-facing `audience`, the same
tier published content already uses (`KilnCMS.CMS.Audiences`). Setting a
non-`:public` audience — from the media library's item detail panel —
**relocates the underlying blob to private storage**:

* **Local adapter**: a second directory (`priv/private_uploads` by default)
  that `KilnCMSWeb.Endpoint` has no `Plug.Static` mount for — nothing serves
  it over HTTP at all. Always available, no configuration needed.
* **S3 adapter**: a **separate bucket** (`S3_PRIVATE_BUCKET`) this app's own
  AWS credentials read directly — it needs no public-read config, no CDN, and
  no `S3_PUBLIC_BASE_URL` equivalent. **Not configuring it refuses gating
  outright** rather than silently leaving the blob in the public bucket: the
  public bucket is public at the *bucket* level (see "Production storage &
  CDN" below), so an object sitting there is reachable at its plain URL
  regardless of what the app ever links to — gating can't be faked on top of
  that.

Every download — gated or not — goes through
[`KilnCMSWeb.MediaDownloadController`](../lib/kiln_cms_web/controllers/media_download_controller.ex)
(`GET /media/:id/download`), never a direct storage URL: it's the one place
that checks the reader's audience (`CMS.get_media_item/2`'s ordinary
policy-checked read — a gated document simply isn't in an unauthorized
reader's result set, so a denied/missing item both 404, never 403, and a
gated document's existence isn't confirmed to a reader without its
audience), serves the **original filename** rather than the UUID storage
key, and bumps the aggregate, privacy-first `download_count` (no per-viewer
identity — consistent with every other counter in this codebase).

An **image** can never be gated (its responsive-variant pipeline —
`Media.VariantWorker` — assumes public storage throughout). Documents and
A/V both can; gating an existing item requires private storage to be
configured first, same as a fresh upload.

## Video and audio (#494)

The library accepts self-hosted **video, audio and WebVTT caption tracks**,
uploaded through the same `/media` picker and byte-validated by
[`KilnCMS.AVProcessor`](../lib/kiln_cms/av_processor.ex) on the same
deny-by-default, magic-bytes-only terms as images and PDFs.

| Kind | Accepted | Stored `content_type` | Size cap |
|------|----------|----------------------|----------|
| Video | MP4 (ISO-BMFF, web brands only), WebM | `video/mp4`, `video/webm` | 500 MB |
| Audio | MP3, M4A/M4B | `audio/mpeg`, `audio/mp4` | 100 MB |
| Captions | WebVTT | `text/vtt` | 2 MB |

### Upload web-ready files — there is no transcoding

Kiln stores exactly what you give it. A QuickTime `.mov`, a Matroska `.mkv`
and an HEIF-branded MP4 are all **rejected at upload**, even renamed to
`.mp4`, because the browser could not play them and nothing here will convert
them. Export H.264/AAC in an MP4 (or VP9/Opus in a WebM) first. Adaptive
streaming (HLS/DASH), in-app transcoding and DRM are deliberately out of
scope — that is a video platform, not a CMS; the `Kiln.Plugin` seam is where
an external transcoder (Mux-style) would attach.

### Duration and poster frames need ffmpeg — and work without it

[`KilnCMS.Media.AVWorker`](../lib/kiln_cms/media/av_worker.ex) runs after
upload (off the request, like `VariantWorker`), re-fetches the original from
storage, and shells out to `ffprobe`/`ffmpeg` for the playback duration, the
video's intrinsic dimensions, and a poster frame taken one second in.

**ffmpeg is an optional system dependency, not a Mix dep.** Install it in
your image (`apk add ffmpeg` / `apt-get install -y ffmpeg`) to get those
three things. Without it every step no-ops: the upload still stores and still
plays, it simply has no duration and no generated poster, and an editor picks
a poster image by hand — which the `video` block supports either way.

Note that ffprobe writes `width`/`height` for a video exactly as libvips does
for an image, so **`width` alone does not mean "this is an image"** anywhere
in this codebase. `KilnCMS.MediaKind.of/1` is the one place that decides an
item's kind, from its `content_type`.

### Blocks

A/V is placed on content with the **`video`** and **`audio`** blocks —
distinct from `embed`, which points at YouTube/Vimeo. The video block carries
a poster image reference, a WebVTT caption track reference, and `autoplay` /
`loop` flags (autoplay always renders muted, since no browser will autoplay
sound).

Neither block ever stores a storage URL. Their `src` is always
`/media/<media_id>/stream`, for the same reason the `file` block's href is
always `/media/<id>/download`: a gated item has no public URL to store, and a
public one can be gated later, which would leave a baked URL pointing at a
blob that has since moved. A pasted `url` field remains for media hosted
somewhere else entirely, and is used only when no library item is set.

### Streaming and `Range`

`GET /media/:id/stream`
([`MediaDownloadController.stream/2`](../lib/kiln_cms_web/controllers/media_download_controller.ex))
serves playback bytes under the same authorization as the download route, and
differs from it on three points:

* **Inline, not `attachment`** — a `<video>` cannot play a response the
  browser is told to save. Only content types on
  `KilnCMS.MediaKind.inline_streamable?/1`'s exact allowlist are served that
  way; anything else falls back to the attachment path, so an
  editor-supplied `content_type` (it *is* writable through the API) can never
  make this route an inline host for arbitrary content on the app's origin.
* **`Range` requests** — seeking is a `Range:` request, and a player shows no
  scrub bar without `Accept-Ranges`. Answered by `Storage.fetch_range/3`,
  which reads only the requested slice (`:file.pread` locally, a ranged
  `GET` on S3). Every response is capped at 8 MB, so a seek never pulls a
  whole film into memory — and the cap holds on the *un-ranged* path too,
  which streams the body in 8 MB chunks rather than buffering it. That
  matters because omitting `Range` (or sending an unparseable one) would
  otherwise be a one-header way to ask for a 500 MB allocation.
* **No download counter** — one scrub is dozens of ranged requests;
  `download_count` stays a download-only measure.

### Gating A/V

A video or audio item gates exactly like a document. One extra step applies:
**gating discards the generated poster frame**, row and blob. A poster is
written to *public* storage (it renders as a plain `<img>`), and a still from
a members-only video should not stay world-readable once the video isn't.
Un-gating re-derives it (#821), so a re-published video does not open on a
black frame. A poster picked by hand on the block still wins — it is a
different field, and `Blocks.Video.poster_src/1` prefers it.

If you serve media from a CDN on another hostname, note that `CSP_IMG_SRC`
widens the browser CSP's `media-src` as well as its `img-src`; without it,
`default-src 'self'` blocks a cross-host `<video>`.

### Large objects

Nothing in the pipeline holds a whole video in memory. Uploads above 16 MB go
to S3 as a streamed multipart upload (smaller ones keep the single `PUT`, so a
4 KB thumbnail doesn't pay for three round trips); `Storage.copy_to_file/3`
streams a blob to a temp file for `Media.AVWorker` and for the gating
relocation; and the stream route chunks its responses as described above. The
one deliberate exception is `GET /media/:id/download`, which is a whole-file
response by definition — keep the document caps in mind if you raise them.

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
