# 0017. An unverifiable bearer flips on in a minor, under Breaking, and is counted first

- **Status** — accepted (2026-11-07). Refines the "#2161 commitment" in
  [ADR 0012](0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md).
  The default has already flipped (it ships on); this records why that is a
  minor and what was added so operators can see it coming.
- **References** — [#2161](https://github.com/The-Verscienta/kiln_cms/issues/2161),
  [#2273](https://github.com/The-Verscienta/kiln_cms/issues/2273).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

A `Bearer` JWT that does not verify used to be served as anonymous: a `200` with
published content, so the client never learned it was signed out. ADR 0012
committed to a `401`, behind a flag in one release and on by default in the
next. Two questions that record left open:

1. **Is flipping a default that turns a `200` into a `401` a major?** No.
   `docs/releasing.md` defines major as "the overlay contract broke" and files a
   flipped default or a changed status code under `### Breaking` in a **minor**.
   The 1.x additive-only habit for public wire behaviour is why this needs a
   Breaking note and an announced release before it, not a different number.
   A major would train operators to pass `--allow-major` for a change that
   breaks no overlay.
2. **Who actually breaks?** Not an attacker: a well-meaning client that attaches
   a stored token to every call, including calls to public content (a static-site
   build, a server-side fetcher, a mobile app). It used to get published content
   and now gets a `401`. Verscienta's sites are production consumers and may do
   this.

## Decision

- The flip stays in a **minor**, as `### Breaking`, with the release note below.
- Every stale-bearer request emits `[:kiln_cms, :api, :invalid_bearer]` whether
  or not it is refused, with `enforced`, `surface`, `read?` and `reason`
  (`expired` / `malformed` / `invalid`) and no token, user or address. `read?`
  (a `GET`/`HEAD`, or anything on `/gql`) is the proxy for "a public route that
  never needed the token"; whether a route is public is a policy question the
  plug cannot answer. This lets an operator count the callers a release would
  break, and the same data says how many are still sending a stale token while
  the one-release escape hatch (`KILN_API_REJECT_INVALID_BEARER=false`) is open.
- The check covers only pipelines that load a JWT (`/api/*`, `/gql`). Public
  HTML, `/preview`, `/api/auth/*` and `/api/openapi` still ignore a stale token,
  so this is not "all bearer tokens are validated". `kiln_…` API keys already
  returned `401` when invalid.

## Considered and rejected

- **A response header (`x-kiln-token-status`) while the flag is off.** It helps
  only during the one release the flag is off, and the default is now on.
- **Gating the flip on a telemetry threshold.** Written and reconsidered: the
  flag shipped a release ahead of the flip, as 0012 specified, and the escape
  hatch covers a client that cannot be fixed in time. A threshold nobody was
  collecting for would have been a gate in name only.
- **Never flip**, **a major**, **a per-organisation setting**: the first
  contradicts 0012, the second misreads `releasing.md`, the third needs a
  migration for a behaviour no tenant asked to vary.

## Interaction with #2273

Headless services use `kiln_…` keys (ADR 0012), which already `401` when
invalid, so the lenient path left was the user-JWT one: a human or browser
credential. 0012 names the hazard for a draft-write key: a typo in the secret
should not read as a successful public request. Had #2273 gone the OIDC route,
a failing external-issuer JWT would have hit this same path; it did not, so the
two decisions are separable.

## Release-note wording

> **Breaking: a bearer token that does not verify now returns `401`.**
> `/api/*` and `/gql` used to treat an expired, revoked or malformed
> `Authorization: Bearer` JWT as an anonymous request and return the published
> content. They now return `401 invalid_token`. A client that attaches a stored
> token to every request, including requests for public content, will start
> failing once the token expires: drop the header, or sign in again, on a `401`.
> API keys (`kiln_…`) are unchanged. Count affected requests with the
> `[:kiln_cms, :api, :invalid_bearer]` telemetry event. To buy time set
> `KILN_API_REJECT_INVALID_BEARER=false`; the variable is removed in the next
> release.

## Amendment (2026-11-10): the escape hatch's removal is gated on the count

[#2318](https://github.com/The-Verscienta/kiln_cms/issues/2318). The reasoning
above rejects gating the *flip* on a telemetry threshold. It does not cover
removing `KILN_API_REJECT_INVALID_BEARER`, which has not happened, and that
removal is gated:

- **Signal.** `[:kiln_cms, :api, :invalid_bearer]` events with `enforced: false`
  and `read?: true`: stale tokens still reaching public reads while the hatch is
  open. (Only an operator who set the variable to `false` produces
  `enforced: false`, so the count is read on the instances that use the hatch.)
- **Who reads it.** kilncms.dev and the Verscienta sites (production consumers)
  report the count before the release that removes the variable.
- **Fallback.** If the count is not zero when the removal release arrives, the
  hatch stays one more release, and this record is amended again; the same check
  is repeated before the release after. The telemetry only informs the
  release-note wording if removal is eventually forced.

Read `enforced: true` alongside it: those are the `401`s actually served, which
say whether removal hurts anyone. `enforced: false` alone is zero by
construction on an instance that never set the hatch, so zero there is not
evidence about stale clients elsewhere. Core attaches no handler or metric to
the event; the reporting sites attach their own (`:telemetry.attach/4`).

The `/gql` `401` body (#2318) is now GraphQL-shaped and keeps `code:
"invalid_token"` beside `extensions.code: "unauthenticated"`, so a client that
read the old envelope's `code` still matches; the case-insensitive scheme match
also turns a `bearer <jwt>` that used to be served as anonymous into a `401`.
Both go under Breaking in the release note.

This changes the "removed in the next release" wording in the release note
above and in ADR 0012's table: removal is *planned* for the next release and
happens only when the count is zero.

