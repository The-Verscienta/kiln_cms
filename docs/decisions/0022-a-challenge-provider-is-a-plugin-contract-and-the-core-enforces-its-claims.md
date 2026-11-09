# 0022. A human-verification provider is a plugin contract, and the core enforces what it claims

- **Status** — accepted (2026-11-09).
- **References** — [#2249](https://github.com/The-Verscienta/kiln_cms/issues/2249)
  (the third of three parts), following
  [ADR 0020](0020-human-verification-is-deployment-wide-and-fails-open-only-within-the-sign-in-budget.md)
  (sign-in and registration) and
  [ADR 0021](0021-a-form-opts-in-to-human-verification-and-an-unverified-submission-is-held-not-refused.md)
  (public forms). Partly supersedes ADR 0020's choice of a single,
  core-internal provider.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

ADR 0020 shipped Cloudflare Turnstile as the one provider, behind a
behaviour inside the core, and deferred a plugin callback "once the shape is
proven". #2249 asks for reCAPTCHA v2 too, and for a way to add others. Three
things made the core-internal shape wrong for that:

- **Dependency plugins could not implement it.** A plugin shipped as a Mix
  dependency compiles before the core, so a behaviour that lives in the core
  does not exist when the plugin compiles.
- **The core trusted provider code on request paths.** Every auth page and
  every delivered page with a form called the provider's `script_url/0`,
  `global/0` and `csp_sources/0`, unbounded. Only `verify/2` ran under a
  deadline.
- **Each provider enforced its own claims.** The hostname and action checks
  lived inside Turnstile's verification. A second provider would have had to
  repeat them, and a third-party one could have skipped them.

## Decision

- **`Kiln.Challenge.Provider` in the SDK, registered by
  `c:Kiln.Plugin.challenge_providers/0`.** It is part of the unreleased
  `kiln_plugin` 1.4.0. Callbacks: `id/0`, `label/0`, `widget/0`,
  `csp_sources/0` and `verify/2`. The operator picks a provider by its id
  (`CHALLENGE_PROVIDER`). Built-ins are listed first, so a plugin can never
  take over `turnstile` or `recaptcha`.
- **Checked once, then only data on request paths.** The named provider is
  resolved and checked with `Kiln.Challenge.Provider.conformance/1`, once per
  node and value, into a memoised descriptor. Pages read only the
  descriptor. An id nobody installed, a provider that fails conformance, or
  one whose callbacks raise leaves verification **off**, as an unconfigured
  provider always has: no widget, no wider policy. It is said at boot and in
  a rate-limited log line.
- **Conformance is strict about what reaches the page policy.** The script
  must be `https://`, carry no credentials, and be covered by one of the
  provider's own `script-src` entries. Every CSP source must be
  `https://host[:port][/path]`: no wildcards, keywords, quotes, `;` or `,`.
  Render options must be JSON and may not set the sitekey or the callbacks.
  Within 1.x these rules only loosen. Wildcard hosts may be allowed later.
- **`widget/0` is data, with a discriminator.** `api: :explicit_render` is
  the only kind today: `render(element, options)` plus `reset`, with `remove`
  called when present. A future widget kind is added under a new value.
  `render_options`, `action_option`, `onload_param`, `response_field` and
  `interactive` describe the differences between Turnstile and reCAPTCHA
  without the browser code naming either.
- **The core enforces the claims.** `verify/2` answers `{:ok, claims}` with
  the `hostname` and `action` the provider reported. The core refuses a
  missing or foreign hostname whenever hostnames are checked, and an action
  that is present and differs. A provider that always reports the action
  (Turnstile) refuses an answer without one itself.
- **A provider's answer is read conservatively.** `:missing` and `:malformed`
  belong to the core's precheck. A provider returning either, or any refusal
  the contract does not name, is read as `:invalid`. That matters because a
  missing token can be admitted during an outage (ADR 0020) and a refused one
  never is. An unavailable reason the contract does not name, or any answer
  outside the shape, is a crash.
- **reCAPTCHA v2 is built in; Turnstile stays recommended.** reCAPTCHA loads
  from `www.recaptcha.net` and `www.gstatic.com`, never `www.google.com`,
  which also serves JSONP endpoints that would undo a strict `script-src`.
  Verification goes to `www.recaptcha.net` too. v2 is interactive, so a
  public form asks the visitor to complete it before sending rather than
  waiting for it. Its tokens carry no action.
- **v2 only.** An answer carrying a `score` (a v3 or Enterprise key) is
  refused.

## Considered and rejected

- **Adding `recaptcha` to the closed list and stopping there.** It answers
  the second provider and not the request for a contract, and the claims
  would still be enforced per provider.
- **Keeping the behaviour in the core and registering plugins through the
  `providers:` setting.** Dependency plugins could not implement it.
  `providers:` remains a test seam only.
- **Trusting a plugin's CSP sources as given.** A source with a `;` or a
  keyword rewrites the page policy for every visitor.
- **Branching on the provider in the browser code.** Every new provider would
  need a JavaScript release. The widget data describes the differences
  instead.
- **reCAPTCHA v3.** It passes or fails on a score threshold Kiln would have
  to guess, offers the visitor no step that fixes a low score, expires its
  tokens in two minutes, and runs on every page it is loaded on. It also
  breaks ADR 0020's rule that only a provider's own refusal is final.
- **Loading reCAPTCHA from `www.google.com`.** The JSONP endpoints there are
  a known way round a strict policy.
- **Failing closed, or refusing to boot, on an unknown provider.** An
  operator's typo would lock everyone out of sign-in, or take the site down.
  Off, said loudly, matches how a missing key already behaves.

## Residual risks

- A reCAPTCHA v2 token is not bound to an action. One solved on this
  deployment's form can be spent once on its sign-in within the token's two
  minutes. The hostname is still checked, so the token was solved on a page
  this deployment serves.
- reCAPTCHA has no `remove`. A widget LiveView replaces stays in the script's
  own bookkeeping until the page unloads.
- reCAPTCHA answers a wrong secret key with `invalid-input-response`, the
  code for a bad token, not `invalid-input-secret`. A misconfigured
  reCAPTCHA secret therefore looks like every token being refused: nobody is
  admitted (the safe direction), but no "secret refused" log line appears
  and sign-in does not fail open. Turnstile reports a wrong secret as such.
- Google's test secret still answers `success: true` with the hostname
  `testkey.google.com`, which must be listed in `CHALLENGE_HOSTNAMES` while
  it is in use. Its test site key now renders "Invalid site key", so trying
  the widget end to end needs a real v2 key registered for the development
  hostname.

## Verified

The reCAPTCHA page policy was checked in headless Chromium against the
development server: `/sign-in`, `/register`, a form's own page and its embed
raised no Content-Security-Policy violation on the page with the sources
listed above.

## Follow-ups

1. Per-site keys and a settings page for forms:
   [#2505](https://github.com/The-Verscienta/kiln_cms/issues/2505).
2. A self-hosted proof-of-work provider:
   [#2506](https://github.com/The-Verscienta/kiln_cms/issues/2506).
