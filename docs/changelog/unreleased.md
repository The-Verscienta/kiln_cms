# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

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

<a id="a-delivery-that-fails-on-an-unreadable-signing-key-now-says-so"></a>

- **A delivery that fails on an unreadable signing key now says so.** (#1487)
  It used to claim that federation was not enabled.
  `Federation.active_settings(org_id, require_key?: true)` returns
  `:key_unreadable` for a site that is on but whose key the vault cannot open.
  `DeliveryWorker` settles those deliveries with *"this site's signing key is
  unreadable — was SECRET_KEY_BASE rotated without re-encrypting?"* and logs a
  warning. `/editor/federation` and `mix kiln.federation status` now show
  whether the key is readable.

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

