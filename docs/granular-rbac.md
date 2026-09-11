# Granular RBAC

Kiln's editorial roles are `:admin` / `:editor` / `:viewer`. Granular RBAC
([issue #332](https://github.com/The-Verscienta/kiln_cms/issues/332)) adds
finer axes on top, so a blog editor can't touch marketing pages.

**Status: shipped — Phase 1 and Phase 2 slices 1–4, plus per-org tiers
(#419).** The sections below are in the order they landed; read this summary
for the current model.

## The model today

| Axis | What it scopes | Section |
|---|---|---|
| **Tier** (`:admin`/`:editor`/`:viewer`) | the capability level, **per org** — a membership's `role` | Per-org capability tiers |
| **`editable_types`** | which content types an editor may create and update | Phase 1 |
| **`readable_types`** | which types' drafts / in-review / archived content an editor sees | Phase 2, slice 2 |
| **`field_grants`** | which attributes an editor may change, per type | Phase 2, slice 3 |
| **Custom `Role`** | a named, org-owned bundle of the three scope axes | Phase 2, slice 4 |
| **`audiences`** | which *published*, audience-gated content a consumer can read — a separate axis from editorial scope | [memberships.md](memberships.md) |

Each scope axis lives on the org membership (`KilnCMS.Accounts.OrgMembership`),
on its custom role, and on the user; the effective value resolves
membership → role → user, first non-empty wins. Admins bypass the scope axes.
Everything is managed per org at **`/editor/team`** (admin-only); the user-level
columns are the single-org fallback, set through `:manage_access`.

## Phase 1: `editable_types`

Each user has an **`editable_types`** list (on `KilnCMS.Accounts.User`) — the
content types an editor may **create and update**:

- **Empty (the default)** — no restriction; the editor may author every type.
  Existing editors are therefore unchanged.
- **Non-empty** (e.g. `["post"]`) — the editor may author only those types;
  create/update on any other type is forbidden.

Admins **bypass** this entirely (they can author any type), and viewers/anonymous
callers never gain authoring access. The type name is the resource's
`__kiln_content_type__` (`"page"`, `"post"`, project types, and `"entry"` for the
dynamic (D17) types as a group).

## How it's enforced

A single policy check, `KilnCMS.CMS.Checks.EditableContentType`, replaces the
"is an editor" authorization on the content **create/update** policy in the
`KilnCMS.CMS.Content` macro. Because every content type is built from that macro,
the scope applies uniformly to compiled and project types with no per-type code.

Phase 1 scoped authoring only; read scoping arrived with `readable_types` in
Phase 2, slice 2 (below).

## Managing it

Per org, use **`/editor/team`** (Phase 2, slice 4, below).
The user-level columns — the fallback for accounts without a membership — are
set through the `:manage_access` action (alongside `role` and `audiences`):

```elixir
KilnCMS.Accounts.manage_user_access!(user, %{editable_types: ["post"]}, actor: admin)
```

## Phase 2, slices 1+2 (shipped)

**Membership-resolved scoping (slice 1).** With multi-tenancy (#336), the
scope axes live on `KilnCMS.Accounts.OrgMembership` too, so one account can be
a blog editor on site A and unrestricted on site B. The policy checks resolve
the *effective* scope via `KilnCMS.Accounts.Scoping`: a **non-empty**
membership scope for the request's org wins; otherwise the user column applies
(the single-org fallback — existing deployments are unchanged). A tenant-less
request resolves against the default org, the same org its writes stamp.

**Affiliation is fail-closed.** A user who holds memberships gets **no**
editorial scope on an org they have no membership for — the org resolves from
the client-controlled host, so falling back to the (typically empty =
unrestricted) user column there would let a scoped editor escape their
restriction by switching hosts. Accounts with no memberships at all (pre-#336
data) keep the user-column behavior everywhere. Affiliation is memoized per
process for a few seconds, so the several checks in one request cost one
lookup.

**Read-axis scoping (slice 2).** `readable_types` (same shape and defaults as
`editable_types`, on both the user and the membership) scopes **editorial
visibility**: for types outside a non-empty scope, an editor no longer sees
drafts/in-review/archived content — they read those types like any signed-in
consumer (published, audience-gated). Published visibility is never narrowed;
the consumer-facing audience axis is untouched. Enforced by one policy check,
`KilnCMS.CMS.Checks.ReadableContentType`, replacing the editors-see-everything
grant in the Content macro's read policy **and** in the PaperTrail version
policies — a version's `changes` carry the full document snapshot, so history
follows the same scope as the document. Set via `:manage_access` (user) or
the membership, like the other axes.

Interplay with the write axis: an **explicit** `editable_types` entry implies
editorial visibility for that type (restricting reads never revokes granted
authoring), but an *empty* (unrestricted) editable scope does not widen reads
— it would dissolve every read restriction. When scoping `readable_types`,
scope `editable_types` alongside it.

## Phase 2, slice 3 (shipped) — per-field write grants

`field_grants` (user + membership, same membership-wins resolution) maps a
content-type name to the attribute names an editor may **change** on existing
documents of that type — `%{"post" => ["title", "blocks"]}`. No entry for a
type means no per-field restriction.

An **admin-defined (dynamic) type is named by its own name**, not by `entry` —
`%{"recipe" => ["title"]}` binds recipes and nothing else (#927). This differs
from `editable_types`, which still groups every dynamic type under `entry`; the
two axes are resolved by different code, and only the field axis is per-type
today. Note the failure mode this fixed: a key that resolves to nothing reads as
*no restriction*, so a grant naming a type the resolver could not match failed
**open** rather than closed. Enforced by one generic change,
`KilnCMS.CMS.Changes.EnforceFieldGrants`, on every update action in the
Content macro (not Ash `field_policies`, which gate reads — write-gating
inspects the changeset).

Deliberate semantics:

- Only **user-supplied, actually-changing** input violates — the editor form
  posts every field on save, and resubmitting unchanged values must pass.
- Workflow transitions (`submit_for_review`, …) carry no content attributes
  and pass untouched: a grant scopes *what* may be edited, not *which verbs*
  run (verbs have their own policies).
- The headless `block_tree` argument writes the `blocks` attribute, so it
  requires the `"blocks"` grant. The block tree is **one attribute** —
  sub-block grants are out of scope (`Kiln.Block.Policy`'s schema-declared
  `editable_by` covers block-field granularity in the editor).
- Relationship arguments (tags, related links) are curation, not attributes —
  ungoverned by grants.
- Creates are ungoverned: authoring a *new* document is gated by
  `editable_types`; grants refine stewardship of existing content. The one
  exception is **duplication** (`KilnCMS.CMS.Duplication`), the only create
  that carries *another record's* values: a field-granted editor's copy carries
  only the attributes their grant names (blocks only with the `"blocks"`
  grant). Two attributes are exempt — `title`, because the copy needs one to
  exist, and `audience`, because dropping it would fall back to the `:public`
  default and quietly *widen* access to a gated body. Links stay ungoverned
  there too.
- `custom_fields` is granted as a whole attribute; per-custom-field keys
  (`custom_fields.<name>`) are a possible later refinement.
- **Version restores require full field access**: `restore_version` rewrites
  the whole document from a snapshot (via force-changes the param inspection
  can't see), so any editor under a field grant for the type is refused the
  verb outright.
- Grant maps resolve **per type key** across the levels (membership → role →
  user): an override for one type never discards another level's restriction
  on a different type.

## Phase 2, slice 4 (shipped) — custom roles + `/editor/team`

**Custom roles.** `KilnCMS.Accounts.Role` is a named, org-owned bundle of the
three grant axes — define "Blog editor" once, assign it to memberships via
`role_id`. Resolution becomes membership-attribute → role-attribute →
user-column (non-empty wins at each level), so a membership can still override
its role per axis. Deleting a role nilifies assignments (members fall back to
their own scope). The capability *tier* (`:admin`/`:editor`/`:viewer`) stays
on the user — a custom role refines an editor's scope, it does not replace the
tier, and the built-ins therefore need no seeded rows: a membership without a
custom role simply has no extra restriction bundle.

**Team UI.** `/editor/team` (admin-only) manages the current org's members —
add by existing account email, set tier / custom role / per-member scope
overrides, remove — and its custom roles. Scope inputs are plain
comma-separated type lists and a JSON textarea for field grants.

## Per-org capability tiers (shipped — #419)

The membership's `role` is the member's **effective tier on that org**:
`OrgAdmin`/`OrgEditor` policy checks (resolving through the same memoized
`Scoping` affiliation) replace the global-role grants on every org-scoped
resource, and the web layer (route gates, console nav, workflow buttons)
reads `Scoping.effective_tier/2`. Semantics:

- a **platform admin** (`User.role == :admin`) keeps `:admin` everywhere —
  the operator break-glass; user/org/membership administration itself stays
  on the global role (that's where tiers are granted);
- members get their membership tier; affiliated users have **no tier** on
  orgs they hold no membership for (fail-closed, like the scope axes);
- accounts with no memberships at all keep `User.role` (pre-#336 data).

So `/editor/team`'s tier select now *governs*: an org can promote a global
viewer to site editor, or demote a global editor to site viewer, without
touching their other sites.

## Later phases

- **Per-dynamic-type `editable_types`** (that axis still groups every dynamic
  type under the `entry` key; `field_grants` became per-type in #927).
- Strict tenancy (`global?: false`) — #419 PRs 2–3.
