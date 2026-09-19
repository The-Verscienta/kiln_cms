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

<a id="version-history-over-the-api"></a>

- **Version history over the API.** `GET /api/content/:type/:id/revisions`
  lists a document's revisions newest first (version id, action, timestamp,
  the acting user's id, and the *names* of the editorial fields each write
  changed), keyset-paginated with `?limit=` and an opaque `?cursor=`.
  `GET …/revisions/:version_id` adds that version's raw `changes` and the full
  `snapshot` of the document at it — folded by `KilnCMS.CMS.VersionSnapshot`,
  the same fold restore and the compare view use. `POST
  …/revisions/:version_id/restore` runs the type's `:restore_version` as the
  caller. An authenticated, editor-tier surface: authorized by the version
  resources' own policies with the real actor and the host's org — no
  credential is a `401`; a viewer, an out-of-scope restricted editor, another
  org's document or version, or another dynamic type's document is a `404`; a
  read-only API key's restore is refused `403` by the content policies. Every
  response is `Cache-Control: private, no-store`. The JS and Elixir clients
  gain `listRevisions`/`list_revisions`, `revision` and
  `restoreRevision`/`restore_revision`. See docs/api.md → "Version history
  (revisions)".

<a id="content-releases-are-readable-over-jsonapi"></a>

- **Content releases are readable over JSON:API.** `GET /api/json/releases`
  (`?include=items`, `filter[state]=`) and `GET /api/json/release-items`
  (`filter[release_id]=`) expose releases (#500) read-only to an editor-tier
  credential of the request's org — the console's own `:read` and policy, so a
  viewer or anonymous caller gets an empty list. There are no write routes:
  shipping a release publishes as its triggering admin, and that stays in the
  console. Creator/trigger user ids are not exposed. The JS and Elixir clients
  gain `releases`/`list_releases`, `release` and
  `releaseItems`/`list_release_items`. See docs/json-api.md → "Content
  releases (read-only)".

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

