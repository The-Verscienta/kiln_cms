# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

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

## Added

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

