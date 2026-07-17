# Granular RBAC (Phase 1)

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

## Phase 2

- **A team-management UI** (`/editor/team`) so admins assign roles + type scope
  without AshAdmin.
- **Read-axis scoping** and **per-field** permissions.
- **Per-dynamic-type** scoping (today all dynamic types share the `entry` key).
- **Custom roles** — named bundles of permissions defined in the admin (the
  fuller Directus-style model).
