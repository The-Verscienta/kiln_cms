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
| **Temporary tier** (`granted_role`) | a *higher* tier that expires on its own, on the membership or the user | Temporary tiers |

Each scope axis lives on the org membership (`KilnCMS.Accounts.OrgMembership`),
on its custom role, and on the user; the effective value resolves
membership → role → user, first non-empty wins (for `field_grants`, per type:
the first level that has the type's key wins, even with `[]`). Admins bypass
the scope axes.
Everything is managed per org at **`/editor/team`** (platform admins only); the user-level
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
type means no per-field restriction. An **empty list** is a restriction, not
its absence: `%{"post" => []}` lets the editor change *no* field of an
existing post (creating posts and running workflow verbs still work).

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
- `custom_fields` as a bare key grants every custom field, as before. A
  single custom field, a group or one sub-field of a group is granted with a
  dotted key (`custom_fields.<name>`), and the private ones can also be hidden
  from an editor: see
  [Per-custom-field grants and read restrictions](#per-custom-field-grants-and-read-restrictions).
- **Version restores require full field access**: `restore_version` rewrites
  the whole document from a snapshot (via force-changes the param inspection
  can't see), so any editor under a field grant for the type is refused the
  verb outright. So is an editor with a read restriction on the type (below):
  a restore would overwrite the values they cannot see.
- Grant maps resolve **per type key** across the levels (membership → role →
  user): an override for one type never discards another level's restriction
  on a different type. A key falls through only when it is absent; a `[]` at
  the membership stops resolution there, so it overrides a role's list for
  that type.

## Per-custom-field grants and read restrictions

Custom fields (see [extending-content.md](extending-content.md)) can be granted
one at a time, and a private custom field can be hidden from some editors.
Both live on the same three levels as the other axes (membership, custom
role, user; the first level that names the type wins), and both apply to
editors only: admins are exempt, and so are system and actor-less writes.

### Write: `field_grants` keys

An entry in a type's `field_grants` list can be:

| Entry | Lets the editor change |
|---|---|
| `custom_fields` | every custom field (the original grant, unchanged) |
| `custom_fields.<name>` | that one top-level field |
| `custom_fields.<group>` | a whole group field, including adding, removing and reordering its rows |
| `custom_fields.<group>.<sub>` | that one sub-field, in every row of the group |

Field names are lower-case letters, digits and underscores, starting with a
letter, so the dot is unambiguous. Saving a role with a malformed entry
(`custom_fields.Name`, `custom_fields.a.b.c`) is refused, instead of silently
granting nothing. Whether the name is a real field is not checked at save: a
stale name is shown as "(not found)" in the pickers. Link fields are not
granted on their own (they ride on the reference they belong to), and computed
fields are never written by anyone.

- **Only the keys the editor changes are judged.** Re-sending a stored value,
  in whatever spelling the form uses, is not a change, so saving a document
  whose other fields are out of the editor's reach works. A change outside the
  grant is refused with "custom_fields.price cannot be changed: outside your
  field grant for this content type" (the key named is the one that failed).
- **Creates are held to the keys too, but only for a role that lists a
  `custom_fields.*` entry.** A key outside the grant may carry only its
  default on a new document. A role with just the bare `custom_fields` key (or
  none) keeps the old rule: creating a document is ungoverned.
- **A hidden field cannot be written** (below), on a create or an update.

### Read: `field_read_grants`

`field_read_grants` is a map of type to the private custom fields the editor
may see, with the same type keys as `field_grants`:

```elixir
%{
  field_grants: %{"post" => ["title", "custom_fields.summary"]},
  field_read_grants: %{"post" => ["custom_fields.internal_notes"]}
}
```

- A type with no key is unrestricted. `[]` hides every private field of the
  type. `"custom_fields"` shows all of them, and `custom_fields.<name>` one.
- **A field the editor may write is always readable.** Reading is implied by
  the write grant.
- **Only top-level `private: true` fields can be restricted.** A field that is
  not private is world-readable on published content, cached anonymous
  responses and fired artifacts, so hiding it from one role would promise
  something Kiln cannot deliver. Group sub-fields cannot be private, so they
  cannot be hidden (they can still be write-granted).
- **A read-granted field can't stop being private.** Switching it to public in
  the field definition is refused ("can't be turned off while a role or
  member's read grant for this type names the field"); remove it from the role
  or member first. Saving a read grant that names a field that exists but is
  not private is refused too ("... is not a private custom field of ...").
- **The editor does not see a hidden field anywhere**: not in the document
  form, the content list's columns, filter, sort and CSV/JSON export, version
  history and diffs, nor in JSON:API, GraphQL and MCP responses (mutation
  responses included). Filtering or sorting on a hidden name answers like an
  unknown field. A restricted editor's save leaves hidden values exactly as
  stored.
- **A field they can read but not change is shown read-only** in the editor
  ("Your role can see this field but not change it."). This now also applies to
  an editor holding an old whole-attribute grant that omits `custom_fields`.
- **Version restore is refused** for an editor with a read restriction on the
  type, with the same message as for a field grant.
- **Duplicates, translations, copies and imports** carry only the custom
  fields the actor may write; hidden and unwritable values are left out.
- **Known limit: a hidden required field blocks creating.** If a private field
  that is `required` is hidden from the editor, their create, copy or import
  of that type fails validation, because they cannot supply the value.
  Either make the field optional, or let that role read it.

**Actor-less surfaces are unaffected, and need not be.** Fired artifacts,
webhooks, the change feed, RSS and the `kiln_reporting_v1` SQL views read as no
Kiln user and already leave out every `private` field
(see [reporting.md](reporting.md)), so a read restriction only narrows *which
editors* see a private field.

### Restrict custom fields on a role

Start on `/editor/team` as a platform admin, in the **Custom roles** section,
on a role (or **Edit** on a member) whose type has custom fields. A private
custom field must exist on the type for the read picker to appear.

1. Open the type's row under **Field grants** and choose **Only these fields**
   in **Fields of Post** (for example).
2. Under **Individual custom fields**, tick the fields they may change. A
   group's own box lets them add, remove and reorder its rows; the indented
   boxes beneath it change one sub-field in every row. Leave all of them
   unticked and tick **Custom fields (all of them)** for the old all-or-nothing
   grant.
3. Below, in **Custom fields they can read**, choose **Only these private
   fields** and tick the private fields they may see (or **All private
   fields**). **None of them** hides every private field; on a role the first
   choice is **All private fields** (no restriction), on a member it is the
   inherit choice.
4. Click **Add role** on a new role, or **Save** on an existing role or
   member. The role's row summarises the scope, for example
   `fields: Post: title, custom_fields.summary · can read: Post: custom_fields.internal_notes`.

| Message | Meaning |
|---|---|
| "Pick at least one field, or choose None of them." | **Only these private fields** with nothing ticked. |
| "... is not a valid field name for ..." | A `field_grants` or `field_read_grants` entry is malformed. |
| "... is not a private custom field of ..." | A read grant names a field that is not private. |
| "custom_fields.<name> cannot be changed: outside your field grant for this content type" | What the editor sees when they change a field outside their grant. |

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

**Team UI.** `/editor/team` (platform admins only; an admin of one site is sent
to the access-denied page) manages the current org's members —
add by email (an address with a confirmed account is added, any other is
[invited](account-administration.md#invite-someone-to-a-site)), set tier / custom role / per-member scope
overrides, grant a temporary tier, remove — and its custom roles. The three
scope axes are set with pickers (#2141): content types are ticked from the
site's own list, and each content type's field grant is a choice between no
restriction, **Only these fields** and **No fields**. Roles and memberships
themselves are changed by platform admins only (`/editor/team`'s policies, as
in [memberships.md](memberships.md)).

What the pickers store:

| Picker choice | Type axis stores | Field grant for the type stores |
|---|---|---|
| **No restriction from this role** (role) / **Inherit (custom role, then account)** (member) | `[]` | no key |
| **Only these types** / **Only these fields** | the ticked list | the ticked list |
| **No fields (can't change existing documents)** | — | `[]` |

- **Only these…** with nothing ticked is refused, never saved as `[]`: on a
  type axis `[]` means *no restriction*, so an empty pick would silently widen
  the axis to every type.
- Built-in types are ticked one by one. Every custom (dynamic) type is one
  choice, **Custom content types (all of them)**, stored as `"entry"`,
  because `editable_types` and `readable_types` still group them under that
  key. Field grants list each custom type on its own row, under its own name.
- The fields offered for a type are the ones its edit actions accept, named
  the way enforcement compares them (`title` and `blocks` cover the working
  copy too; `custom_fields` is the grant for all custom fields, and the
  individual custom fields are listed beneath it, see below). Developers
  can read the same list from
  `KilnCMS.CMS.Changes.EnforceFieldGrants.grantable_fields/1`.
- A saved form is **merged onto the stored value**: a stored type name, grant
  key or field name this site no longer recognizes is shown marked
  "(not found)" with its current state and kept on save; unticking it removes
  it. A role saved without any change is not written at all (the page says
  "No changes."), because every role update drops the live connections of
  everyone holding the role.
- On a member, **Only these…** *replaces* the custom role's list or grant for
  that axis or type — it can widen past the role — and **No fields** overrides
  the role's grant. Under **Inherit**, the form shows what currently applies:
  "Currently inherited: …", taken from the custom role picked in the form, else
  the account.

### Scope a custom role

Start on `/editor/team` as a platform admin, in the **Custom roles** section.

1. In the new-role form, type a **Name** (for example "Blog editor") and an
   optional **Description**.
2. Under **Content types they may edit**, choose **Only these types**. The
   site's content types appear as checkboxes; tick **Post**.
3. Under **Content types they may read in the editor**, leave
   **No restriction from this role**, or choose **Only these types** and tick
   the types whose drafts members should see. Types they may edit are always
   readable.
4. Under **Field grants**, open the row for **Post** (under **Built-in**). In
   **Fields of Post**, choose **Only these fields** and tick **Title** and
   **Blocks**. To stop members changing a type's existing documents at all,
   choose **No fields (can't change existing documents)** instead.
5. Click **Add role**. The page says "Role added.", and the role's row
   summarises its scope, for example
   `edit: post · fields: Post: title, blocks`.
6. Assign the role to members: click **Edit** on a member, pick it under
   **Custom role**, and click **Save**.

The role above stores:

```elixir
%{
  editable_types: ["post"],
  readable_types: [],
  field_grants: %{"post" => ["title", "blocks"]}
}
```

To change it later, click **Edit** on the role's row, change the pickers, and
click **Save**.

### Override one member's scope

1. On `/editor/team`, click **Edit** on the member's row.
2. Each axis starts at **Inherit (custom role, then account)**, with
   "Currently inherited: …" showing what applies now. Choosing a different
   **Custom role** in the same form updates that line.
3. Choose **Only these types** (or, on a field-grant row, **Only these
   fields** or **No fields**) for the axis to override, tick the values, and
   click **Save**. The page says "Saved."

### When the pickers refuse a save

| Message | Meaning |
|---|---|
| "Pick at least one type, or choose No restriction from this role." | A role's type axis is on **Only these types** with nothing ticked. |
| "Pick at least one type, or choose Inherit." | The same, on a member. |
| "Pick at least one field, or choose No fields." | A field-grant row is on **Only these fields** with nothing ticked. |

A refused save writes nothing: the other axes keep their stored values too.

An editor held to a field grant sees "cannot be changed: outside your field
grant for this content type" on a field outside it, and any grant on a type
(including **No fields**) refuses restoring an old version of it: "restoring
a version requires full field access for this content type".

The accounts it can add from — every registration on the instance, with the
platform role, password resets and account removal — are at `/editor/accounts`:
see [Account administration](account-administration.md).

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
- a membership that is not `:active` (a registration [awaiting approval](account-administration.md#approving-registrations),
  or rejected, #2251) grants **no tier** on its org, and still makes the
  account affiliated.

So `/editor/team`'s tier select now *governs*: an org can promote a global
viewer to site editor, or demote a global editor to site viewer, without
touching their other sites.

## Temporary tiers (shipped)

Either tier — the site tier on a membership, or the platform role on the user —
can be granted for a bounded window: "editor on this site until Friday". Two
columns carry it, `granted_role` and `granted_role_expires_at`, and the standing
`role` is never overwritten, so expiry is a comparison rather than a scheduled
write. A loaded `role` is always the standing tier; `Scoping.effective_tier/2`
and `Checks.PlatformAdmin` apply a live grant through
`KilnCMS.Accounts.RoleGrant.effective_role/1` at the moment they decide.

Grant a site tier from `/editor/team` (on the member's Edit panel) and a platform
role from `/editor/accounts`. A grant carries **no scope axes** — it moves the
tier only, leaving `editable_types`, `readable_types`, `field_grants` and the
custom role exactly as they were.

The member's row on `/editor/team` leads with the tier that applies on the site
now, and while a grant is live a line under it says until when and what it
returns to ("Editor is temporary: until …, then Viewer."). See
[See which role applies now](account-administration.md#see-which-role-applies-now).

Full rules: [Account administration](account-administration.md).

## Later phases

- **Per-dynamic-type `editable_types`** (that axis still groups every dynamic
  type under the `entry` key; `field_grants` became per-type in #927).
- Strict tenancy (`global?: false`) — #419 PRs 2–3.
