# 0013. The invalid-bearer default flips on evidence, not on the calendar alone

- **Status** — accepted (2026-11-06), refining [ADR 0012](0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)
  ("The #2161 commitment"). The 14-day / 0.1% gate and the versioning reading
  below are still to be confirmed by the maintainer.
- **References** — [#2161](https://github.com/The-Verscienta/kiln_cms/issues/2161),
  [#2273](https://github.com/The-Verscienta/kiln_cms/issues/2273).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

A request whose `Authorization: Bearer <jwt>` does not verify (expired, revoked,
malformed, or its user deleted) is served as an **anonymous** request: a `200`
with the published subset. The client holding the stale token is never told it
was signed out. `KILN_API_REJECT_INVALID_BEARER` (in `KilnCMSWeb.Plugs.ApiKeyAuth`)
turns that into a `401` on `/api/*` and `/gql`; it is off by default.

ADR 0012 commits to **flipping that default on in the release after the flag
ships**, keeping the flag as an escape hatch for one more release, and says not
to leave the flag in place indefinitely. This record does not reopen the
commitment. It says what has to be true before the flip, because the commitment
names a date and not the thing the date is standing in for.

The principal breakage of the flip is not the attacker case. It is a
**well-meaning client that attaches a stored token to every call, including calls
to public content that never needed it** (a static-site build, a server-side
fetcher, a mobile app). Today it silently gets published content; after the flip
it gets a hard `401` for something it was entitled to read anonymously.
Verscienta's sites are production consumers and may do exactly this.

Scope of the flip: the check runs only in pipelines that load a JWT
(`loads_bearer: true`: `/api/*` and `/gql`). Public HTML delivery, `/preview`,
`/api/auth/*` and `/api/openapi` still treat a stale token silently, so the flip
does **not** mean "all bearer tokens are validated". `Bearer kiln_…` API keys
already `401` when invalid and are out of scope.

## Which versioning rule governs

`docs/releasing.md` defines **major** as "the overlay contract broke" and files a
flipped default or a changed status code under `### Breaking` in a **minor**. The
repo also works under an additive-only convention for public wire behaviour in
1.x, and a new `401` on an existing route is not additive.

Reading adopted: **the additive-only convention is why the flip needs a Breaking
note and an evidence gate; `releasing.md` still decides the number.** The flip
ships in a minor. A major would train operators to pass `--allow-major`
reflexively for a change that breaks no overlay, and waiting for 2.0 would leave
0012's commitment unmet.

## Options

**A. Flip in the minor after the flag ships, as `### Breaking`, flag kept as an
escape hatch** (0012's commitment). Fast. Without evidence it is a guess, and
the installs we cannot observe get only the release note.

**B. Flip in a major.** Not available under `releasing.md` (above).

**C. Never flip; keep opt-in forever.** Zero regression risk, but the outside
audit's #2161 finding stays accepted, and 0012 already rejects it.

**D. Per-organisation setting.** The env var is already per deployment. A
per-org column needs a migration for a behaviour no tenant has asked to differ
on; rejected unless telemetry shows one tenant cannot be fixed.

**E. Warn in-band, never refuse.** Keep the `200` and add a response header so
a client can detect staleness. Additive, and meets the issue's actual complaint
without the public-route regression. It does not remove the silent downgrade, so
on its own it is not enough, but it is cheap and ships with the flag.

**F. Per-surface default.** Splits the contract for no stated reason; rejected
unless the evidence shows one surface carries all the stale traffic.

## Decision

**E now, then A on evidence.** Both land with the flag, so the flag's release
already tells operators and clients what is coming:

1. `x-kiln-token-status: invalid` on a response served to a stale bearer while
   the flag is off. One fixed word (no reason, so it is not an oracle), with
   `vary: authorization`; a request with a credential is never anonymous to
   `PublicCache`, so the header cannot reach a shared cache entry.
2. `[:kiln_cms, :api, :invalid_bearer]` fires with the flag on or off and carries
   `enforced`, `surface` (`json_api` / `graphql` / `media` / `other`), `read?` (a
   `GET`/`HEAD`, or anything on `/gql`; whether a route is public is a policy
   question the plug cannot answer, so this is the nearest cheap proxy) and
   `reason` (`expired` / `malformed` / `invalid`; revoked, deleted-user and bad
   signature cannot be told apart without a lookup). No token, user or address.
3. **The flip is made in the next minor if the evidence below clears the gate.**
   If it does not, the flip is deferred **one release at a time**, each deferral
   recorded in that release's notes with the numbers, so 0012's "do not leave it
   indefinitely" still holds: deferral is a decision someone writes down, not a
   default.

## Evidence needed before the flip

The telemetry above is built to answer these; the old bare counter could not.

1. **Collect** on kilncms.dev and every Verscienta site running the flag, for at
   least 14 days, covering a release cycle and any scheduled build.
2. **Threshold (proposed):** invalid-bearer requests with `read?: true` are under
   0.1% of API requests, and no single client accounts for most of them or each
   such client has been fixed. "Zero" is not required: a browser holding an
   expired JWT will always show some, and those clients should be told.
3. **Kiln's own clients.** Confirm `clients/js` and `kiln_client` never send a
   user JWT, and what each does on a `401` (retry, refresh, throw).
4. **CDN check.** Confirm no CDN in front of kilncms.dev or the Verscienta sites
   strips `Authorization` before the origin. If it does, the flag is invisible
   to those clients and the telemetry undercounts.
5. **Unobservable installs** get only the release note. Say so plainly in the
   note; do not claim the telemetry covers them.

## Interaction with #2273

ADR 0012 resolves #2273 as a `draft_write` **API-key** scope, not OIDC/JWT
pass-through.

- Headless services authenticate with `kiln_…` keys, which already `401` when
  invalid, so the flag concerns only user JWTs: a human or browser credential.
  That population shrinks as headless use moves to keys, which is why the flip
  can wait for evidence at little cost.
- 0012 notes that a typo in a draft-write key's secret turns a write into an
  unexplained failure on a "public" request. That is the strongest argument for
  not letting the flip slip: the key path is already strict, and the JWT path is
  the one left lenient.
- Had #2273 gone the OIDC route, an external-issuer JWT that failed validation
  would hit this same path. It did not, so the two decisions are separable.

## Upgrade-note wording (for the release that flips the default)

> **Breaking: a bearer token that does not verify now returns `401`.**
> `/api/*` and `/gql` used to treat an expired, revoked or malformed
> `Authorization: Bearer` JWT as an anonymous request and return the published
> content. They now return `401 invalid_token` with `www-authenticate: Bearer`.
> A client that attaches a stored token to every request, including requests
> for public content, will start failing once the token expires: drop the
> header, or sign in again, on a `401`. API keys (`kiln_…`) were already refused
> when invalid and are unchanged. Since the previous release, responses to such
> requests carried `x-kiln-token-status: invalid`, and the
> `[:kiln_cms, :api, :invalid_bearer]` telemetry event counts them. To keep the
> old behaviour for one more release set `KILN_API_REJECT_INVALID_BEARER=false`.

## Open questions

1. Confirm the versioning reading (a minor with a Breaking note).
2. Confirm 14 days / 0.1% as the gate, and who reads the Verscienta numbers.
