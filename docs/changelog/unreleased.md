# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="a-cdn-in-front-of-the-headless-api-now-caches-anonymous-jsonapi-graphql-get-and"></a>

- **A CDN in front of the headless API now caches anonymous JSON:API, GraphQL
  `GET` and `/api/search` responses for up to 60 seconds.** They used to go out
  as Plug's `private, max-age=0`; they are now `public, max-age=60,
  stale-while-revalidate=60` with an `ETag`. A credentialed request is
  `private, no-store` and every response says `Vary: Accept, Authorization,
  Origin`, so
  a cache that honours `Vary` needs nothing. One that ignores it must be told to
  bypass the cache on an `Authorization` header, or an editor's token is handed
  the published answer instead of its drafts. `KILN_API_CACHE=false` restores
  the old headers; `KILN_CDN_PURGE_URL` makes a publish visible at once.

## Added

<a id="anonymous-jsonapi-graphql-and-search-reads-are-cdn-cacheable-with-a-body-etag"></a>

- **Anonymous JSON:API, GraphQL and search reads are CDN-cacheable, with a body
  ETag and 304s.** Only the fired-artifact API sent cache headers before, so
  every other delivery read reached the app — where Contentful, Sanity and
  Storyblok serve those from a CDN. `KilnCMSWeb.Plugs.PublicCache` runs on
  `/api/json`, `/gql` and `/api/search`: a `GET` with no `Authorization`,
  `x-api-key`, unlock grant or cookie that answers `200` gets `public,
  max-age=60, stale-while-revalidate=60` (`KILN_API_CACHE_MAX_AGE`,
  `KILN_API_CACHE_SWR`), an `ETag` and a `304` for a matching
  `If-None-Match`. The ETag is a digest of the body and its content type
  rather than of chosen fields, so it cannot miss an input the way #1079's
  did; it is weak (`W/"…"`) because Bandit will not gzip a response with a
  strong one. Anything carrying a credential is `private, no-store`, since an
  editor's token sees drafts on the same URLs. GraphQL is cached only for a
  `GET` whose document is in the URL and that completed without `errors`;
  Absinthe refuses mutations over `GET`, and a `POST` is never public. A
  handler that sets its own `cache-control` is never overridden. `Vary:
  Accept, Authorization, Origin` is merged into any existing `Vary` rather than
  replacing it — `Origin` always, since a copy cached without one lacks the
  CORS header a browser needs; the locale is always a URL input, so there is
  no `Accept-Language` to vary on. See `docs/api.md` → "Caching and
  CDNs".

<a id="optional-cdn-purge-on-publish-kilncdnpurgeurl"></a>

- **Optional CDN purge on publish (`KILN_CDN_PURGE_URL`).** Cacheable API
  responses, and public fired-artifact ones, carry the site's surrogate key as
  `Surrogate-Key` and `Cache-Tag`. With a purge URL set, every
  `<type>.published`, `.unpublished`, `.updated` and `release.published`
  enqueues one purge of that key — `{"tags": [...]}` plus a `Surrogate-Key`
  header, so the Cloudflare and Fastly purge APIs work directly
  (`KILN_CDN_PURGE_TOKEN`, `KILN_CDN_PURGE_TOKEN_HEADER`). It hangs off the
  webhook funnel beside automation and federation, is coalesced per site among
  *scheduled* jobs only (a running purge may predate the publish) and per
  transaction (so a release's purge runs after it commits), retried with
  backoff, and sent through `KilnCMS.SafeFetch`. The whole site is purged
  because a list or query response records no document ids.

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

