# Security Policy

## Supported versions

KilnCMS is pre-1.0. Security fixes land on `main` only, and downstream projects
pick them up by moving their submodule pin (`mix kiln.update`). There are no
maintained release branches yet.

| Version | Supported |
|---|---|
| `main` | ✅ |
| Anything older | ❌ — rebase onto `main` |

Once 1.0 ships this table will name the release lines that receive backports.

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
- **A fix on `main`**, plus a published GitHub Security Advisory with a CVE where
  warranted. We'll credit you by the name or handle you ask for, or keep you
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
