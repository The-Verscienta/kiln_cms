# 0011. Each organization gets its own console origin, under the console host

- **Status** — accepted; unreleased (targets 1.0.0).
- **References** — [#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688), follow-up to [#1661](https://github.com/The-Verscienta/kiln_cms/issues/1661) and [#740](https://github.com/The-Verscienta/kiln_cms/issues/740); threat model residual risk 16.
- **Changelog** — the Unreleased Security section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

`KILN_CONSOLE_HOST` (#740) moves the editor console to a host that serves no
tenant content, so an org admin's code injection (#490) is cross-origin to it.
But org resolution is host-derived, and the console host names no org: it was
the **default org's** console. On a multi-org install, setting it redirected
every other org's `/editor` to the default org's console, where their admins
are not members. Leaving it unset kept each org's console on the org's own
host, which is same-origin with that org's code injection and so reachable by
one tenant's admin in the browsers of other tenants' editors (residual 16).

## Decision

**Every organization's console is served on its own origin,
`<slug>.<KILN_CONSOLE_HOST>`.** The bare console host stays the default
org's console. The name is derived, not stored: no new column and no
migration, and an org has a console host from the moment it exists.
`KilnCMSWeb.Tenant` resolves `<slug>.<console host>` to the org with that
slug, the same way it resolves `<slug>.<base host>`. A console route on any
org's site host redirects a `GET` to that org's console host, and no console
host ever serves delivery.

## The two options

**(a) One console origin per org** (chosen), derived as a subdomain of the
console host. An org-level `console_domain` attribute was the other shape of
(a). It is left out because a derived name needs no schema change, and
because a console under an org's own registrable domain cannot use the
deployment's passkeys (see below).

**(b) One tenant-aware console host**, where the session or a URL segment
picks the org. It is rejected for these reasons:

- **Kiln's tenancy invariant is "the tenant is the host the transport
  connected on".** `SetTenant`, `:assign_current_org`, and all four socket
  families (`/live`, `/ws/gql`, `/ws/bridge`, `/ws/collab`) rely on it. #654
  and #687 exist to make it hold. Under (b) each of them would need a second,
  session-derived source of truth on one host, and the console's own calls
  into `/api/**` and `/gql` would too. Every such call site is a place where
  one tenant could be confused with another.
- **Shared routes render tenant content.** Previews, media download and stream,
  and the headless APIs are served on the console host as well (see
  `KilnCMSWeb.Surface`). On one shared console origin, org A's content served
  there would be same-origin with org B's console session. Per-org origins
  bound any such content to its own org's console.
- **Two tabs, two orgs.** A session-selected org fights itself across tabs. A
  path-selected org would change every `/editor/...` URL.

What (b) does better is operations: one host, one TLS name, and no wildcard DNS.
(a) needs `*.<console host>` in DNS and in the certificate. A deployment
serving tenants on `*.<base host>` already runs that kind of setup.

## Passkeys: why the console host must sit under `PHX_HOST`

A WebAuthn credential is bound to its **RP ID**. Kiln's RP ID is the
endpoint's host (`PHX_HOST`), and it **does not change here**, so every
existing passkey keeps working. Nobody re-enrolls.

The browser accepts that RP ID on any origin whose host ends in it. On
`https://acme.console.example.com`, an RP ID of `example.com` is accepted.
Until this change the server side accepted only the exact `PHX_HOST` origin
(Wax's default). As a result, passkey sign-in on the console host and on
every tenant host failed with an origin mismatch. The ceremony now also
accepts the console host and its one-label subdomains, with the endpoint's
scheme and port. Tenant site hosts are deliberately **not** accepted. A site's
code injection could ask the browser for an assertion under the shared RP ID,
and the server would then honour it.

A console host outside `PHX_HOST` (say `console.example.net`) cannot use
the deployment's passkeys at all, because the browser refuses the RP ID. That
was already true before this change. Kiln warns about it at boot rather than
changing the RP ID, which would orphan every registered passkey. The
per-org `console_domain` variant fails this test for any org on its own
domain, which is the second reason it was not chosen.

## Cookies and CSRF

- **Cookies.** The session and remember-me cookies are host-only and, in
  production, `__Host-`-prefixed (decision 0005). A session on
  `acme.console.example.com` is therefore never sent to `acme.example.com`,
  to `beta.example.com`, or to `beta.console.example.com`, and no sibling can
  plant one there. Signing in on org A's console host gives no session on
  org B's site host or console host. Each is its own sign-in.
- **CSRF.** All these hosts are same-*site*, so `SameSite=Lax` does not
  separate them. It never did between tenant subdomains either. Forms and the
  LiveView socket rely on the per-session CSRF token embedded in the page, and
  a cross-origin script cannot read that token. `check_origin` admits
  `//*.<PHX_HOST>`. That wildcard now also covers per-org console hosts under
  `PHX_HOST`. Kiln adds the console host and `*.<console host>` itself, so an
  operator no longer has to list them in `CHECK_ORIGINS`.

## Hosted offering (#334)

The current plan runs one instance per customer, and that shape needs none of
this. For a shared deployment, per-org console hosts under a wildcard such as
`*.console.<platform domain>` are the usual SaaS arrangement. They keep the
platform's passkeys working, provided `PHX_HOST` is the platform domain.

## Migration

- **Single-org installs:** no change. The console either shares the site's
  origin (unset) or sits on the bare console host (set), as before.
- **Multi-org without `KILN_CONSOLE_HOST`:** no change, and the warning
  remains. Setting the variable is now a complete fix rather than one that
  strands every non-default org.
- **Multi-org with `KILN_CONSOLE_HOST`:** non-default orgs' `/editor` now
  redirects to `<slug>.<console host>` instead of the default org's console,
  where their admins had no access. Add `*.<console host>` to DNS and the TLS
  certificate before upgrading. Anyone signed in on the bare console host signs
  in again on their org's console host.

Residual 16 therefore becomes a configuration choice, not a structural gap.
The console is still opt-in, because a console host is a DNS and TLS change
that Kiln cannot make for an operator on upgrade.
