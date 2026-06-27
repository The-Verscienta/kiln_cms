# Authorization Policy Matrix

KilnCMS authorizes every resource action through `Ash.Policy.Authorizer`. This
document is the per-resource reference for **who may do what** — the source of
truth is each resource's `policies do … end` block; this table mirrors it and is
backed by the policy test suite (`test/kiln_cms/**/​*_policies_test.exs` plus
`policies_test.exs` / `version_policies_test.exs`).

## Roles

The `role` attribute on `KilnCMS.Accounts.User` (`lib/kiln_cms/accounts/user.ex`)
has three values:

| Role      | Intent                                                            |
|-----------|-------------------------------------------------------------------|
| `:admin`  | Full access. A `bypass` clause on every resource short-circuits all checks. |
| `:editor` | Authors content, manages taxonomy/media, runs draft→review transitions. |
| `:viewer` | Default on registration. Reads published content only; no authoring. |

### Audiences (the read axis)

`role` gates **authoring**. A separate, orthogonal **audience** axis gates which
signed-in end-users may *read* a published record — the consumer-facing access
model (cf. Directus "Professional"/"Patient" access). Configured via
`config :kiln_cms, :audiences` (`KilnCMS.CMS.Audiences`); `:public` is always
implied.

- Each content record carries one `audience` (default `:public`).
- Each user carries a set of `audiences` (`KilnCMS.Accounts.User`), assigned by
  an admin via `:manage_access` — never self-service.
- A published record is readable when its audience is `:public`, **or** its
  audience is one of the reader's audiences. Editors/admins see everything.

So the content read row below is `:public`-published for anonymous/viewer;
audience-restricted published rows additionally require membership.

Two non-role actors also appear below:

- **anonymous** — no actor (`authorize?: true` with no `actor:`); the public site / headless API.
- **system** — trusted internal callers running with `authorize?: false` (the delivery controller recording views, the webhook delivery worker, the AshOban scheduler). System calls bypass policies entirely and are intentionally *not* expressible as a role.

Legend: ✅ allowed · ❌ forbidden · 🔎 allowed but row-filtered (reads return only the rows the policy permits, never an error) · ⚙️ system-only (`authorize?: false`).

## Content — `Page`, `Post` (`KilnCMS.CMS.Content` macro)

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `search`, `by_slug`, …) | ✅ all | ✅ all | 🔎 published + audience | 🔎 published + `:public` |
| `create`, `update` | ✅ | ✅ | ❌ | ❌ |
| `submit_for_review` | ✅ | ✅ | ❌ | ❌ |
| `unpublish` | ✅ | ✅ | ❌ | ❌ |
| `archive` | ✅ | ✅ | ❌ | ❌ |
| `restore_version` | ✅ | ✅ | ❌ | ❌ |
| `publish`, `publish_scheduled` | ✅ | ❌ | ❌ | ❌ |
| `return_to_draft` | ✅ | ❌ | ❌ | ❌ |
| `destroy` (soft-delete), `purge` (hard) | ✅ | ❌ | ❌ | ❌ |
| `trashed` (read), `restore` (untrash) | ✅ | ❌ | ❌ | ❌ |

`publish_scheduled` is additionally allowed for the **system** AshOban scheduler
via `bypass AshOban.Checks.AshObanInteraction`.

## Version history — `Page.Version`, `Post.Version` (`KilnCMS.CMS.VersionPolicies`)

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read | ✅ | ✅ | ❌ | ❌ |
| `create`, `update`, `destroy` | ✅* | ❌ | ❌ | ❌ |

\* `forbid_if always()` blocks manual create/update/destroy for every non-admin
role; the admin `bypass` technically permits it, but in practice versions are
written only by AshPaperTrail as a side effect of content actions
(`authorize?: false`).

## Taxonomy — `Category`, `Tag`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `by_slug`) | ✅ | ✅ | ✅ | ✅ |
| `create`, `update` | ✅ | ✅ | ❌ | ❌ |
| `destroy` | ✅ | ❌ | ❌ | ❌ |

Taxonomy is world-readable because published content references it on the public
/ headless frontends.

## Join tables — `Tagging`, `ContentLink`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read | ✅ | ✅ | ✅ | ✅ |
| `create`, `update`, `destroy` | ✅ | ✅ | ❌ | ❌ |

Read is open so published content can load its tags/related links; linking and
unlinking is an editing action. `Tagging` has no domain code interface (it is
managed through `manage_relationship` on the content resources).

## Media — `MediaItem`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read | ✅ | ✅ | ✅ | ✅ |
| `create`, `update` | ✅ | ✅ | ❌ | ❌ |
| `destroy` (soft), `purge` (hard) | ✅ | ❌ | ❌ | ❌ |
| `trashed` (read), `restore` (untrash) | ✅ | ❌ | ❌ | ❌ |

Media is world-readable because published content embeds it (featured images,
inline assets).

## Webhooks — `WebhookEndpoint`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Endpoint configuration is admin-only. The delivery worker reads endpoints as the
**system** (`authorize?: false`).

## Custom fields — `FieldDefinition`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_type`) | ✅ | ✅ | ❌ | ❌ |
| `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Defining the schema (fields per content type) is admin-only; editors read
definitions so the content editor can render the inputs. Both the editor and the
`ApplyCustomFields` write change read definitions as the **system**
(`authorize?: false`).

## Analytics — `ContentView`, `SearchQuery`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`top`, `zero_result`) | ✅ | ✅ | ❌ | ❌ |
| `record` | ⚙️ | ⚙️ | ⚙️ | ⚙️ |

`record` is `forbid_if always()` for every role — view/search counts are written
only by the **system** delivery path (`authorize?: false`). Reading aggregates is
editor/admin only (privacy-first: no per-user data is stored anyway).

## Accounts — `User`, `Token`

`User` (`lib/kiln_cms/accounts/user.ex`):

| Action | admin | editor / viewer (self) | editor / viewer (other) | anonymous |
|--------|:-----:|:----------------------:|:-----------------------:|:---------:|
| read | ✅ all | 🔎 own record | 🔎 filtered out | ❌ |
| `change_password` | ✅ | ✅ (own) | ❌ | ❌ |
| auth flows (sign-in, register, reset) | ✅ | ✅ | ✅ | ✅ (AshAuthentication bypass) |

Field policy: the `role` field is visible only to **admins or the user
themselves**; other readers see the record without `role`.

`Token` — every action is gated to the AshAuthentication interaction bypass; there
are no caller-facing token actions.
