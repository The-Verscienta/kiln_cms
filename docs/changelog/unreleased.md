# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

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

