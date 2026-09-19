# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Breaking

<a id="headless-slug-lookups-now-answer-a-missing-translation-from-the-sites-fallback"></a>

**Headless slug lookups now answer a missing translation from the site's
fallback chain, and an unsupported locale is a `400`.** `GET /api/content/:type/:slug?locale=es`,
`GET /api/resolve` and GraphQL `*BySlug` used to answer a slug with no `es`
variant with a 404 / `null`; they now serve the first published variant along
the site's chain — by default the default locale, exactly as the built-in site
always did — and say which locale they served (`x-kiln-locale`,
`Content-Language`, the record's `locale`). A front end that relied on the 404
to detect a missing translation passes `?fallback=false` (GraphQL
`fallback: false`) to keep it, or configures `[]` for that locale at
`/editor/locales`. A locale the deployment does not run (`?locale=de`, a typo
like `fr_CA`) is now `400 unsupported_locale` on the artifact API,
`/api/resolve` and `/api/menus` — the menus endpoint used to answer it with the
default-locale menu — and an error on GraphQL `*BySlug` and `menu`.

## Added

<a id="locale-fallback-chains-fr-ca-fr-en-per-site-on-every-delivery-surface"></a>

- **Locale fallback chains (`fr-CA → fr → en`), per site, on every delivery
  surface.** A site sets, per locale, what a missing translation serves at
  `/editor/locales`: the default locale (unchanged behaviour), an explicit
  ordered chain taken as written, or nothing — over an operator default in
  `config :kiln_cms, :i18n, fallbacks:`. The chain is walked in one query by
  `:public_by_slug` itself, so the artifact API, `/api/resolve`, the new
  JSON:API `GET /api/json/<type>/by-slug/:slug` routes, GraphQL `*BySlug` and
  the built-in site all answer alike; navigation menus follow a configured
  chain but never the implicit hop to the default locale. Requests narrow it
  with `?fallback=false` or `?fallback_locale=`, every response names the
  locale served (`x-kiln-locale`, `Content-Language`, ETags), and
  `GET /api/locales` publishes each locale's chain. A variant the reader may
  not open is skipped like a missing one. Resolution is per locale, not per
  document, so field-level localization (#1327) can reuse the same chains.
  ([#1579](https://github.com/The-Verscienta/kiln_cms/pull/1579))

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

