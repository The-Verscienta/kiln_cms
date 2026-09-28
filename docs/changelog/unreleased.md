# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="on-012-before-upgrading-to-10"></a>

- **On 0.12, before `mix kiln.update --allow-major` to 1.0: run the block
  backfill and `mix kiln.deprecations --migrate-audiences`, and drain the queue.**
  1.0 is a major, so `mix kiln.update` refuses it without `--allow-major`, and
  it removes what 0.12 deprecated (see *Breaking*). Three things to do while
  still on 0.12, in this order:

  1. `mix kiln.blocks.backfill` (in a release,
     `bin/kiln_cms eval 'KilnCMS.Release.backfill_blocks()'`), if you have not
     since 0.12, so no stored block is still in the legacy shape.
  2. `mix kiln.deprecations --migrate-audiences` (in a release,
     `bin/kiln_cms eval 'KilnCMS.Release.deprecations(migrate_audiences: true)'`).
     It gives every account that still reads gated content through the
     `User.audiences` fallback a default-organization membership carrying the
     same audiences. 1.0 does this on its own after every deploy, but only
     moments after the node starts serving; running it first means no reader
     loses access even for that moment.
  3. Let the webhook and newsletter queues drain. `mix kiln.deprecations` exits
     non-zero while any account or queued job is left, so it can gate the
     upgrade script. A job still queued in a pre-0.12 shape is cancelled by
     1.0, with an error in the log, and its work is not done.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

## Breaking

<a id="remove-the-published-option"></a>

- **Remove the `published?:` option on `use KilnCMS.CMS.Content`; passing it now
  warns as an unknown option.** It had been ignored since every content type
  gained the `:published` read, and 0.12 deprecated it. An overlay that still
  passes it gets the same compile-time warning as any other unknown option at
  its `use` line — not an error. Unknown options stay warnings until 2.0, which
  makes them compile errors; an overlay built with `--warnings-as-errors` fails
  on it now. Delete the option.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="remove-the-editor-route-aliases"></a>

- **Remove the `/editor/pages/:id` and `/editor/posts/:id` editor routes; each
  now answers with a `301` to `/editor/content/page|post/:id`.** They were
  aliases from before the generic editor route, deprecated in 0.12. They no
  longer mount the editor, so the per-visit deprecation warning is gone too.
  The redirect exists for bookmarks and for review-request mail older releases
  sent, and costs one plain route each; it does not touch the record — the
  editor route it points at does the sign-in, the gate and the lookup. It is a
  courtesy rather than a covered surface, and a later major may drop it.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="remove-the-user-audiences-fallback"></a>

- **Remove the `User.audiences` fallback for accounts with no membership; a job
  on every boot moves such accounts onto a default-organization membership.**
  An account holding no `OrgMembership` anywhere used to read gated content
  through the global `User.audiences` column, on every site.
  `KilnCMS.Accounts.Scoping.audiences/2` now gives it `[]`, like every other
  account without a membership on the site. So that no paying or granted reader
  silently loses access on upgrade, `KilnCMS.Accounts.LegacyAudiencesWorker` is
  queued on every boot (deduplicated for a day across nodes) and gives each such
  account a default-organization membership carrying its audiences, standing
  role and any live temporary role — through
  `KilnCMS.Accounts.LegacyAffiliation`, the step billing and the console's
  audience checkboxes already take. It is a job rather than a migration because
  the step is an Ash action and migrations run without the application; until
  it has run, an unmigrated account reads only public content, never more. A
  site-provider sign-in no longer refuses a membership-less account for its
  `User.audiences`, since they grant nothing anywhere. The column is kept,
  unread: it is the only record of what a legacy account held, billing still
  writes the cross-organization union there, and 2.0 may drop it.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))

<a id="stop-running-pre-012-job-shapes"></a>

- **Stop running webhook and newsletter jobs queued in a pre-0.12 argument
  shape; each is cancelled with an error in the log.** A
  `KilnCMS.Webhooks.DeliveryWorker`, `KilnCMS.Newsletter.SendWorker` or
  `KilnCMS.Newsletter.MailWorker` job without `org_id`, and the pre-ledger
  webhook job (`endpoint_id`/`event`/`payload`), ran against the default
  organization with a deprecation warning in 0.12. 1.0 cancels them instead:
  running one would mean guessing its organization, and crashing would retry a
  job that can never succeed. The error names the worker and the arguments'
  keys, not their values. Jobs 0.12 or later enqueued always carry `org_id` and
  are unaffected.
  ([#1543](https://github.com/The-Verscienta/kiln_cms/issues/1543))
