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
- Each user carries a set of `audiences`, assigned by an admin via
  `:manage_access` — **or granted by an active paid membership** (#337 Phase 2),
  through a system-only recompute. Never self-service either way.
- Audiences resolve **per organization** (`KilnCMS.Accounts.Scoping.audiences/2`,
  applied by `KilnCMS.CMS.Checks.InAudience`): a member's
  `OrgMembership.audiences` for the site being served; `[]` for an actor
  affiliated elsewhere but not here (**fail-closed**, since the org comes from a
  client-controlled host); the global `User.audiences` column only for accounts
  with no memberships at all (pre-#336 data and single-org installs).
- A published record is readable when its audience is `:public`, **or** its
  audience is one the reader holds *on that org*. Editors/admins see everything.

So the content read row below is `:public`-published for anonymous/viewer;
audience-restricted published rows additionally require membership.

Two non-role actors also appear below:

- **anonymous** — no actor (`authorize?: true` with no `actor:`); the public site / headless API.
- **system** — trusted internal callers running with `authorize?: false` (the delivery controller recording views, the webhook delivery worker, the AshOban scheduler). System calls bypass policies entirely and are intentionally *not* expressible as a role.

Legend: ✅ allowed · ❌ forbidden · 🔎 allowed but row-filtered (reads return only the rows the policy permits, never an error) · ⚙️ system-only (`authorize?: false`).

## Content — `Page`, `Post`, `Entry` (`KilnCMS.CMS.Content` macro)

`Entry` is the dynamic-content-type resource; it is generated from the same
macro and so carries an identical policy stack. Everything below applies to all
three, and to any content type a downstream project defines.

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

## Version history — `Page.Version`, `Post.Version`, `Entry.Version` (`KilnCMS.CMS.VersionPolicies`)

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read | ✅ | ✅ | ❌ | ❌ |
| `create`, `update`, `destroy` | ✅* | ❌ | ❌ | ❌ |

\* `forbid_if always()` blocks manual create/update/destroy for every non-admin
role; the admin `bypass` technically permits it, but in practice versions are
written only by AshPaperTrail as a side effect of content actions
(`authorize?: false`).

## Taxonomy — `Category`, `Tag`, `TagGroup`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `by_slug`) | ✅ | ✅ | ✅ | ✅ |
| `create`, `update` | ✅ | ✅ | ❌ | ❌ |
| `destroy` | ✅ | ❌ | ❌ | ❌ |

Taxonomy is world-readable because published content references it on the public
/ headless frontends.

Destroying a `TagGroup` does not destroy its tags — `tags.tag_group_id` is
nilified, so they fall back to "Ungrouped" in the editor's picker.

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

## Mail settings — `Mail.Settings`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `init`, `generate_dkim`, `rotate_dkim`, `configure_key_source`, `set_server_ip`, `record_verification` | ✅ | ❌ | ❌ | ❌ |

Instance-wide mail/DKIM configuration (`/editor/mail`) is admin-only. The
delivery pipeline resolves the DKIM key as the **system**
(`authorize?: false` via `KilnCMS.Mail.dkim_config/0`), as does the lazy
singleton creation (`ensure_settings!/0`, reached only from the admin page).

## Bounce suppression — `Mail.SuppressedRecipient`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `suppress`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Managed from `/editor/mail` (admin-only). The delivery pipeline writes
suppressions on a hard bounce and consults them before queuing as the
**system** (`authorize?: false`). As with reads elsewhere, a non-admin read is
filtered to nothing rather than erroring, so the list never leaks.

## Custom fields — `FieldDefinition`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_type`) | ✅ | ✅ | ❌ | ❌ |
| `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Defining the schema (fields per content type) is admin-only; editors read
definitions so the content editor can render the inputs. Both the editor and the
`ApplyCustomFields` write change read definitions as the **system**
(`authorize?: false`).

## Analytics — `ContentView`, `ContentViewDay`, `SearchQuery`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`top`, `in_window`, `zero_result`) | ✅ | ✅ | ❌ | ❌ |
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

## Platform accounts — `Organization`, `OrgMembership`, `Role`, `ApiKey`, `Passkey`, `UserIdentity`

These five resources gate on the **platform** role
(`actor_attribute_equals(:role, :admin)`), not on `OrgAdmin` — they are the
tenant registry and the credentials that sit above any one tenant, so "admin"
here means platform admin.

`Organization` — no `destroy` action exists; organizations are deliberately not
deletable.

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `by_slug`, `by_custom_domain`) | ✅ all | 🔎 own memberships | 🔎 own memberships | ❌ |
| `create`, `update` | ✅ | ❌ | ❌ | ❌ |

`OrgMembership`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_user`, `for_org`) | ✅ all | 🔎 own rows | 🔎 own rows | ❌ |
| `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

The read grants above are why both resources scope their deny to write actions
only: Ash AND-combines every applicable policy, so a bare `policy always()`
would hard-forbid the self-read rather than filter it.

`Role` (per-org role definitions):

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_org`), `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Scoping resolution itself reads roles as the **system** (`authorize?: false`).

`ApiKey`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_user`), `create`, `revoke`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Minting returns the plaintext key exactly once; only the SHA-256 hash is stored.
Sign-in looks the key up through the AshAuthentication interaction bypass.

