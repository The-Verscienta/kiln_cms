# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="upgrading-to-091-rebuild-and-re-run-overlay-tests"></a>

**Upgrading to 0.9.1: rebuild, and re-run your overlay's tests.** This
patch release exists for security fixes, but it takes its dependencies
further than a patch usually does: `ash` 3.29 → 3.33, `ash_ai` to the 1.x
line, and every other affected package to its patched release (see the
Security entry). Kiln's own code needed no changes beyond one config key.
An overlay that calls Ash, AshAuthentication or `ash_ai` directly should
rebuild and run its test suite before deploying. One behaviour change can
reach stored data: string length validation now counts codepoints, as
Postgres does, rather than graphemes. A value that only fitted its
`max_length` because combining characters counted as one grapheme is now
rejected the next time it is saved. No migration runs, and nothing is
rewritten on upgrade.

## Changed

<a id="the-dependency-audit-also-reads-hexs-own-advisory-feed"></a>

- **The dependency audit also reads Hex's own advisory feed.** `mix deps.audit` reads
  mirego's mirror of the Elixir advisory database, and on 2026-09-18 that
  mirror knew none of the 89 advisories — six CRITICAL, all in
  `ash_authentication` — that Hex's own feed listed against the v0.9.0 lock,
  so the gate passed green. `mix hex.audit` reads Hex's feed and now runs
  beside it in `mix precommit` and in the `Dependency audit` CI job. Both stay:
  the two databases are maintained separately and neither is a superset of the
  other. An advisory with no fixed release is acknowledged in the `:hex`
  section of `mix.exs`, not skipped.

<a id="string-lengths-are-counted-in-codepoints-as-postgres-counts-them"></a>

- **String lengths are counted in codepoints, as Postgres counts them.** Ash 3.33 refuses to
  compile until a project chooses how `max_length`, `min_length` and
  `string_length` count. Kiln picks `:codepoints`, the count Postgres uses, so
  a length validated in Elixir agrees with one enforced atomically in the
  database, and a field's `max_length` bounds the bytes actually stored. The
  old count was graphemes, where one grapheme can carry any number of
  combining characters; a value that only passed because of that gap is now
  rejected with the same validation error as any other over-long string.

## Security

<a id="every-advisory-published-against-the-090-dependency-set-is-fixed-including-six"></a>

- **Every advisory published against the 0.9.0 dependency set is fixed, including six CRITICAL in `ash_authentication`.** The lock behind v0.9.0 carried
  89 open advisories across 17 packages: 6 CRITICAL, 23 HIGH, 28 MEDIUM, 32
  LOW. The CRITICAL ones were all in `ash_authentication` 4.14.1 and
  `ash_authentication_phoenix` 2.17.1: a revoked session was still accepted
  because the `jti` was never checked on read (CVE-2026-86533), the
  remember-me guard read a session key nothing wrote, so a remembered sign-in
  could replace the session (CVE-2026-76949), magic-link tokens could be
  replayed through a check-then-use race (CVE-2026-82761),
  `require_confirmed_with` was not enforced on the action and failed open
  (CVE-2026-85500), and an OAuth2 sign-in attached to an existing account
  without comparing emails (CVE-2026-88952). Among the HIGHs: session
  fixation because the session id was not renewed on sign-in, a
  purpose-limited JWT accepted as a bearer token, a confirmation token
  accepted on any record, a sign-in token minted for one resource accepted by
  another, and superlinear base62 decoding in API-key sign-in. Every one is
  closed by `ash_authentication` 4.15.0 and `ash_authentication_phoenix`
  2.17.4. Kiln already used the sign-out confirmation page that 2.17.x makes
  the default, and its two-factor pending-sign-in tokens keep their own `jti`
  ledger, so no route, form or session shape changed. The rest of the set is
  fixed by moving every affected package to its patched release within its
  existing constraint — `ash` 3.33.6 (a filter injection through a forged
  keyset cursor), `ash_postgres` 2.13.1 (`rename_tenant` reporting success on
  failure), `ash_phoenix` 2.3.25 (a nil tenant in the subdomain hook),
  `ash_admin` 1.3.2 (stored XSS, atom exhaustion, cookie shadowing from a
  sibling subdomain, path traversal in uploads), `ash_graphql` 1.12.0
  (cross-tenant subscription disclosure, complexity-limit bypass), `bandit`
  1.12.5 and `mint` 1.10.0 (connection-pinning and memory-exhaustion DoS),
  `html_sanitize_ex` 1.5.5 (quadratic backtracking in the CSS scrubber),
  plus `ash_sql`, `ash_oban`, `ash_paper_trail`, `postgrex`, `igniter`,
  `phoenix_live_view` and `ymlr` — and by two constraint bumps: `ash_ai` to
  `~> 1.0` (an EEx evaluation of prompt content that was remote code
  execution, an identity-tool filter that took operator maps, an MCP origin
  check that a spoofed `X-Forwarded-Proto` bypassed, and leaked provider
  errors; its one breaking change, `req_llm` becoming optional, was already
  anticipated by declaring `req_llm` directly) and the dev-only `usage_rules`
  to `~> 1.2`. `mix hex.audit` reports the lock clean.
