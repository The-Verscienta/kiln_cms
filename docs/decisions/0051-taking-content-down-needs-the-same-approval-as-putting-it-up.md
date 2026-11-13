# 0051. Taking content down needs the same approval as putting it up

- **Status** — accepted (2026-11-13), recording the rule #2472 shipped
  (merged 2026-11-08). It is written after the fact, so it argues against the
  code as it is now.
- **References** — [#2134](https://github.com/The-Verscienta/kiln_cms/issues/2134),
  the decision, and [#2472](https://github.com/The-Verscienta/kiln_cms/pull/2472),
  which built it; [#2475](https://github.com/The-Verscienta/kiln_cms/issues/2475),
  which asked for this record; #2473 for the refusal wording.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#takedown-needs-publish-rights)
  (Breaking), with its upgrade step in
  [What's new in 1.9](../whats-new/v1.9.md#before-you-upgrade) (item 6).

## The problem

A site can make publishing an admin's approval step: editors submit for
review, and an admin decides what goes live
(`SiteEditorialSettings.editors_can_publish`, **Team → Publishing**). Before
1.9 that step guarded only one direction. Any editor could unpublish a live
page, archive anything, or set the date on which the scheduler would do either.
On a site that asked for review, an editor could take a page off the site,
which is as visible to readers as putting one on, with nobody approving it.

## Decision

Every way of taking content down takes the permission that publishing takes:
an admin (`KilnCMS.CMS.Checks.OrgAdmin`), or an editor of the request's org on
a site that lets editors publish (`KilnCMS.CMS.Checks.EditorMayPublish`). One
switch decides both directions. In the content resource's `policies` block
(`KilnCMS.CMS.Content`):

- **The actions.** `:unpublish`, `:archive` and their scheduled twins
  `:unpublish_scheduled` and `:archive_scheduled` share the one policy with
  `:publish` and `:publish_scheduled`. `:archive` is gated from every state it
  leaves, draft and in-review included: archiving an in-review page also
  takes it out of an admin's review queue.
- **The dates.** Setting, moving or clearing `scheduled_at` takes the
  permission, as it did before. So do `unpublish_at` and `expiry_action`, but
  only on an update of a record that is published or has `scheduled_at` set,
  judged on the row as it was read (`KilnCMS.CMS.Checks.LiveOrScheduled`).
  Each field has a policy of its own.
- **Releases.** A content release may carry Unpublish items, and composing a
  release stays editor work. Shipping one (`ContentRelease` `:schedule` and
  `:start`) is admin-only, whatever the switch says, so a release is stricter
  than the switch, never a way around it.

`EditorMayPublish` reads the switch uncached through
`KilnCMS.CMS.EditorialSettings`, which answers "no" when the row is missing or
the read fails. A refusal is the policy's, so every surface gets it: the
LiveViews, JSON:API (`PATCH …/unpublish`), GraphQL (`unpublish<Type>`) and the
code interfaces. The editors offer the controls only to someone the policy
would admit, and `KilnCMSWeb.WorkflowMessages` says which rule refused a forged
or stale click.

## Why the dates and the scheduled twins are gated too

The AshOban scheduler runs `:publish_scheduled`, `:unpublish_scheduled` and
`:archive_scheduled` through `bypass AshOban.Checks.AshObanInteraction`, with
no person checked when they fire. Whoever wrote the date made the decision,
so the date is gated, not the run:

- A `scheduled_at` is a publish.
- On a live record, an `unpublish_at` is an unpublish, and `expiry_action`
  decides whether it unpublishes, archives or only flags. Changing either is a
  takedown.
- On a draft with `scheduled_at` set, the same date takes the page down after
  the scheduled publish. #2472 first gated only published records, and review
  widened it for this case.

The scheduled twins have code interfaces (`unpublish_scheduled_post` and
`archive_scheduled_post` on `KilnCMS.CMS`), so a person can call them
directly. They sit
in the publish policy so that such a call is checked like the action it
mirrors.

## Rejected

- **Gating only in the UI.** Hiding the buttons stops nobody using the API or
  a forged LiveView event. The policy is the gate, and the UI only follows it.
- **Gating only `:unpublish`.** `:archive` from published takes a page down
  just as surely, and so do both scheduled twins and an `unpublish_at` on a
  live page. Gating one of these would move the takedown to another.
- **One policy for both fields.** `changing_attributes([:unpublish_at,
  :expiry_action])` matches only when *both* change, so a combined policy
  would let a change to either field alone through. Folding them into the
  `scheduled_at` policy fails the same way. Each field has its own policy.
- **Gating the dates on drafts too.** On a draft nobody has scheduled, or on
  a create, `unpublish_at` and `expiry_action` do nothing until someone with
  publish rights publishes or schedules the whole record. Gating them there
  would only stop an editor preparing an embargo on their own draft. The
  publisher is meant to approve the dates along with the page, but not every
  route shows them ([#2892](https://github.com/The-Verscienta/kiln_cms/issues/2892)): an admin can approve or publish from a
  content-list row or the bulk bar, where the **Unpublishes** badge appears
  only on published rows, and a release publishes its items without showing
  their dates.
- **Gating `:unarchive`.** It lands on draft, so nothing goes online or
  offline. It stays with the editor-level policy, as does `:publish_changes`,
  which only changes a page that is already live
  ([The working copy](../working-copy.md)).

## Consequences

- **Upgraded sites.** `editors_can_publish` defaults to off on a site that
  never answered the first-run `/setup` question, which is every site upgraded
  from before the switch existed. There, editors lost Unpublish and Archive in
  1.9.0, including archiving their own drafts, and their `:read_write` API keys
  get `403` on unpublish. Turning on **Let editors publish** gives both back,
  along with publishing, because one switch decides both.
- **Rolling back** is safe. The change has no migration and no data change.
- **Releases and the calendar.** "Add to release" with an Unpublish action is
  still offered to editors who may not publish, which is safe because only an
  admin ships a release. The calendar still lets them drag a live page's
  unpublish chip, and refuses the move when it is dropped.

How to take content down, step by step, is in
[Take content down](../take-content-down.md). The permissions are in the
[policy matrix](../policy-matrix.md).
