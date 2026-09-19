# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="one-click-deploy-templates-for-render-railway-flyio-and-digitalocean"></a>

- **One-click deploy templates for Render, Railway, Fly.io and DigitalOcean.**
  `render.yaml` (with a Deploy to Render button), `fly.toml`, `.do/app.yaml`
  and a Railway recipe each run the published image at a pinned tag, with
  Postgres 17 and pgvector and with media kept across restarts. The steps,
  costs and caveats for each are in `docs/deploy-platforms.md`, including
  what none of them solves yet: no platform documents its proxy's address
  range, so per-IP rate limiting behind one is per-deployment until a
  follow-up reads the platform's client-IP header. None has yet been deployed
  end to end; the page says so.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

<a id="kilnmediaroot-a-stable-directory-for-local-media"></a>

- **`KILN_MEDIA_ROOT`: a stable directory for local media.** Unset, the Local
  storage adapter writes under the release's own `priv/uploads` — in the image
  `/app/lib/kiln_cms-<version>/priv/uploads`, a path that moves with every
  version, so no volume could be mounted to keep uploads across an upgrade or
  a PaaS restart. Set, public files go to `<dir>/public` (served at
  `/uploads`, which now reads the adapter's root per request instead of a
  compiled-in path) and private ones to `<dir>/private`. The in-app backup and
  `scripts/backup.sh` default `MEDIA_DIR` to it, the image creates
  `/app/media` owned by `nobody`, and boot reports a directory the app cannot
  write to. Ignored under S3.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

<a id="upload-media-over-the-api"></a>

- **Upload media over the API.** Until now no headless surface could create a
  media item — the write API (#330) covered content but not the library, so an
  integration had to hand files to a human. `POST /api/media` takes a
  multipart `file`, `POST /api/media/import-url` fetches a public URL through
  `SafeFetch`, and `POST /api/media/uploads` + `/uploads/complete` presign a
  `PUT` into the private bucket for files too large to send through the app.
  All three run the library's own pipeline (`Media.Ingest`): byte-sniffing,
  per-kind caps, the EXIF/PDF/A-V strips and the #1122 quarantine, variants,
  and the `MediaItem` create under the caller's actor, which stamps the
  uploader. Alt text, caption, decorative flag, focal point and tags can be set
  on upload, and afterwards through `PATCH /api/json/media-items/:id` or
  GraphQL `updateMediaItem` — a new `:update_metadata` action, since `:update`
  also accepts `storage_key`/`url`. Moving the focal point re-derives the
  crops. A `:read_write` key (or JWT) on an editor account is required; a
  read-only key or a viewer is refused **before** `POST /api/media`'s body is
  read — the endpoint's multipart parser now leaves that one route's body for
  its controller to parse after authorizing, under a limit the size of the
  largest upload cap rather than the endpoint-wide 8 MB. The routes charge a
  new `media_upload` rate-limit bucket (60/min per address) on top of `:api`.
  `focal_x`/`focal_y` are now constrained to 0.0–1.0. No MCP upload tool:
  media has no draft state, so it would be the one tool whose output an LLM
  could publish unreviewed (docs/mcp.md). The JS client (0.2.0) and Elixir
  client (0.3.0) gain `uploadMedia`/`upload_media`, URL import, metadata
  updates and the direct-upload flow. Docs: `docs/api.md` → "Uploading media".

## Fixed

<a id="buttons-links-badges-and-fields-that-rendered-unstyled-now-look-like-what-they"></a>

- **Buttons, links, badges and fields that rendered unstyled now look like what
  they are.** The console's component kit borrows DaisyUI's class names without
  the dependency, and a dozen templates still used DaisyUI classes the kit never
  defined — so they compiled, rendered, and styled nothing. "Turn on outbound
  checking" on `/editor/links` read as plain text: `<.button class="…">`
  replaced the component's own `btn btn-primary` classes instead of adding to
  them, which also stripped mail settings' "Unsuppress". The same shape was
  behind the social accounts "Remove" button (`btn-error`), sixteen `class="link"`
  anchors that Tailwind's preflight had reduced to body text, borderless date and
  note fields in the editor's task form (`input`, `textarea`), status pills on
  experiments, federation and governance (`badge-*`, now `<.badge>`), the error
  on a passphrase-protected page (`alert`), and oversized `btn-xs` buttons. The
  kit gains `.link` and `.field-label` for the call sites that already used them,
  and a test now fails on any DaisyUI-named class in the web layer that
  `assets/css/app.css` does not define.

<a id="a-paas-health-check-no-longer-gets-a-redirect-and-phxhost-falls-back-to-the"></a>

- **A PaaS health check no longer gets a redirect, and `PHX_HOST` falls back
  to the platform's hostname.** `force_ssl` answered a platform's
  plain-HTTP probe of `/up` with a 301, which a platform that counts only 2xx
  reads as a failed deploy; `/live` and `/up` now answer over plain HTTP
  (`/ready`, which carries queue depths, still redirects). With `PHX_HOST`
  unset or blank the host is now `RENDER_EXTERNAL_HOSTNAME`,
  `RAILWAY_PUBLIC_DOMAIN` or `<FLY_APP_NAME>.fly.dev` before `example.com`, so
  a fresh deploy's editor connects; a blank `PHX_HOST` used to become an empty
  host.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

