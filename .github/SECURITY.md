# Security Policy

## Supported versions

Kiln supports release lines by **minor** version: the newest one fully, the one
before it for security fixes only, and for a limited time.

| Line | Supported | Gets |
|---|---|---|
| The latest minor (e.g. `1.1.x` once `1.1.0` is out) | ✅ | Every fix, as a patch release on that line |
| The previous minor of the same major (e.g. `1.0.x`) | 🔒 for 90 days | Security fixes only, for 90 days from the release date of the minor that replaced it |
| `0.x` (including `0.12.x`), once `1.0.0` is out | ❌ | Nothing from `1.0.0`'s release date: upgrade with `mix kiln.update --allow-major` |
| Anything older | ❌ | Nothing: upgrade to a supported line |
| `main` | Development | Fixes land here first; not a release |

**The 90 days are counted from the next minor's release date.** If `1.1.0` is
released on 1 March, `1.0.x` gets security fixes until 30 May, and none after.
A fix released within the window ships as a `1.0.x` patch; after it, the fix
reaches you only by upgrading to `1.1.x`.

**The rule applies within a major line, from `1.0.0` on.** The previous minor
is the one before the latest minor *of the same major*; the window does not
carry across a major version. Until `1.0.0` ships, `0.12.x` is the latest
minor and is supported as such. **Support for `0.x` ends on `1.0.0`'s release
date:** from then on `0.12.x` gets no fixes, security or otherwise. Upgrade a
`0.x` project with `mix kiln.update --allow-major` after reading the 1.0
upgrade notes.

**How a fix reaches a supported line.** It lands on `main` first. The latest
minor gets a patch release. If that is not the previous minor's release, the
fix is cherry-picked onto a short-lived branch cut from the previous minor's
newest tag, tagged as its next patch, and the branch is deleted
([`docs/releasing.md`](../docs/releasing.md#patch-releases-and-backports) has
the procedure). There are no long-lived maintenance branches: the project has
one maintainer, and the policy does not promise more than one person can keep
patched.

**Picking up a fix.** Downstream projects move their submodule pin with
`mix kiln.update` (the newest release) or `mix kiln.update --to vX.Y.Z` (a
patch on an older line). The container image is published under its exact
version (`ghcr.io/the-verscienta/kiln_cms:1.0.3`) on every line. From `1.0.0`
it is also published under the floating major tag (`:1`) and `:latest`, but
those two only ever point at the highest release. A patch on the previous minor
never moves them, so an install that tracks `:1` gets the latest minor's
patches, not the previous minor's. Pin exact versions if you stay on the
previous minor.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report privately through GitHub:

1. Go to the [Security tab](https://github.com/The-Verscienta/kiln_cms/security)
   of this repository.
2. Choose **Report a vulnerability**.
3. Fill in the advisory form.

That opens a private advisory visible only to you and the maintainers, where we
can discuss the issue, prepare a fix, and credit you when it's published.

### What to include

- The affected surface — route, LiveView, API endpoint, socket, Oban worker, or
  mix task. [`docs/threat-model.md`](../docs/threat-model.md) maps the public
  surface if you want to name it precisely.
- The version or commit SHA you tested against, and how KilnCMS was configured
  (multi-tenancy on/off, auth method, storage backend).
- Reproduction steps, ideally as a failing test or a `curl` invocation.
- The impact you believe it has: whose data, which trust boundary is crossed.
- Whether you have a suggested fix.

### What to expect

- **Acknowledgement** within 3 business days.
- **An initial assessment** — severity, affected versions, whether we can
  reproduce it — within 10 business days.
- **A fix on `main`** and a patch release for each
  [supported line](#supported-versions) the problem affects, plus a published
  GitHub Security Advisory with a CVE where warranted. The advisory lists the
  patched version on each line. We'll credit you by the name or handle you ask for, or keep you
  anonymous if you prefer.
- We ask for coordinated disclosure: please give us 90 days before publishing,
  or less if we ship a fix sooner and agree on a date with you.

## Scope

In scope — anything that lets someone:

- read unpublished, audience-restricted, or other tenants' content;
- authenticate as, or act as, another user or organization;
- escalate a `viewer`/`editor` actor beyond the policies in
  [`docs/policy-matrix.md`](../docs/policy-matrix.md);
- inject script into the editor or the delivered site (XSS through block
  content, custom fields, or form submissions);
- extract secrets — API keys, webhook signing keys, storage credentials, auth
  tokens, preview/collab/bridge tokens;
- reach internal networks from the server (SSRF via webhooks, media fetch, or
  the embed/oEmbed path).

Out of scope:

- Findings that require the operator to have already misconfigured the
  deployment in a way the docs warn against (for example running with
  `dev_routes` enabled in production, or exposing `/admin` publicly).
- Volumetric denial of service against a self-hosted instance.
- Missing hardening headers on routes that serve no authenticated content,
  absent a demonstrated impact.
- Vulnerabilities in dependencies with no KilnCMS-specific exploit path — those
  are handled by the `mix deps.audit` CI gate; open a normal issue or PR to bump
  the dependency.
- Automated scanner output pasted without a reproduction.

## Security controls in this repository

Contributions are expected to keep these green — see
[`CONTRIBUTING.md`](../CONTRIBUTING.md):

- **`mix sobelow`** — static security scan, part of `mix precommit` and CI.
- **`mix deps.audit`** — `mix.lock` against the Elixir advisory database, in
  `mix precommit` and as its own CI job so a new advisory doesn't bury unrelated
  results.
- **Policy coverage guard** — an Ash resource with no authorizer fails the test
  suite. Authorization is mandatory; a new resource without policies is a bug.
- **[`docs/threat-model.md`](../docs/threat-model.md)** — the network edge, its
  trust boundaries, and the residual risks operators should watch. Update it
  whenever you add a public route, socket, or outbound integration.
