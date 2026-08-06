# Content releases

A **release** is a named bundle of publishes and unpublishes that goes live as
one coordinated change
([#500](https://github.com/The-Verscienta/kiln_cms/issues/500)). A campaign that
touches a landing page, three posts, a menu fragment and a retired announcement
ships as a single unit at a single moment — or, if any one piece can't ship,
none of it does.

Before this, coordination meant lining up N identical `scheduled_at` timestamps
and hoping. This is the same idea Contentful calls Launch and Sanity calls
Releases.

> Not to be confused with [Releasing](releasing.md), which is about cutting a
> version of KilnCMS itself.

## Using it

**Releases** in the editor sidebar (`/editor/releases`) lists releases in three
groups: **Planned** (open, scheduled, publishing, failed), **Published**, and
**Closed** (rolled back, archived).

1. **Create a release** from the form at the top of the list — a name and
   optional notes.
2. **Add content to it.** In the content list (`/editor`), tick the records you
   want and use **Add to release**. Choose the release, and whether it should
   **Publish** or **Unpublish** each of them when it goes live.
3. **Review it.** The release page lists everything in the bundle with its title
   resolved, and badges any item that couldn't ship as it stands (e.g. *"cannot
   be published from archived"*) or that would be a no-op (*"already in that
   state — will be skipped"*).
4. **Preview it.** **Create preview link** mints a short-lived, shareable URL
   showing every document as the release would publish it, plus everything the
   release takes down. No editor account needed to open it — useful for
   sign-off with people outside the CMS.
5. **Ship it.** Either set a **Go live at** datetime (a minute-resolution cron
   fires it, same cadence as per-item scheduling) or hit **Publish now**.
6. **Undo it.** A published release offers **Roll back**: every item it changed
   returns to the state it was in before.

### Who can do what

Composing a release is editor work; shipping one is admin work.

| Action | Editor | Admin |
| --- | --- | --- |
| Create and rename a release | ✅ | ✅ |
| Add / remove content | ✅ | ✅ |
| Reopen a failed release | ✅ | ✅ |
| Archive or delete a release that never shipped | ✅ | ✅ |
| Archive or delete a **scheduled** or **published** release | ❌ | ✅ |
| Schedule, **Publish now**, **Roll back** | ❌ | ✅ |

This mirrors Kiln's existing rule that publishing is an admin approval step: a
release must not become a way for an editor to publish content they otherwise
couldn't. The go-live worker necessarily runs unauthorized (it publishes across
types on behalf of the bundle), so the gate is at the release, and the admin who
scheduled or started it is recorded and used as the acting user for every item —
version history and the audit chain name a person, not "system".

Closing out follows the same logic. Archiving is one-way, so archiving a
published release permanently ends its group rollback, and archiving or deleting
a scheduled one silently cancels a launch somebody else planned. Both are admin
calls; an editor can still close out a release nobody has committed to.

Adding content to a release also respects the **granular-RBAC type scope**
(#332): an editor restricted to `post` cannot put a `page` in a release. That
matters more here than elsewhere, because the preview link below renders every
item's unpublished body to whoever holds it — so a release can only ever expose
what the editor who filled it was already allowed to see.

### One record, one open release

A given piece of content can sit in **at most one** release that hasn't shipped.
Adding it to a second one is refused. This is enforced by a partial unique index
in Postgres, not by an application check, because two editors adding the same
page to two different releases at the same moment is precisely the race a
check-then-insert loses.

Removing the item, or archiving the release, frees the record again.

## What "atomic" means here

The interesting question is what happens when item 7 of 10 fails.

Publishing N items through the normal per-item actions means N state
transitions, N artifact fires and N webhook dispatches. That sounds like
something no transaction could cover — but in Kiln **every side effect of the
publish path is a database write**:

| Publish-path effect | What it actually does |
| --- | --- |
| `NotifyWebhooks` | inserts a `WebhookDelivery` row + an Oban job |
| `FireArtifacts` | inserts an Oban job |
| Automation dispatch | inserts an Oban job |
| `Governance.Chain` | inserts anchor rows |

The actual HTTP POSTs and artifact renders are performed later, by Oban workers
— and Oban shares the same repo. Nothing has left the database at the moment the
release is running.

So `KilnCMS.CMS.Releases` runs the whole bundle inside **one**
`Repo.transaction`. A failure on any item rolls back the earlier items *and* the
webhook deliveries, artifact fires and automation jobs they queued. Subscribers
never see a partial campaign; the site is untouched; the release lands in
**Failed** with the offending item and the reason recorded on it.

The honest cost: one long transaction holding row locks on every item for its
duration (bounded at two minutes).

### Skipped, not failed

If somebody publishes one of the pages by hand before the release fires, that
item's desired end state already holds. Failing the entire launch over a no-op
would be pedantic, so such items are marked **Skipped** — recorded, visible, and
deliberately untouched by a later rollback, because the release didn't put them
there.

A genuinely impossible transition — an archived record, a trashed one, a content
type that no longer exists — is a real failure and aborts the release.

### Retrying a failed release

**Reopen for editing** returns a failed release to open with its items intact
and still pending, so you can fix the offending record and publish again. The
go-live job does not retry itself: a release that aborted needs an editorial
decision, not another attempt against the same broken item. Scheduling and
**Publish now** are deliberately not offered on a failed release — reopening is
the first step, and those transitions don't exist from `failed`.

### A stuck claim

`publishing` and `rolling_back` mean "a worker owns this release right now".
If that worker dies — a node restart, a job discarded — nobody is left to say
otherwise, and the release would sit there forever with its items still
reserving their content against every other release.

**Release a stuck claim** (admin only) is the way out: it returns a stuck
go-live to `failed` and a stuck rollback to `published`, after which the normal
reopen-and-retry path works. Only use it when you know no publish is actually
running — that is the one thing the system can't determine for you, which is why
it is a button and not automatic.

## Preview as of a release

`/preview/release/:token` renders the site as the release would leave it: each
publishing document through the same block components and public layout the live
site uses, and a list of everything coming down.

Unlike [point-in-time](point-in-time.md) delivery — which has to replay
`:changes_only` version history because the state it wants no longer exists
anywhere — a release's *future* state is simply the live draft row. In Kiln a
document's editable record **is** its next published state, with the fired
artifact as the frozen public copy alongside it. So the overlay is a read, not a
replay.

Preview links are signed with `Phoenix.Token`, stateless, and valid for **one
hour** — wider than the 15-minute single-record draft preview, because a release
review is a sign-off pass over several documents rather than a glance at one. A
link opened on a different site's host is refused rather than rendered under the
wrong tenant's branding.

## Rollback

Rolling back walks the applied items in reverse and restores what each one
replaced, using the `prior_state` and `prior_version_id` captured **before** the
item's transition ran — the only moment those are knowable.

- An item the release **published** goes back down, returning to `draft`, or to
  `in_review` if that's where it was (a plain unpublish always lands in `draft`,
  which would quietly lose a review in flight).
- An item the release **unpublished** goes back up. If the record was edited
  while it was dark, its captured version is restored first, so rollback brings
  back the body that was actually live rather than whatever it drifted into. An
  untouched record is simply republished — no needless extra version.

An item whose content has since been **deleted outright** is recorded as undone
and skipped. Failing on it would wedge the group: the release would return to
`published`, the item would stay applied, and every retry would hit the same
missing record — so one purged page would strand every *other* item of the
release live, with no way to take the group down.

Otherwise rollback runs in one transaction with the same all-or-nothing
guarantee: if any item can't be restored, the release stays **Published** and
nothing moves.

## Calendar and events

Scheduled and shipped releases appear on the editorial calendar
(`/editor/calendar`) alongside per-item schedules, with their own chip colour.

Two events dispatch through the standard [webhook](webhooks.md) and
[automation](automation.md) funnel:

- `release.published`
- `release.rolled_back`

Both carry the release's id, name and item list, and are subscribable on any
webhook endpoint exactly like `page.published`. Because they go through the same
funnel, an automation rule scoped to content type `release` with trigger
`published` fires on them too. They are dispatched **inside** the go-live
transaction, so a release that aborts never emits one.

## Under the hood

| Module | Role |
| --- | --- |
| `KilnCMS.CMS.ContentRelease` | the release: state machine, schedule, failure record |
| `KilnCMS.CMS.ReleaseItem` | one pending change; the partial unique index lives here |
| `KilnCMS.CMS.Releases` | go-live and rollback — the transaction |
| `KilnCMS.CMS.Workers.ReleaseWorker` | runs one go-live or rollback off-request |
| `KilnCMS.CMS.ReleasePreview` | the overlay and its signed share token |

States: `open ⇄ scheduled → publishing → published | failed`, with
`failed → open` (reopen), `published → rolling_back → rolled_back`,
`publishing | rolling_back → failed | published` (abandon), and `archived` as
the close-out from anywhere that isn't mid-flight.

`publishing` and `rolling_back` are **claim** states rather than cosmetics: both
the minute cron and the Publish-now button transition into them before any work
starts. The claim is a compare-and-**swap**, not a compare-and-hope — the guard
is in the `UPDATE`'s own `WHERE` clause, so a console page held open since 08:59
(still showing `scheduled` after the 09:00 cron claimed the release) gets a stale
-record error rather than shipping the bundle a second time. The worker's job is
enqueued *inside* the claim's transaction, so a claim can never commit without
one.
