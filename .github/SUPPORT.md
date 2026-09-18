# Getting help with KilnCMS

Short version: **questions and bugs go to [issues](https://github.com/The-Verscienta/kiln_cms/issues);
security problems go to [private advisory reporting](https://github.com/The-Verscienta/kiln_cms/security/advisories/new),
never to an issue.** One maintainer reads all of it, so the rest of this page is
about what to expect.

## Before you ask

Most operational questions are already answered in writing, and pointing you at
the answer is the fastest response you can get:

- [Getting started](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/getting-started.md)
  — run it locally, then the map of every other guide.
- [Deploy](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/deploy.md)
  and [Environment variables](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/environment-variables.md)
  — the required secrets, boot behaviour, health endpoints, backups.
- [Downstream projects](https://github.com/The-Verscienta/kiln_cms/blob/main/projects/README.md)
  — how a site layers its own content types on the core, and the
  [overlay contract](https://github.com/The-Verscienta/kiln_cms/blob/main/projects/README.md#the-overlay-contract)
  it does that against. This is how KilnCMS is meant to be consumed.
- [Headless consumer guide](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/headless-consumer-guide.md)
  — which of JSON:API / GraphQL / MCP / RAG you want.
- [Authorization policy matrix](https://github.com/The-Verscienta/kiln_cms/blob/main/docs/policy-matrix.md)
  — who can do what, per resource and action.

`mix docs` builds the same guides locally with the module reference alongside
them.

## Where to put what

| You have | Go here |
|---|---|
| A question — "how do I", "is this supposed to", "which guide covers" | A [new issue](https://github.com/The-Verscienta/kiln_cms/issues/new/choose); a blank one is fine, just say up front that it is a question (it gets the `question` label on triage — you will not be able to apply one yourself) |
| A bug — it behaves incorrectly | The [bug report](https://github.com/The-Verscienta/kiln_cms/issues/new?template=bug_report.yml) template |
| A feature idea | The [feature request](https://github.com/The-Verscienta/kiln_cms/issues/new?template=feature_request.yml) template |
| A finding from a beta session | The [beta feedback](https://github.com/The-Verscienta/kiln_cms/issues/new?template=beta_feedback.yml) template, one finding per issue |
| A **security vulnerability** | [Report a vulnerability](https://github.com/The-Verscienta/kiln_cms/security/advisories/new) — the full policy, scope and timelines are in [SECURITY.md](SECURITY.md) |
| A patch | [CONTRIBUTING.md](https://github.com/The-Verscienta/kiln_cms/blob/main/CONTRIBUTING.md) — the workflow and the `mix precommit` gate |

GitHub Discussions is not enabled, so there is no separate forum to check.

### Bug or security issue?

If the answer to "who could abuse this, and what would they get?" is anybody
other than the person triggering it — another tenant's content, an unpublished
draft, someone else's session, a secret, the server's network — report it
privately. If in doubt, report it privately; an over-cautious advisory costs
nothing and is easy to reopen as a public issue.

A crash, a wrong count, a broken layout, a migration that fails: those are
bugs. Open them publicly, where other people can find them.

## What a good report contains

Enough for someone else to reproduce it without asking you a follow-up:

- the version or commit SHA (a running instance reports both on
  `/editor/system`);
- how it is configured — multi-tenancy on or off, auth method, storage backend,
  whether an overlay under `projects/` is active;
- what you did, what you expected, what happened instead;
- the actual error — a stack trace, the LiveView console message, the relevant
  server log lines, not a paraphrase.

A failing test is the strongest form of a bug report. Second strongest is a
`curl` invocation.

## What to expect

Honest, not discouraging:

- **This is a single-maintainer project.** There is no support rota, no paid
  support tier, and no response-time guarantee on anything except security
  reports — [SECURITY.md](SECURITY.md) commits to acknowledging those within 3
  business days, and that commitment is kept ahead of everything on this page.
- **Public issues are answered on a best-effort basis**, in bursts rather than
  continuously. Days, sometimes longer.
- **Reproducible bugs get looked at first**; questions that a guide already
  answers get a link; feature requests are read, labelled, and may then sit
  indefinitely. Silence on a feature request means "not scheduled", not "no" —
  and if you are willing to implement it, say so, because that changes the
  answer.
- **KilnCMS is pre-1.0** (see the status section in
  [the README](https://github.com/The-Verscienta/kiln_cms#status--maturity)).
  Fixes land on `main` and reach you when you move your submodule pin; there
  are no maintained release branches to backport to.

## If you are evaluating KilnCMS for a team

The two things worth reading before you commit are the
[status and maturity](https://github.com/The-Verscienta/kiln_cms#status--maturity)
section of the README — bus factor, what is stable, what is not — and
[the overlay contract](https://github.com/The-Verscienta/kiln_cms/blob/main/projects/README.md#the-overlay-contract),
which is the interface your own code would be written against. Questions about
either are welcome as issues; "would you consider X a supported surface" is a
useful question to ask *before* you build on it, not after.