`Passkey`:

| Action | admin | editor / viewer (own) | editor / viewer (other) | anonymous |
|--------|:-----:|:---------------------:|:-----------------------:|:---------:|
| read (`read`, `for_user`) | ✅ all | 🔎 own credentials | 🔎 filtered out | ❌ |
| `destroy` | ✅ | ✅ (own) | ❌ | ❌ |
| `register`, `bump_usage` | ⚙️ | ⚙️ | ⚙️ | ⚙️ |

`register` and `bump_usage` are `forbid_if always()` — the WebAuthn ceremony
code writes them as the system.

`UserIdentity` — every action is forbidden to every role; only
AshAuthentication's own OAuth machinery passes, via its interaction bypass.

## Forms — `Form`, `FormField`, `FormSubmission`

`Form`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| `active_by_slug` (read) | ✅ | ✅ | ✅ | ✅ |
| read (`read`) | ✅ | ✅ | ❌ | ❌ |
| `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

`active_by_slug` is the public render path — it is what lets an anonymous
visitor load a form. Building forms is an admin concern, like webhooks and field
definitions.

`FormField`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_form`) — parent form `active` | ✅ | ✅ | ✅ | ✅ |
| read (`read`, `for_form`) — parent form inactive | ✅ | ✅ | ❌ | ❌ |
| `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Anonymous reads stay open because fields render on public forms, but they now
mirror the parent's visibility rather than being unconditional: the read policy
filters on `form.active == true`, so the fields of an inactive form are no
longer readable directly (#565 — previously the `active` flag was enforced only
*where forms are fetched*, not on this resource).

One policy covers every read action deliberately. The public render path is
`Forms.get_active/2`, which loads `[:fields]` as an anonymous but **authorized**
read — and a relationship load runs the resource's primary `:read`, not
`:for_form`. A narrower per-action grant would leave that load matching an
editors-only policy and render the form with no fields at all, silently: a load
filters rather than raises.

`FormSubmission`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `recent_for_form`), `create`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Submission contents are visitor-provided data, frequently PII — admin eyes only.
The public submit path validates and then writes as the **system**.

## Redirects & branding — `Redirect`, `SiteBranding`

| Resource | read | writes |
|---|---|---|
| `Redirect` (`read`) | ✅ everyone incl. anonymous | admin only (`create`, `destroy`) |
| `SiteBranding` (`read`) | ✅ everyone incl. anonymous | admin only (`save`, `update`, `destroy`) |

Both are public information by design — delivery serves the same redirect map to
anyone who hits an old URL, and branding tokens render on every public page.
Both reads are tenant-scoped, so a request sees only its own site's rows. The
slug-change hook that writes redirects runs as the **system**.

## Code injection — `SiteCodeInjection` (#490)

| Resource | read | writes |
|---|---|---|
| `SiteCodeInjection` (`read`) | ✅ everyone incl. anonymous | admin only (`save`, `update`, `destroy`) |
| `SiteCodeInjection.Version` (`read`) | admin only | ❌ nobody (system-written, never destroyed) |

The row's contents are served verbatim to anonymous visitors, so the read policy
says they are public rather than pretending otherwise. The **history** is not:
"what the site serves now" and "who put it there, and what it said last week"
are different questions with different audiences, so the version twin is
org-admin only and has no writable action at all.

Writes are the tightest surface in this table for their size — this is stored
XSS by design, so an org admin writing it is the whole authorization model. The
second half of that model is not a policy: `KilnCMSWeb.Plugs.CodeInjection` runs
only in the `:delivery` pipeline, so the snippet can never render in the editor
console. See [code-injection.md](code-injection.md).

## Content types — `TypeDefinition`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `by_name`, `archived`) | ✅ | ✅ | ❌ | ❌ |
| `create`, `update`, `destroy` (soft), `restore` | ✅ | ❌ | ❌ | ❌ |

Admins own the schema; editors read definitions so the editor UI can list
dynamic types. Mirrors `FieldDefinition`.

## Compliance — `Consent`, `HistoryAnchor`, `DocumentEvent`

`Consent`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_content`), `record` | ✅ | ✅ | ❌ | ❌ |
| `destroy` | ✅ | ❌ | ❌ | ❌ |

