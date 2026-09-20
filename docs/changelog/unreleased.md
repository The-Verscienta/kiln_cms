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

## Upgrade notes

<a id="webhook-signing-secrets-move-to-an-encrypted-column"></a>

- **Webhook signing secrets move to an encrypted column.** Three migrations
  add `webhook_endpoints.secret_encrypted`, encrypt every existing secret into
  it with `KilnCMS.Keys.Vault`, and drop the plaintext `secret` column. The
  secrets themselves do not change, so receivers need nothing. Rolling back
  decrypts them into the old column. Like every vault column, they are keyed
  off `SECRET_KEY_BASE`: rotate that and each endpoint's secret becomes
  unreadable, its deliveries are refused, and it has to be re-created
  (`docs/secrets-rotation.md`).

<a id="webhook-receivers-should-move-to-x-kilncms-webhook-signature"></a>

- **Webhook receivers should move to `x-kilncms-webhook-signature`.** The
  body-only `x-kilncms-signature` is still sent on every delivery, but it is
  deprecated and will be removed in a later release. The new header binds a
  timestamp into the HMAC; verify it with the recipe in `docs/webhooks.md` or
  the client helpers. The delivery body also gains a top-level `delivery_id`,
  which is additive. Existing endpoints keep the event list they were saved
  with, so to hear about deletions, tick the new `archived`, `deleted` and
  `restored` events on each one.

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

## Breaking

<a id="some-graphql-queries-that-ran-before-are-now-refused-as-too-costly-and-a"></a>

- **Some GraphQL queries that ran before are now refused as too costly, and a
  refused introspection query gets a GraphQL error instead of a 403.** A
  to-many relationship with no `limit` (`tags`, `relatedPosts`,
  `featuredPosts`) now costs five rows, not one, under the same cap of 200. A
  query that lists such relationships for each row of a 25-row page can go over
  it: `publishedPosts { results { title tags { name } relatedPosts { title } } }`
  costs 300. Ask for a smaller page or pass `limit` on the relationship.
  Documents nested more than 15 fields deep or longer than 2,000 tokens are
  refused, as is a batched `/gql` body of more than 10 operations. With
  introspection off (production), `__schema` and `__type` are refused with a
  `200` and `errors`, like any invalid document; the old plug answered `403`.
  `docs/headless-graphql-api.md` has a new section, "Query cost".

## Upgrade notes

<a id="rotating-secretkeybase-keeps-stored-keys-now-if-the-steps-run-in-order"></a>

