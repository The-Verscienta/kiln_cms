# 0012. Headless services get a draft-write API-key scope, not OIDC pass-through

- **Status** — accepted; unreleased. The scope and its policy, provenance on
  token drafts and the surface audit (below) are in. Self-rotation (below,
  "Rotation") is its own change. The opt-in #2161 flag shipped in its own
  change (#2297), and its default flipped on in the release after (#2301).
- **References** — [#2273](https://github.com/The-Verscienta/kiln_cms/issues/2273);
  settles the direction of [#2161](https://github.com/The-Verscienta/kiln_cms/issues/2161);
  builds on [#330](https://github.com/The-Verscienta/kiln_cms/issues/330) (the write API).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

A headless consumer (Verscienta's app) wants to call `/api/json`, `/gql` and the
media endpoints with a credential that can do exactly two things: read what the
public may read, and submit **drafts** for a human to review. It must never be
able to publish, unpublish, schedule, archive, delete, or edit a document that
is live.

What existed could not say that. An API key authenticates AS its owning user and
inherits that user's role. `:read` is read-only. `:read_write` lets the key do
whatever its owner may, so on an editor it can publish when the site lets
editors publish, and on any account whose role is later raised it quietly gains
the new power. There was no scope between "cannot write" and "writes as the
owner".

## Decision

**A third `access` value, `:draft_write`, on the existing `ApiKey`.** A key with
that scope may create content and edit **its own drafts**, and nothing else.
The bound is a policy on `Content`, not a property of the owner:

- It is an **allowlist**. `create`; `update` and `autosave` of a row that is
  still `state == :draft` AND whose `author_id` is the key owner. Every other
  `Content` action is refused, including ones added later, because the list is
  closed rather than a set of named prohibitions. `submit_for_review` is
  refused by default: a person moves work into the review queue.
- It is enforced by a `forbid_if` placed **above** the admin/`OrgAdmin` bypass,
  the same ordering `ApiKeyWithoutWriteAccess` uses. It does not consult the
  owner's role at request time. Promoting the owner after the key was minted
  widens nothing.
- It is a **new, separately named check** (`Checks.DraftWriteKey`).
  `ApiKeyWithoutWriteAccess` is unchanged and still matches a `:draft_write`
  key, so every other resource (media, taxonomy, menus, links) refuses the key
  without having been edited. Only `Content` carves it back in. A consequence
  to keep: a draft cannot set tags, category or related links.
- Minting stays **admin-only**, with two checks that are defense in depth, not
  the control: the key's lifetime is capped (`:draft_write_key_max_ttl_days`,
  default 30), and the owner must have no editor or admin tier anywhere.

"Short-lived" is therefore a ceiling an operator sets, not a token-exchange
protocol. With a 30-day cap and admin-only minting, a person had to re-mint
the service's key every month; the next section is how a key that an admin
opted in keeps itself alive without that, and without minting anything it was
not already.

## Rotation

A `:draft_write` key may **exchange itself for a fresh one**, if and only if the
admin who minted it gave it a rotation window.

- **Opt-in, per key, with an end date.** `rotatable_until` is set at mint
  (the admin UI offers off / 90 / 180 days / 1 year), at most
  `:draft_write_key_max_rotation_days` (default 365) from mint. It is nil by
  default: a key minted without one behaves exactly as before. Only a
  `:draft_write` key may carry it.
- **`POST /api/keys/rotate`**, `Authorization: Bearer kiln_…`, empty body. A
  plain controller, not JSON:API, GraphQL or `/mcp`: `ApiKey` is on none of
  those today, and putting credential minting into the public schemas (and the
  clients generated from them) would widen them for one caller. The answer is
  `201` with the new plaintext once, `Cache-Control: no-store`, on the tight
  `:auth` rate bucket.
- **Same owner, same scope, same name, same window.** The `:rotate` action
  accepts no input at all; everything is copied from the key the actor
  authenticated with. There is nothing to narrow because `:draft_write` is
  already the narrowest scope that writes, and nothing a caller can widen.
- **The chain cannot outlive the admin's date.** The new key expires at
  `min(now + :draft_write_key_max_ttl_days, rotatable_until)` and inherits
  `rotatable_until` unchanged. After that date the key simply expires and a
  person re-mints.
- **One live key per lineage.** The presenting key is re-read under a row lock
  and revoked in the same transaction that creates its successor. Two
  concurrent rotations serialize; the second finds the row revoked and fails.
  Revoking the live key (the admin list shows it, with "Rotated from …") ends
  the lineage. `lineage_id` (the original mint's id) and `rotated_from_id`
  record it.
- **The mint rules run again.** The same `Validations.DraftWriteKey` runs on
  rotation, so an owner who has been given an editor or admin tier since the
  mint cannot rotate (`409`), and the lineage ends at its current expiry.
- **Who may run it.** `ApiKey`'s `:rotate` policy is
  `Checks.RotatableDraftWriteKey` alone: a `:draft_write` key, unrevoked,
  unexpired, inside its window. A `:read` or `:read_write` key, a JWT or
  session user, an admin, or no actor is `Forbidden`. Admins mint; they do not
  rotate. The existing admin-only policies are now scoped by action type, so a
  create action added later matches no policy and is refused.

**Rejected: a separate rotation credential an admin issues to the service.** It
is a second secret, longer-lived than the key, whose one power is minting keys,
and the service has to store it next to the key it renews. A leak of it is
strictly worse than a leak of the key. Self-rotation never produces a
credential stronger, longer-lived or differently owned than the one presented.

### Reuse detection

A leaked key with a rotation window could otherwise rotate itself until the
window closes, with the service none the wiser until its own key stops working.
So rotation follows the refresh-token rule: once a key is rotated away, nobody
should ever present it again. If somebody does, **on the rotation endpoint**,
more than **120 seconds** after it was rotated, and the presented secret
**verifies** against the revoked row (`KilnCMS.Accounts.ApiKeyReuse`):

1. every live key of the lineage is revoked (Kiln cannot tell whether the
   service or the thief holds it), and
2. every platform admin is mailed, naming the key and its owner, and it is
   logged and emitted as `[:kiln_cms, :api_key, :reuse_detected]` telemetry.

Why only the rotation endpoint: a service with several workers has requests in
flight on the old key while one worker rotates. Those 401s are expected, and
burning the lineage on them would turn every rotation into an outage. Why the
grace period: a retry after a lost `201`, or two workers rotating at once,
looks exactly like reuse a second later. Inside it the old key still gets a
plain `401` (it is revoked either way); the grace only withholds the alarm. The
cost of the rule, accepted: a service that loses the `201` has lost the new key
and must ask for a re-mint.

Every successful rotation is logged and emitted as
`[:kiln_cms, :api_key, :rotated]` telemetry. Kiln has no audit-log resource;
the key list in the admin UI is the durable record (status "Rotated", the
window, and the predecessor).

### Rotation and #2161

`/api/keys/rotate` is authenticated-only whatever `KILN_API_REJECT_INVALID_BEARER`
says: no `Authorization` header, a non-`kiln_` bearer, or a key that does not
verify is a `401` (`invalid_api_key`), never an anonymous request. The flag only
changes surfaces with an anonymous fallback, and this one has none.

## The two options

**(A) Extend API keys** (chosen). The credential is hashed at rest, revocable,
always expiring, carries the `kiln_` prefix that secret scanners match, is
already minted in the admin UI, and is already understood by `/mcp`, the bridge
socket and the revision endpoints. The new scope is one atom and one policy
block. Nothing new has to be trusted from outside.

**(B) OIDC / JWT pass-through**, where Kiln accepts the consumer's own identity
tokens. It is rejected for now, for these reasons:

- It adds an issuer, JWKS fetching and caching, claim-to-role mapping and key
  rotation to the set of things an attacker can try to confuse. Each is a place
  where "which tenant, which user, which scope" gets decided from data Kiln does
  not control.
- No requirement here needs it. Verscienta authenticates its own users; Kiln
  only ever sees the application service. Per-end-user identity reaching Kiln
  would be the trigger to revisit.
- Revocation becomes the issuer's problem and lag, where a revoked API key
  stops working on its next request (and drops its owner's open sockets).

What (B) does better is attribution of a draft to a specific end user. That is
covered more modestly: a draft created with the key records the key's id and
name and an opaque `on_behalf_of` string the service sends in the
`X-Kiln-On-Behalf-Of` header. It is stored for display and **never used for
authorization**. Who can read it is the subject of the next section.

## Who can read the provenance

The three fields (`created_via_key_id`, `created_via_key_name`, `on_behalf_of`)
are readable through JSON:API, GraphQL and `/mcp`, by **authenticated callers
only**:

- an actor in the **editor or admin tier**, by the same editorial-read check
  that lets them see unpublished content (`Checks.ReadableContentType`; an
  editor whose read scope excludes the type does not see them);
- a `:draft_write` key, for the **drafts it created itself**
  (`Checks.DraftWriteOwnProvenance`: `state == :draft` and the row's
  `created_via_key_id` is this key, so a second key on the same owner sees
  nothing of the first's).

Never for an anonymous caller, a preview-link holder, or a viewer-tier actor,
whether the row is published or a draft. A published row made through a token
keeps its provenance, still hidden from all of them.

**Mechanism: Ash field policies on exactly these three fields**, plus the
catch-all `field_policy :*` with `authorize_if always()`. Ash requires a field
policy for every field once one exists, and the catch-all is what keeps the rest
of `Content` exactly as its resource policies decide: it adds no restriction
and removes none. The alternative, a public calculation guarded by a custom
module, was rejected: it would re-implement the authorization by hand inside a
calculation, it is computed even for a refused caller unless the module checks
the actor itself, JSON:API omits calculations from a default response (so the
fields would not appear unless asked for), and `authorize?: false` reads would
compute it. Field policies are enforced by the framework on every actor-scoped
read, are already used on `User`, and fail closed.

**Cost: no query per row, and none per read.** `ReadableContentType` is a
simple check, decided once per read by the same `Scoping` tier lookup the read
policy already made (memoized per process), and `DraftWriteOwnProvenance` is a
filter check compiled into the read's own SQL. Field policies never run a
check's per-record `check/4`, so neither can go per row. Measured
with and without the block (20 rows, cold memo as in a fresh request): an
editor's `CMS.list_posts!` is 1 `posts` + 2 `org_memberships` queries both
ways, a JSON:API list or single read with any key 5, a GraphQL list 6, a page
with its 20 children 4; anonymous reads stay at 1. Wall time is unchanged
within noise. With the memo off (the test config) the policy re-resolves the
tier: +4 `org_memberships` lookups for a viewer and +8 for an editor per read,
still constant in the row count. `test/kiln_cms_web/content_field_policy_query_count_test.exs`
holds both: the counts for 1 row equal those for 20, on every surface, and
with the production memo each read issues exactly the queries above.

The attributes are therefore `public?: true`, which is what puts them on the
API schemas. What a refused caller sees:

| Surface | Refused caller |
|---|---|
| JSON:API | the key is **absent** from `attributes`, also under `?fields[post]=on_behalf_of` (a sparse fieldset naming only forbidden fields returns empty attributes, not an error) |
| GraphQL | the field is `null`, and ash_graphql adds one `forbidden_field` entry to `errors` for each such field **the query asked for**, beside the intact `data`. A query that does not select them has no error. (`forbidden_field_mode: :materialized` would remove the entries but changes the field's type to a union: a breaking change to a public schema, so not taken) |
| `/mcp` | omitted from the tool result |
| filter / sort on the field | Ash evaluates a forbidden field as `nil` in a filter, so `filter[on_behalf_of]=x` matches nothing for them: no oracle (tested) |

For a permitted caller, a row with no provenance has `null` (or the key
omitted where the serializer drops nils), the same as any unset attribute.

What does **not** carry it, by construction and by test: `ContentSerializer`
(webhook payloads, and the preview endpoint, which serves anonymous link
holders) names its fields and is unchanged; `/api/sync` reads
`PublishedArtifact`, not `Content`; reads with `authorize?: false` (search
indexing, firing, the CDN purge path) are not subject to field policies and do
not serialize these fields. **Caching:** an anonymous response is the only one
`PublicCache` stores, and it never contains the fields because an anonymous
actor is never permitted them; an authenticated response is `private,
no-store` and not ETag-validated, so a cached copy can neither carry the fields
to the wrong audience nor hide them from the right one. The `Vary:
Authorization` header already on these routes covers a cache that honours it.

Additive under 1.x: three new nullable fields on the Page/Post/Entry resources
in `docs/api/openapi.json` and `docs/api/schema.graphql` (also three filter
inputs, and the names in the `sort`/`fields` patterns). Nothing removed or
renamed; the TypeScript/Kotlin/Swift exports and `clients/` are generated from
block and custom-field definitions, not these attributes, and are unchanged.

## Threat model

| Threat | Response |
|---|---|
| **Leaked key.** The credential escapes a service's logs or repo. | It can only create and edit drafts it authored: nothing live changes, nothing is deleted, nothing is sent to review. It expires within the cap, is revocable, and has a secret-scannable prefix. The worst case is junk drafts and reading what a viewer reads. |
| **Privilege escalation through the owner's role.** The key rides an account later promoted to editor or admin. | The forbid sits above the admin bypass and ignores the role. Mint refuses editor-capable owners as a second line. A test promotes the owner after mint and shows it still cannot publish. |
| **Confused deputy.** The service is tricked into acting on a document it should not touch, or a draft is made to look human-authored. | The row condition requires the key owner to be the author, and a document with a live version or working copy is refused. Provenance marks token drafts (the creating key's id and name, and the service's opaque `on_behalf_of`) so a reviewer can tell them apart. It lives on the row only, not in version history: a key reads the history of every draft its owner authored, but the provenance of only the drafts it created, so recording it in a version would show one key's `on_behalf_of` to another key on the same owner. |
| **A new `Content` action** grants the key something nobody reviewed. | Allowlist, not denylist, and a test that enumerates every update and destroy action on `Content` and asserts the unlisted ones are refused. |
| **Another resource lacks the carve-out and is more permissive than intended.** | The other resources forbid on `ApiKeyWithoutWriteAccess`, which fails closed for any access value but `:read_write`. Media writes are refused and tested. |
| **Replay of a stolen key.** | Not prevented by the scope. Bounded by the lifetime cap and revocation. A bearer secret is replayable by design. |
| **A leaked key rotates itself forever.** | Only if an admin gave it a rotation window, and never past that window's end (at most a year from mint). Rotating revokes the presenting key, so a thief who rotates first locks the service out, and the service's next rotation attempt (after the 120-second grace) is detected as reuse: the lineage is revoked and admins are mailed. |
| **Rotation as escalation.** | The action takes no input and copies owner, scope, name and window from the presenting key; the mint-time owner check runs again. A key can only ever become an identical key with a fresh secret and a no-later end date. |
| **Spam of the review queue.** | The key cannot submit for review, so drafts do not reach a reviewer's queue until a person moves them. Request rate limiting is not changed by this record. |

Out of scope: **audience-restricted reads on behalf of a subject.** The key reads
as its owner's audiences. Serving different end users different gated content
through one key is a different feature (and wants (B)).

## The #2161 commitment

[#2161](https://github.com/The-Verscienta/kiln_cms/issues/2161) asks that an
`Authorization: Bearer` header that fails verification return 401, where today a
bad non-`kiln_` bearer silently degrades to an anonymous request. For a service
holding a draft-write key that is a real hazard: a typo in the secret turns
writes into an unexplained 403 on a "public" request and a read into a public
read. The fix is a behaviour change on public surfaces, so:

1. It ships behind an **opt-in environment flag, default off**
   (`KILN_API_REJECT_INVALID_BEARER`), in the release that introduces it. A request with no `Authorization` header stays anonymous
   either way.
2. The next release **flips the default on** (the flag remains as an escape
   hatch for one more release), with a release note in both releases.
3. This record is the commitment. Do not leave the flag in place indefinitely:
   the follow-up that flips the default is part of the work, not optional.

With the flag on, a `Bearer` header that verifies as nothing is a `401` in the
standard JSON error envelope (`invalid_token`) on `/api/json`, `/gql` and the
other `/api` routes; `Bearer kiln_…` with a bad key was already a `401` and is
unchanged. The flag is its own change and its own pull request, separable from
the scope. **Flip-default-next-release is a commitment:** the release after the
one that ships the flag changes its default to on.

**Where it stands.**

| Release | `KILN_API_REJECT_INVALID_BEARER` | Change |
|---|---|---|
| The one containing #2297 | opt-in, default **off** | added, with an Added note announcing the flip |
| The next one | default **on**; `false` restores the anonymous fallback | flipped by #2301, with an Upgrade note |
| The one after that | the escape hatch is **removed**; an unverifiable bearer is always a `401` | still to do |

Removing the escape hatch is the same kind of commitment as the flip: delete the
`reject_invalid_bearer` config and the `KILN_API_REJECT_INVALID_BEARER` read,
keep the rejection, and say so under Upgrade notes. An operator who still has
the variable set to `false` then gets the `401` like everyone else.

## Surface audit

Every way in with a `kiln_` key, checked with a real bearer in
`test/kiln_cms_web/draft_write_key_*_test.exs` and
`test/kiln_cms_web/channels/draft_write_key_sockets_test.exs`:

| Surface | Result |
|---|---|
| `/api/json`, `/gql` | create, and update of the key's own draft; everything else on `Content` refused |
| `/mcp` | `create_*` and `update_*` for own drafts; `submit_*_for_review`, `create_tag` and `create_category` are refused and not even listed |
| Media (`/api/media*`, JSON:API and GraphQL media writes) | refused, whatever the owner's role |
| Revisions (`/api/content/…/revisions`) | no history for a viewer-tier owner; restore refused |
| `POST …/preview-token` | bounded to drafts the key's owner authored, on top of the tier gate; a viewer-tier owner mints nothing |
| Bridge socket (`api_key=`) | read-only; streams published documents and the key's own drafts; the scope survives the periodic re-check |
| Collab socket | a key is not a credential for it (it takes a signed-in session's token), and the viewer-tier owner joins no room |
| `POST /api/keys/rotate` | only a `:draft_write` key with an open rotation window; issues an identical key and revokes the presenting one (`test/kiln_cms/accounts/draft_write_key_rotation_test.exs`, `test/kiln_cms_web/draft_write_key_rotation_test.exs`) |

Reads follow the owner's role like any key's: a promoted owner reads as that
role. Only writes are bounded above the role.

## Consequences

- Operators get a scope they can hand to an app service without reasoning about
  the account behind it.
- `Content` carries one more policy block and one more check module to keep in
  step with new actions; the enumeration test makes forgetting loud.
- Shipped with #2273: provenance columns (additive, nullable), the audit of
  `/mcp`, the sockets and preview endpoints against this allowlist, and the
  consumer guide. The #2161 flag is its own change.
