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

  # System-only actions, and only those.
  forbid_unless action([:reindex_search_text, :set_embedding])
  authorize_if KilnCMS.Checks.SystemActor
end
```

For a person the first clause has already decided; for a system actor every
other action forbids at the second. Nothing is short-circuited.

**Scope is per resource and action, not per subsystem.** The `subsystem` label
on the struct (`SystemActor.new(:firing)`) is provenance for logs, telemetry
and `Ash.Error.Forbidden` messages; the check matches any system actor.
Deciding "system may record a view but not purge content" is done by which
rows appear below — encoding the caller's identity a second time inside the
policy would let the two drift.

The struct carries no `:id` and no `:role`, so every actor-attribute check
written for people resolves it to nothing: `Scoping.effective_tier/2` returns
`:none`, `Scoping.audiences/2` returns `[]`. A system actor can therefore only
ever be authorized by an explicit clause below.

| Resource | Actions admitting `Checks.SystemActor` | Why |
|---|---|---|
| `Firing.ReferenceEdge` | `read`, `from_source`, `to_target`, `upsert`, `destroy` | The re-fire wave rebuilds a document's outgoing edges on every fire and walks them backwards to find referrers. The graph is derived from the document itself and has no caller-facing write path (`forbid_if always()` for everyone, admin included), so the fire path was the only thing the old bypass existed for. |
| `Firing.PublishedArtifact` | `read`, `for_document`, `get_surface`, `upsert`, `destroy` | The firing engine is the only writer an artifact has ever had, and unpublish is the only destroyer. On read the actor is admitted **alongside** `Checks.DocumentReadable`, not instead of it: delivery settles the audience question on the *document* first (`Firing.Delivery.resolve/5`) and then fetches the body by id, so re-running the document check there with the anonymous actor would refuse every gated page delivery had just unlocked. |
| `Firing.SyncExposure` | all (`read`, `for_documents`, `record`) | The sync API's record of which document ids it has handed an anonymous caller (`GET /api/sync`, `KilnCMS.Firing.Sync`). A tombstone may name only an id recorded here, so the table is what keeps a never-public draft, gated or locked document out of a delta. No person has a read or write path — `forbid_if always()` for everyone, admin included. |
| `CMS.TypeDefinition` | `read`, `by_name`, `including_archived` | Read-only. The fire path resolves a dynamic document's public type name and its schema.org `@type` from its definition. Writing one is still admin-only. |
| `CMS.FieldDefinition` | `read`, `for_type`, `for_definition` | Read-only. Firing needs the field schema to turn a document's `custom_fields` values into JSON-LD, and every content write validates against it (`Changes.ApplyCustomFields`, as `CMS.Bookkeeping.system/0`, #1659, with `authorize_with: :error` — a filtered "no definitions" would drop every stored value). Defining a field is still admin-only. |
| `Analytics.Funnel`, `Analytics.FunnelStep` | the primary `read` **only** | Funnel *definitions*, never traffic (#1659). The experiment engine resolves a `:funnel_completion` goal to its funnel's last step — delivery's cached target map (`Experiments.funnel_targets/1`) and the `:start` guard (`GoalConfigured`) — and `mix kiln.experiment` resolves `--goal-funnel SLUG`. All three read as `Analytics.system/1` and fail closed (`authorize_with: :error`): a refused read under the filter answers `[]`, which delivery would cache as "no funnel targets". Narrowed inside the `action_type(:read)` policy with `forbid_unless action(:read)`, so `FunnelStep.:for_funnel` (the builder's read) and every write stay editor/admin. No traffic resource in this domain admits the system actor. |
| `Search.BlockEmbedding` | `read`, `for_document`, `nearest`, `upsert`, `destroy` | The per-block semantic index. `Search.BlockIndexer` is the only writer it has ever had — rows are derived from the document's own block tree — and `BlockSearch` / `Search.Related` are its only readers. Whether a *caller* may see a hit is decided one tier up, when the matching document is hydrated under their own authorization. |
| `Search.TagEmbedding` | `read`, `for_tags`, `nearest`, `upsert`, `destroy` | Same shape, for tag-name vectors: written by `TagEmbeddingWorker` and `Search.Related`, read by `Search.Related` only. |
| `CMS.MediaDerivative` | all (`read`, `for_item`, `record`, `destroy`) | The bookkeeping row behind each cached on-the-fly image transform (`/media/:id/t/…`). `Media.Derivatives` is its only reader and writer: it counts an item's rows against the per-item budget, prunes the ones cut from a replaced original or around a moved focal point, and lists them for a purge. No person — admin included — reads or writes a row, and there is no API surface. Who may *see* a transform is decided on the `MediaItem`, by the transform controller's ordinary policy-checked read. |
| `CMS.MediaItem` | `read` **only**, named inside the `action_type(:read)` policy | The alt-text publish gate (`Validations.MediaAltText`) asks which of a document's media ids are marked `decorative`. It also runs for `publish_scheduled`, whose caller is the AshOban scheduler with no actor, so it cannot read as the caller. Narrowed by `forbid_unless action(:read)`: through `library` or `search` it reads only what a stranger may (public, not quarantined), `trashed` stays admin-only, and it has no write. A refusal fails the publish closed ("alt text could not be checked"), never "not decorative". |
| `CMS.Consent` | `for_content` **only** | The required-consent publish gate (`Validations.RequiredConsent`) lists one document's consents, for the same reason (the scheduler has no actor). It may not record a consent or list them all. A refusal fails the publish closed ("consents could not be checked"), never "nothing required". |
| `CMS.MediaItem` | `read`, `quarantine_expired`, `record_processing`, `release_quarantine`, and `purge` of a **quarantined** item only | The media pipeline, as `Media.system/0` (#1659). `VariantWorker`, `AVWorker` and `AVStripWorker` re-read the item they were enqueued for (quarantined or gated included) with `authorize_with: :error`, so a refused read fails the job rather than reading as "gone" — which for the strip would leave the upload quarantined until the reaper deleted it. The derived fields (dimensions, duration, variants, `variant_failures`) are written through `record_processing`, never `update`, so the grant cannot gate an item or touch its tags or editor fields; the strip releases through `release_quarantine`. `QuarantineReaper` scans every site through `quarantine_expired` (a `multitenancy :bypass` read, admitted to the system actor **alone** by a policy above the admin bypass) and purges; the strip purges an upload it refuses. `purge` is admitted only while `quarantined == true`: a released item may be in use, and deleting it stays an admin act. The regeneration scan reads with `authorize_with: :error` too. Not admitted: `update`, `update_metadata`, the soft `destroy`, `trashed`, `restore`, `increment_downloads`. |
| `CMS.Form` | `read` **only** | The form pipeline, as `Forms.system/0` (#1659). `NotificationWorker` and `AutoresponderWorker` re-read the form a submission was queued for, active or not, with `authorize_with: :error`: a refused read would filter to "form deleted" and the mail would silently never go out, so it fails the job instead. Building, editing or deleting a form stays admin-only. |
| `CMS.FormField` | `for_form` **only** | The submission is validated against the form's fields; `AutoresponderWorker` and the autoresponder-template validation (`Forms.Autoresponder.definitions_for_form/4`, which a seed or template instantiation reaches with no editor session) read them too. Every one runs with `authorize_with: :error`: a refused read filtering to `[]` would accept a submission with every required field skipped and every value dropped. |
| `CMS.FormSubmission` | `create` **only** | `Forms.submit/3` records a visitor's validated submission. Visitor data stays admin eyes only: the system cannot read a submission back, re-mark it or delete one. The retention prune is the AshOban trigger's own bypass, unchanged. |
| `CMS.SiteEmbedSettings` | `read` **only** | The embed route resolves a site's framing default on a visitor's request (`Forms.EmbedPolicy.org_default/1`). The read runs with `authorize_with: :error`, and a failure resolves to `[]` (same-origin only) — never to "no row", which would inherit the deployment's `EMBED_ORIGINS`, wider than a site default of `[]` it may be hiding. Saving the default stays an admin act. Granted through `OrgSettings`' `system_actions:` option. |
| `Accounts.ThrottleCounter` | `prune` **only** | The shared auth budgets' counter table (#1619). The scheduled prune deletes closed windows; the actor is admitted so an operator or a test can run it by hand. The budgets are charged by `Accounts.ThrottleStore` in raw SQL before anyone is authenticated, so no action serves that path. `read` is forbidden to everyone, admin included: a count per hashed key is an oracle nobody needs. |
| `Accounts.Organization` | `read` **only** | The tenant registry (#1659). `Accounts.list_org_ids/0` is the tenant list behind every all-orgs sweep (AshOban's per-tenant scheduler scans, GDPR erasure, audit verification, the digests), and `Accounts.default_org/0` is the default-org fallback. Both read with `authorize_with: :error`, so a lost grant raises (or answers `:error`) instead of filtering to `[]`, which every sweep would have read as "no orgs, nothing to do". Narrowed inside the member-read policy with `forbid_unless action(:read)`: `by_slug` and `by_custom_domain`, the request path's tenant resolution, are not admitted, and creating or editing an org stays platform-admin. |
| `CMS.ExternalLink` | `read`, `observe`, `record_check`, `destroy` | The outbound link checker's bookkeeping (#474, #1659), as `Links.system/0`. `Links.Sweep` upserts each occurrence it finds in published content, prunes the rows it no longer sees and reads which URLs are due; `Links.CheckWorker` reads a URL's failure count and writes the verdict to every row sharing it. Every existing action is named, inside the editor read policy and the admin write policy, so one added later is not admitted by default. The reads that back a decision fail closed: the failure-count read and the due-URL stream run with `authorize_with: :error` (a refused read would filter to "pruned" or "nothing due"), and a refused `observe` aborts the sweep before its prune, which would otherwise delete every row and its failure count. The report page reads as the viewing editor, not as the system. |
| `CMS.SiteLinkCheck` | `read`, `record_sweep` **only** | The sweep and the check worker read whether outbound checking is on (re-read immediately before each request), and the sweep stamps `last_swept_at`. The read runs with `authorize_with: :error` and any error resolves to "disabled", the closed direction for a switch that authorizes egress. The settings form's `save` is not admitted: turning checking on stays an admin act. Granted through `OrgSettings`' `system_actions:` option. |
| `Automation.Rule` | `read` **only** | `KilnCMS.Automation.RuleWorker` re-reads the rule it was enqueued for, and `Automation.dispatch/3` matches an event against the site's rules; that match fails closed (`authorize_with: :error`), so a refused read fails the dispatch job rather than dropping every rule. Authoring a rule is still admin-only — the grant is narrowed to reads inside the existing `policy always()` with `forbid_unless action_type(:read)`. |
| `Social.Account` | `read`, `enabled_for_provider`, `record_post` **only** | The announcer lists a provider's enabled accounts for a publish, `Social.configured?/1` asks whether any is enabled, and the announcer stamps "last posted" (`record_post`, which accepts no attributes) on the account it posted as (#1659). Minting, editing or deleting the credentials for a site's public voice stays an admin act, narrowed the same way. |
| `Social.Post` | `claim`, `succeed`, `fail`, `unresolved`, `skip` **only** | The announce ledger (`Social.system/0`, #1659). The claim is written before the provider is called and its unique index is the "announce once" guarantee; a refused claim is a Forbidden that posts nothing, never "already announced". No read and no `destroy`: a deleted claim would free the dedupe key for a second post. |
| `CMS.WebhookEndpoint` | `read`, `record_delivery_success`, `record_delivery_failure` **only** | The dispatch scan and the delivery worker read endpoints (`Webhooks.system/0`, #1659), and the worker keeps the health counters behind auto-disable. Creating, editing or deleting an endpoint stays an admin act. Both reads pass `authorize_with: :error`: a refused scan would read as "no endpoint subscribed" and a refused lookup as "endpoint deleted", so a lost grant is logged (and, in the worker, retried) instead. |
| `CMS.WebhookDelivery` | `read`, `create`, `record_attempt` **only** | The delivery ledger: dispatch writes the row, the worker re-reads it (failing closed: a refused read is retried, not taken for "pruned") and records each attempt. `destroy` is not admitted; the prune trigger runs under its own `AshObanInteraction` bypass. |
| `Mail.Settings` | `read`, `init` **only** | The DKIM signer and DNS checks read the singleton with no actor of their own, and `ensure_settings!/0` inserts the empty row (`Mail.system/0`, #1659). The read fails closed: `nil` would read as "no DKIM key" and send unsigned. Changing the key or the server IP stays platform-admin. |
| `Mail.SuppressedRecipient`, `Mail.SiteSuppressedRecipient` | `read`, `suppress` **only** | The pipeline looks every recipient up before queuing and records a hard bounce on the list of the relay that reported it (`Mail.system/0`, #1659). The lookup passes `authorize_with: :error`: a refused read would otherwise be "not suppressed" and resume mail to dead addresses, so `enqueue!/2` drops the recipient and logs, and the newsletter worker retries. Clearing a suppression (`destroy`) stays an admin act. |
| `CMS.Comment` | `create`, `read` | An editorial-intelligence reaction posts its findings as a document-level comment (#946) on a thread it must be able to read. No `author_id` is stamped — the actor has no `:id` — so `created_by_rule_id` carries the provenance. `update` is **not** admitted: automation posts, it does not edit what anyone said. |
| `CMS.Task` | `create`, `read`, and of the updates `complete` and `mark_overdue_notified` **only** | The same reaction assigns findings as a task, and the lifecycle sweep probes for an open review before opening another. `AssigneeIsEditor` still vets the assignee (validations run whatever the actor is) and `creator_id` stays unstamped. A publish completes the record's open tasks (`Changes.AutoCompleteTasks`, as `CMS.Bookkeeping.system/0`, #1659) — a scheduled publish has no person to do it as — reading them with `authorize_with: :error`, so a refused read fails the publish instead of leaving them open. The task digest (`Notifications.TaskDigestWorker`, as `Notifications.system/0`, #1659) reads due and newly overdue tasks with `authorize_with: :error`, since a refused read would read as "nothing due" and the digest would stop without a word, and it writes the "`task.overdue` already fired" stamp in the same transaction as the event's dispatch, as an atomic claim that refuses a row another run already stamped. Both updates are named inside the `action_type(:update)` policy with `forbid_unless`: assigning, editing or reopening a task stays an editor's. The notifier also reads a comment thread's participants from `CMS.Comment`'s existing `read` grant, with `authorize_with: :error`. |
| `Accounts.PushSubscription` | `read`, `for_users`, `touch_delivered`, `destroy` **only** | Web Push delivery (#628, #1659) as `Push.system/0`: the sender's lookup (`for_users`), the worker's reload by id (`read`), the "last delivered" stamp, and pruning a device its push service reported gone. The two reads fail closed with `authorize_with: :error`, because a refused read would filter to "no devices" and drop every push without a word; the sender logs the refusal and the worker returns an error for Oban to retry. `for_user` (the settings list) and `bound_to_key` (the site-key rotation sweep) are not admitted. `subscribe` is authorized against the device's own user (`relating_to_actor(:user)`) rather than bypassed, so no actor other than a platform admin (the resource's top-of-stack bypass) can register a device for somebody else. The key-rotation sweep (`CMS.Changes.DropVapidSubscriptions`) deletes the rotated key's rows through the same `destroy` grant. |
| `CMS.Redirect` | `create`, `destroy` | A rename of a published record's address leaves a 301 behind and retires any redirect squatting on the new one (`Changes.RecordSlugRedirect`, as `CMS.Bookkeeping.system/0`, #1659). The rename is an editor's; writing a redirect by hand stays an admin act. A refused create fails the rename, so a published URL is never vacated without its 301. `read` is world-readable already. |
| `CMS.ReleaseItem` | `mark_cancelled` **only** | Archiving a release that never shipped frees its pending items (`Changes.CancelPendingReleaseItems`, as `CMS.Bookkeeping.system/0`, #1659). The archiving editor may not reach a `mark_*` write — they rewrite what rollback restores from — so the pending items are read as the editor, with `authorize_with: :error` (a refusal must not archive the release with its items still reserving their content), and marked cancelled as the system. The other `mark_*` writes stay the release worker's. |
| `CMS.FormSpamSettings` | `read` **only** | The submission scorer (`Changes.ScoreFormSubmission`, as `CMS.Bookkeeping.system/0`, #1659) reads the site's disallowed keywords for an anonymous visitor. With `authorize_with: :error`, and a read error no longer answers `[]`: either raises, so a submission is refused rather than stored unscored. Saving the list stays an admin act. Granted through `OrgSettings`' `system_actions:` option. |
| `CMS.ContentRelease` | `read`, `abandon`, `mark_published`, `mark_failed`, `mark_rolled_back`, `mark_rollback_failed` **only** | The release go-live and rollback worker (`CMS.Releases`, `CMS.Workers.ReleaseWorker`, #1659) re-reads the release it was enqueued for, records the outcome, and abandons its own claim when a run crashes. The four `mark_*` writes carry no other policy, so no person, admin included, may stamp a release `:published` that never published. `read` is narrowed to the plain action (not `editable`, `by_state`, `in_window`), and `abandon` sits inside the admin policy with `forbid_unless action(:abandon)`: scheduling, starting and shipping a release stay an admin's decision. |
| `CMS.ReleaseItem` | `for_release_with_status`, `mark_applied`, `mark_skipped`, `mark_rolled_back` **only** | The same worker lists a release's pending (or applied) items and records what it did to each, including the `prior_state` / `prior_version_id` rollback restores from; no person may write those. The item read fails closed (`authorize_with: :error`): a refused read would otherwise be an empty release, marked `:published` having published nothing. Composing a release (`add`, `set_action`, `cancel`) stays editor work. The *content* steps of a claimed release still run `authorize?: false`, since the system actor holds no content grant. |
| `CMS.SiteEditorialSettings` | `read` **only** | `Checks.EditorMayPublish` asks whether editors may publish from inside the publish (whose caller may be the scheduler), and `TaskSettings.site_default/1` asks whether publishing completes tasks from a release's go-live. Both fail closed: a refusal answers "editors may not publish", and raises rather than applying the shipped task default. `save` is not admitted. Granted through `OrgSettings`' `system_actions:` option. |
| `Billing.Settings` | `read`, `init` **only** | The checkout path and the webhook receiver resolve provider credentials with no actor of their own, and `ensure_settings!/0` inserts the empty singleton on first use. Narrowed inside the existing platform-admin policy; the write path to payment credentials stays platform-admin, and every secret column is vault-encrypted and `sensitive?`. |
| `Billing.Membership` | `read`, `apply_provider_state`, `anonymize` | A paid membership is what grants an audience and a newsletter tier segment, so the tier sync must see the ones it is syncing. The two writes are `forbid_if always()` for every person — this resource has no admin bypass — and are taken only by the verified webhook worker, the reconcile sweep and GDPR erasure. |
| `Billing.WebhookEvent` | `read` (by id), `claim`, `mark_processed`, `mark_ignored`, `mark_failed` **only** | The webhook worker re-reads its recorded event, claims it and settles it (#1659). Every write is closed to every person. `receive` stays the receiver's `authorize?: false` (a webhook has no actor; the provider's HMAC is the grant), and `destroy`, `recent`, `by_event_id` and `purgeable` are not admitted: a system actor cannot insert, list or erase a payment event. The worker's read fails closed, since `nil` would mean "event gone" and cancel the job. |
| `Billing.MembershipEvent` | `read`, `append`, `anonymize_actor` | The append-only entitlement trail. No person may write one and there is no `destroy` action at all; the billing pipeline appends and GDPR erasure redacts the acting admin. The governance dashboard reads it as `Governance.system/0` (#1659), with `authorize_with: :error` so a lost grant raises rather than showing an empty trail. |
| `Newsletter.Segment` | `read`, `for_tier`, `sync_managed` **only** | The tier-backed lifecycle is driven by billing, not by a human: both write actions are `forbid_if always()` for everyone including admins. Managing a segment by hand stays an admin act, so the grant is narrowed inside the blanket admin policy as well — Ash ANDs policies, so both halves are needed. |
| `Newsletter.Subscriber` | `read`, `confirmed`, `link_member` **only** | `link_member` is the one write that may set `user_id`, and it is `forbid_if always()` for everyone. The send pipeline (`Newsletter.system/0`, #1659) reads a campaign's recipients (`confirmed`) and re-reads each one before delivery (`read`), both with `authorize_with: :error`: a refused list would read as "no subscribers" and mark the campaign sent having mailed nobody, and a refused re-read would cancel the recipient's unique job for good, so both log and retry. Narrowed the same way, so admin-only list management and every consent change are untouched. |
| `Newsletter.NewsletterSend` | `create`, `read`, `mark_sending`, `mark_sent`, `record_sent`, `record_failed` **only** | The "on publish → send the newsletter" automation (`Automation.RuleWorker`) records the campaign it queues (#1655). The send pipeline (`SendWorker`, `MailWorker`, as `Newsletter.system/0`, #1659) re-reads the campaign it was enqueued for, failing closed (a refusal retries rather than cancelling as "not found"), and keeps the fan-out and per-recipient counters. A counter write that fails after delivery is logged, not retried, so nobody is mailed twice. `mark_failed` and `destroy` stay admin acts: the row is the record of what went out and the automation's dedupe key. Narrowed inside the blanket admin policy. |
| `Newsletter.SegmentMembership` | all | The join row between a subscriber and a tier segment. The sync genuinely reads, creates and destroys them as entitlements change, and the row carries nothing beyond the two ids. |
| `Federation.Follower` | all (`read`, `deliverable`, `follow`, `record_failure`, `record_success`, `destroy`) | The follower list is kept by the system, not by a person (#1659): the inbox records a signed remote `Follow` (no Kiln user is behind it) and removes it on `Undo`, the fan-out reads who to deliver to, the delivery worker keeps the failure count and drops a dead follower, and a block removes the followers it covers. The tenant filter still applies. |
| `Federation.Delivery` | `read`, `create`, `settle` **only** | The fan-out and the inbox's `Accept` write one ledger row per follower; the delivery worker re-reads and settles it. `destroy` is **not** admitted — the ledger is pruned by its AshOban trigger, and a system actor cannot erase the record of whether a POST went out. |
| `Federation.Block` | `read` **only** | The inbox asks whether an actor or its instance is blocked before it records a `Follow`. Deciding what to block stays an admin act. |
| `Federation.SiteFederation` | `read`, `record_delivery`, `enable`, `disable`, `rekey` **only** | Every federation path starts from the site's settings (`Federation.active_settings/2`); the delivery worker stamps "last federated"; and `mix kiln.federation` (`enable`, `disable`, `rekey`) is an operator at a shell on the host, the deployment's own authority. The settings form's `save` and `destroy` are not admitted — editing the site's public identity stays an admin act. Granted through `OrgSettings`' `system_actions:` option, which narrows inside the macro's read and write policies. |
| `Federation.SeenSignature` | `record`, `expired`, `destroy` **only** | The inbound replay-nonce store: `HttpSignature` records a verified signature, `SeenSignatureSweeper` counts and deletes expired rows. The plain `read` is refused to everyone, the system actor included — nothing needs to list nonces. No person has any path to this table. |
| `Experiments.Experiment` | `read`, `running`, `create`, `start`, `conclude` **only** | Delivery reads the running set (`Experiments.system/0`, #1659) to decide which arm a page serves and whether a form submission or a later page view converts; the variant-write and `:start` guards read the parent and the running set. `mix kiln.experiment` is an operator at a shell on the host and creates, starts and concludes. `update`, `archive` and `destroy` are not admitted — narrowed inside the admin write policy with `forbid_unless action(...)`. Every read that backs an assignment, a start guard or a result passes `authorize_with: :error` (and `has_many :variants` sets `authorize_read_with :error`, since the option does not reach a relationship load), so a lost grant errors instead of answering "nothing is running". |
| `Experiments.Variant` | `read`, `create` **only** | The arms delivery assigns between (loaded with the running set) and the `:start` guard counts; `mix kiln.experiment variant` adds one. Re-weighting or removing an arm stays an admin act. |
| `Experiments.VariantDay` | `read`, `record_impression`, `record_conversion` **only** | The per-variant daily counters. Delivery and the form-submission path write the two counters; `mix kiln.experiment show` reads them, failing closed (the results panel reads them as the viewing editor). `destroy` is not admitted — a system caller cannot erase a result. |
| `CMS.HistoryAnchor` | `create`, `for_content` **only** | The tamper-evidence chain (#1659): the publish pipeline mints a document's next anchor and `Governance.Chain` reads that document's anchors back to verify or extend them. The plain `read` is not admitted: no Ash read lists anchors across documents. Checkpoint minting does read every document's head, through raw SQL (`Checkpoint.current_heads/1`, `standing_at_witnessed_positions/2`) that no policy governs and that cannot be refused, by design: the head set a checkpoint signs must never be silently shortened. There is still no `update` or `destroy` action. The read's code interface defaults to `authorize_with: :error`: a refused read would filter to `[]`, which reads as "never anchored", so a lost grant raises instead. Version rows themselves stay `authorize?: false` with a written reason: they are the editorial history, and a standing system read over them is the `PointInTime` case #1402 refused. |
| `CMS.ChainCheckpoint` | `recent`, `unwitnessed`, `create`, `record_publication` **only** | The org-wide witness (#666): `Governance.CheckpointWorker` mints a checkpoint, publishes it and records the receipt, and verification loads the checkpoint an entry names (`get_chain_checkpoint`, a `get_by` on `recent`, so the plain `read` is not admitted). Named action by action inside `policy always()` so a `destroy` added later is not admitted by default. Reads fail closed (their code interfaces default to `authorize_with: :error`): an empty `unwitnessed` would show an outage as healthy, and an empty `recent` would restart the chain at sequence 1. |
| `CMS.ChainCheckpointEntry` | `create`, `for_content`, `for_checkpoint` **only** | The per-document entries each checkpoint commits to, and verification's read of a document's strongest witnessed head. A refused `for_content` would read as "never witnessed", which is exactly what a truncation wants to look like, so it raises instead and the verdict floors to `:unverifiable`. |
| `CMS.Page`, `CMS.Post`, `CMS.Entry` (content) | `reindex_search_text`, `set_embedding` and `set_published_version_id` **only**, named inside the `action_type([:create, :update])` policy | Three system-only actions on denormalized columns: the fragment-expanded search text (`Firing.Engine.fire/2`), the document-level search vector (`Search.EmbeddingWorker`), and the pointer at the version a publish wrote (`Changes.RecordPublishedVersion` / `ClearPublishedVersion`, as `CMS.Bookkeeping.system/0`, #1659 — the publish may be the scheduler's). None accepts `:blocks` and all are ignored by PaperTrail. The grant sits inside the policy written for people, narrowed to those two actions by `forbid_unless action(...)` — see above for why that rather than a bypass. Keep the list short and every member system-only. Nothing else on the content resources admits the system actor: it holds no tier, so `EditableContentType` / `ReadableContentType` / `InAudience` all refuse it, and a system actor reads no content at all. |
| `History.DocumentEvent` | `for_document`, `by_actor`, `append`, `anonymize_actor` **only** | The block-level event log (#1659). The History API appends an event with the next per-document sequence number, folds one document's events for time-travel, and GDPR erasure redacts one user's events (a bulk update authorizes its query as a read, hence `by_actor`). The plain `read` is not admitted: nothing lists the whole log. No person, admin included, may append or rewrite an event. Every read fails closed (`authorize_with: :error`, `authorize_query_with: :error` on the erasure): a refused sequence read would hand out a number already taken, a refused fold would render an empty document, and a refused erasure would erase nothing and report success. |
| `CMS.FeedSettings` | `read` **only** | `KilnCMS.Feeds` resolves a site's syndication policy for anonymous feed readers (#1659). A refused read would be "no row", the operator config, cached for the TTL, which can turn full content on for a site that switched it off, so the read fails closed to `Feeds.unavailable/0`, uncached. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `CMS.SiteCompliance` | `read` **only** | `Compliance.Settings` resolves a site's claim-checking rules and publish gate for the editor panel and the publish path (#1659). Fails closed to `Settings.unavailable/0`, uncached, for the same reason as `FeedSettings`. Saving the row stays an admin act. Granted through `OrgSettings`' `system_actions:`. |
| `Analytics.SearchQuery` | `record` **only** | `Search.record_query/3` counts a search, usually an anonymous visitor's (#1659). No person may record one (an admin still can, through the admin bypass above the policy), and the system may not read or purge the counters; the nightly purge is the AshOban trigger's own. |

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
| `publish`, `publish_scheduled` | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| any action changing `scheduled_at` | ✅ | ⚙️ when the site lets editors publish | ❌ | ❌ |
| `return_to_draft` | ✅ | ❌ | ❌ | ❌ |
| `destroy` (soft-delete), `purge` (hard) | ✅ | ❌ | ❌ | ❌ |
| `trashed` (read), `restore` (untrash) | ✅ | ❌ | ❌ | ❌ |

`publish_scheduled` is additionally allowed for the **system** AshOban scheduler
via `bypass AshOban.Checks.AshObanInteraction`.

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

The alt-text publish gate (`Validations.MediaAltText`) reads the `decorative`
flag as the **system actor**, through the plain `read` only (#1659); see
[The system actor](#the-system-actor).

The pipeline's own actions — `record_processing`, `release_quarantine` and
the cross-site `quarantine_expired` scan — are not an editor's. The first two
are admin (bypass) or system actor only; `quarantine_expired` is the system
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
| `anonymize` | ✅ | ❌ | ❌ | ❌ |
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
([`account-administration.md`](account-administration.md)). Two are refused for
everyone, admins included:

| Action | Why nobody may call it |
|---|---|
| `:sign_in_with_passkey` | Mints a session token; only the verified WebAuthn ceremony reaches it (`authorize?: false`), and the preparation refuses any actor-carrying call — so not even an admin can mint a token for another account |
| `:sync_billing_audiences` | Entitlements are recomputed by `KilnCMS.Billing.Entitlements` alone; the change module refuses an actor-carrying call, so no authorized path grants an audience by hand |

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
The public submit path validates and then writes as the **system**
(`Forms.system/0`, admitted to `create` alone — see "The system actor").

## Redirects & branding — `Redirect`, `SiteBranding`

| Resource | read | writes |
|---|---|---|
| `Redirect` (`read`) | ✅ everyone incl. anonymous | `create`: admin only · `destroy`: admin, **or** whoever may write the target record · both also the slug-change hook's system actor (see "The system actor") |
| `SiteBranding` (`read`) | ✅ everyone incl. anonymous | admin only (`save`, `update`, `destroy`) |

Both are public information by design — delivery serves the same redirect map to
anyone who hits an old URL, and branding tokens render on every public page.
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
| `Firing.PublishedArtifact` | ✅ whoever may read the **source document** | ❌ **everyone, incl. admin** |
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

An actor-less *read* is fail-closed for free: `^actor(:id)` templates to `nil`,
the filter reduces to `user_id == NULL`, and no row satisfies it.

Org-scoped (`multitenancy strategy :attribute, attribute :org_id`) — a user who
edits two sites sees each site's notifications in that site's console only.

## Webhook deliveries — `WebhookDelivery`

| Action | admin | editor | viewer | anonymous |
|--------|:-----:|:------:|:------:|:---------:|
| read (`read`, `recent`), `create`, `record_attempt`, `destroy` | ✅ | ❌ | ❌ | ❌ |

Delivery history is admin-only. The delivery pipeline writes the row and its
attempts as the system actor (never `destroy`), and the `prune_deliveries` AshOban trigger runs under the
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