**Rotating `SECRET_KEY_BASE` keeps stored keys now, if the steps run in
order.** Nothing needs doing on upgrade (#1487). The next time you rotate
`SECRET_KEY_BASE`:

1. Set `PREVIOUS_SECRET_KEY_BASE` to the old value next to the new
   `SECRET_KEY_BASE`, and restart.
2. Run `mix kiln.vault.reencrypt`. In a release, run
   `bin/kiln_cms eval 'KilnCMS.Release.reencrypt_vault()'`.
3. Once a `--dry-run` reports nothing left, unset `PREVIOUS_SECRET_KEY_BASE`.

If you retire the old value before step 2, the DKIM key, social credentials,
billing secrets and ActivityPub actor key are orphaned, exactly as before.
Sessions are still signed out either way. See `docs/secrets-rotation.md`.
## Added

<a id="get-apisync-a-delta-api-that-sees-deletions"></a>

- **`GET /api/sync`: a delta API that sees deletions.** A headless mirror —
  static build, search index, edge store — can now take the site's public
  content once (`?initial=true`) and then only what changed since a signed,
  opaque cursor: upserts carrying the fired artifact, and tombstones for any
  document that stopped being publicly readable (unpublished, archived,
  soft-deleted, purged, moved to a members audience, passphrase-locked).
  `filter[updated_at][gt]` could never see a document leave, so a mirror kept
  locked and paywalled documents indefinitely. Visibility is anonymous
  whoever calls — the resource policies with no actor plus the same rule as an
  explicit filter — and a tombstone is an id and a type only, never a body,
  slug or reason. Changes come from the PaperTrail version tables; a tombstone
  may only name a document the sync API has already served (a new
  `sync_exposures` table), so a draft, gated or locked document that was
  never public never appears in a delta, not even as an id. Windows trail the
  clock by a commit lag (`config :kiln_cms, KilnCMS.Firing.Sync,
  commit_lag_seconds:`, default 10) so an in-flight transaction is not
  skipped; delivery is at-least-once. The migration also adds an
  `(org_id, version_inserted_at)` index to each content version table, built
  in the migration's transaction. Both official clients wrap the loop
  (`kiln.sync()`, `KilnClient.sync/1`); see `docs/api.md` → "Sync".
  ([#1581](https://github.com/The-Verscienta/kiln_cms/pull/1581))

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

<a id="webhooks-announce-a-documents-whole-lifecycle-created-archived-deleted-and"></a>

- **Webhooks announce a document's whole lifecycle: `created`, `archived`,
  `deleted` and `restored`.** A mirror used to hear only about publishes, so a
  document moved to the trash stayed on the mirror forever. `archived` fires
  from every state (alongside the existing `unpublished` when the document was
  live), `deleted` fires on a move to the trash (`DELETE` over the API is one),
  and `restored` fires on the way back out of the trash or out of the archive.
  `archived` and `deleted` carry a tombstone, the document's `id`, `slug`,
  `locale`, `state` and `updated_at` and nothing else, because they fire for
  drafts too. `restored` carries the full body only when the document is
  published again, and the tombstone otherwise. All three are on by default for
  new endpoints. `created` carries a new draft's full body, so, like
  `in_review`, it is opt-in. Dynamic types get the same four events.

<a id="timestamped-webhook-signatures-and-a-stable-delivery-id"></a>

- **Timestamped webhook signatures and a stable delivery id.** Every delivery
  now carries `x-kilncms-webhook-signature: t=<unix>,v1=<hex>`, an
  HMAC-SHA256 of `"<t>.<raw body>"`, and `delivery_id` in the signed body
  (echoed in `x-kilncms-delivery-id`). The id is the ledger row's, so it is the
  same across a delivery's retries. A receiver that refuses a `t` more than
  five minutes from its clock can no longer be replayed to. That closes
  threat-model residual risk 14 for receivers that verify the new header.
  `KilnCMS.Webhooks.verify/4` is the reference implementation, and the JS client
  (`verifyWebhook`) and the Elixir client (`KilnClient.Webhook.verify/4`) ship
  the same check, pinned to one shared test vector.

<a id="conditional-writes-on-the-headless-api-etag-if-match-and-expectedlockversion"></a>

- **Conditional writes on the headless API: `ETag`, `If-Match` and
  `expectedLockVersion`.** An API `PATCH` used to be last-write-wins: the
  server read the record and applied the patch in one request, so a client
  writing from a copy it fetched earlier silently overwrote whatever an editor
  had saved since. Single-record JSON:API responses now carry an `ETag`
  (`"<lock_version>-<state>"`), and `If-Match` on `PATCH`, the workflow routes
  and `DELETE` refuses a write from any other version with `412
  precondition_failed`, the current tag in `meta`. The tag includes `state`
  because a publish changes the document without bumping `lock_version`, and a
  client that read a draft must not PATCH what has since gone live. GraphQL
  mutations take the same check as an optional `expectedLockVersion` input,
  and `lock_version` is now a readable (never writable) attribute on every
  content type. The comparison runs inside the write's transaction against the
  row locked for update. Without either, nothing changes. `If-Match` and `ETag`
  are allowed through CORS.

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

<a id="the-official-sdks-write-speak-graphql-and-are-ready-to-publish"></a>

- **The official SDKs write, speak GraphQL, and are ready to publish.**
  `@kiln-cms/client` 0.2.0 and `kiln_client` 0.3.0 gain the JSON:API write
  surface (#330) — `create`, `update`, the four routed workflow transitions
  (`submit_for_review`, `return_to_draft`, `publish`, `unpublish`) behind one
  generic `transition`, and the reversible soft-delete — each refusing
  client-side, before any request, when no API key is configured. Both add a
  minimal `graphql(query, variables)` helper for `/gql`, and typed errors that
  map 401/403, 404, 400/422 (with field pointers), 409 (with the record's
  current state), 429 (with `Retry-After`) and 5xx to distinct classes (JS) or
  `:reason` atoms (Elixir); the Elixir read functions keep their existing
  `{:http_status, …}` errors. A new `release-clients.yml` workflow publishes
  either SDK from its own tag (`client-js-vX.Y.Z`, `kiln_client-vX.Y.Z`) —
  version-checked, gated on an `npm`/`hex` environment, with npm provenance and
  a build-provenance attestation. Nothing is published yet: the first release
  needs the one-time registry setup described in each client's README.
  ([#1568](https://github.com/The-Verscienta/kiln_cms/pull/1568))

<a id="rotating-secretkeybase-no-longer-loses-database-stored-keys"></a>

- **Rotating `SECRET_KEY_BASE` no longer loses database-stored keys.** (#1487)
  `KilnCMS.Keys.Vault` now has a read-only dual-key window: with
  `PREVIOUS_SECRET_KEY_BASE` set to the old value, it opens ciphertext under
  either secret and writes only under the current one.
  `mix kiln.vault.reencrypt` (`KilnCMS.Release.reencrypt_vault/1` in a
  release) then moves every vault column across. It runs one transaction per
  table, with rows locked. A second run changes nothing. `--dry-run` reports
  without writing. A value that opens under neither secret is reported by id
  and never overwritten, and the task then exits non-zero. The old secret is
  read from an environment variable named with `--old-secret-key-base-env`,
  never from argv.

  The columns are found, not listed. Each has the new
  `KilnCMS.Keys.Vault.Ciphertext` type, which is stored as `:binary`, so there
  is no migration. A test fails if any other binary attribute is neither that
  type nor explicitly accounted for. The read window covers the vault only.
  Session cookies, `Phoenix.Token`s and JWTs remain a hard cutover. The runbook
  (`docs/secrets-rotation.md`) and threat-model residual 12 are rewritten to
  match.

<a id="a-sites-activitypub-actor-can-be-re-keyed"></a>

- **A site's ActivityPub actor can be re-keyed.** (#1487) Use
  `mix kiln.federation rekey` or *Re-key* on `/editor/federation`. Both are
  admin-only, through `SiteFederation`'s new `:rekey` action. The action
  replaces both halves of the keypair and keeps the origin, username, actor id
  and `keyId`, which is the identity remote servers hold. In the same
  transaction it queues an actor `Update` to every deliverable follower
  (`KilnCMS.Federation.ActorUpdateWorker`), carrying the new `publicKeyPem`.
  The job becomes visible only at commit, so the `Update` cannot leave before
  `/actor` serves the key that signs it. The key half of `MintIdentity` is now
  a shared `MintKeypair` change, and the fan-out `AnnounceWorker` used is
  shared as `KilnCMS.Federation.deliver_to_followers/4`. The confirmation says
  plainly that some servers may keep the old key until they re-fetch the actor.

<a id="a-site-can-send-its-mail-through-its-own-smtp-relay-set-from-the-console"></a>

- **A site can send its mail through its own SMTP relay, set from the console.**
  `/editor/site-mail` (under Configure → Integrations) lets a site admin set
  the relay host, port, encryption, credentials and From address that site's
  mail goes out through. No `SMTP_*` variables and no redeploy (#1322). It
  covers newsletters and their confirmations, form notifications and
  autoresponders, workflow, task and comment notifications, and automation
  emails. Account mail (sign-in links, password resets, confirmations, sign-in
  alerts) stays on the operator's relay, because accounts belong to the
  deployment. The `SMTP_*` / `MAIL_MODE` variables are unchanged. They are the
  relay for every site that hasn't set its own.

  This is the first integration #1322 moves out of the environment, and it
  sets the pattern for the rest:

  - **Stored per site.** The row is per site (`KilnCMS.CMS.SiteMailRelay`, on
    `KilnCMS.CMS.OrgSettings`), and one site's row never affects another.
  - **Password encrypted.** It is stored with `KilnCMS.Keys.Vault` and never
    shown again. A blank save keeps it. It has no env-var or file source, so a
    site admin can't point it at `SECRET_KEY_BASE`.
  - **Fails closed.** If the row can't be read, or its password can't be
    decrypted, that site's mail is *held* and retried. It never falls back to
    the operator's relay (`KilnCMS.Mail.SiteRelay`), and the page says when the
    password needs re-entering.
  - **Built from the row alone.** The connection takes nothing from the
    operator's mailer config, so the operator's relay password can't end up in
    a connection to a host a site chose.
  - **SSRF-checked.** The relay host is refused if it is a private, loopback,
    link-local or metadata address, at save and again at every connection. The
    connection goes to the pinned address with gen_smtp's MX lookup off.
    Certificates are always verified, and there is no unencrypted option.
  - **Can't suppress addresses.** A hard reject through a site's relay cancels
    that message but doesn't add the address to the instance-wide suppression
    list, which would let one site block an address, including its password
    resets, for every site. A site relay's outage doesn't raise the operator's
    relay-unreachable alert.

  `docs/secrets-rotation.md` lists the new encrypted column: rotating
  `SECRET_KEY_BASE` means each site with its own relay re-enters the password.
<a id="idempotency-key-on-the-headless-writes"></a>

- **`Idempotency-Key` on the headless writes.** A write that times out left a
  client unable to retry: a repeated `POST` created a second document, and a
  repeated `/publish` answered 409 because the first attempt had already
  landed. Send an `Idempotency-Key` on any authenticated `POST` or `PATCH`
  under `/api/json`, or on `POST /gql`, and a retry replays the first
  attempt's status, body and `content-type`/`etag`/`location`, marked
  `idempotency-replayed: true`, without running anything again. The same key
  with a different request is `422 idempotency_key_reused`; while the first
  request is still in flight it is `409 idempotency_request_in_progress` with
  `retry-after`. Keys are scoped to the acting user, matched on method, path,
  query and the *parsed* body (so a re-serialized retry still matches), and
  kept for 24 hours by an hourly-pruned `idempotent_requests` table. 2xx and
  request-level 4xx are stored; 401/403, 409, 429, 5xx and bodies over 1 MB
  are not, so those retry for real. Without the header nothing changes.
<a id="memberships-can-notify-other-systems-membershipactivated-and-membershipcanceled"></a>

- **Memberships can notify other systems: `membership.activated` and
  `membership.canceled` webhook events.** They fire when a paid membership starts
  or stops granting access — not on renewals or dunning retries — so a
  subscribed endpoint can provision a hosted account, sync a CRM, or revoke
  either without talking to the payment provider. The event is enqueued in the
  same transaction as the access change and delivered after it commits, with
  retries and an `event_id` to dedupe on. The payload carries the member's
  email; `docs/data-flows.md` records the flow. Opt-in per endpoint.
  ([#334](https://github.com/The-Verscienta/kiln_cms/issues/334))
<a id="on-the-fly-image-transforms-get-mediaidtops"></a>

- **On-the-fly image transforms: `GET /media/:id/t/:ops`.** Any processed
  image can now be resized, cropped and re-encoded on request —
  `/media/<id>/t/w_1080,ar_16:9,fm_auto` — with width, height, aspect ratio,
  `dpr`, `fit` (`cover`/`contain`), crop anchored on the item's focal point (or
  an edge), format (`jpg`/`png`/`webp`/`avif`, or `auto` from `Accept`) and
  quality. Output is never upscaled. Renders go through the existing libvips
  pipeline and are cached as derivatives in blob storage, keyed on what is
  rendered (so equivalent requests share one file and edits simply miss), and
  served with an `ETag`; a URL carrying the `v` version pin is
  `immutable` for a year. Abuse is bounded at every layer: unsigned URLs may
  only use an allowlist of sizes, ratios and qualities, and HMAC-signed ones
  (`KILN_IMAGE_TRANSFORM_KEY`) any value within a 4000px output cap; sources
  over the upload pixel cap are refused before decoding; cache misses spend a
  per-IP `:media_render` budget and wait on a per-node render gate; and each
  item keeps at most 200 derivatives. The route reads the item exactly as
  `/media/:id/download` does, so gated and quarantined media stay 404.
  Builders ship in both SDKs (`kiln.imageUrl`/`imageSrcset`,
  `KilnClient.image_url/2`/`image_srcset/2`) and as
  `<KilnCMSWeb.MediaComponents.transform_img>` for public templates, all held
  to one set of shared test vectors. One migration (`media_derivatives`). See
  `docs/media-pipeline.md` ("On-the-fly transforms").
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

<a id="the-visual-editing-bridge-takes-a-preview-token-instead-of-an-api-key"></a>

- **The visual-editing bridge takes a preview token instead of an API key.**
  Until now `bridge.js` could see a draft only by putting an editor's API key
  in the browser, where it sees every draft until someone revokes it. It now
  accepts a preview token: set `data-kiln-preview-token`, or call
  `KilnBridge.setPreviewToken(t)`. The token is read-only, opens one document
  and lasts 15 minutes. `GET /api/visual-editing/:type/:slug` reads it from an
  `x-kiln-preview-token` header (now on the CORS allowlist) or from
  `?preview_token=`. It checks the token's type, site, slug and locale against the
  route. It then serves that document's working copy, as `/preview/:token`
  does, with `no-store`. An expired, tampered or mismatched token gets
  `404 invalid_preview`, and a presented token is never swapped for the key or
  for an anonymous read. `/ws/bridge?preview_token=` connects without an actor
  only when the token names this type, id and host's org. Its periodic re-check
  from #775 re-verifies the token and closes the connection once it expires, so a
  leaked token streams for at most 15 minutes plus 30 seconds. `bridge.js` now
  reconnects when the server closes the socket, which the socket's docs had
  always claimed it did. It backs off while refused and uses whatever token it
  holds. The front end re-mints to keep a long session going, either on every
  render or on a timer. `docs/visual-editing-bridge.md` → *Preview tokens and
  long edit sessions* has both patterns and now recommends the token over the
  key.

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
  ([#1576](https://github.com/The-Verscienta/kiln_cms/pull/1576))

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
  ([#1574](https://github.com/The-Verscienta/kiln_cms/pull/1574))

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

<a id="the-graphql-schema-and-the-openapi-document-are-committed-and-a-production-site"></a>

- **The GraphQL schema and the OpenAPI document are committed, and a production
  site hands its own to an API key.** `mix kiln.api.specs` writes
  `docs/api/schema.graphql` and `docs/api/openapi.json`; CI fails when they fall
  behind the code, and the docs build publishes them. Production still refuses
  introspection and the public OpenAPI document (#567), but
  `GET /api/graphql/schema.graphql` and `GET /api/json/open_api` now answer any
  valid API key, so codegen can target a site's own schema, overlay types
  included. `GRAPHQL_INTROSPECTION_ENABLED` turns introspection back on at
  runtime. The OpenAPI description now covers the write routes, entries,
  taxonomy and API keys (an `apiKeyAuth` scheme) instead of calling the API
  read-oriented.
  ([#1567](https://github.com/The-Verscienta/kiln_cms/pull/1567))

<a id="an-opt-in-prometheus-endpoint-for-the-apps-metrics"></a>

- **An opt-in Prometheus endpoint for the app's metrics.** Before this, nothing
  in production recorded the metrics `KilnCMSWeb.Telemetry` defines: the
  dashboard that shows them exists only in development, and no reporter was
  installed. Set `KILN_METRICS_ENABLED=true` and a [Peep](https://hexdocs.pm/peep)
  reporter serves `GET /metrics` on a listener of its own, never on the public
  endpoint:
  - it binds `127.0.0.1:9568` by default (`KILN_METRICS_PORT`)
  - `KILN_METRICS_BIND=all` binds every interface, for a scraper on a private
    network
  - `KILN_METRICS_TOKEN` optionally requires a bearer token

  Durations are now histograms rather than summaries, so p95 can be computed
  from them. Tags are bounded: content types you define in the admin are
  reported as `dynamic`. Off by default, so a stock install records nothing
  and opens no port. Alerts that must reach every operator still go through
  logs and Sentry. `docs/observability.md` and `docs/performance.md` now agree
  on all of this, and `docs/performance.md` records a first headless-API p95
  baseline of 2.7–7.4 ms, measured on a laptop.
  ([#1362](https://github.com/The-Verscienta/kiln_cms/issues/1362))

## Changed

<a id="the-content-list-says-an-items-status-in-words-the-trigram-glyph-is-opt-in"></a>

- **The content list says an item's status in words; the trigram glyph is
  opt-in.** Each row used to carry an I-Ching trigram whose three lines meant
  published, translated and scheduled, named in its tooltip as "li · fire" or
  "kun · earth" — the last of the bagua theming, which the Overview had
  already dropped, and a mark a new editor had to learn to decode. Rows now say
  "Missing translations" when a slug group lacks a locale, and the schedule
  line reads "Publishes Sep 22, 2026, 11:07 AM" (or "Unpublishes …") instead of
  a bare date explained only by a hover title; the state badge already said the
  rest. Anyone who
  reads the glyph can turn it back on under Your settings → Content list
  (`User.status_marks`, a new column that defaults every account, existing
  ones included, to words). `docs/design-language.md` extends its "no internal
  metaphors" rule to pictures.
  ([#1323](https://github.com/The-Verscienta/kiln_cms/issues/1323))
## Changed

<a id="the-dependency-audit-also-reads-hexs-own-advisory-feed"></a>

- **The dependency audit also reads Hex's own advisory feed.** `mix deps.audit` reads
  mirego's mirror of the Elixir advisory database, and on 2026-09-18 that
  mirror knew none of the 89 advisories — six CRITICAL, all in
  `ash_authentication` — that Hex's own feed listed against the v0.9.0 lock,
  so the gate passed green. `mix hex.audit` reads Hex's feed and now runs
  beside it in `mix precommit` and in the `Dependency audit` CI job. Both stay:
  the two databases are maintained separately and neither is a superset of the
  other. An advisory with no fixed release is acknowledged in the `:hex`
  section of `mix.exs`, not skipped.

<a id="string-lengths-are-counted-in-codepoints-as-postgres-counts-them"></a>

- **String lengths are counted in codepoints, as Postgres counts them.** Ash 3.33 refuses to
  compile until a project chooses how `max_length`, `min_length` and
  `string_length` count. Kiln picks `:codepoints`, the count Postgres uses, so
  a length validated in Elixir agrees with one enforced atomically in the
  database, and a field's `max_length` bounds the bytes actually stored. The
  old count was graphemes, where one grapheme can carry any number of
  combining characters; a value that only passed because of that gap is now
  rejected with the same validation error as any other over-long string.
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

<a id="a-delivery-that-fails-on-an-unreadable-signing-key-now-says-so"></a>

- **A delivery that fails on an unreadable signing key now says so.** (#1487)
  It used to claim that federation was not enabled.
  `Federation.active_settings(org_id, require_key?: true)` returns
  `:key_unreadable` for a site that is on but whose key the vault cannot open.
  `DeliveryWorker` settles those deliveries with *"this site's signing key is
  unreadable — was SECRET_KEY_BASE rotated without re-encrypting?"* and logs a
  warning. `/editor/federation` and `mix kiln.federation status` now show
  whether the key is readable.

<a id="a-relay-refusing-the-operators-password-no-longer-suppresses-every-recipient"></a>

- **A relay refusing the operator's password no longer suppresses every
  recipient.** gen_smtp reports a failed AUTH (`auth_failed`), a missing TLS
  stack and a 5xx to MAIL FROM as permanent failures, and mail delivery treated
  every permanent failure as a hard bounce: it cancelled the job and put the
  recipient on the instance-wide suppression list. A rotated `SMTP_PASSWORD`
  therefore stopped mail, password resets included, to everyone the queue
  tried, until an admin removed each address from `/editor/mail`. Now a reject
  suppresses the recipient only when it arrives in the mail transaction with an
  enhanced status saying the address is dead (`5.1.1`, `5.1.2`, `5.1.3`,
  `5.1.6`, `5.1.10`, `5.2.1`). A permanent refusal of our own side (anything
  while opening the session: banner, EHLO, STARTTLS, AUTH; or a sender or AUTH
  reply: `5.1.7`, `5.1.8`, `5.7.8`, `530`, `535`, SPF/DKIM/DMARC `5.7.20` to
  `5.7.26`) retries on the usual ~16h schedule and raises one aggregated alert
  (`Logger.error`, a Sentry message and `[:kiln_cms, :mail, :relay_refused]`
  telemetry, at most every 15 minutes), so the mail goes out once the relay is
  fixed. Any other 5xx (a spam filter, a full mailbox, a bare `550`) still
  cancels the message but no longer suppresses the address. Addresses a relay
  failure already suppressed stay on the list: clear them from `/editor/mail`.

<a id="mix-setup-stops-early-with-the-real-reason-when-the-checkouts-path-has-a-space"></a>

- **`mix setup` stops early, with the real reason, when the checkout's path has
  a space.** Only one dependency cannot compile under such a path:
  `picosat_elixir`, whose Makefile uses absolute paths as make targets. It used
  to fail late, with an error telling you to install gcc and make. The docs said
  every native dependency failed there, and that removing `igniter` crashed the
  compiler. Neither is true, and the docs now say what is. The upstream fix is
  [bitwalker/picosat_elixir#14](https://github.com/bitwalker/picosat_elixir/pull/14),
  not yet released.
  ([#1321](https://github.com/The-Verscienta/kiln_cms/issues/1321))
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

## Security

<a id="point-in-time-reads-asof-apply-the-passphrase-lock-and-the-audience-as-live"></a>

- **Point-in-time reads (`?as_of=`) apply the passphrase lock and the audience
  as live delivery does.** Three gaps on an unauthenticated, CDN-cacheable
  surface. A historical snapshot of a passphrase-locked document (#496), read
  with a grant, was served `cache-control: public, max-age=300` — and the grant
  usually rides in the `x-kiln-unlock` header, which no shared cache keys on, so
  a CDN would hand the unlocked body to the next caller at that URL. It is now
  `private, no-store`, as live delivery already was. The historical collection
  (`GET /api/content/:type?as_of=`, GraphQL `contentAsOf`) listed the slug and
  title of every document published at `as_of`, locked and members-only ones
  included — the leak #1032 closed on `/published`. It now lists only documents
  public to an anonymous reader both now and at `as_of`. And the snapshot
  checked only today's audience, so a document that was members-only at
  `as_of` and is public now served its old gated body; it now answers
  `404 not_public` for dates it was not public. The lock has no history (its
  hash is kept out of version rows), so its current state applies to every
  date. See `docs/point-in-time.md`.

<a id="a-request-on-a-host-that-names-no-site-no-longer-reads-the-database-for-the"></a>

- **A request on a host that names no site no longer reads the database for the
  default site every time.** With `TENANT_STRICT_HOST` off, a `Host` that
  resolves to no organization — a health check by IP, the platform's own
  hostname (`*.onrender.com`, `*.fly.dev`) when `PHX_HOST` is a custom domain,
  any unrecognised header — is served the default site. That host's miss was
  cached, but the default site behind it was one `organizations` read per
  request, made in the endpoint above every rate limiter. Under delivery load
  it queued on the connection pool behind view-tracking writes: measured while
  baselining the metrics exporter, the endpoint's p95 was 11–19 ms on such a host against
  about 3 ms on `PHX_HOST`, with the router under 1 ms on both. The fallback now
  shares the canonical host's host-cache entry, so it is refreshed on the same
  five-minute schedule as every other host (an edit to the default site no
  longer shows up instantly on a stray host and late on `PHX_HOST`), and a
  failed read is still never cached.

## Security

<a id="webhook-signing-secrets-are-encrypted-at-rest"></a>

- **Webhook signing secrets are encrypted at rest.** They were a plaintext
  column. `sensitive?` kept them out of logs, but not out of a database dump, a
  backup or a read replica, and whoever holds a secret can sign deliveries its
  receiver will accept as Kiln's. They are now `KilnCMS.Keys.Vault` ciphertext,
  read through `WebhookEndpoint.secret/1`. A secret that no longer decrypts
  refuses the delivery (`delivery failed: signing secret unreadable` on the
  ledger) rather than sending it unsigned, and the console says so on the
  endpoint's row.

<a id="mint-1101-closes-a-response-smuggling-advisory-in-its-http1-chunked-parser-eef"></a>

- **`mint` 1.10.1 closes a response-smuggling advisory in its HTTP/1 chunked
  parser (EEF-CVE-2026-82672, MEDIUM).** Mint's HTTP/1 chunked-transfer decoder
  treated everything after the chunk-size digits as a chunk extension without
  validating it, so a chunk-size line of `5ZZZZZ` or `5 9` was accepted as a
  5-byte chunk where RFC 9112 permits only an optional `;`-introduced
  extension. A malicious HTTP/1 origin can use that difference to desynchronize
  Mint from a stricter intermediary on a pooled connection and poison the
  response queue for later requests that share it. Kiln reaches Mint through
  Req and Finch, which carry every outbound HTTP path in the app — webhook
  delivery, ActivityPub federation, media URL import, external link checking,
  S3, Meilisearch, Stripe, Sentry, and Swoosh's `ApiClient.Req` in prod — and
  webhooks, federation and URL import all aim at hosts an operator or an editor
  supplies, so the hostile-origin half of the precondition is reachable rather
  than theoretical. `mint` 1.10.1, published the same day as the advisory, is
  the fix OSV names for it. `mint` is a transitive dependency, so this is a lockfile bump alone: every constraint on
  it in the tree (`~> 1.0`, `~> 1.6`, `~> 1.8`) already admits 1.10.1, and no
  Kiln code, configuration or API changed. It is the second advisory against
  this package in two days — the 0.9.0 sweep had moved `mint` *to* 1.10.0 to
  clear a connection-pinning and memory-exhaustion DoS.

<a id="every-advisory-published-against-the-090-dependency-set-is-fixed-including-six"></a>

- **Every advisory published against the 0.9.0 dependency set is fixed, including six CRITICAL in `ash_authentication`.** The lock behind v0.9.0 carried
  89 open advisories across 17 packages: 6 CRITICAL, 23 HIGH, 28 MEDIUM, 32
  LOW. The CRITICAL ones were all in `ash_authentication` 4.14.1 and
  `ash_authentication_phoenix` 2.17.1: a revoked session was still accepted
  because the `jti` was never checked on read (CVE-2026-86533), the
  remember-me guard read a session key nothing wrote, so a remembered sign-in
  could replace the session (CVE-2026-76949), magic-link tokens could be
  replayed through a check-then-use race (CVE-2026-82761),
  `require_confirmed_with` was not enforced on the action and failed open
  (CVE-2026-85500), and an OAuth2 sign-in attached to an existing account
  without comparing emails (CVE-2026-88952). Among the HIGHs: session
  fixation because the session id was not renewed on sign-in, a
  purpose-limited JWT accepted as a bearer token, a confirmation token
  accepted on any record, a sign-in token minted for one resource accepted by
  another, and superlinear base62 decoding in API-key sign-in. Every one is
  closed by `ash_authentication` 4.15.0 and `ash_authentication_phoenix`
  2.17.4. Kiln already used the sign-out confirmation page that 2.17.x makes
  the default, and its two-factor pending-sign-in tokens keep their own `jti`
  ledger, so no route, form or session shape changed. The rest of the set is
  fixed by moving every affected package to its patched release within its
  existing constraint — `ash` 3.33.6 (a filter injection through a forged
  keyset cursor), `ash_postgres` 2.13.1 (`rename_tenant` reporting success on
  failure), `ash_phoenix` 2.3.25 (a nil tenant in the subdomain hook),
  `ash_admin` 1.3.2 (stored XSS, atom exhaustion, cookie shadowing from a
  sibling subdomain, path traversal in uploads), `ash_graphql` 1.12.0
  (cross-tenant subscription disclosure, complexity-limit bypass), `bandit`
  1.12.5 and `mint` 1.10.0 (connection-pinning and memory-exhaustion DoS),
  `html_sanitize_ex` 1.5.5 (quadratic backtracking in the CSS scrubber),
  plus `ash_sql`, `ash_oban`, `ash_paper_trail`, `postgrex`, `igniter`,
  `phoenix_live_view` and `ymlr` — and by two constraint bumps: `ash_ai` to
  `~> 1.0` (an EEx evaluation of prompt content that was remote code
  execution, an identity-tool filter that took operator maps, an MCP origin
  check that a spoofed `X-Forwarded-Proto` bypassed, and leaked provider
  errors; its one breaking change, `req_llm` becoming optional, was already
  anticipated by declaring `req_llm` directly) and the dev-only `usage_rules`
  to `~> 1.2`. `mix hex.audit` reports the lock clean.

<a id="wsgql-runs-under-the-same-cost-limits-as-gql-batches-are-counted-per-operation"></a>

- **`/ws/gql` runs under the same cost limits as `/gql`, batches are counted per
  operation, and introspection is refused however a document arrives.** The
  complexity cap was an `Absinthe.Plug` option on the `/gql` forward, so the
  GraphQL socket never had one. An anonymous `/ws/gql` client could send
  queries, mutations and subscriptions of any cost. Setting the option on the
  socket would not have been enough: Absinthe.Phoenix.Channel replaces a
  socket's options after its first document. Both transports now build their
  document pipeline with `KilnCMSWeb.GraphqlLimits`, which pins the complexity
  cap (200) and a token limit (2,000) over any option a caller passes, and adds
  a depth limit (15). A JSON array body ran every element as its own operation,
  with no maximum, for one hit on the 60-a-minute `:gql` bucket.
  `KilnCMSWeb.Plugs.GraphqlBatchLimit` refuses a batch of more than 10
  operations and charges the bucket once per operation. The production
  introspection block read `params["query"]` only, so `[{"query":
  "{__schema{…}}"}]` returned the whole schema, write mutations included, and
  the socket was never checked at all. The block is now a pipeline phase that
  reads the parsed document, on both transports. To-many relationships with no
  `limit` were priced as one row, so `relatedPosts { relatedPosts { … } }`
  cost about 2 a level while returning k^depth rows. They are now priced at
  five rows, and at `limit` rows when one is given.
<a id="each-document-sent-over-wsgql-now-counts-against-the-gql-rate-limit-and-a"></a>

- **Each document sent over `/ws/gql` now counts against the `:gql` rate limit,
  and a malformed document no longer strips a GraphQL socket of its tenant and
  actor.** Only the connect was counted (`:gql_join`), so an anonymous client
  could connect once and send any number of documents, each allowed the full
  complexity cap. `KilnCMSWeb.GraphqlLimits.SocketDocumentBudget`, the first
  phase of the socket's document pipeline, now charges every document the
  client sends to `:gql`, the 60-a-minute bucket `/gql` requests use, under the
  address the connect was charged under. A client has one GraphQL budget
  whichever transport it uses. The key is the address, not the account as for
  `/ws/collab` frames (decision record 0002): documents are not a per-keystroke
  stream, and an anonymous socket has no account. A subscription's pushes are
  not charged. They re-run only the phases Absinthe.Phase.Init recorded, and
  the budget runs before Init. Over budget, the document is answered before it
  is parsed with a GraphQL error whose `extensions` are
  `{code: "too_many_requests", retry_after: <seconds>}`, and the socket and its
  subscriptions stay up. A second defect turned up on the way:
  Absinthe.Phoenix.Channel keeps the context a document ends with as the
  socket's context, and a document refused before Absinthe copied the context
  onto it (a syntax error, the token limit) ended with none. One malformed
  document left the socket with no tenant, no actor and no pubsub until it
  reconnected, so its next query ran with no tenant and its next subscription
  crashed the channel. The budget phase now puts the context on the document
  before any other phase runs. This closes the `/ws/gql` part of threat-model
  residual item 10; `/live` events are still uncounted.
