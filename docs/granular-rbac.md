# Granular RBAC

Kiln's editorial roles are `:admin` / `:editor` / `:viewer`. Granular RBAC
([issue #332](https://github.com/The-Verscienta/kiln_cms/issues/332)) adds a
finer authoring axis on top: an editor can be scoped to **specific content
types**, so a blog editor can't touch marketing pages.

## What Phase 1 does

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

Read access is **not** scoped in Phase 1 — an editor still *sees* all content
(the read policy is unchanged); only *authoring* is restricted. Publishing stays
admin-only as before.

## Managing it

`editable_types` is set by an admin via the `:manage_access` action (alongside
`role` and `audiences`) — today through AshAdmin (`/admin`) or the console,
exactly like role assignment:

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

**Read-axis scoping (slice 2).** `readable_types` (same shape and defaults as
`editable_types`, on both the user and the membership) scopes **editorial
visibility**: for types outside a non-empty scope, an editor no longer sees
drafts/in-review/archived content — they read those types like any signed-in
consumer (published, audience-gated). Published visibility is never narrowed;
the consumer-facing audience axis is untouched. Enforced by one policy check,
`KilnCMS.CMS.Checks.ReadableContentType`, replacing the editors-see-everything
grant in the Content macro's read policy. Set via `:manage_access` (user) or
the membership, like the other axes.

## Phase 2, slice 3 (shipped) — per-field write grants

`field_grants` (user + membership, same membership-wins resolution) maps a
content-type name to the attribute names an editor may **change** on existing
documents of that type — `%{"post" => ["title", "blocks"]}`. No entry for a
type means no per-field restriction. Enforced by one generic change,
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
  `editable_types`; grants refine stewardship of existing content.
- `custom_fields` is granted as a whole attribute; per-custom-field keys
  (`custom_fields.<name>`) are a possible later refinement.

## Later phases

- **Custom roles + `/editor/team` UI** (slice 4) — see the design note on
  [#332](https://github.com/The-Verscienta/kiln_cms/issues/332).
- **Per-dynamic-type** scoping (today all dynamic types share the `entry` key).
