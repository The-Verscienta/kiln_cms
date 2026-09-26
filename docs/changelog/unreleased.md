# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Breaking

<a id="multi-org-installs-now-refuse-unknown-hosts-unless-tenantstricthostfalse"></a>

- **Multi-org installs now refuse unknown hosts unless `TENANT_STRICT_HOST=false`.**
  `TENANT_STRICT_HOST` has a third state, and it is the new default: **unset
  means auto** — strict host matching is on if and only if more than one
  organization exists. A single-org install behaves exactly as before; a
  deployment with two or more organizations, where `TENANT_STRICT_HOST` was
  never set, now answers a request whose `Host` matches no organization (a bare
  hostname, an IP literal, a platform's internal hostname, an attacker-supplied
  header) with a `404` — or a retryable `503` if the database is down — instead
  of the default org's content, branding and analytics. The `PHX_HOST` apex, the
  `KILN_CONSOLE_HOST`, the health probes (`/up`, `/ready`) and the payment
  webhook are never refused.

  **To keep the old behaviour**, set `TENANT_STRICT_HOST=false`. Kiln then warns
  about it at boot and on `/editor/system`, as it has since #660, and those
  warnings now name the explicit `false` as the cause. An explicit
  `TENANT_STRICT_HOST=true` is unchanged.

  Auto follows the organization count without a restart: creating the second
  organization turns it on immediately on the node that served the create, and
  on the others through a `Phoenix.PubSub` broadcast (a node that misses it
  recounts within five minutes). The per-request check reads a cached verdict,
  never a count. If the count cannot be read at all — a node that booted while
  Postgres was unreachable — auto fails **closed** and refuses unknown hosts
  until a count succeeds, because serving another tenant's site to an
  unrecognized host cannot be undone and a retryable refusal can. See
  `KilnCMSWeb.Tenant.OrgCount`, `docs/multi-tenancy.md` and
  `docs/environment-variables.md`. Decision 4 of `docs/roadmap-1.0.md`
  ([#1547](https://github.com/The-Verscienta/kiln_cms/issues/1547)).
