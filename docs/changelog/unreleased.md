# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="on-a-multi-org-deployment-with-kiln_console_host-set-add-console-host-to-dns"></a>

- **On a multi-org deployment with `KILN_CONSOLE_HOST` set, add
  `*.<console host>` to DNS and TLS before upgrading.** A console route on a
  non-default organization's site now redirects to that organization's own
  console host, `<slug>.<console host>`, instead of to the default
  organization's console, where that organization's admins had no access.
  That host has to resolve to Kiln and be covered by the certificate: a
  certificate for `*.example.com` does not cover `acme.console.example.com`.
  Anyone signed in on the bare console host signs in again on their
  organization's console host. Single-org deployments and deployments without
  `KILN_CONSOLE_HOST` are unaffected. If the console host is not under
  `PHX_HOST`, Kiln now warns at boot that passkeys cannot work there, which was
  already the case
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688)).

## Breaking

<a id="on-a-multi-org-install-with-kiln_console_host-set-each-non-default-orgs-console"></a>

- **On a multi-org install with `KILN_CONSOLE_HOST` set, each non-default
  org's console moves to `<slug>.<console host>`: add wildcard DNS and a
  wildcard TLS certificate for `*.<console host>` before upgrading.** The documented meaning of `KILN_CONSOLE_HOST` changes for
  this one configuration. Before, a console route on a non-default
  organization's site redirected to the bare console host, which is the
  default organization's console. Now it redirects to that organization's own
  console host, `<slug>.<console host>` (for example
  `acme.console.example.com`). Unless that name resolves to Kiln and is covered
  by the certificate, those editors reach no console at all after the upgrade.
  A certificate for `*.example.com` does not cover `acme.console.example.com`.
  Editors signed in on the bare console host sign in again on their
  organization's console host. Single-org installs, and installs without
  `KILN_CONSOLE_HOST`, are unaffected
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688)).

## Security

<a id="kiln_console_host-now-isolates-every-organizations-console-each-on-its-own"></a>

- **`KILN_CONSOLE_HOST` now isolates every organization's console, each on its
  own `<slug>.<console host>` origin.** Until now the console host was the
  default organization's console only. On a multi-org deployment, setting it
  sent every other organization's editors to a console they could not use.
  Leaving it unset kept each console same-origin with its site's code
  injection, where one tenant's admin could act with other tenants' editors'
  sessions (threat model residual risk 16). Now the bare console host stays
  the default organization's console, and `KilnCMSWeb.Tenant` resolves
  `<slug>.<console host>` to the organization with that slug, the way it
  resolves `<slug>.<base host>`. Org resolution stays host-derived, so every
  socket and LiveView keeps the tenant it connected on. No console host
  serves delivery, no two organizations' consoles share an origin, and the
  host-only session cookie on one console host is never sent to a site or to
  another console. The console host no longer resolves as the organization
  whose slug is its first label. Passkey ceremonies now also accept console
  origins, under the unchanged relying-party ID, so existing passkeys work
  there with no re-enrollment. Before this, every passkey ceremony on a console
  host failed Wax's exact-origin check. Tenant site origins are still refused,
  because code injection runs on them. Console hosts are added to the socket
  origin check automatically. The reasoning, including why the design uses
  one host per organization rather than one shared console host that switches
  organization, is
  [decision record 0011](../decisions/0011-each-organization-gets-its-own-console-origin-under-the-console-host.md)
  ([#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688)).
