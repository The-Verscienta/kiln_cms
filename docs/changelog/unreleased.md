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

<a id="share-a-draft-copy-preview-link-in-the-editor-and-a-preview-token-api"></a>

- **Share a draft: *Copy preview link* in the editor, and a preview-token API.**
  `GET /preview/:token` and its shared view `/preview/:token/live` have existed
  since #379, but nothing outside the tests ever minted a token, so neither
  could be used. The content editor now has a **Copy preview link** button: it
  mints a read-only link to that one document, valid for 15 minutes, copies it
  and shows it with what it grants. A headless front end's draft mode mints
  server-side with `POST /api/content/:type/:id/preview-token` (an editor's
  `:read` key is enough) and hands the browser the token instead of its key.
  The response is `{token, url, type, id, expires_at, expires_in}`, where `url` is on
  the owning site's host, the only one that honours it. The JS client gains
  `mintPreview(type, id)`. Minting is gated on **editorial read visibility**
  (`Checks.ReadableContentType`, the grant that shows an editor drafts), not on
  reading the row. Otherwise a viewer or a type-scoped editor could mint a link
  to a published page and read its pending working copy. `docs/api.md` →
  Preview tokens has the refusals (401/403/404). `docs/visual-editing-bridge.md`
  now asks for a `:read` key rather than `:read_write`, since the bridge only
  reads. The bridge itself still takes a key, not a preview token.

## Fixed

<a id="a-preview-link-shows-the-working-copy-and-works-for-admin-defined-types"></a>

- **A preview link shows a live document's unpublished edits, and works for
  admin-defined types.** Both preview surfaces rendered the record's row. For a
  published document with pending edits, that is the text readers already
  have, not the working copy being reviewed; both now render
  `WorkingCopy.view/1`, as the editor and a release preview do. A token also
  named its type by resource module, so every admin-defined type signed itself
  as `entry` and could not be resolved. Tokens now carry the public type name
  and are resolved under the token's org. A token in the old shape is refused
  as invalid. None were ever minted outside tests.

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

