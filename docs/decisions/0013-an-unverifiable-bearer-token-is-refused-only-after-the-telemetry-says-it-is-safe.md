# 0013. An unverifiable bearer token is refused only after the telemetry says it is safe

- **Status** — accepted (2026-11-06): the in-band header first (E, built in the
  stacked change on #2298), then the flip (A) only if the evidence clears the gate; the versioning reading and the
  14-day / 0.1% gate below are still to be confirmed. Nothing here changes a
  default. The opt-in flag itself is in [#2298](https://github.com/The-Verscienta/kiln_cms/pull/2298)
  (default off); this record decides when, and whether, that default flips.
- **References** — [#2161](https://github.com/The-Verscienta/kiln_cms/issues/2161),
  [#2273](https://github.com/The-Verscienta/kiln_cms/issues/2273),
  [ADR 0012](0012-headless-services-get-a-draft-write-api-key-scope-not-oidc-pass-through.md)
  (on the #2273 branch; renumber at merge if another record lands first).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

A request whose `Authorization: Bearer <jwt>` does not verify (expired, revoked,
malformed, or its user deleted) is served as an **anonymous** request: a `200`
with the published subset. The client holding the stale token is never told it
was signed out. #2298 adds `KILN_API_REJECT_INVALID_BEARER` (`:reject_invalid_bearer`),
which turns that into a `401` on `/api/*` and `/gql`, and emits
`[:kiln_cms, :api, :invalid_bearer]` whether or not the flag is on. The docs say
the default is "planned to become on in a later release".

The principal breakage of a flip is not the attacker case. It is a **well-meaning
client that attaches a stored token to every call, including calls to public
content that never needed it** (a static-site build, a server-side fetcher, a
mobile app). Today it silently gets published content; after a flip it gets a
hard `401` for something it was entitled to read anonymously. Verscienta's sites
are production consumers and may do exactly this.

Scope of what a flip delivers: the plug is mounted in the `:api` and `:graphql`
pipelines only. Public HTML delivery, `/preview`, `/api/auth/*` and
`/api/openapi` still treat a stale token silently. A flip does **not** mean "all
bearer tokens are validated". `Bearer kiln_…` API keys already `401` when invalid
(`ApiKeyAuth`) and are out of scope.

## Which versioning rule governs

Two rules pull apart, and the record has to pick one.

- `docs/releasing.md` defines **major** as "the overlay contract broke" and says
  a default that flipped, or a status code that changed, is a `### Breaking`
  entry in a **minor**. By that rule a flip is minor-eligible.
- The repo also works under an "additive-only on public surfaces during 1.x"
  convention (`docs/path-forward.md`, `docs/field-level-localization.md`).
  A new `401` on an existing route is not additive.

Proposed reading: **the additive-only convention governs wire behaviour that a
conforming client could depend on; `releasing.md` governs the version number.**
A `401` for a credential that never authenticated is a change to a wire outcome,
so it needs the Breaking note and the evidence gate below, but it does not break
the overlay contract and must not bump major (that would train operators to pass
`--allow-major` reflexively). Consequence: "flip in a major" is not available
under `releasing.md`; it reduces to "wait for 2.0", which in practice means
"never" unless 2.0 is planned for other reasons.

## Options

**A. Flip in the next minor, as `### Breaking`, with the flag kept as a kill
switch.** Default on; `KILN_API_REJECT_INVALID_BEARER=false` restores today's
behaviour. Fast; relies entirely on the release note for installs we cannot
observe. Without the evidence gate it is a guess.

**B. Flip in a major.** Not available under `releasing.md` (above). Equals
"wait for 2.0".

**C. Never flip; keep opt-in forever.** Zero regression risk. Cost: the outside
audit's #2161 finding stays an accepted low-severity item, and every deployment
that wants the safer behaviour must discover the flag.

**D. Per-site setting.** The flag already is one (an env var per deployment, so
per site on a multi-install, not per organisation). A per-org column would need a
migration for a behaviour no tenant has asked to differ on; rejected unless the
telemetry shows one tenant cannot be fixed.

**E. Warn in-band, never refuse.** Keep the `200` but add a response header
(for example `X-Kiln-Token-Status: expired`) so a client can detect staleness.
Additive, and meets the issue's actual complaint ("the client never learns it was
signed out") without the public-route regression. It does not stop a revoked
token being treated as anonymous, which was never unsafe: anonymous is the
least-privileged outcome.

**F. Per-surface default.** Flip `/gql` or JSON:API alone. Splits the contract
for no stated reason; rejected unless the evidence shows one surface carries all
the stale traffic.

## Evidence needed before any flip

The current event is a bare counter with `pipeline` and `enforced` metadata. It
cannot tell a stale token from garbage, nor name the route or client. Before the
flip is decided:

1. **Enrich the event** (additive, no behaviour change; built with the header):
   `surface` (`json_api` / `graphql` / `media` / `other`), `read?` (a `GET`/`HEAD`,
   or anything on `/gql`: whether a route is public is a policy question the plug
   cannot answer, so this is the nearest cheap proxy), and `reason` (`expired` /
   `malformed` / `invalid`; revoked and deleted-user cannot be told from a bad
   signature without a lookup), and nothing user-identifying.
2. **Collect** on kilncms.dev and every Verscienta site that runs #2298:
   at least 14 days, covering a release cycle and any scheduled build.
3. **Threshold (proposed):** the flip is justified only if invalid-bearer
   requests with `read?: true` are under 0.1% of API requests and no
   single client accounts for most of them, or each such client has been fixed.
   "Zero" is not required: a browser holding an expired JWT will always show
   some, and those clients should be told.
4. **Check Kiln's own clients.** `clients/js` and `kiln_client` document `kiln_…`
   keys only; confirm neither ever sends a user JWT and what each does on a `401`
   (retry, refresh, throw).
5. **CDN check.** Confirm no CDN in front of kilncms.dev or the Verscienta sites
   strips `Authorization` before the origin. If it does, the flag is invisible to
   those clients and the telemetry undercounts.
6. **Unobservable installs** get only the release note. State that plainly in
   the note; do not claim the telemetry covers them.

## Interaction with #2273

ADR 0012 resolves #2273 as a `draft_write` **API-key** scope, not OIDC/JWT
pass-through. Two consequences:

- Headless services authenticate with `kiln_…` keys, which already return `401`
  when invalid. The flag concerns only user JWTs: a human or browser credential.
  That population shrinks as headless use moves to keys, which weakens the case
  for urgency and supports "measure first".
- Had #2273 gone the OIDC route, an external-issuer JWT that fails validation
  would hit this same path, and the flag would have become the rule for service
  tokens. It is not, so the two decisions are separable. #2161 asked for them to
  be settled together; this record settles #2161's half on that basis, and the
  `invalid_bearer?/1` helper stays available if OIDC is revisited.

## Recommendation (for the decision)

**Option E now, then Option A only if the telemetry clears the threshold.**

1. Ship #2298 as is (default off) and close the duplicate #2297.
2. Add the in-band staleness header (E) and the richer telemetry fields, both
   additive, in the same minor.
3. Collect the evidence above. If it clears the threshold, flip in the *next*
   minor after that, under `### Breaking`, with the flag retained as a kill
   switch for one further minor. If it does not, stay on C.

Never flip in a major, and never in a patch.

## Upgrade-note wording (if and when the flip ships)

> **Breaking: a bearer token that does not verify now returns `401`.**
> `/api/*` and `/gql` used to treat an expired, revoked or malformed
> `Authorization: Bearer` JWT as an anonymous request and return the published
> content. They now return `401` with `www-authenticate: Bearer`. A client that
> attaches a stored token to every request, including requests for public
> content, will start failing once the token expires: drop the header, or sign in
> again, on a `401`. API keys (`kiln_…`) were already refused when invalid and
> are unchanged. To keep the old behaviour for one more release set
> `KILN_API_REJECT_INVALID_BEARER=false`. Before upgrading, count affected
> requests with the `[:kiln_cms, :api, :invalid_bearer]` telemetry event
> (`enforced: false`).

## Open questions for the decision-maker

1. Accept the versioning reading above (minor, with Breaking note)?
2. Accept E-then-A, or choose A on a date, or C?
3. Is 14 days / 0.1% the right gate, and who reads the Verscienta numbers?
