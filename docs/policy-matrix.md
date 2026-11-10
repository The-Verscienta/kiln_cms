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
model (cf. Directus role-based read access). Configured via
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
  client-controlled host); `[]` for an account with no memberships at all. The
  global `User.audiences` column is read by no policy: its fallback for
  membership-less accounts was removed at 1.0 (#1543), and a post-deploy job
  moves such accounts onto a default-org membership carrying it.
- A published record is readable when its audience is `:public`, **or** its
  audience is one the reader holds *on that org*. Editors/admins see everything.

So the content read row below is `:public`-published for anonymous/viewer;
audience-restricted published rows additionally require membership.

Two non-role actors also appear below:

- **anonymous** — no actor (`authorize?: true` with no `actor:`); the public site / headless API.
- **system** — trusted internal callers: workers, Oban jobs, the AshOban
  scheduler, delivery-path bookkeeping, mix tasks. Not a role, because it is
  not a person: it is either `%KilnCMS.SystemActor{}` running *under* the
  policies (see [The system actor](#the-system-actor) below — the direction of
  travel, #1402) or, still, a raw `authorize?: false` that runs around them.

  Because a raw bypass skips *every* policy on the resource, each remaining
  site is a piece of the authorization surface this matrix does not show. So
  each one has to say why it is safe, with a marker directly above the call
  (or inside it):

  ```elixir
  # authorize?: false — delivery: `:public_by_slug` filters published +
  # audience + unlock itself, and `tenant:` scopes it to this site.
  CMS.get_published_page_by_slug!(slug, locale, args, authorize?: false, tenant: org)
  ```

  The dash is `—` or `--`, and the reason must say something — at least three
  words: a delivery action whose own filter carries the published/audience/
  unlock grant, a tenant already scoped by the router, a pre-auth flow with no
  actor, a system read of display data on a self-only-read resource. "Directly
  above" means the comment block touching the statement the call is part of
  (above `x =`, a pipeline's head, a `with` clause, a `case` pattern); a
  marker above a `def ... do` does not reach into its body. A comment that
  only *mentions* a bypass (`multitenancy :bypass`, "the admin bypass above")
  justifies nothing (#1739). One marker covers one call: a second bypass
  pasted under a justified one — or a pipeline that reads and then loads —
  needs its own. `mix kiln.authz.check` (part of `mix precommit` and CI)
  fails on a site without one (#1309, #1739).

  **The gate covers all of `lib/`** (#1402). Files that predate the
  system-actor migration and still carry unexplained bypasses are listed in the
  task's `@backlog` with the exact count each one has — 129 files, 313 sites
  when that landed. It is a ratchet, not an exemption: a file with no entry
  must be clean, so new code is gated from the day it lands; a listed file may
  not gain a site; and a listed file that *loses* one fails too, with the
  number to write, because an allowance nobody maintains stops being a
  ratchet. Nothing may be added. Emptying it finishes #1402.

### The system actor

`%KilnCMS.SystemActor{}` (`lib/kiln_cms/system_actor.ex`) is the actor a worker,
an Oban job, a delivery-path bookkeeping write or a mix task passes instead of
`authorize?: false`. `KilnCMS.Checks.SystemActor` is the policy check that
admits it. The actor answers **who**, never **which org**: a system call still
passes `tenant:` explicitly and `multitenancy strategy :attribute` is untouched.

**It is not a privilege boundary against our own code** — any module that can
build a system actor could have written `authorize?: false` instead. Three
things it does buy:

1. **The grant is declared** where every other grant is, so this document can
   list it. The table below is enforced: `KilnCMS.PolicyCoverageTest` fails the
   build when a resource admits `Checks.SystemActor` without a row here.
2. **A policy added tomorrow still applies.** An `authorize_if` clause grants
   exactly the policy it sits in; a bypass (and `authorize?: false`) grants
   everything, forever, including policies that do not exist yet.
3. **Validations, changes and the tenant filter keep running**, exactly as they
   do for a person.

**Admitted with `authorize_if`, never `bypass`.** A `bypass
Checks.SystemActor` is the same standing grant `authorize?: false` gave, only
spelled differently, and it would swallow every policy declared beneath it —
including ones a later PR adds, which is the thing this exists to stop.
`PolicyCoverageTest` fails the build on a system-actor bypass. (The one
top-of-stack clause that IS right is `bypass
AshOban.Checks.AshObanInteraction` on `publish_scheduled`: there the caller
genuinely *is* the AshOban scheduler and Ash itself vouches for it from the
trigger metadata on the changeset, rather than from an actor the caller chose.
Prefer that check wherever the caller is the scheduler.)

Ash **ANDs** policies, so on a resource with a broad `action_type(:update)`
policy written for people, a second policy admitting system code changes
nothing — the broad one still refuses — and widening *it* would grant system
every update on the resource. The answer is still not a bypass: narrow the
grant inside the policy that would otherwise refuse, with `action/1` as a
check.

```elixir
policy action_type([:create, :update]) do
  authorize_if KilnCMS.CMS.Checks.EditableContentType

  # System-only actions, and only those — each to its own caller.
  forbid_unless action([:reindex_search_text, :set_embedding])
  authorize_if {KilnCMS.Checks.SystemActor, subsystem: :firing, action: :reindex_search_text}
  authorize_if {KilnCMS.Checks.SystemActor, subsystem: :search, action: :set_embedding}
end
```

For a person the first clause has already decided; for a system actor every
other action forbids at the second. Nothing is short-circuited.

**Scope is per resource, action *and* subsystem (#1747).** Every clause names
the subsystems it admits — `{KilnCMS.Checks.SystemActor, subsystem: [...]}`,
required, and a bare check fails the build — and those are the labels the
calling code builds its actor with (`SystemActor.new(:firing)`, a domain's
`system/0`). Before #1747 the check matched any system actor, so a grant one
worker needed was every worker's: admitting publishing to `Task :complete` let
the automation worker complete anyone's task. The rules the grants follow:

- **A write is admitted to exactly the subsystems whose code calls it.** When
  two writes in one clause have different callers, `action:` narrows the
  clause (`subsystem: :cms_bookkeeping, action: :complete`).
- **A read clause names every subsystem that reads through it.** An
  `action_type(:read)` grant admits those subsystems to each read action on
  the resource, and the row lists every one.
- **A label no clause names is admitted nowhere.** `:branding` and
  `:code_injection` label their resolvers' reads of a row every visitor may
  read anyway, and no grant names them.

The **Subsystems** column is the machine-readable half of each row: groups of
`` `action`, `action`: `:subsystem`, `:subsystem` `` separated by ` · `. It is
enforced in both directions. `KilnCMS.PolicyCoverageTest` fails when a clause
names a subsystem its row does not, and `KilnCMS.SystemActorScopeTest` asks Ash,
for every action on every resource below and every subsystem label in the
application, whether a system actor of that subsystem is admitted, and fails
unless the answer is exactly this column: each named subsystem in, every
other one out. `CMS.Bookkeeping` (`:cms_bookkeeping`) and `CMS.Housekeeping`
(`:cms_registry`, `:cms_settings`, `:releases`, `:promotion`) stay separate
labels because their grants barely overlap: folding them would hand the
release worker publishing's task and redirect writes, and the reverse.

The struct carries no `:id` and no `:role`, so every actor-attribute check
written for people resolves it to nothing: `Scoping.effective_tier/2` returns
`:none`, `Scoping.audiences/2` returns `[]`. A system actor can therefore only
ever be authorized by an explicit clause below — or by a branch that admits
everyone, the anonymous visitor included (published `:public` content, a
`:public` settings row, a redirect).

| Resource | Actions admitting `Checks.SystemActor` | Subsystems (per action) | Why |
|---|---|---|---|
| `Firing.ReferenceEdge` | `read`, `from_source`, `to_target`, `upsert`, `destroy` | `destroy`, `read`, `from_source`, `to_target`, `upsert`: `:firing` | The re-fire wave rebuilds a document's outgoing edges on every fire and walks them backwards to find referrers. The graph is derived from the document itself and has no caller-facing write path (`forbid_if always()` for everyone, admin included), so the fire path was the only thing the old bypass existed for. |
| `Firing.PublishedArtifact` | `read`, `for_document`, `get_surface`, `upsert`, `destroy`, `refire` | `read`, `for_document`, `get_surface`: `:delivery`, `:firing` · `destroy`, `upsert`: `:firing` · `refire`: `:overlay` | The firing engine is the only writer an artifact has ever had, and unpublish is the only destroyer. `refire` (#2048, `KilnCMS.Firing.refire/3`) is the covered way for an overlay's own code — a handler for another install's webhook, with no person behind it — to re-fire named documents, so it admits the `:overlay` label (and editors); it only queues the normal fire job, which then writes as `:firing`. On read the actor is admitted **alongside** `Checks.DocumentReadable`, not instead of it: delivery settles the audience question on the *document* first (`Firing.Delivery.resolve/5`) and then fetches the body by id, so re-running the document check there with the anonymous actor would refuse every gated page delivery had just unlocked. |
| `Firing.SyncExposure` | all (`read`, `for_documents`, `record`) | `read`, `record`, `for_documents`: `:sync` | The sync API's record of which document ids it has handed an anonymous caller (`GET /api/sync`, `KilnCMS.Firing.Sync`). A tombstone may name only an id recorded here, so the table is what keeps a never-public draft, gated or locked document out of a delta. No person has a read or write path — `forbid_if always()` for everyone, admin included. |
| `CMS.TypeDefinition` | every read (`read`, `by_name`, `archived`, `get_by_id_including_archived`) | `read`, `archived`, `get_by_id_including_archived`, `by_name`: `:cms_registry`, `:firing`, `:operator`, `:promotion` | Read-only. The fire path resolves a dynamic document's public type name and its schema.org `@type` from its definition. Writing one is still admin-only. |
| `CMS.FieldDefinition` | `read`, `for_type`, `for_definition`, `inverse_of`, `refresh_time_dependent` | `read`, `for_type`, `for_definition`, `inverse_of`: `:cms_bookkeeping`, `:cms_registry`, `:computed_fields`, `:events`, `:firing`, `:localization`, `:schema_export` · `refresh_time_dependent`: `:computed_fields` | Read-only, plus the daily computed-field refresh. `refresh_time_dependent` (`Computed.DailyRefresh`) is the scheduled action that moves `today()` formulas to the site's new day; it walks every org, so it sits ABOVE the admin bypass and admits only the scheduler (`AshObanInteraction`) and `:computed_fields` (an operator running it by hand) — no admin. It reads the computed definitions as `:computed_fields` with `authorize_with: :error`, since a refused read would freeze every countdown silently. Firing needs the field schema to turn a document's `custom_fields` values into JSON-LD, and every content write validates against it (`Changes.ApplyCustomFields`, as `CMS.Bookkeeping.system/0`, #1659, with `authorize_with: :error` — a filtered "no definitions" would drop every stored value). Field-level localization (#1327, `:localization`) reads each field's `localization` mode to know which values to share between locale variants or fill along the fallback chain. Which reverse fields a type shows (R4, `inverse_of`) is read as `:cms_registry` by `CMS.ReverseFields` — the editor, GraphQL's `referencedBy(inverse:)` and the schema export — and by `Validations.InverseName` to keep the names unique. Defining a field is still admin-only. |
| `CMS.FieldSection` | every read (`read`, `for_type`, `for_definition`) | `read`, `for_type`, `for_definition`: `:schema_export` | Read-only. How each section of a type's custom fields is laid out in the editor (#2280); the schema export reports a fieldset or tab layout as `x-kiln-section-display`, reading it as it reads the field definitions — `authorize_with: :error`, so a refused read fails the export instead of dropping the annotation. Laying out a section is admin-only. |
| `Analytics.Funnel` | the primary `read` **only** | `read`: `:experiments`, `:operator` | Funnel *definitions*, never traffic (#1659). The experiment engine resolves a `:funnel_completion` goal to its funnel's last step — delivery's cached target map (`Experiments.funnel_targets/1`) and the `:start` guard (`GoalConfigured`) — and `mix kiln.experiment` resolves `--goal-funnel SLUG`. All three read as `Analytics.system/1` and fail closed (`authorize_with: :error`): a refused read under the filter answers `[]`, which delivery would cache as "no funnel targets". Narrowed inside the `action_type(:read)` policy with `forbid_unless action(:read)`, so `FunnelStep.:for_funnel` (the builder's read) and every write stay editor/admin. No traffic resource in this domain admits the system actor. |
| `Analytics.FunnelStep` | the primary `read` **only** | `read`: `:experiments` | Loaded with its funnel (`load: :steps`) by the experiment engine's two funnel reads above; `mix kiln.experiment` resolves a funnel's id alone and does not load its steps. The builder's `for_funnel` and every write stay editor/admin. |
| `Search.BlockEmbedding` | `read`, `for_document`, `nearest`, `document_centroids`, `upsert`, `destroy` | `destroy`, `read`, `for_document`, `upsert`, `nearest_to_vector`, `nearest`, `document_centroids`: `:search` | The per-block semantic index. `Search.BlockIndexer` is the only writer it has ever had — rows are derived from the document's own block tree — and `BlockSearch` / `Search.Related` / `Organize` are its only readers. `document_centroids` (#1596) is a read in all but name — the same rows, averaged per document in SQL — and admits the same two readers as `read`, the search system actor and editors. Whether a *caller* may see a hit is decided one tier up, when the matching document is hydrated under their own authorization. |
| `Search.DocumentChunkEmbedding` | `read`, `for_document`, `nearest_to_vector`, `create`, `destroy` | `create`, `destroy`, `read`, `for_document`, `nearest_to_vector`: `:search` | Vectors over the part of a long document's `search_text` past the embedder's window (#1940). `Search.DocumentChunkIndexer` (inside `EmbeddingWorker`) and the content `:purge` are its only writers; the block leg of `Search.hybrid/3` its only reader. Rows hold no text, but read the way `BlockEmbedding` is — the search system actor and editors — and whether a *caller* may see the document a chunk points at is decided by reading the document under their own authorization. |
| `Search.TagEmbedding` | `read`, `for_tags`, `nearest`, `upsert`, `destroy` | `destroy`, `read`, `for_tags`, `upsert`, `nearest_to_vector`, `nearest_any`: `:search` | Same shape, for tag-name vectors: written by `TagEmbeddingWorker` and `Search.Related`, read by `Search.Related` only. |
| `CMS.MediaDerivative` | all (`read`, `for_item`, `record`, `destroy`) | `destroy`, `read`, `for_item`, `record`: `:media_transforms` | The bookkeeping row behind each cached on-the-fly image transform (`/media/:id/t/…`). `Media.Derivatives` is its only reader and writer: it counts an item's rows against the per-item budget, prunes the ones cut from a replaced original or around a moved focal point, and lists them for a purge. No person — admin included — reads or writes a row, and there is no API surface. Who may *see* a transform is decided on the `MediaItem`, by the transform controller's ordinary policy-checked read. |
| `CMS.MediaItem` | `read` **only**, named inside the `action_type(:read)` policy | `read`: `:publish_gate` | The alt-text publish gate (`Validations.MediaAltText`) asks which of a document's media ids are marked `decorative`. It also runs for `publish_scheduled`, whose caller is the AshOban scheduler with no actor, so it cannot read as the caller. Narrowed by `forbid_unless action(:read)`: through `library` or `search` it reads only what a stranger may (public, not quarantined), `trashed` stays admin-only, and it has no write. A refusal fails the publish closed ("alt text could not be checked"), never "not decorative". |
| `CMS.Consent` | `for_content` **only** | `for_content`: `:publish_gate` | The required-consent publish gate (`Validations.RequiredConsent`) lists one document's consents, for the same reason (the scheduler has no actor). It may not record a consent or list them all. A refusal fails the publish closed ("consents could not be checked"), never "nothing required". |
| `CMS.MediaItem` | `read`, `quarantine_expired`, `record_processing`, `release_quarantine`, `adopt_into_image_backend`, and `purge` of a **quarantined** item only | `read`, `release_quarantine`, `record_processing`, `adopt_into_image_backend`, `quarantine_expired`, `purge`: `:media` | The media pipeline, as `Media.system/0` (#1659). `VariantWorker`, `AVWorker` and `AVStripWorker` re-read the item they were enqueued for (quarantined or gated included) with `authorize_with: :error`, so a refused read fails the job rather than reading as "gone" — which for the strip would leave the upload quarantined until the reaper deleted it. The derived fields (dimensions, duration, variants, `variant_failures`) are written through `record_processing`, never `update`, so the grant cannot gate an item or touch its tags or editor fields; the strip releases through `release_quarantine`. `QuarantineReaper` scans every site through `quarantine_expired` (a `multitenancy :bypass` read, admitted to the system actor **alone** by a policy above the admin bypass) and purges; the strip purges an upload it refuses. `purge` is admitted only while `quarantined == true`: a released item may be in use, and deleting it stays an admin act. The regeneration scan reads with `authorize_with: :error` too. `mix kiln.media.adopt_image_backend` (`Media.Adoption`, #1955) scans the same way and writes through `adopt_into_image_backend`, which only sets the image backend, key and URL of a row Kiln holds no file for (a row imported by URL) — never one it already stores or one a backend already holds. Not admitted: `update`, `update_metadata`, the soft `destroy`, `trashed`, `restore`, `increment_downloads`. |
| `CMS.Form` | `read` **only** | `read`: `:forms` | The form pipeline, as `Forms.system/0` (#1659). `NotificationWorker` and `AutoresponderWorker` re-read the form a submission was queued for, active or not, with `authorize_with: :error`: a refused read would filter to "form deleted" and the mail would silently never go out, so it fails the job instead. Building, editing or deleting a form stays admin-only. |
| `CMS.FormField` | `for_form` **only** | `for_form`: `:forms` | The submission is validated against the form's fields; `AutoresponderWorker` and the autoresponder-template validation (`Forms.Autoresponder.definitions_for_form/4`, which a seed or template instantiation reaches with no editor session) read them too. Every one runs with `authorize_with: :error`: a refused read filtering to `[]` would accept a submission with every required field skipped and every value dropped. |
| `CMS.FormSubmission` | `create` **only** | `create`: `:forms` | `Forms.submit/3` records a visitor's validated submission. Visitor data stays admin eyes only: the system cannot read a submission back, re-mark it or delete one. The retention prune is the AshOban trigger's own bypass, unchanged. |
| `CMS.SiteEmbedSettings` | `read` **only** | `read`: `:forms` | The embed route resolves a site's framing default on a visitor's request (`Forms.EmbedPolicy.org_default/1`). The read runs with `authorize_with: :error`, and a failure resolves to `[]` (same-origin only) — never to "no row", which would inherit the deployment's `EMBED_ORIGINS`, wider than a site default of `[]` it may be hiding. Saving the default stays an admin act. Granted through `OrgSettings`' `system_actions:` option. |
| `Accounts.ThrottleCounter` | `prune` **only** | `prune`: `:operator` | The shared auth budgets' counter table (#1619). The scheduled prune deletes closed windows; the actor is admitted so an operator or a test can run it by hand. The budgets are charged by `Accounts.ThrottleStore` in raw SQL before anyone is authenticated, so no action serves that path. `read` is forbidden to everyone, admin included: a count per hashed key is an oracle nobody needs. |
| `Accounts.Organization` | `read` **only** | `read`: `:accounts` | The tenant registry (#1659). `Accounts.list_org_ids/0` is the tenant list behind every all-orgs sweep (AshOban's per-tenant scheduler scans, GDPR erasure, audit verification, the digests), and `Accounts.default_org/0` is the default-org fallback. Both read with `authorize_with: :error`, so a lost grant raises (or answers `:error`) instead of filtering to `[]`, which every sweep would have read as "no orgs, nothing to do". Narrowed inside the member-read policy with `forbid_unless action(:read)`: `by_slug` and `by_custom_domain`, the request path's tenant resolution, are not admitted, and creating or editing an org stays platform-admin. |
| `CMS.ExternalLink` | `read`, `observe`, `record_check`, `destroy` | `destroy`, `read`, `observe`, `record_check`: `:links` | The outbound link checker's bookkeeping (#474, #1659), as `Links.system/0`. `Links.Sweep` upserts each occurrence it finds in published content, prunes the rows it no longer sees and reads which URLs are due; `Links.CheckWorker` reads a URL's failure count and writes the verdict to every row sharing it. Every existing action is named, inside the editor read policy and the admin write policy, so one added later is not admitted by default. The reads that back a decision fail closed: the failure-count read and the due-URL stream run with `authorize_with: :error` (a refused read would filter to "pruned" or "nothing due"), and a refused `observe` aborts the sweep before its prune, which would otherwise delete every row and its failure count. The report page reads as the viewing editor, not as the system. |
| `CMS.SiteLinkCheck` | `read`, `record_sweep` **only** | `read`, `record_sweep`: `:links` | The sweep and the check worker read whether outbound checking is on (re-read immediately before each request), and the sweep stamps `last_swept_at`. The read runs with `authorize_with: :error` and any error resolves to "disabled", the closed direction for a switch that authorizes egress. The settings form's `save` is not admitted: turning checking on stays an admin act. Granted through `OrgSettings`' `system_actions:` option. |
| `Automation.Rule` | reads (`read`, `matching`) **only** | `read`, `matching`: `:automation` | `KilnCMS.Automation.RuleWorker` re-reads the rule it was enqueued for, and `Automation.dispatch/3` matches an event against the site's rules; that match fails closed (`authorize_with: :error`), so a refused read fails the dispatch job rather than dropping every rule. Authoring a rule is still admin-only — the grant is narrowed to reads inside the existing `policy always()` with `forbid_unless action_type(:read)`. |
| `Social.Account` | `read`, `enabled_for_provider`, `record_post` **only** | `read`, `record_post`: `:social` · `enabled_for_provider`: `:automation` | The announcer lists a provider's enabled accounts for a publish, `Social.configured?/1` asks whether any is enabled, and the announcer stamps "last posted" (`record_post`, which accepts no attributes) on the account it posted as (#1659). Minting, editing or deleting the credentials for a site's public voice stays an admin act, narrowed the same way. |
| `Social.Post` | `claim`, `succeed`, `fail`, `unresolved`, `skip` **only** | `claim`, `succeed`, `fail`, `unresolved`, `skip`: `:social` | The announce ledger (`Social.system/0`, #1659). The claim is written before the provider is called and its unique index is the "announce once" guarantee; a refused claim is a Forbidden that posts nothing, never "already announced". No read and no `destroy`: a deleted claim would free the dedupe key for a second post. |
| `CMS.WebhookEndpoint` | `read`, `record_delivery_success`, `record_delivery_failure` **only** | `read`, `record_delivery_success`, `record_delivery_failure`: `:webhooks` | The dispatch scan and the delivery worker read endpoints (`Webhooks.system/0`, #1659), and the worker keeps the health counters behind auto-disable. Creating, editing or deleting an endpoint stays an admin act. Both reads pass `authorize_with: :error`: a refused scan would read as "no endpoint subscribed" and a refused lookup as "endpoint deleted", so a lost grant is logged (and, in the worker, retried) instead. |
| `CMS.Propagation` | `read`, `completed_since`, `open_since`, `open`, `settle_cdn`, `complete` **only** | `read`, `settle_cdn`: `:webhooks`, `:cdn` · `completed_since`, `open_since`, `open`, `complete`: `:webhooks` | Propagation records (#1927): the fan-out opens one per publish or withdrawal, the delivery worker settles it, and the CDN purge worker records the purge half. Settling stays with `:webhooks` because it counts the record's deliveries, and a count under an actor the ledger refuses reads zero. Reads pass `authorize_with: :error`. `destroy` is not admitted; the prune trigger runs under its own `AshObanInteraction` bypass. |
| `CMS.WebhookDelivery` | `read`, `create`, `record_attempt`, `mark_recovered` **only** | `read`, `create`, `record_attempt`, `mark_recovered`: `:webhooks` | The delivery ledger: dispatch writes the row, the worker re-reads it (failing closed: a refused read is retried, not taken for "pruned"), records each attempt, and stamps a lost retraction recovered once a later one reaches the endpoint (#1926). `destroy` is not admitted; the prune trigger runs under its own `AshObanInteraction` bypass. |
| `Mail.Settings` | `read`, `init` **only** | `read`, `init`: `:mail` | The DKIM signer and DNS checks read the singleton with no actor of their own, and `ensure_settings!/0` inserts the empty row (`Mail.system/0`, #1659). The read fails closed: `nil` would read as "no DKIM key" and send unsigned. Changing the key or the server IP stays platform-admin. |
| `Mail.SuppressedRecipient`, `Mail.SiteSuppressedRecipient` | `read`, `suppress` **only** | `read`, `suppress`: `:mail` | The pipeline looks every recipient up before queuing and records a hard bounce on the list of the relay that reported it (`Mail.system/0`, #1659). The lookup passes `authorize_with: :error`: a refused read would otherwise be "not suppressed" and resume mail to dead addresses, so `enqueue!/2` drops the recipient and logs, and the newsletter worker retries. Clearing a suppression (`destroy`) stays an admin act. |
| `CMS.Comment` | `add`, every read | `read`, `for_content`, `unresolved_for_content`, `for_document`, `unresolved`, `for_block`: `:automation`, `:notifications` · `add`: `:automation` | An editorial-intelligence reaction posts its findings as a document-level comment (#946) on a thread it must be able to read. No `author_id` is stamped — the actor has no `:id` — so `created_by_rule_id` carries the provenance. `update` is **not** admitted: automation posts, it does not edit what anyone said. |
| `CMS.Task` | `assign`, every read, and of the updates `complete` and `mark_overdue_notified` **only** | `read`, `open_for_content_kind`, `for_content`, `for_block`, `open_for_content`, `for_assignee`, `open_due_between`, `due_within`, `newly_overdue`: `:automation`, `:cms_bookkeeping`, `:notifications` · `assign`: `:automation` · `complete`: `:cms_bookkeeping` · `mark_overdue_notified`: `:notifications` | The same reaction assigns findings as a task, and the lifecycle sweep probes for an open review before opening another. `AssigneeIsEditor` still vets the assignee (validations run whatever the actor is) and `creator_id` stays unstamped. A publish completes the record's open tasks (`Changes.AutoCompleteTasks`, as `CMS.Bookkeeping.system/0`, #1659) — a scheduled publish has no person to do it as — reading them with `authorize_with: :error`, so a refused read fails the publish instead of leaving them open. The task digest (`Notifications.TaskDigestWorker`, as `Notifications.system/0`, #1659) reads due and newly overdue tasks with `authorize_with: :error`, since a refused read would read as "nothing due" and the digest would stop without a word, and it writes the "`task.overdue` already fired" stamp in the same transaction as the event's dispatch, as an atomic claim that refuses a row another run already stamped. Both updates are named inside the `action_type(:update)` policy with `forbid_unless`: assigning, editing or reopening a task stays an editor's. The notifier also reads a comment thread's participants from `CMS.Comment`'s existing `read` grant, with `authorize_with: :error`. Each update goes to its own caller only (#1747): automation, which opens tasks, cannot complete one — the refusal #1659 had to relax while the check matched any system actor. |
| `Accounts.PushSubscription` | `read`, `for_users`, `for_user`, `touch_delivered`, `destroy`, `forget_on_takeover` **only** | `destroy`, `read`, `for_users`, `touch_delivered`: `:push` · `for_user`, `forget_on_takeover`: `:invitations` | Web Push delivery (#628, #1659) as `Push.system/0`: the sender's lookup (`for_users`), the worker's reload by id (`read`), the "last delivered" stamp, and pruning a device its push service reported gone. The two reads fail closed with `authorize_with: :error`, because a refused read would filter to "no devices" and drop every push without a word; the sender logs the refusal and the worker returns an error for Oban to retry. `for_user` (the settings list) and `bound_to_key` (the site-key rotation sweep) are not admitted for `:push`. Accepting an invitation over an unconfirmed account (#2453, `Changes.ForgetPriorCredentials`) lists that account's devices with `for_user` and removes each with `forget_on_takeover`, as `:invitations`; `forget_on_takeover` is declared above the platform-admin bypass too, so no person may call it. `subscribe` is authorized against the device's own user (`relating_to_actor(:user)`) rather than bypassed, so no actor other than a platform admin (the resource's top-of-stack bypass) can register a device for somebody else. The key-rotation sweep (`CMS.Changes.DropVapidSubscriptions`) deletes the rotated key's rows through the same `destroy` grant. |
| `CMS.ContentLink` | every read (`read`, `backlinks`, `references_from`, `references_to`), `create`, `destroy`, `set_position` | `read`, `backlinks`, `references_from`, `references_to`: `:cms_bookkeeping` · `create`, `destroy`, `set_position`: `:cms_bookkeeping` | Reference edges (#1594). Every content write whose live `custom_fields` moved reconciles the record's `kind: :reference` edges with what its `:reference` fields store (`Changes.SyncReferenceLinks` → `ContentLinks.reconcile/1`, as `CMS.Bookkeeping.system/0`): it reads the record's own edges through `references_from` with `authorize_with: :error` (a refused read would look like "no edges" and duplicate them) and creates and deletes the difference. The write may be a scheduled publish of a working copy or an unpublish folding one, with no person behind it. The same write reads the edges pointing at each target it adds through `references_to`, to hold a field's `max_sources` (R1b), and a purge reads the edges pointing at the purged record to apply each field's `on_target_delete` (R5) — both with `authorize_with: :error`, since a refused read would pass the cap or skip the rule. The nightly purge's `:purgeable` read (`Preparations.SkipRestrictedTargets`) reads the `:restrict` fields' edges the same way, through `read`, to leave out the records it would only be refused. Curated links stay an editor's to write. Their order is the one exception (#2025): after a content write that set the related list as a whole, `Changes.OrderRelatedLinks` → `ContentLinks.order_related/2` reads the record's `kind: :related` links through `read` and writes each moved one's `position` through `set_position`, which accepts nothing else — the write may again be a scheduled publish of a working copy. The general `update` is not admitted. |
| `CMS.RelatedLink` | `read`, `create`, `destroy` | `read`, `create`, `destroy`: `:localization` | Curated related content (#2025) stays an editor's to write, with one exception: field-level localization's copy of a **shared** related list (#1859, `I18n.Changes.ApplySharedFields`, inside `:sync_shared_fields`). The copy lists the translation's own `kind: :related` rows with `authorize_with: :error` (a refused read would look like "no links" and duplicate every one), destroys the ones the shared list no longer names and creates the missing ones, each target already resolved to its variant in the translation's locale. It writes the rows directly rather than through `manage_relationship`, which would look the targets up as the actor, and the system actor reads content only as an anonymous visitor would. Their order is then written as `:cms_bookkeeping` (`ContentLinks.order_related/2`, the `CMS.ContentLink` row above). |
| `CMS.Tagging` | `create`, `destroy` | `create`, `destroy`: `:localization` | Linking and unlinking a tag is an editing action, with one exception: field-level localization's copy of a **shared** tag set (#1859). `:sync_shared_fields` relates the source variant's tag ids to the translation through the `tags` `manage_relationship` (`I18n.Changes.ApplySharedFields`), which creates and destroys `Tagging` rows as the `:localization` system actor. It never updates one. Reading taggings and tags is open to everyone already. |
| `CMS.Redirect` | `create`, `destroy` | `destroy`, `create`: `:cms_bookkeeping` | A rename of a published record's address leaves a 301 behind and retires any redirect squatting on the new one (`Changes.RecordSlugRedirect`, as `CMS.Bookkeeping.system/0`, #1659). The rename is an editor's; writing a redirect by hand stays an admin act. A refused create fails the rename, so a published URL is never vacated without its 301. `read` is world-readable already. |
| `CMS.ReleaseItem` | `mark_cancelled` **only** | `mark_cancelled`: `:cms_bookkeeping` | Archiving a release that never shipped frees its pending items (`Changes.CancelPendingReleaseItems`, as `CMS.Bookkeeping.system/0`, #1659). The archiving editor may not reach a `mark_*` write — they rewrite what rollback restores from — so the pending items are read as the editor, with `authorize_with: :error` (a refusal must not archive the release with its items still reserving their content), and marked cancelled as the system. The other `mark_*` writes stay the release worker's. |
| `CMS.FormSpamSettings` | `read` **only** | `read`: `:cms_bookkeeping` | The submission scorer (`Changes.ScoreFormSubmission`, as `CMS.Bookkeeping.system/0`, #1659) reads the site's disallowed keywords for an anonymous visitor. With `authorize_with: :error`, and a read error no longer answers `[]`: either raises, so a submission is refused rather than stored unscored. Saving the list stays an admin act. Granted through `OrgSettings`' `system_actions:` option. |
| `CMS.ContentRelease` | `read`, `abandon`, `mark_published`, `mark_failed`, `mark_rolled_back`, `mark_rollback_failed` **only** | `read`, `mark_published`, `mark_failed`, `abandon`, `mark_rolled_back`, `mark_rollback_failed`: `:releases` | The release go-live and rollback worker (`CMS.Releases`, `CMS.Workers.ReleaseWorker`, #1659) re-reads the release it was enqueued for, records the outcome, and abandons its own claim when a run crashes. The four `mark_*` writes carry no other policy, so no person, admin included, may stamp a release `:published` that never published. `read` is narrowed to the plain action (not `editable`, `by_state`, `in_window`), and `abandon` sits inside the admin policy with `forbid_unless action(:abandon)`: scheduling, starting and shipping a release stay an admin's decision. |
| `CMS.ReleaseItem` | `for_release_with_status`, `mark_applied`, `mark_skipped`, `mark_rolled_back` **only** | `mark_applied`, `mark_skipped`, `mark_rolled_back`, `for_release_with_status`: `:releases` | The same worker lists a release's pending (or applied) items and records what it did to each, including the `prior_state` / `prior_version_id` rollback restores from; no person may write those. The item read fails closed (`authorize_with: :error`): a refused read would otherwise be an empty release, marked `:published` having published nothing. Composing a release (`add`, `set_action`, `cancel`) stays editor work. The *content* steps of a claimed release still run `authorize?: false`, since the system actor holds no content grant. |
| `CMS.SiteEditorialSettings` | `read` **only** | `read`: `:cms_settings` | `Checks.EditorMayPublish` asks whether editors may publish from inside the publish (whose caller may be the scheduler), and `TaskSettings.site_default/1` asks whether publishing completes tasks from a release's go-live. Both fail closed: a refusal answers "editors may not publish", and raises rather than applying the shipped task default. `save` is not admitted. Granted through `OrgSettings`' `system_actions:` option. |
| `CMS.SiteSafetyFields` | `read` **only** | `read`: `:cms_settings` | `Changes.RecordChangeSeverity` reads which fields of a content type are safety-relevant on every live edit, publish and restore, whose caller may be the scheduler, an API key or an importer. With `authorize_with: :error`; a failed or refused read lists every field (a severity recorded that was not strictly needed), never none. `save` is not admitted: what counts as safety-relevant stays an admin act. Editors read it. Granted through `OrgSettings`' `system_actions:` option. |
| `Billing.Settings` | `read`, `init` **only** | `read`, `init`: `:billing` | The checkout path and the webhook receiver resolve provider credentials with no actor of their own, and `ensure_settings!/0` inserts the empty singleton on first use. Narrowed inside the existing platform-admin policy; the write path to payment credentials stays platform-admin, and every secret column is vault-encrypted and `sensitive?`. |
| `Billing.Membership` | every read, `apply_provider_state`, `anonymize` | `read`, `for_user`, `entitling_for_user`, `all_for_user`, `by_subscription`, `by_customer`, `stale`: `:accounts`, `:billing`, `:newsletter` · `apply_provider_state`, `anonymize`: `:billing` | A paid membership is what grants an audience and a newsletter tier segment, so the tier sync must see the ones it is syncing. The two writes are `forbid_if always()` for every person — this resource has no admin bypass — and are taken only by the verified webhook worker, the reconcile sweep and GDPR erasure. |
| `Billing.WebhookEvent` | `read` (by id), `claim`, `mark_processed`, `mark_ignored`, `mark_failed` **only** | `read`, `claim`, `mark_processed`, `mark_ignored`, `mark_failed`: `:billing` | The webhook worker re-reads its recorded event, claims it and settles it (#1659). Every write is closed to every person. `receive` stays the receiver's `authorize?: false` (a webhook has no actor; the provider's HMAC is the grant), and `destroy`, `recent`, `by_event_id` and `purgeable` are not admitted: a system actor cannot insert, list or erase a payment event. The worker's read fails closed, since `nil` would mean "event gone" and cancel the job. |
| `Billing.MembershipEvent` | every read, `append`, `anonymize_actor` | `read`, `for_membership`, `recent`: `:billing`, `:governance` · `append`, `anonymize_actor`: `:billing` | The append-only entitlement trail. No person may write one and there is no `destroy` action at all; the billing pipeline appends and GDPR erasure redacts the acting admin. The governance dashboard reads it as `Governance.system/0` (#1659), with `authorize_with: :error` so a lost grant raises rather than showing an empty trail. |
| `Backups.Run` | `read`, `running`, `by_stamp`, `start`, `skip`, `record_progress`, `finish`, `fail`, `resume`, `import`, `mark_pruned` **only** | `read`, `running`, `by_stamp`, `start`, `skip`, `record_progress`, `finish`, `fail`, `resume`, `import`, `mark_pruned`: `:backups` | The backup history (#2217). The backup's step chain (`Backups.Steps`, #2218) opens a run before any file lands, updates it as the dump, media archive and off-site copy complete and settles it (or records a refused attempt as `skip`), and re-opens a failed or interrupted run as `resume` (#2218: back to `running`, outcome cleared, guarded to a failed in-app run or a `running` one that has gone quiet; the stamp and `started_at` stay the original attempt's); `Backups.Importer` turns cron-made backups into rows (`import`, an upsert on the stamp that never touches an existing run) after checking which stamps exist (`read`); `Backups.reconcile_stale_runs/0` fails `running` runs quiet for longer than a step's timeout, measured from the later of `started_at` and `updated_at`, skipping the run the backup lock holds (`running`). All as `Backups.system/0`. The platform admin's "Resume" button writes nothing itself: it requests a backup (`Backups.request(resume: stamp)` as the admin, `platform_admin?` re-checked in the handler) and the chain's start step, as the system actor, does the `resume`. The pipeline's writes are closed to every person, platform admin included: their policy names them and admits only the system actor, so there is no `authorize_if PlatformAdmin` ahead of it. `history` (the page) stays the platform admin's, and there is no `destroy` action (#2225). Reads that must not read as "nothing stale" or "no runs yet" use `authorize_with: :error`. Retention marks another, finished run's deleted files `pruned` through `mark_pruned` (#2218), which has no status filter; `record_progress`, `finish` and `fail` land only on a `running` run. The one write a person makes is `cancel` (#2218), the platform admin's alone (system actor refused): it has its own policy, and any other write matches no policy and is forbidden. |
| `Backups.Lock` | `read`, `ensure`, `hold`, `move`, `mark_executing`, `finishing`, `clear`, `queue_waiting`, `fold`, `request`, `reclaim_stale` | `read`, `ensure`, `hold`, `move`, `mark_executing`, `finishing`, `clear`, `queue_waiting`, `fold`, `request`, `reclaim_stale`: `:backups` | The cluster-wide backup lock (#2218), one row. The step chain takes, moves and releases it inside one transaction under an advisory lock, together with the Oban insert or cancel it decides on; every row write is `Backups.system/0`'s, so no person (platform admin included) holds, moves or clears it. `request` is every entry point that starts a backup (the Backups page as the platform admin, the legacy worker and console as the system actor); its implementation writes the row as the system actor. `reclaim_stale` is the heartbeat's sweep. A platform admin also reads the row (the in-flight strip). |
| `Backups.NodeBeat` | `read`, `beat`, `prune` | `read`, `beat`, `prune`: `:backups` | Each node's backup heartbeat (#2218), stamped with the database's clock. The heartbeat upserts its row and prunes rows a day old; the lock's reclaim sweep reads the holder's node beat. System-only: no person reads or writes a beat. |
| `Newsletter.Segment` | `read`, `for_tier`, `sync_managed` **only** | `read`: `:automation`, `:newsletter` · `for_tier`, `sync_managed`: `:newsletter` | The tier-backed lifecycle is driven by billing, not by a human: both write actions are `forbid_if always()` for everyone including admins. Managing a segment by hand stays an admin act, so the grant is narrowed inside the blanket admin policy as well — Ash ANDs policies, so both halves are needed. The "send as newsletter" automation reads the segment its rule names as the sender (`Newsletter.send_as_newsletter/2`, #1659), `read` only. |
| `Newsletter.Subscriber` | `read`, `confirmed`, `link_member` **only** | `read`, `confirmed`, `link_member`: `:newsletter` | `link_member` is the one write that may set `user_id`, and it is `forbid_if always()` for everyone. The send pipeline (`Newsletter.system/0`, #1659) reads a campaign's recipients (`confirmed`) and re-reads each one before delivery (`read`), both with `authorize_with: :error`: a refused list would read as "no subscribers" and mark the campaign sent having mailed nobody, and a refused re-read would cancel the recipient's unique job for good, so both log and retry. Narrowed the same way, so admin-only list management and every consent change are untouched. |
| `Newsletter.NewsletterSend` | `create`, `read`, `mark_sending`, `mark_sent`, `record_sent`, `record_failed` **only** | `create`: `:automation` · `read`, `mark_sending`, `mark_sent`, `record_sent`, `record_failed`: `:newsletter` | The "on publish → send the newsletter" automation (`Automation.RuleWorker`) records the campaign it queues (#1655), and only that: it never reads or rewrites the ledger (dedupe is the unique index, not a read). The send pipeline (`SendWorker`, `MailWorker`, as `Newsletter.system/0`, #1659) re-reads the campaign it was enqueued for, failing closed (a refusal retries rather than cancelling as "not found"), and keeps the fan-out and per-recipient counters, but cannot open a campaign. A counter write that fails after delivery is logged, not retried, so nobody is mailed twice. `mark_failed` and `destroy` stay admin acts: the row is the record of what went out and the automation's dedupe key. Narrowed inside the blanket admin policy, with `action:` splitting the two callers. |
| `Newsletter.SegmentMembership` | all | `destroy`, `read`, `create`: `:newsletter` | The join row between a subscriber and a tier segment. The sync genuinely reads, creates and destroys them as entitlements change, and the row carries nothing beyond the two ids. |
| `Federation.Follower` | all (`read`, `deliverable`, `follow`, `record_failure`, `record_success`, `destroy`) | `destroy`, `follow`, `record_failure`, `record_success`: `:federation` · `read`, `deliverable`: `:federation`, `:operator` | The follower list is kept by the system, not by a person (#1659): the inbox records a signed remote `Follow` (no Kiln user is behind it) and removes it on `Undo`, the fan-out reads who to deliver to, the delivery worker keeps the failure count and drops a dead follower, and a block removes the followers it covers. The tenant filter still applies. |
| `Federation.Delivery` | `read`, `create`, `settle` **only** | `read`, `create`, `settle`: `:federation` | The fan-out and the inbox's `Accept` write one ledger row per follower; the delivery worker re-reads and settles it. `destroy` is **not** admitted — the ledger is pruned by its AshOban trigger, and a system actor cannot erase the record of whether a POST went out. |
| `Federation.Block` | `read` **only** | `read`: `:federation` | The inbox asks whether an actor or its instance is blocked before it records a `Follow`. Deciding what to block stays an admin act. |
| `Federation.SiteFederation` | `read`, `record_delivery`, `enable`, `disable`, `rekey` **only** | `read`: `:federation`, `:operator` · `enable`, `rekey`, `disable`: `:operator` · `record_delivery`: `:federation` | Every federation path starts from the site's settings (`Federation.active_settings/2`); the delivery worker stamps "last federated"; and `mix kiln.federation` (`enable`, `disable`, `rekey`) is an operator at a shell on the host, the deployment's own authority. The settings form's `save` and `destroy` are not admitted — editing the site's public identity stays an admin act. Granted through `OrgSettings`' `system_actions:` option, which narrows inside the macro's read and write policies. |
| `Federation.SeenSignature` | `record`, `expired`, `destroy` **only** | `record`, `destroy`, `expired`: `:federation` | The inbound replay-nonce store: `HttpSignature` records a verified signature, `SeenSignatureSweeper` counts and deletes expired rows. The plain `read` is refused to everyone, the system actor included — nothing needs to list nonces. No person has any path to this table. |
| `Experiments.Experiment` | `read`, `running`, `create`, `start`, `conclude` **only** | `read`, `running`: `:experiments`, `:operator` · `create`, `start`, `conclude`: `:operator` | Delivery reads the running set (`Experiments.system/0`, #1659) to decide which arm a page serves and whether a form submission or a later page view converts; the variant-write and `:start` guards read the parent and the running set. `mix kiln.experiment` is an operator at a shell on the host and creates, starts and concludes. `update`, `archive` and `destroy` are not admitted — narrowed inside the admin write policy with `forbid_unless action(...)`. Every read that backs an assignment, a start guard or a result passes `authorize_with: :error` (and `has_many :variants` sets `authorize_read_with :error`, since the option does not reach a relationship load), so a lost grant errors instead of answering "nothing is running". |
| `Experiments.Variant` | `read`, `create` **only** | `read`: `:experiments`, `:operator` · `create`: `:operator` | The arms delivery assigns between (loaded with the running set) and the `:start` guard counts; `mix kiln.experiment variant` adds one. Re-weighting or removing an arm stays an admin act. |
| `Experiments.VariantDay` | `read`, `record_impression`, `record_conversion` **only** | `read`: `:operator` · `record_impression`, `record_conversion`: `:experiments` | The per-variant daily counters. Delivery and the form-submission path write the two counters; `mix kiln.experiment show` reads them, failing closed (the results panel reads them as the viewing editor). `destroy` is not admitted — a system caller cannot erase a result. |
| `CMS.HistoryAnchor` | `create`, `for_content` **only** | `create`, `for_content`: `:governance` | The tamper-evidence chain (#1659): the publish pipeline mints a document's next anchor and `Governance.Chain` reads that document's anchors back to verify or extend them. The plain `read` is not admitted: no Ash read lists anchors across documents. Checkpoint minting does read every document's head, through raw SQL (`Checkpoint.current_heads/1`, `standing_at_witnessed_positions/2`) that no policy governs and that cannot be refused, by design: the head set a checkpoint signs must never be silently shortened. There is still no `update` or `destroy` action. The read's code interface defaults to `authorize_with: :error`: a refused read would filter to `[]`, which reads as "never anchored", so a lost grant raises instead. Version rows themselves stay `authorize?: false` with a written reason: they are the editorial history, and a standing system read over them is the `PointInTime` case #1402 refused. |
| `CMS.ChainCheckpoint` | `recent`, `unwitnessed`, `create`, `record_publication` **only** | `create`, `record_publication`, `recent`, `unwitnessed`: `:governance` | The org-wide witness (#666): `Governance.CheckpointWorker` mints a checkpoint, publishes it and records the receipt, and verification loads the checkpoint an entry names (`get_chain_checkpoint`, a `get_by` on `recent`, so the plain `read` is not admitted). Named action by action inside `policy always()` so a `destroy` added later is not admitted by default. Reads fail closed (their code interfaces default to `authorize_with: :error`): an empty `unwitnessed` would show an outage as healthy, and an empty `recent` would restart the chain at sequence 1. |
| `CMS.IpBlockRule` | `list`, `destroy`, `create` **only** | `list`: `:ip_block`, `:operator` · `destroy`: `:operator` · `create`: `:scanner_guard` | The per-org IP block list (#2242). The edge check (`Security.IpBlocklist`, on every request and socket connect) reads a site's rules as the `:ip_block` actor and caches them; `:operator` is `KilnCMS.Release.ip_blocks/1`, the way back in when an admin has blocked their own network (lists and removes, with a cache bust). `create` stays an admin act, except that the scanner guard (#2253, `Security.ScannerGuard`) adds a temporary rule for an address that racks up delivery 404s or probes bait paths: `:scanner_guard` may `create` and nothing else (it cannot list or remove), and `:operator` is admitted to `list` and `destroy` only. The guard counts its own automatic rules through the `:ip_block` read. The read passes `authorize_with: :error`: a refused read would otherwise come back as `[]`, be cached as "no rules", and read as healthy. A failed read fails open and is never cached. |
| `CMS.ChainCheckpointEntry` | `create`, `for_content`, `for_checkpoint` **only** | `create`, `for_content`, `for_checkpoint`: `:governance` | The per-document entries each checkpoint commits to, and verification's read of a document's strongest witnessed head. A refused `for_content` would read as "never witnessed", which is exactly what a truncation wants to look like, so it raises instead and the verdict floors to `:unverifiable`. |
| `CMS.Page`, `CMS.Post`, `CMS.Entry` (content) | `clear_reference_target`, `convert_custom_field`, `refresh_computed`, `reindex_search_text`, `resnapshot_media`, `set_embedding`, `set_published_version_id` and `sync_shared_fields` **only**, named inside the `action_type([:create, :update])` policy | `set_embedding`: `:search` · `set_published_version_id`: `:cms_bookkeeping` · `reindex_search_text`: `:firing` · `sync_shared_fields`: `:localization` · `refresh_computed`: `:computed_fields` · `resnapshot_media`: `:media` · `convert_custom_field`: `:field_conversion` · `clear_reference_target`: `:cms_bookkeeping` | `refresh_computed` (`Computed.DailyRefresh`) re-derives a published record's computed fields on the site's new day when a `today()` formula's value moved: no input (the date rides in the changeset context), versioned so the sync API sees it, no webhook, `updated_at` kept, and a compare-and-swap on the `lock_version` it read instead of the optimistic lock, so it never bumps an open editor's lock and loses to their save. Its read of the records is `authorize?: false`, like `Firing.Sweep`'s, for the reason given there. `resnapshot_media` (`mix kiln.media.resnapshot`) is built the same way: it re-takes each stored `:media` custom-field snapshot from the current library item (`Media.Snapshot`), resolving the items as the `:media` pipeline actor. `convert_custom_field` (`mix kiln.fields.convert`, `CMS.FieldConversion`) is the same shape again: it writes rows parsed from a JSON-in-text field into a `:group` field, the rows riding in the changeset context and coerced as an editor's save of the group would be; a pending working copy's held value is converted with it. Three system-only actions on denormalized columns: the fragment-expanded search text (`Firing.Engine.fire/2`), the document-level search vector (`Search.EmbeddingWorker`), and the pointer at the version a publish wrote (`Changes.RecordPublishedVersion` / `ClearPublishedVersion`, as `CMS.Bookkeeping.system/0`, #1659 — the publish may be the scheduler's). None accepts `:blocks` and all are ignored by PaperTrail. The fourth, `sync_shared_fields` (#1327, `I18n.SharedFields`), is a content write: it copies the `:shared` field values a person published on a document's default-locale variant into the other locale variants, so it is versioned and takes the optimistic lock. It accepts no input — the values ride in the changeset context — and nothing routes it. The grant sits inside the policy written for people, narrowed to those two actions by `forbid_unless action(...)` — see above for why that rather than a bypass. `clear_reference_target` (R5, `ContentLinks.TargetDelete`) is the other content write: purging a record takes it out of every referrer whose `:reference` field is set to clear on delete, one write per referrer from inside the purge's transaction, as `CMS.Bookkeeping.system/0` — the purge's consequence, not the purging admin's own edit, and the purge may be the nightly scheduler's. Versioned and locked like `sync_shared_fields`, with the target in the changeset context and nothing routing it. Keep the list short and every member system-only. Nothing else on the content resources admits the system actor: it holds no tier, so `EditableContentType` / `ReadableContentType` / `InAudience` all refuse it, and a system actor reads content only as an anonymous visitor would: published `:public` records through the public branch of the read policy, never a draft or a gated record. The row covers every content type built on `KilnCMS.CMS.Content`, including an overlay's own, since each carries the same grants; `KilnCMS.SystemActorScopeTest` holds them all to it. |
| `History.DocumentEvent` | `for_document`, `by_actor`, `append`, `anonymize_actor` **only** | `append`, `for_document`, `by_actor`, `anonymize_actor`: `:history` | The block-level event log (#1659). The History API appends an event with the next per-document sequence number, folds one document's events for time-travel, and GDPR erasure redacts one user's events (a bulk update authorizes its query as a read, hence `by_actor`). The plain `read` is not admitted: nothing lists the whole log. No person, admin included, may append or rewrite an event. Every read fails closed (`authorize_with: :error`, `authorize_query_with: :error` on the erasure): a refused sequence read would hand out a number already taken, a refused fold would render an empty document, and a refused erasure would erase nothing and report success. |
| `Security.Event` | `record`, `by_actor`, `older_than`, `sign_in_from_ip`, `anonymize_actor`, `prune` **only** | `record`, `by_actor`, `older_than`, `anonymize_actor`, `prune`: `:security` · `sign_in_from_ip`: `:scanner_guard` | The security audit log (#2241). The recorder appends an event as `Security.system/0`; GDPR erasure (`Security.anonymize_actor/1`) scrubs the events a user acted in or is the target of (a bulk update authorizes its query as a read, hence `by_actor`); retention (`Security.prune/1`) deletes events past their window in keyset chunks (hence `older_than`). `sign_in_from_ip` is the scanner guard's one read (#2253): it will not auto-block an address a person signed in from recently. The plain `read` and `list` are not admitted: nothing system-side lists the log. No person, admin included, may record, rewrite or delete an event. Erasure and prune fail closed (`authorize_query_with: :error`, `authorize_with: :error`): a refused bulk query would match nothing and report success. |
| `CMS.FeedSettings` | `read` **only** | `read`: `:feeds` | `KilnCMS.Feeds` resolves a site's syndication policy for anonymous feed readers (#1659). A refused read would be "no row", the operator config, cached for the TTL, which can turn full content on for a site that switched it off, so the read fails closed to `Feeds.unavailable/0`, uncached. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SiteCompliance` | `read` **only** | `read`: `:compliance` | `Compliance.Settings` resolves a site's claim-checking rules and publish gate for the editor panel and the publish path (#1659). Fails closed to `Settings.unavailable/0`, uncached, for the same reason as `FeedSettings`. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SiteAdminAllowlist` | `read`, `operator_override` **only** | `read`: `:admin_allowlist`, `:operator` · `operator_override`: `:operator` | The admin allowlist (#2248). The gates (`Security.AdminAllowlist`, on every console and sign-in request, LiveView join and collab connect) read a site's list as the `:admin_allowlist` actor and cache it; the read passes `authorize_with: :error`, so a refused read is an infrastructure failure that fails closed (503, uncached) rather than reading as "no list". The save's audit change reads the previous list as the same actor, in the transaction. `:operator` is `KilnCMS.Release.admin_allowlist/1`, the way back in when a list has locked the admins out: it lists, and runs `operator_override`, which can only add an entry to a list that is on or empty it, and records `admin_allowlist_overridden`. An org admin is refused `operator_override`; saving the list stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SitePasswordPolicy` | `read` **only** | `read`: `:accounts` | The breached-password check (`Accounts.PasswordPolicy`, #2240) reads the site's off / warn / block stance while a registration, a reset or a first-run setup is under way, none of which has an admin actor. A refused read is `authorize_with: :error`, so it fails open to `warn` and is logged, rather than reading as "no row" and handing the decision to the operator default. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SiteRegistration` | `read` **only** | `read`: `:registrations` | Registration approval (#2251). `Changes.QueueRegistration` reads whether a self-registration on this site waits for an admin (`Accounts.RegistrationPolicy`) while the registration is under way, which has no admin actor. A refused read is `authorize_with: :error` and fails **closed**: the registration is refused with a retryable error and nothing is created, because "no approval needed" is the direction that lets an unreviewed account in. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `Accounts.OrgMembership` | `queue_registration`, `approve_registration_by_invitation`, `raise_role_by_invitation` **only** | `queue_registration`: `:registrations` · `approve_registration_by_invitation`, `raise_role_by_invitation`: `:invitations` | The registration's own write (#2251): `Changes.QueueRegistration` records the `:pending` membership inside the new account's create, and `SiteSso.Admission` for a new account a site's own single sign-on provisions while the site's `approval_for_site_sso` is on (#2514); neither has an actor of its own. No person may queue one — the platform-admin bypass forbids this action, so the system-only policy decides it for an admin too. `approve_registration_by_invitation` (#2514) is `Invitations.grant_membership/4` honouring an accepted invitation over a waiting or rejected registration on its site; a rejected one only when the invitation was sent after the rejection. `raise_role_by_invitation` (#2452) is the same accept over an active membership below the invited tier: it raises the standing tier, judged on the locked row, and never lowers it (an equal or higher tier is refused before any write). Every other membership write stays a platform admin's, and approving or rejecting under Registrations is an admin of the row's own org. |
| `Accounts.Invitation` | `retire` **only** | `retire`: `:invitations` | A membership change superseding a pending invitation (#2452): when a platform admin changes the tier or custom role of the person it names on its site, or removes them, `Changes.RetirePendingInvitation` retires it inside that write's transaction, locked before the membership row, so an older link cannot undo the decision. Recorded as `invitation_revoked` in the site's log, with the admin who made the change as the actor. Declared above the platform-admin bypass as well as in the closing policy, so no person may call it; an admin withdraws an invitation with `revoke`. |
| `Accounts.Passkey` | `for_user`, `forget_on_takeover` **only** | `for_user`, `forget_on_takeover`: `:invitations` | Accepting an invitation over an unconfirmed account (#2453): `Changes.ForgetPriorCredentials` lists the passkeys whoever registered the address first enrolled and removes each, inside the accept's transaction, recording `passkey_removed` with no actor. `forget_on_takeover` is declared above the platform-admin bypass, so no person, an admin included, may call it; an owner or an admin removes a passkey with `destroy`. The read fails closed (`authorize_with: :error`): a refused read would leave every passkey in place. |
| `Accounts.UserIdentity` | `for_user`, `forget_on_takeover` **only** | `for_user`, `forget_on_takeover`: `:invitations` | The same takeover (#2453), for identity-provider links. No shipped path links one to an unconfirmed account; the takeover removes any it finds all the same. Every other action stays AshAuthentication's own. |
| `Accounts.ApiKey` | `for_user`, `revoke` **only** | `for_user`, `revoke`: `:invitations` | The same takeover (#2453): an admin may have minted a key for the unconfirmed account, so each live one is revoked through `revoke`, which records `api_key_revoked` with no actor. Minting, listing and revoking stay a platform admin's otherwise. |
| `Accounts.User` | `anonymize` **only** | `anonymize`: `:registrations` | Erasing an unconfirmed, rejected registration (#2514). When a site's `SiteRegistration.rejected_accounts` is `:erase_unconfirmed` and a standing admin of that site rejects with `erase: true`, `Changes.EraseRejectedAccount` erases the applicant inside the rejection's transaction; the deciding admin may be a site admin, who may not erase accounts, so it runs as `SystemActor.new(:registrations)`. The policy admits the subsystem; `Changes.GuardRegistrationErasure` on the action holds it to the one erasure: the context must name a membership of that account that this transaction has just rejected (`:rejected`, its `decided_at`, `created_account`), the account's row is re-locked `FOR UPDATE`, and `Registrations.Erasure.check/1` must pass (never confirmed, nothing but that application). Anything else is refused and the account is untouched. Every other erasure stays a platform admin's. |
| `CMS.SiteSessionPolicy` | `read` **only** | `read`: `:accounts` | The idle timeout (`Accounts.IdleTimeout`, #2246) reads the site's timeouts and its "sign out everyone" watermark on signed-in requests and LiveView mounts, none of which has an admin actor. A refused read is `authorize_with: :error`, so it fails open (no timeout, no watermark), is logged and is not cached, rather than reading as "no row". Saving the row and `sign_out_all` stay admin acts. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SiteBotBudgets` | `read` **only** | `read`: `:bot_budgets` | The delivery rate limiter (`BotBudgets`, #2243) reads a site's per-class ceilings while answering an anonymous public request, which has no admin actor. A refused read is `authorize_with: :error`, so it is logged and answered with the operator's values (never wider than the operator allowed), reused for 20 seconds, rather than cached for five minutes as "no row". Browser requests never read it. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SiteSecurityLog` | `read` **only** | `read`: `:security` | `Security.PruneWorker` reads each site's security-log retention window (#2241) through `Security.retention_days/1`, with no admin actor. A refused or failed read answers `0` (keep everything) and is logged, so a lost grant never deletes on a window nobody confirmed. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SearchSynonym` | `read` **only** | `read`: `:search` | `Search.Synonyms` reads a site's synonym rules for every search, usually an anonymous visitor's (A7). Fails closed (`authorize_with: :error`): a refused read raises rather than caching "no synonyms" for the TTL. Writing a rule stays an editor's; deleting one an admin's. |
| `Analytics.SearchQuery` | `record` **only** | `record`: `:search` | `Search.record_query/3` counts a search, usually an anonymous visitor's (#1659). No person may record one (an admin still can, through the admin bypass above the policy), and the system may not read or purge the counters; the nightly purge is the AshOban trigger's own. |

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
| `unarchive` | ✅ | ✅ | ❌ | ❌ |
| `restore_version` | ✅ | ✅ | ❌ | ❌ |
| `publish`, `publish_scheduled` | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| `unpublish`, `unpublish_scheduled` | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| `archive` (from any state), `archive_scheduled` | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| any action changing `scheduled_at` | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| an update changing `unpublish_at` on a record that is published or has `scheduled_at` set | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| an update changing `expiry_action` on a record that is published or has `scheduled_at` set | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| `return_to_draft` | ✅ | ❌ | ❌ | ❌ |
| `destroy` (soft-delete), `purge` (hard) | ✅ | ❌ | ❌ | ❌ |
| `trashed` (read), `restore` (untrash) | ✅ | ❌ | ❌ | ❌ |

`publish_scheduled`, `unpublish_scheduled` and `archive_scheduled` are run by
the **system** AshOban scheduler, allowed via
`bypass AshOban.Checks.AshObanInteraction`; no person is checked when they
fire.

⚙️ **Editors can publish, per site.** `SiteEditorialSettings.editors_can_publish`
(`Checks.EditorMayPublish`) lets an org's editors publish directly. `/setup`
asks a new site, and admins change it under **Team → Publishing**. It defaults
to off, so an upgraded site keeps admin approval until an admin turns it on. A
read failure also answers "off" (`KilnCMS.CMS.EditorialSettings`). The
content-type scope still applies: an editor limited to some types can publish
only those.

Setting, moving or clearing `scheduled_at` takes the same permission as
`publish`, because the scheduler publishes that date through its bypass with
nobody checked at go-live.

Taking content down takes the same permission as putting it up (#2134).
`unpublish` and `archive` sit in the `publish` policy; `archive` is gated from
every state, so an editor on a site where only admins publish cannot archive
their own draft. `unarchive` lands on draft and stays editor-level, as does
`publish_changes` ([The working copy](working-copy.md)). `unpublish_at` and
`expiry_action` are gated the same way, but only on an update of a record that
is published or has `scheduled_at` set, as the row was read before the update
(`Checks.LiveOrScheduled`): on such a record they are a takedown the scheduler
runs through its bypass. On an unscheduled draft, or a create, they do nothing
until someone with publish rights publishes or schedules the record, so an
editor may write them there. Sending the value a record already has is not a
change and is allowed. The two fields have a policy each, because
`changing_attributes([a, b])` matches only when both change.

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

## Join tables — `Tagging`, `ContentLink`, `RelatedLink`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| `Tagging` read | ✅ | ✅ | ✅ | ✅ |
| `ContentLink` read (`read`, `backlinks`, `references_from`) | ✅ | ✅ | both ends readable | both ends readable |
| `RelatedLink` read | ✅ | ✅ | both ends readable | both ends readable |
| `create`, `update`, `destroy` | ✅ | ✅ | ❌ | ❌ |

`Tagging` read is open so published content can load its tags; linking and
unlinking is an editing action. `Tagging` has no domain code interface (it is
managed through `manage_relationship` on the content resources).

A `ContentLink` names two documents, so since 1.1 (#1594) a reader below
editor sees one only when they may read **both** its source and its target
(`Checks.LinkEndsReadable`, which re-reads the ends under the reader's own
authorization, the way `Checks.DocumentReadable` does for artifacts). It used
to be world-readable, which let a published page's `incoming_links` name the
drafts linking to it.

`RelatedLink` (#2025) is not a table of its own: it is `content_links`'
curated `kind: :related` rows, read through a base filter, as the join of
every `related_<type>s` relationship and of its write side `curated_<type>s`.
Its policies are `ContentLink`'s for people. The join read Ash runs behind
those relationships is admitted as such (`Checks.ThroughRelatedJoin`): it
never returns a row, and the related records are filtered by their own
policy. The one system actor it admits is field-level localization's copy
of a shared related list (#1859), in "The system actor" above; the same
copy links a shared tag set through `Tagging`.

## Media — `MediaItem`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read | ✅ | ✅ | ✅ | ✅ |
| `create`, `update` | ✅ | ✅ | ❌ | ❌ |
| `destroy` (soft), `purge` (hard) | ✅ | ❌ | ❌ | ❌ |
| `trashed` (read), `restore` (untrash) | ✅ | ❌ | ❌ | ❌ |

Media is world-readable because published content embeds it (featured images,
inline assets).

The alt-text publish gate (`Validations.MediaAltText`) reads the `decorative`
flag as the **system actor**, through the plain `read` only (#1659); see
[The system actor](#the-system-actor).

The pipeline's own actions — `record_processing`, `release_quarantine`,
`adopt_into_image_backend` and the cross-site `quarantine_expired` scan — are
not an editor's. The first three are admin (bypass) or system actor only; `quarantine_expired` is the system
actor's alone, admin included. See "The system actor" above.

The routes that serve a media item's **bytes** — `/media/:id/download`,
`/media/:id/stream` and the on-the-fly transforms at `/media/:id/t/:ops` — all
read the row through this policy under the request's session actor
(`MediaDownloadController.readable_item/2`), so a gated item is a 404 on every
one of them to anyone without its audience, and a quarantined item is a 404 to
everyone. The transform route additionally refuses out-of-bounds parameters
(an off-allowlist size or a bad signature) before it reads anything.

## Webhooks — `WebhookEndpoint`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Endpoint configuration is admin-only. The delivery pipeline reads endpoints and
keeps their health counters as the **system actor** (see
[The system actor](#the-system-actor)); it cannot create, edit or delete one.

## Mail settings — `Mail.Settings`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `init`, `generate_dkim`, `rotate_dkim`, `configure_key_source`, `set_server_ip`, `record_verification` | ✅ | ❌ | ❌ | ❌ |

Instance-wide mail/DKIM configuration (`/editor/mail`) is admin-only. The
delivery pipeline resolves the DKIM key as the **system actor**
(`KilnCMS.Mail.dkim_config/0`), as does the lazy singleton creation
(`ensure_settings!/0`); both are admitted for `read` and `init` only.

## Provenance settings — `Provenance.Settings`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `generate` | ✅ | ❌ | ❌ | ❌ |

The instance's generated content-signing key (#1929) is platform-admin-only,
for the same reason as `Mail.Settings`: the row is tenant-less. `/setup`
generates it as the admin it has just created, and the overview's "served
unsigned" strip offers the same action to a platform admin. There is no update
or destroy: a key that signed manifests is never replaced in place. Signing
reads the row as the system (`authorize?: false` via
`KilnCMS.Provenance.stored_key/0`), as the billing checkout reads its
credentials.

## Billing settings — `Billing.Settings`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `init`, `store_secret`, `configure_key_source`, `record_verification`, `clear_credentials` | ✅ | ❌ | ❌ | ❌ |

Instance-wide payment-provider credentials (`/editor/billing`) are
platform-admin-only — deliberately **not** per-org, for the same reason as
`Mail.Settings`: the row is tenant-less, so an org-admin check would resolve
against the default org. The checkout path and webhook receiver read the row as
the **system** (`authorize?: false` via `KilnCMS.Billing.get_settings/0`), as
does the lazy singleton creation (`ensure_settings!/0`, reached from the admin
page and from `verify_credentials/1`, which pre-checks its actor against this
policy before doing anything).

## Backup history — `Backups.Run`

| Action | platform admin | editor | org admin (not platform admin) | viewer | anonymous | `:backups` system actor |
|--------|:-----:|:------:|:-----:|:------:|:---------:|:-----:|
| `read`, `history`, `running`, `by_stamp` | ✅ | ❌ | ❌ | ❌ | ❌ | `read`, `running`, `by_stamp` only |
| `start`, `skip`, `record_progress`, `finish`, `fail`, `resume`, `import`, `mark_pruned` | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| `cancel` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |

One row per backup attempt (`/editor/backups`, "History"). Instance-wide and
tenant-less, so the gate is the global role (`Accounts.Checks.PlatformAdmin`),
**never** `OrgAdmin`, which would resolve a tenant-less subject to the default
org. People can only read, except that a platform admin may `cancel` a
running backup (#2218, audited as `backup_canceled`); every other write is the
backup pipeline's (`Backups.system/0`), named action by action. There is no
`destroy` action until retention lands (#2225). Not exposed through GraphQL,
JSON:API or MCP.

## Backup lock — `Backups.Lock`, `Backups.NodeBeat`

| Action | platform admin | editor | org admin (not platform admin) | viewer | anonymous | `:backups` system actor |
|--------|:-----:|:------:|:-----:|:------:|:---------:|:-----:|
| `Lock` `read`, `request` | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| `Lock` `ensure`, `hold`, `move`, `mark_executing`, `finishing`, `clear`, `queue_waiting`, `fold`, `reclaim_stale` | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| `NodeBeat` `read`, `beat`, `prune` | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |

The step chain's lock and the nodes' heartbeats (#2218). Instance-wide and
tenant-less, gated on the global role. A platform admin asks for a backup
(`request`, which writes the row as the system actor) and sees what is in
flight; the row itself is written only by the pipeline.

## Bounce suppression — `Mail.SuppressedRecipient`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read, `suppress`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Managed from `/editor/mail` (admin-only). The delivery pipeline writes
suppressions on a hard bounce and consults them before queuing as the
**system actor** (`read` and `suppress` only; a refused lookup fails closed and
the recipient is not mailed). As with reads elsewhere, a non-admin read is
filtered to nothing rather than erroring, so the list never leaks.

## Custom fields — `FieldDefinition`

| Action | admin | editor | viewer | anonymous | system |
|--------|:-----:|:------:|:------:|:---------:|:------:|
| read (`read`, `for_type`, `for_definition`) | ✅ | ✅ | ❌ | ❌ | ✅ |
| `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ | ❌ |

Defining the schema (fields per content type) is admin-only; editors read
definitions so the content editor can render the inputs. Firing reads them to
turn `custom_fields` values into JSON-LD, as `%KilnCMS.SystemActor{}` (#1402 —
`KilnCMS.Firing.CustomFields`); the `ApplyCustomFields` write change still
reads them with `authorize?: false`.

`FieldSection` (`lib/kiln_cms/cms/field_section.ex`, #2280), how each section
of a type's custom fields is laid out in the content editor:

| Action | admin | editor | viewer | anonymous | system |
|--------|:-----:|:------:|:------:|:---------:|:------:|
| read (`read`, `for_type`, `for_definition`) | ✅ | ✅ | ❌ | ❌ | ✅ `:schema_export` |
| `create`, `update`, `destroy` | ✅ | ❌ | ❌ | ❌ | ❌ |

It follows `FieldDefinition`: laying out a type's fields is admin-only (the
**Sections of** panel at `/editor/fields`, the field sync import), and editors
read the layout as themselves so the content editor can render tabs and
fieldsets. The schema export reads it as the system actor, `:schema_export`
only, to report `x-kiln-section-display`. Scoped by `org_id` like a field
definition; there is no JSON:API, GraphQL or MCP route.

## Analytics — `ContentView`, `ContentViewDay`, `SearchQuery`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`top`, `in_window`, `zero_result`) | ✅ | ✅ | ❌ | ❌ |
| `record` | ⚙️ | ⚙️ | ⚙️ | ⚙️ |

`record` is `forbid_if always()` for every role — view/search counts are written
only by the **system** delivery path (`authorize?: false`). Reading aggregates is
editor/admin only (privacy-first: no per-user data is stored anyway).
`SearchQuery`'s `record` is written as a system actor instead (#1659), admitted
by name; see [The system actor](#the-system-actor).

## Accounts — `User`, `Token`

`User` (`lib/kiln_cms/accounts/user.ex`):

| Action | admin | editor / viewer (self) | editor / viewer (other) | anonymous |
|--------|:-----:|:----------------------:|:-----------------------:|:---------:|
| read | ✅ all | 🔎 own record | 🔎 filtered out | ❌ |
| `change_password` | ✅ | ✅ (own) | ❌ | ❌ |
| `manage_access`, `grant_temporary_role`, `send_password_reset` | ✅ | ❌ | ❌ | ❌ |
| `anonymize` | ✅ | ❌ | ❌ | ❌ (⚙️ system actor, `:registrations`, guarded) |
| `expire_role_grant` | ✅ | ❌ | ❌ | ❌ (⚙️ AshOban sweep) |
| auth flows (sign-in, register, reset) | ✅ | ✅ | ✅ | ✅ (AshAuthentication bypass) |

"admin" throughout this section is `KilnCMS.Accounts.Checks.PlatformAdmin`: the
**effective** platform role, which counts a temporary admin grant only until it
expires — re-checked at authorization, so a long-lived LiveView or GraphQL
socket's actor stops authorizing the moment its grant runs out.
`:manage_access` and `:grant_temporary_role` additionally carry
`Validations.StandingAdminOnly`: a *temporary* admin passes the policy but cannot
confer or extend a tier.

Field policy: the `role` field is visible only to **admins or the user
themselves**; other readers see the record without `role`. `granted_role` and
`granted_role_expires_at` are `public? false` and so reach no API surface at all —
field policies cover only public fields, which is why they are not listed beside
`role` there. Nothing copies a grant into `role` on read, so the `role` a reader
is allowed to see is always the standing one.

The three admin levers above are the account console's
([`account-administration.md`](account-administration.md)). Six are refused for
everyone, admins included:

| Action | Why nobody may call it |
|---|---|
| `:sign_in_with_passkey` | Mints a session token; only the verified WebAuthn ceremony reaches it (`authorize?: false`), and the preparation refuses any actor-carrying call — so not even an admin can mint a token for another account |
| `:sync_billing_audiences` | Entitlements are recomputed by `KilnCMS.Billing.Entitlements` alone; the change module refuses an actor-carrying call, so no authorized path grants an audience by hand |
| `:register_with_invitation`, `:accept_invitation_with_password` | Accepting a site invitation (#2135): the first creates a confirmed account, the second sets a new password over an unconfirmed one, revokes its tokens, and forgets every other credential it held (#2453): its two-step verification and recovery codes, passkeys, identity-provider links, push devices and API keys, as the invitations system actor. The emailed token is the credential, so only `KilnCMSWeb.InviteLive` calls them (`authorize?: false`), and `Changes.AcceptInvitation` refuses any actor-carrying call, since the admin bypass would pass `forbid_if always()`. Neither checks `:registration_enabled`: an invite-only site is where invitations are how accounts arrive |
| `:request_sign_in_unlock`, `:redeem_sign_in_unlock` | The emailed link that lifts a sign-in pause (#2250): the first mails a link to a paused account, if there is one, and the second clears the account's sign-in counter. An anonymous request and the emailed token are the only ways in, so only `KilnCMSWeb.SignInUnlockController` calls them (`authorize?: false`, the request host's site in `context:`), and `SignInUnlockAction` refuses any actor-carrying call, since the admin bypass would pass `forbid_if always()`. No signed-in person, an operator included, can mint or spend a link. See [Lift a sign-in pause by email](account-administration.md#lift-a-sign-in-pause-by-email) |

`NotLastAdmin` sits on `:manage_access` and `:anonymize` as a **validation**, not
a policy: admins bypass `User`'s policies wholesale, so a `forbid_if` would never
fire, and the refusal has to carry a sentence.

**Demo mode** (`KILN_DEMO_RESET=confirm`) narrows the self-service column:
`change_password` and the TOTP actions (`setup_totp`, `confirm_totp`,
`disable_totp`, `regenerate_totp_recovery_codes`) refuse every non-admin actor
with `DemoAccountLocked`, as do `Passkey.register` and `Passkey.destroy` below.
Every visitor to a demo is the same shared account. See
[`demo-mode.md`](demo-mode.md#7-credentials-for-the-shared-account).

`Token` — every AshAuthentication action is gated to the AshAuthentication
interaction bypass, and the nightly expunge trigger to the AshOban one. There are
no caller-facing token actions.

That includes the revocation a password change or reset runs (#734):
`KilnCMS.Accounts.Changes.RevokeAllTokens` reaches `User.log_out_everywhere` →
`Token.revoke_all_stored_for_subject` through `AshAuthentication.Strategy.action/4`,
which marks the call as AshAuthentication's own, so both resources' interaction
bypasses admit it — no `authorize?: false`, and no system-actor grant. That
matters for the anonymous half: `:reset_password_with_token` has no actor at
all, only the emailed reset token its validation checks.

Three actions are ours rather than AshAuthentication's, and all three are
`forbid_if always()` — no actor may reach any of them:

| Action | What it is for |
|---|---|
| `:spend_jti` | Records a redeemed headless two-factor blob (#743) |
| `:hold_for_second_factor` | Parks a first-factor token while a code is owed (#742) |
| `:release_second_factor_hold` | Returns it to use once the code lands (#742) |

`KilnCMS.Accounts.PendingSignIn` calls all three with `authorize?: false`,
because the whole point of both steps is that the caller has **not** finished
signing in — there is no actor to authorize. **The headless single-use guarantee
and the #742 hold both depend on that flag**, so a change that tightens
`authorize?` handling has to keep these calls working.

The domain names them (`spend_pending_sign_in`, `hold_first_factor_token`,
`release_first_factor_token`) plus `get_stored_token_by_jti`, a by-jti `:read`. A
name is not an opening here: no policy matches `:read` either, so every one of
them is refused without the `authorize?: false` only that module passes.

**Your own sessions (#1823).** The settings page's session list adds three
self-service actions, all scoped by `KilnCMS.Accounts.Checks.OwnsToken` — a
filter check matching rows whose `subject` is the actor's own. A row of another
account is filtered out rather than refused, so a jti naming someone else's
session lists nothing and revokes nothing. There is no admin bypass: an admin
signs another account out with *Sign out everywhere* on the Accounts page.

| Action | Who | What it is for |
|---|---|---|
| `:own_sessions` | the token's owner | The account's usable `"user"` rows — the list |
| `:own_tokens` | the token's owner | Every row it owns; the read the revocation's bulk update runs through |
| `:revoke_own_session` | the token's owner | Flips a `"user"`, `"remember_me"` or held row to `"revocation"` |

Two more are bookkeeping and `forbid_if always()`, like the three above:
`:record_sign_in` (the browser a session signed in from and its remember-me
cookie's jti, by `KilnCMSWeb.Plugs.SessionTracking`) and `:record_session_use`
(`last_used_at`, at most every five minutes, from a signed-in mount).
`KilnCMS.Accounts.Sessions` calls both with `authorize?: false`, keyed by the jti
in the signed session.

**Idle timeout and "sign out everyone" (#2246).** Five more, all
`forbid_if always()` in the same policy as the two above, so no actor reaches
any of them, an admin included. Each is called with `authorize?: false` only by
the module named:

| Action | Called by | What it is for |
|---|---|---|
| `:session_activity` | `Accounts.IdleTimeout` | A by-jti read of one row, with its idle time by the database clock |
| `:bind_session_to_site` | `Accounts.Sessions` | Stamps `org_id` on a session or remember-me row of the named account. Never moves a row bound to another site, and never binds one older than the site's last "sign out everyone" |
| `:expire_idle_session` | `Accounts.IdleTimeout` | Revokes an idle session and its remember-me row (`revoked_reason: "idle"`); the idle test is repeated in the UPDATE |
| `:revoke_stale_session` | `Accounts.IdleTimeout` | Revokes a row bound to no site that predates the site's watermark, when it is next used there (`revoked_reason: "admin_sign_out_all"`) |
| `:revoke_org_session` | `Accounts.Sessions.revoke_org/2`, from `SiteSessionPolicy` `:sign_out_all` | Revokes every session, remember-me and two-factor hold row bound to one site, minus the kept jtis |

Every write is keyed by a jti read from the signed session cookie (or a
remember-me cookie whose signature was verified first) and also filtered on the
account's `subject`, so a jti naming another account's row changes nothing.
`:record_sign_in` and `:record_session_use` now take the site too, and the
second also bumps the remember-me row and never touches a row bound to another
site.

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

The system actor may use the plain `read` only (#1659, see
[The system actor](#the-system-actor)).

`OrgMembership`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_user`, `for_org`) | ✅ all | 🔎 own rows | 🔎 own rows | ❌ |
| `create`, `update`, `destroy`, `grant_temporary_role` | ✅ | ❌ | ❌ | ❌ |
| `expire_role_grant` | ✅ | ❌ | ❌ | ❌ (⚙️ AshOban sweep) |
| `registration_queue`, `approve_registration`, `reject_registration` | ✅ (platform, or an admin of the row's org) | ❌ | ❌ | ❌ |
| `queue_registration` | ❌ | ❌ | ❌ | ❌ (⚙️ system actor, `:registrations`) |
| `approve_registration_by_invitation` | ✅ (platform, a direct add) | ❌ | ❌ | ❌ (⚙️ system actor, `:invitations`) |
| `raise_role_by_invitation` | ✅ (platform) | ❌ | ❌ | ❌ (⚙️ system actor, `:invitations`) |

Registration approval (#2251): `for_org` returns `:active` rows only, so a
registration awaiting approval is on no roster. The three registration actions
are decided by `Checks.AdminOfMembershipOrg` — an admin of the org the **row**
names (the `organization_id` argument, for the queue read), never the request's
host — so another site's admin is refused whichever host they ask from. Each
policy names its actions rather than an `action_type`, so neither the self-only
read nor the blanket write refusal applies to them. A temporary platform admin
passes the bypass and is refused by `StandingAdminOnly`, as on every other
membership write.

`reject_registration` takes `erase` (#2514). It changes nothing about who may
reject: it asks to erase the applicant's account as well, which happens only
on a site whose `rejected_accounts` is `:erase_unconfirmed`, for a **standing**
admin of the row's site, and for an account `Registrations.Erasure.check/1`
passes. The erasure runs as the `:registrations` system actor (see
[The system actor](#the-system-actor)), so a site admin, who is refused
`User` `anonymize`, erases nothing else through it.

The AshOban grant is an **unconditional** `bypass AshOban.Checks.AshObanInteraction`
at the top of the policies, not one scoped to `expire_role_grant`: the scheduler
reads the rows to sweep through the primary read first, and a write-scoped grant
leaves that read filtered to nothing. Every create/update also carries
`Validations.StandingAdminOnly`, so a temporary platform admin cannot confer a
site tier that would outlast its own grant.

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

`for_user` and `revoke` also admit the invitations system actor, for an
invitation taking over an unconfirmed account (#2453).

Minting returns the plaintext key exactly once; only the SHA-256 hash is stored.
Sign-in looks the key up through the AshAuthentication interaction bypass.

`Passkey`:

| Action | admin | editor / viewer (own) | editor / viewer (other) | anonymous |
|--------|:-----:|:---------------------:|:-----------------------:|:---------:|
| read (`read`, `for_user`) | ✅ all | 🔎 own credentials | 🔎 filtered out | ❌ |
| `destroy` | ✅ | ✅ (own) | ❌ | ❌ |
| `register`, `bump_usage` | ⚙️ | ⚙️ | ⚙️ | ⚙️ |
| `forget_on_takeover` | ❌ | ❌ | ❌ | ❌ (⚙️ system actor, `:invitations`) |

`register` and `bump_usage` are `forbid_if always()` — the WebAuthn ceremony
code writes them as the system. `forget_on_takeover` (#2453) is the
invitations system actor's alone, declared above the platform-admin bypass;
`for_user` admits that actor too, for the same takeover.

`Invitation` (#2135, `lib/kiln_cms/accounts/invitation.ex`) — a pending
invitation to a site by email. Global like `OrgMembership`: the Team page reads
one org's rows by `organization_id`.

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| `read`, `for_org`, `invite`, `resend`, `revoke`, `add_or_invite` | ✅ | ❌ | ❌ | ❌ |
| `by_token`, `consume`, `accept_existing` | ⚙️ | ⚙️ | ⚙️ | ⚙️ |
| `retire` | ❌ | ❌ | ❌ | ❌ (⚙️ system actor, `:invitations`) |
| `prune_expired` | ✅ | ❌ | ❌ | ❌ (⚙️ AshOban sweep) |

"admin" is `KilnCMS.Accounts.Checks.PlatformAdmin`, as for memberships: a site
admin who is not a platform admin cannot invite. `:invite` and `:resend` also
carry `Validations.StandingAdminOnly`, so a temporary platform admin is refused
there (an accepted invitation would outlast the grant); `:revoke` and the reads
are open to them. `:add_or_invite` runs every read and write as the calling
actor, so `User`'s, `OrgMembership`'s and `Invitation`'s own policies decide.

The three system-only actions are `forbid_if always()` declared **above** the
platform-admin bypass, because a passing bypass skips every policy below it.
They are reached only with `authorize?: false`, by `KilnCMS.Accounts.Invitations`,
`Invitations.AcceptExisting`, `Invitations.AddOrInvite` (retiring an invitation a
direct add superseded) and `Changes.AcceptInvitation`, once the token is in hand.
`:by_token`'s preparation and `:accept_existing`'s implementation also refuse any
actor-carrying call. The AshOban bypass is unconditional and first, as on
`OrgMembership`, because the scheduler reads before its worker destroys.

`UserIdentity` — every action is forbidden to every role; only
AshAuthentication's own OAuth machinery passes, via its interaction bypass,
and the invitations system actor, to `for_user` and `forget_on_takeover`
only, for an invitation taking over an unconfirmed account (#2453).

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
The public submit path validates and then writes as the **system**
(`Forms.system/0`, admitted to `create` alone — see "The system actor").

## Redirects & branding — `Redirect`, `SiteBranding`, `SiteSecurityTxt`

| Resource | read | writes |
|---|---|---|
| `Redirect` (`read`) | ✅ everyone incl. anonymous | `create`: admin only · `destroy`: admin, **or** whoever may write the target record · both also the slug-change hook's system actor (see "The system actor") |
| `SiteBranding` (`read`) | ✅ everyone incl. anonymous | admin only (`save`, `update`, `destroy`) |
| `SiteSecurityTxt` (`read`) | ✅ everyone incl. anonymous | admin only (`save`, `update`, `destroy`) |

All three are public information by design — delivery serves the same redirect map to
anyone who hits an old URL, branding tokens render on every public page, and a
site's `security.txt` row is the file `/.well-known/security.txt` serves (#1873).
Both reads are tenant-scoped, so a request sees only its own site's rows. The
slug-change hook that writes redirects runs as the **system**.

The `destroy` widening is for the content editor, which lists the redirects
standing under the record being edited with a Delete on each:
`Checks.WritesRedirectTarget` matches only a `destroy` on a loaded row, and
decides it by re-asking the target's own `:update` policy as the actor — so a
type-scoped editor cannot prune a redirect at a type they may not author, and a
row whose target is gone or unregistered matches nobody (pruning dead rows stays
an admin job on `/editor/redirects`).

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

## Object storage — `SiteStorage`, `StorageProfile` (#1559)

| Resource | read | writes |
|---|---|---|
| `SiteStorage` (`read`) | admin only | admin only (`save`, `update`, `destroy`) |
| `StorageProfile` (`read`) | admin only | admin only (`create`, `update_credentials`); no destroy |

A site's own S3-compatible bucket, at `/editor/site-storage`. Org-admin on both
sides, like every per-site integration; the rows name the site's storage
provider and account. Profiles are written only through `SiteStorage`'s saves,
and uploads, downloads and media jobs read them as the system
(`KilnCMS.Storage.SiteProfiles`), tenant-scoped to the item's own site — a
media row can name only a profile of its own site.

There is no destroy on `StorageProfile` on purpose: media rows record the
profile their file is in, and deleting one would strand every file in it.
Moving the site to another bucket makes a new profile and leaves the old one.

As for the mail relay below, the stricter parts are not policies: the secret
is encrypted, write-only and database-only; the endpoint must be `https://` and
is refused if it resolves to a private, loopback, link-local or metadata
address, at save and on every connection; and a request to it carries nothing
from the operator's ExAws config.

## Outgoing mail — `SiteMailRelay` (#1322)

| Resource | read | writes |
|---|---|---|
| `SiteMailRelay` (`read`) | admin only | admin only (`save`, `update`, `destroy`) |

A site's own SMTP relay and From address, at `/editor/site-mail`. It is
org-admin on both sides, like every per-site settings row. Nothing here is shown
to a visitor, and the row names the site's mail provider and account. The
delivery jobs read it as the system (`KilnCMS.Mail.SiteRelay`).

Org admin is the right tier, but on a hosted deployment an org admin is a
tenant. That is why this row is stricter than the operator's `Mail.Settings`,
and none of it is a policy. The password is encrypted and never read back into
the form. It can't be pointed at an environment variable or a file, as the
operator's keys can. The relay host is refused if it resolves to a private,
loopback, link-local or metadata address, checked when it is saved and again on
every connection. A site relay's hard rejects cancel the message but don't add
the address to the instance-wide suppression list, because a relay the site
chose could otherwise block any address for every site. They go on the site's
own list instead (next section).

## Site bounce suppression — `Mail.SiteSuppressedRecipient` (#1562)

| Action | admin | editor | viewer | anonymous | system |
|--------|:-----:|:------:|:------:|:---------:|:------:|
| read | ✅ | ❌ | ❌ | ❌ | ✅ |
| `destroy` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `suppress` | ❌ | ❌ | ❌ | ❌ | ✅ |

The addresses one site's own relay rejected as dead, per site
(`org_id`, `email`). Org admin reads and clears it from `/editor/site-mail`; a
non-admin read filters to nothing. Only the delivery pipeline writes it, as
the **system actor**, on a reject naming the recipient that
came through that site's relay. Not even the site's admin can add a row: that
would stop the site's mail to an address without a bounce ever happening.

It is consulted only for mail sent for that site (`KilnCMS.Mail.suppressed?/2`
with `org_id:`). Account mail carries no site and never reads it, and no site
reads another's, so a hostile relay can stop only its own site's mail.

## Push notification key — `SiteVapidKey` (#1560)

| Resource | read | writes |
|---|---|---|
| `SiteVapidKey` (`read`) | admin only | admin only (`save`, `update`, `rotate`, `destroy`) |

A site's own Web Push (VAPID) key pair, at `/editor/site-push`. Org-admin on
both sides, like every per-site settings row. No action accepts a key: `save`
mints the pair on first use and `rotate` replaces it, so a site admin can
never set a key, only generate one. The private half is encrypted and never
rendered. `rotate` and `destroy` delete the site's push subscriptions made
against the old key as a system write, since those rows belong to the
reviewers and not to the admin. `KilnCMS.Push.Keys` reads the row as the
system, for the push worker (which has no actor) and for a reviewer
subscribing on `/editor/settings`, who is not the site's admin.

## Search instance — `SiteMeilisearch` (#1558)

| Resource | read | writes |
|---|---|---|
| `SiteMeilisearch` (`read`) | admin only | admin only (`save`, `update`, `destroy`) |

A site's own Meilisearch instance — URL, API key and index — at
`/editor/site-search`. Org-admin on both sides, like every per-site settings
row; a read by anyone else is filtered to nothing. The indexing jobs and
`Meilisearch.search/2` read it as the system
(`KilnCMS.Search.Meilisearch.SiteInstance`), tenant-scoped to the one site.

As with the site relay, the stricter parts are not policies: the key is
encrypted, never read back into the form, and has no env-var or file source;
the URL must be HTTPS and is refused if it resolves to a private, loopback,
link-local or metadata address, at save and on every request (through
`KilnCMS.SafeFetch`). "Reindex now" re-asks the update policy before
enqueueing (#1166).

## Search synonyms — `SearchSynonym`, `ContentSearch` (A7)

| Resource | read | writes |
|---|---|---|
| `SearchSynonym` (`read`) | editor/admin of the site; the `:search` system actor | `create`, `update`: editor/admin (no read-only API key) · `destroy`: admin only (no API key) |
| `ContentSearch` (`search`, generic) | ✅ any caller | — |

A site's search synonyms and aliases, at `/editor/search-synonyms`. Search
config rather than content: nothing is rendered to a visitor, so reads are the
site's editors' and the search legs', which read as the `:search` system actor
(see "The system actor"). An editor writes rules and turns them off; a hard
delete is an admin's, like everything else here.

`ContentSearch.search` is the `/mcp` `search_content` tool. It has no data of
its own: it runs `Search.global/2` as the caller, so the content read policies
decide every hit it returns — the action's own policy admits the call and
widens nothing.

## AI provider — `SiteAiProvider` (#1557)

| Resource | read | writes |
|---|---|---|
| `SiteAiProvider` (`read`) | admin only | admin only (`save`, `update`, `destroy`) |

A site's own AI provider, API key and model per feature (SEO suggestions, block
assist, `/api/ask` answers), at `/editor/site-ai`. Org-admin on both sides, like
`SiteMailRelay`: the row names the site's AI vendor and account. The features
read it as the system (`KilnCMS.LLM.SiteProvider`) — `/api/ask` has no actor at
all — tenant-scoped to the one site the request is for.

The same tenant rules as the mail relay, none of them a policy: the key is
encrypted, never read back into the form, and has no env-var or file source;
an OpenAI-compatible endpoint must be `https://` and is refused if it resolves
to a private, loopback, link-local or metadata address, at save and on every
request. Changing the provider or endpoint drops the stored key, so a co-admin
cannot send a key they were never shown to a host of their choosing.

## Single sign-on — `SiteSsoProvider`, `SiteSsoDomain` (#1561)

| Resource | read | writes |
|---|---|---|
| `SiteSsoProvider` (`read`) | admin only | admin only (`save`, `update`, `destroy`) |
| `SiteSsoDomain` (`read`) | admin only | admin only (`add`, `verify`, `remove`) |

A site's own OpenID Connect provider and the email domains it may vouch for, at
`/editor/site-sso`. Org-admin on both sides; the sign-in path reads them as the
system (`KilnCMS.Accounts.SiteSso`). `verified_at` is not writable: only
`:verify`, after a DNS lookup that found the record, sets it.

The two `User` actions the sign-in uses — `:sign_in_with_site_sso` (mints the
session token) and `:register_with_site_sso` (provisions a new account) — are
`forbid_if always()` to every authorized caller. The platform-admin bypass would
still pass that, so both also refuse any actor-carrying call in their own
preparation/change: only `SiteSso.Admission`, with `authorize?: false`, reaches
them, after the ID token, the verified domain and the cross-site rule have all
passed.

## Sessions — `SiteSessionPolicy` (#2246)

| Action | org admin (incl. platform admin) | editor | viewer | anonymous | `:accounts` system actor |
|---|:---:|:---:|:---:|:---:|:---:|
| `read` | ✅ | ❌ | ❌ | ❌ | ✅ |
| `save`, `update` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `sign_out_all` (generic action) | ✅ (admin of the tenant) | ❌ | ❌ | ❌ | ❌ |
| `record_sessions_revoked` | ❌ | ❌ | ❌ | ❌ | ❌ (⚙️ only from `sign_out_all`) |
| `destroy` | ❌ | ❌ | ❌ | ❌ | ❌ |

A site's idle timeouts and the watermark of its last "sign out everyone", at
`/editor/sessions`. `sign_out_all` is a generic action, which the macro's
create/update/destroy policy does not cover, so it has its own
`authorize_if Checks.OrgAdmin`; without a tenant it is refused, a platform
admin included. Its implementation (`Accounts.SignOutAll`) writes the watermark
through `record_sessions_revoked` with `authorize?: false`; that action is
`forbid_if always()` to every direct caller. `destroy` is refused to everyone
because the row carries the watermark, and deleting it would let every session
the watermark still catches back in; "Never" on the page saves empty timeouts
instead. `except_session_jti` must be one of the caller's own sessions on the
site, or nothing is revoked.

## Admin allowlist — `SiteAdminAllowlist` (#2248)

| Action | org admin (incl. platform admin) | editor | viewer | anonymous | `:admin_allowlist` system actor | `:operator` system actor |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `read` | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| `save`, `update` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `operator_override` | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| `destroy` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

The networks a site's console and sign-in may be reached from, at
`/editor/admin-allowlist` ([guide](admin-allowlist.md)). Saving is an org-admin
act through the `OrgSettings` write policy, and the save's own
`RefuseAdminLockout` change then refuses a list that does not admit the
address of the admin saving it. `operator_override` carries a second policy
that admits only the `:operator` system actor; policies are ANDed, so an org
admin (who passes the write policy) is still refused. It can add one entry to a
list that is on, or empty the list, and nothing else. `destroy` is
`forbid_if always()` to everyone: off is `save` with an empty list, so turning
it off has one path and one audit trail. The resource is not on JSON:API,
GraphQL or MCP.

## Content types — `TypeDefinition`

| Action | admin | editor | viewer | anonymous | system |
|--------|:-----:|:------:|:------:|:---------:|:------:|
| read (`read`, `by_name`, `archived`) | ✅ | ✅ | ❌ | ❌ | ✅ |
| `create`, `update`, `destroy` (soft), `restore` | ✅ | ❌ | ❌ | ❌ | ❌ |

Admins own the schema; editors read definitions so the editor UI can list
dynamic types. Mirrors `FieldDefinition`. Firing and delivery read them as
`%KilnCMS.SystemActor{}` (#1402), to resolve a dynamic document's public type
name, its URL segment and its schema.org `@type`.

The same reads are routed read-only over JSON:API (`/api/json/type-definitions`,
`/by-name/:name`, `/:id`, with `include=field_definitions`) and MCP
(`read_type_definitions`), so an API key reads as its owner's tier on the
host's org: editor+ lists, a viewer's key or no key gets an empty list. No
write route exists on either surface.

## Compliance — `Consent`, `HistoryAnchor`, `DocumentEvent`

`Consent`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_content`), `record` | ✅ | ✅ | ❌ | ❌ |
| `destroy` | ✅ | ❌ | ❌ | ❌ |

There is no `update` action — consent records are corrected by recording a new
one, not by editing history.

The publish gate (`Validations.RequiredConsent`) reads a document's consents as
the **system actor**, through `for_content` only (#1659); see
[The system actor](#the-system-actor).

`HistoryAnchor` — every action (`read`, `for_content`, `create`) is admin-only;
there is deliberately no destroy. The publish pipeline writes anchors, and the
chain reads them back, as `Governance.system/0`, admitted for `create` and
`for_content` only (see [The system actor](#the-system-actor)).
`ChainCheckpoint` and `ChainCheckpointEntry` are admin-only for people in the
same way, and admit the system actor to their own lists of actions:
`recent`, `unwitnessed`, `create` and `record_publication` on a checkpoint,
and `create`, `for_content` and `for_checkpoint` on an entry. None of the
three admits the plain `read`.

`History.DocumentEvent`:

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `for_document`, `by_actor`) | ✅ | ✅ | ❌ | ❌ |
| `append`, `anonymize_actor` | ❌ | ❌ | ❌ | ❌ |

Writes are refused to every role, admin included — the event log is
append-only through the History API, which writes as `History.system/0` (see
[The system actor](#the-system-actor)), and has no destroy action at all.

## Security audit log — `Security.Event`

| Action | admin | editor | viewer | anonymous | System actor |
|--------|:-----:|:------:|:------:|:---------:|:------------:|
| `read`, `list` | ✅ (own org) | ❌ | ❌ | ❌ | ❌ |
| `by_actor`, `older_than` | ✅ (own org) | ❌ | ❌ | ❌ | `:security` |
| `sign_in_from_ip` | ✅ (own org) | ❌ | ❌ | ❌ | `:scanner_guard` |
| `record`, `anonymize_actor`, `prune` | ❌ | ❌ | ❌ | ❌ | `:security` |

Append-only for people: the log is written, scrubbed and pruned only as
`Security.system/0` (see [The system actor](#the-system-actor)), and has no
create, update or destroy a person can reach. Reads are org-admin only and
tenant-scoped, so another org's admin sees nothing. Not exposed over JSON:API,
GraphQL or MCP.

## Security posture — `Security.PostureReport` (#2252)

| Action | org admin | platform admin | editor | viewer | anonymous | System actor |
|--------|:---------:|:--------------:|:------:|:------:|:---------:|:------------:|
| `run` (generic action) | ✅ (own org; site checks only) | ✅ (any org; site and deployment checks) | ❌ | ❌ | ❌ | ❌ |
| `snapshot` (generic action, #2521) | ✅ (own org; site checks only) | ✅ (any org; site and deployment checks) | ❌ | ❌ | ❌ | ❌ |

`run` is the [Security posture](security-posture.md) page's action;
`snapshot` is the same report for monitoring, in English, with every
result's `details` emptied, and reused for 30 seconds per site and scope set
on each node (`Posture.snapshot/2`). The resource has no data layer and
stores nothing else. One policy covers both actions: `forbid_if
Accounts.Checks.DraftWriteKey` (a `:draft_write` key is refused whoever owns
it, since such a key may draft and nothing else), then `authorize_if
Checks.OrgAdmin`. The site
is the action's tenant, never an argument; with no tenant it is the default
site, which an admin of another site is refused on, and so is an admin whose
membership is still waiting for approval. What a caller *gets* is decided
inside the action from the same actor: every caller gets the `:site` checks,
and a caller whose effective platform role is `:admin` (standing or by a live
grant) also gets the `:deployment` checks (`Posture.scopes_for/1`, shared by
both actions). The console page re-checks the tier
on **Run checks again**, as the security log does.

Three checks read rows no policy would show the caller, with
`authorize?: false` and a written reason at the call site: the site's
administrators and editors (`Posture.Checks.SecondFactor`, through
`Scoping.users_with_tier_query/2`, as the review roster reads it), the
platform administrators (`Posture.Checks.OperatorSecondFactor`), and every
valid API key with its owner (`Posture.Checks.ApiKeys`). Each reaches the page
only as counts and, under **Details**, email addresses and key names; the last
two are `:deployment` checks, shown only to platform admins. The idle-timeout,
allowlist and password-policy checks read through their existing
`:accounts` and `:admin_allowlist` grants (above), with no new grant. At most
three reports of one site run at once on a node; a fourth is refused with
`Security.Errors.PostureBusy`, which is not a permission refusal (the JSON
endpoint answers it `503` with `retry-after: 5`). Not on JSON:API, GraphQL or
MCP: `snapshot` is exposed only at `GET /api/security/posture`, without
`details` ([API guide](api.md#security-posture-monitoring)); `run` is the
page's alone.

## Automation & newsletter

`Automation.Rule`, `Newsletter.Subscriber`, `Newsletter.Segment`,
`Newsletter.SegmentMembership`, `Newsletter.NewsletterSend` all carry the same
single policy: `authorize_if OrgAdmin` on every action. Admin-only across the
board; editors, viewers and anonymous callers get nothing. Creating a
campaign (`Newsletter.send_as_newsletter/2`) runs under that policy as the
sender (#1655) — the console's tier check is UX, not the gate.

The public newsletter flows (`subscribe`, `confirm`, `unsubscribe`) run as the
**system** behind signed-token checks. The send pipeline runs as the
**system actor** (`Newsletter.system/0`; see [The system actor](#the-system-actor)),
and the send guard reads the target segment as the sender. The two token reads
(`by_confirm_token`, `by_unsubscribe_token`) declare `multitenancy :bypass`
deliberately — the token is the secret, and the confirming visitor has no
tenant context.

## Delivery internals — `PublishedArtifact`, `ReferenceEdge`, `BlockEmbedding`, `SyncExposure`

| Resource | read | `create` / `update` / `destroy` |
|---|---|---|
| `Firing.PublishedArtifact` | ✅ whoever may read the **source document** | ❌ **everyone, incl. admin** (the generic `refire`, which queues a fire and writes nothing itself: ✅ editor / admin, and the `:overlay` system actor) |
| `Firing.ReferenceEdge` | ✅ editor / admin | ❌ **everyone, incl. admin** |
| `Search.BlockEmbedding` | ✅ editor / admin | ❌ **everyone, incl. admin** |
| `Firing.SyncExposure` | ❌ **everyone, incl. admin** | ❌ **everyone, incl. admin** |

These have no caller-facing write path: the firing engine, the search indexer
and the sync API write them as the **system**, so nobody — admin included — can create,
update or destroy one through a policy meant for people. All three now say so in
the policy block rather than being reached around it: each admits
`%KilnCMS.SystemActor{}` by name (#1402, and see
[The system actor](#the-system-actor)). `Search.TagEmbedding` — absent from the
table only because nothing caller-facing reads it — has the same shape.

All three used to read `authorize_if always()`. That was tightened in #565, and
the reason it was safe is that every production reader is a system path:
`Firing.Delivery` / `Firing.Engine.read/4` for artifacts, `Firing.References`
for the re-fire wave, `Search.BlockIndexer` / `Search.BlockSearch` /
`Search.Related` for embeddings. What changed is what an *actor-carrying*
caller sees. Every one of those system paths now carries
`%KilnCMS.SystemActor{}` rather than `authorize?: false`.

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

## In-app notifications — `Notifications.Notification` (#1320)

| Action | own recipient | another user (any role) | anonymous |
|--------|:-------------:|:-----------------------:|:---------:|
| read (`read`, `for_user`, `unread_for_user`) | ✅ | 🔎 nothing | 🔎 nothing |
| `mark_read`, `mark_unread` | ✅ | ❌ | ❌ |
| `notify` (create) | ❌ | ❌ | ⚙️ actor-less only |
| `unread_about` (the notifier's duplicate check, #1785) | ❌ | ❌ | ⚙️ actor-less only |
| `forget_actor`, `forget_recipient` (erasure: blank the actor on others' rows; delete the erased account's own, #2514) | ❌ | ❌ | ⚙️ actor-less only |

`authorize_if expr(user_id == ^actor(:id))` is the whole read policy, and this
is the one resource in the tree with **no admin bypass at all**. A notification
list is a reading history — who was named in which review note, which drafts
someone is watching — and a platform admin has no operational need for it. The
sibling `Accounts.PushSubscription` *does* have an admin bypass (an operator
has to be able to see where a device came from); this deliberately does not.

`notify` is the notifier's write, and it addresses somebody *other* than
whoever acted, so it cannot be authorized against the acting user. Rather than
calling it with `authorize?: false`, it is gated `forbid_if actor_present()` +
`authorize_if always()`: the policy still runs and still decides, so an
authenticated caller that reaches the action is refused by a rule a reader can
see. `KilnCMS.Notifications.record_in_app/1` is the only caller.

`unread_about` is the one read on the same terms, and for the same reason: before
writing a review request, publish notice or return to draft, the notifier asks
whether that recipient already has the same one waiting unread for the same
document, and writes nothing if so (#1785). It answers about a recipient who is
not the caller, so it is actor-less only. The self-only read policy names its
three actions rather than `action_type(:read)`, so a read added later matches
no policy and is refused until it gets one.

An actor-less *read* (of the three self-only reads) is fail-closed for free: `^actor(:id)` templates to `nil`,
the filter reduces to `user_id == NULL`, and no row satisfies it.

Org-scoped (`multitenancy strategy :attribute, attribute :org_id`) — a user who
edits two sites sees each site's notifications in that site's console only.

## Saved views — `CMS.SavedView` (#1593)

| Action | admin | editor (owner) | editor (not owner) | viewer | anonymous |
|--------|:-----:|:--------------:|:------------------:|:------:|:---------:|
| read (`read`, `visible`) — private view | ✅ | ✅ | 🔎 nothing | 🔎 nothing | 🔎 nothing |
| read — shared view | ✅ | ✅ | ✅ | 🔎 nothing | 🔎 nothing |
| `create` (private) | ✅ | ✅ | — | ❌ | ❌ |
| `create` / `update` with `shared: true` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `update`, `destroy` — private view | ✅ | ✅ | ❌ | ❌ | ❌ |
| `update`, `destroy` — shared view | ✅ | ❌ | ❌ | ❌ | ❌ |

A saved view is a named filter on the content list, so it is an editor's
resource: `forbid_unless OrgEditor` heads every policy. An editor manages their
own private views; sharing a view with the whole site, and editing or deleting
a shared one, is an admin's (`OrgAdmin` bypass), so the team's view cannot be
renamed out from under it by one member. Org-scoped like every console row: a
view saved on one site is never listed on another. Erasing an account deletes
its private views on every site as part of the erasure (`authorize?: false`,
filtered to that owner, #2514); its shared views stay.

## Webhook deliveries — `WebhookDelivery`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `recent`), `create`, `record_attempt`, `mark_recovered`, `scrub_payload`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Delivery history is admin-only. The delivery pipeline writes the row and its
attempts as the system actor (never `destroy`), and the `prune_deliveries` and
`scrub_retraction_payloads` AshOban triggers run under the
`AshObanInteraction` bypass.

## Propagation records — `Propagation`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `completed_since`, `open_since`), `open`, `settle_cdn`, `complete`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Propagation records (#1927) are admin-only. The webhook pipeline opens and
settles them and the CDN purge worker records the purge half, each as its
system actor (never `destroy`); the `prune_propagations` AshOban trigger runs
under the `AshObanInteraction` bypass.

## The API-key axis

Role and audience are not the only axes. An actor authenticated by a `kiln_…`
API key carries an immutable **access scope** (`:read`, `:read_write` or
`:draft_write`), and three checks gate on it:

| Check | Matches |
|---|---|
| `KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess` | an API-key actor whose key is *not* `:read_write` — i.e. a `:read` key, or any key whose record cannot be inspected (**fails closed to read-only**) |
| `AshAuthentication.Checks.UsingApiKey` | *any* API-key actor, regardless of scope |
| `KilnCMS.Accounts.Checks.DraftWriteKey` | an actor whose key is `:draft_write`, in three modes: `:any` (also the `forbid_if` on `Security.PostureReport`), `:outside_allowlist` (the `forbid_if` on `Content`), `:within_allowlist` (the grant inside `EditableContentType`'s policy) |

Applied as `forbid_if` clauses placed **before** the `OrgAdmin` bypass, so a key
minted on an admin account cannot skip them:

| Resource | `create` / `update` | `destroy` | `purge` (hard delete) |
|---|---|---|---|
| `Page`, `Post`, `Entry` | forbid `ApiKeyWithoutWriteAccess` | forbid `ApiKeyWithoutWriteAccess` | forbid **any** API key |
| `MediaItem`, `Tag`, `TagGroup`, `Category` | forbid `ApiKeyWithoutWriteAccess` | forbid **any** API key | — |
| `Tagging`, `ContentLink`, `RelatedLink` | forbid `ApiKeyWithoutWriteAccess` (all write types) | — | — |

`ApiKeyWithoutWriteAccess` is untouched and still matches a `:draft_write` key,
so **every resource above refuses it** — media, taxonomy, menus, links — except
`Page`/`Post`/`Entry`, which carve it back in through `DraftWriteKey` (#2273):

| `:draft_write` on content | |
|---|---|
| Allowed | `create`; `update` and `autosave` of a row that is `state == :draft` AND `author_id ==` the key owner |
| Refused | everything else, by allowlist: every other update action (`submit_for_review` included: a human moves work into review), publish/unpublish/schedule/archive, `destroy`, `purge`, a published row (also "Live · draft"), an in-review or archived row, another author's draft, any `scheduled_at` change |
| Ordering | the `forbid_if ... mode: :outside_allowlist` sits ABOVE the `OrgAdmin` bypass, so promoting the key's owner after mint widens nothing |
| Mint | admin-only; lifetime capped by `:draft_write_key_max_ttl_days` (default 30); owner must have no editor/admin tier (defense in depth, `Validations.DraftWriteKey`) |
| Rotate | `ApiKey :rotate` (`POST /api/keys/rotate`): only the `:draft_write` key itself, unrevoked, unexpired, inside the admin-set `rotatable_until` (`RotatableDraftWriteKey`; admins and every other actor refused). No input; the successor copies owner, scope, name and window, expires at `min(now + TTL cap, rotatable_until)`, and the presenting key is revoked under a row lock in the same transaction. Reuse of a rotated-away key on that endpoint (after 120 s) revokes the lineage and mails platform admins (`ApiKeyReuse`) |
| Reads | published, audience-permitted content plus the key owner's **own drafts** (`DraftWriteOwnDrafts`, so a PATCH can load its row). Version history: only versions of such drafts, nothing for a viewer-tier owner via the revisions API. That scope is per owner, so a second key on the same owner reads the first key's draft history (and coalesces its autosaves over it); the per-key provenance fields are therefore never written to version `changes` (`ignore_attributes`). A promoted owner reads as that role |
| Preview links | `POST …/preview-token` is bounded to drafts the key's owner authored, on top of the editor-tier gate (`PreviewToken.mint/3`); a viewer-tier owner mints none |
| Links | a draft cannot set tags, category or related links (those writes are refused to the key) |
| Provenance fields | `created_via_key_id`, `created_via_key_name`, `on_behalf_of` on `Content` are public attributes behind **field policies**: visible to `ReadableContentType` (editor/admin tier) and to a `:draft_write` key for drafts it created (`DraftWriteOwnProvenance`); everyone else (anonymous, preview-link, viewer tier, another key) gets them omitted (JSON:API) or null (GraphQL). `field_policy :*` is `authorize_if always()`, so no other field changes |

The net rule: a `:read` key may read whatever its owner may read and write
nothing; a `:read_write` key may author as its owner; a `:draft_write` key may only create and edit its own drafts; **no** key may hard-delete
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
they get no `uuid_primary_key` of their own. They are covered first by requiring
the whole tree's multiset of role-restricted non-default nested values to be
identical before and after a non-admin write (#774): such a value can be neither
introduced nor dropped, but a column already holding an admin-set value may be
resubmitted unchanged.

A count alone cannot say *which* child holds a value. The content editor stamps
each nested child an `"id"`, and where those ids exist the check binds each
admin-set value to the child holding it (#865): a child returning under a known
id must return with that id's value, and a child that held a restricted
non-default value must return under the same id still holding it. Independently,
an id naming **two** children in one submission is always refused — that
collision would otherwise let a decoy satisfy the binding while the rendered
child lost the value.

The binding is **required, not gated** (#954, #865): an id-less submission
against an identified stored tree is refused, not silently downgraded to the
count-only multiset. `KilnCMS.CMS.Calculations.BlockIds` is what makes that
enforceable — it's what closed the gap that used to require gating (nested
child ids were unreadable on a draft) — and it, along with the two narrow
carve-outs that remain (`restore_version`, and a stored tree whose children
never had ids to begin with), is documented in full at
`KilnCMS.CMS.Changes.EnforceBlockFieldPolicy`'s moduledoc rather than
repeated here.

See residual risk 9 in [`threat-model.md`](threat-model.md) for what this does
and does not guarantee — in particular that a wholly id-less stored tree keeps
the re-target until stamped, and that reusing another block's id remains open.

## Coverage

Every resource registered in `:ash_domains` appears above.
`test/kiln_cms/policy_coverage_test.exs` fails the build if a resource is ever
added without `Ash.Policy.Authorizer` and a `policies` block — the failure mode
that matters, since a resource with no authorizer is not merely unprotected but
silently world-writable.