There is no `update` action — consent records are corrected by recording a new
one, not by editing history.

`HistoryAnchor` — every action (`read`, `for_content`, `create`) is admin-only;
there is deliberately no destroy. The publish pipeline writes anchors as the
**system**.

`History.DocumentEvent`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_document`) | ✅ | ✅ | ❌ | ❌ |
| `append`, `anonymize_actor` | ⚙️ | ⚙️ | ⚙️ | ⚙️ |

Writes are `forbid_if always()` for every role — the event log is append-only
through the History API as the system, and has no destroy action at all.

## Automation & newsletter

`Automation.Rule`, `Newsletter.Subscriber`, `Newsletter.Segment`,
`Newsletter.SegmentMembership`, `Newsletter.NewsletterSend` all carry the same
single policy: `authorize_if OrgAdmin` on every action. Admin-only across the
board; editors, viewers and anonymous callers get nothing.

The public newsletter flows (`subscribe`, `confirm`, `unsubscribe`) and the send
pipeline run as the **system** behind signed-token checks. The two token reads
(`by_confirm_token`, `by_unsubscribe_token`) declare `multitenancy :bypass`
deliberately — the token is the secret, and the confirming visitor has no
tenant context.

## Delivery internals — `PublishedArtifact`, `ReferenceEdge`, `BlockEmbedding`

| Resource | read | `create` / `update` / `destroy` |
|---|---|---|
| `Firing.PublishedArtifact` | ✅ whoever may read the **source document** | ❌ **everyone, incl. admin** |
| `Firing.ReferenceEdge` | ✅ editor / admin | ❌ **everyone, incl. admin** |
| `Search.BlockEmbedding` | ✅ editor / admin | ❌ **everyone, incl. admin** |

These three have no bypass of any kind: the firing engine and the search indexer
write them as the **system**, so no caller-facing write path exists.

All three used to read `authorize_if always()`. That was tightened in #565, and
the reason it was safe is that every production reader is a system path
(`authorize?: false`): `Firing.Delivery` / `Firing.Engine.read/4` for artifacts,
`Firing.References` for the re-fire wave, `Search.BlockIndexer` /
`Search.BlockSearch` / `Search.Related` for embeddings. What changed is what an
*actor-carrying* caller sees.

`PublishedArtifact` is the one that mattered: it holds the **rendered body** of a
document, so a blanket grant meant the audience axis enforced on `Content` was
not re-enforced one tier down — paid, gated content was readable in artifact
form. Its read now runs `Firing.Checks.DocumentReadable`, a manual (runtime)
check that re-reads the source document under the caller's own authorization and
keeps only the artifacts whose document came back. It **delegates** to the
content policy instead of restating it, for two reasons: `document_type` is
polymorphic (`:page`, `:post`, `:entry` for every dynamic type) with no
relationship to join through, and a denormalized `audience` column would lag the
document, because firing is asynchronous. Editors short-circuit the check.

The other two are enumeration surfaces — the link graph (including edges from
unpublished drafts) and `ancestor_context` block text from every indexed
document, drafts included — so they are simply editor-and-up.

## Webhook deliveries — `WebhookDelivery`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `recent`), `create`, `record_attempt`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Delivery history is admin-only. The delivery pipeline writes attempts as the
system, and the `prune_deliveries` AshOban trigger runs under the
`AshObanInteraction` bypass.

## The API-key axis

Role and audience are not the only axes. An actor authenticated by a `kiln_…`
API key carries an immutable **access scope**, and two checks gate on it:

| Check | Matches |
|---|---|
| `KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess` | an API-key actor whose key is *not* `:read_write` — i.e. a `:read` key, or any key whose record cannot be inspected (**fails closed to read-only**) |
| `AshAuthentication.Checks.UsingApiKey` | *any* API-key actor, regardless of scope |

Applied as `forbid_if` clauses placed **before** the `OrgAdmin` bypass, so a key
minted on an admin account cannot skip them:

| Resource | `create` / `update` | `destroy` | `purge` (hard delete) |
|---|---|---|---|
| `Page`, `Post`, `Entry` | forbid `ApiKeyWithoutWriteAccess` | forbid `ApiKeyWithoutWriteAccess` | forbid **any** API key |
| `MediaItem`, `Tag`, `TagGroup`, `Category` | forbid `ApiKeyWithoutWriteAccess` | forbid **any** API key | — |
| `Tagging`, `ContentLink` | forbid `ApiKeyWithoutWriteAccess` (all write types) | — | — |

The net rule: a `:read` key may read whatever its owner may read and write
nothing; a `:read_write` key may author as its owner; **no** key may hard-delete
anything, whoever owns it.

## Block field policies — `editable_by`

A third, finer axis sits *inside* the block tree. A `Kiln.Block` field may
declare `editable_by: [roles]` (`Kiln.Block.Policy`); absent that, any editor
may edit it, and admins may edit everything. Today `KilnCMS.Blocks.Quote`
declares `field :featured, editable_by: [:admin]`.

Enforcement is at the resource boundary, not in the UI:
`KilnCMS.CMS.Changes.EnforceBlockFieldPolicy` runs on every content create and
update, so the write API's `block_tree` argument, MCP tools and GraphQL
mutations are all covered — not just the editor form, which additionally filters
the fields it renders. An existing block (matched by id) may keep whatever value
it already had; a new block must carry the field's declared default.

Omitting a restricted field is not the same as setting it to its default, and
used to be treated as if it were: a **wholly id-less** tree that leaves the
field out now fails when any stored block of that type holds a non-default
value, rather than silently clearing it (#566). The remedy the error names is
to send each block's id — a tree carrying ids is judged block by block as
before, so inserting a new block beside a restricted one is unaffected.

Nested children of a `columns` block are raw maps rather than union members, so
they carry no identity at all and are held to the stricter default-value rule.
See residual risk 8 in [`threat-model.md`](threat-model.md) for what this does
and does not guarantee — in particular that reusing another block's id is a
separate, still-open hole.

## Coverage

Every resource registered in `:ash_domains` appears above.
`test/kiln_cms/policy_coverage_test.exs` fails the build if a resource is ever
added without `Ash.Policy.Authorizer` and a `policies` block — the failure mode
that matters, since a resource with no authorizer is not merely unprotected but
silently world-writable.
