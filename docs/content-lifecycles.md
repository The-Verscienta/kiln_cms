# Content lifecycles

Publishing answers *is this live?*. Lifecycles answer the two questions that
come after: **when does this stop being live**, and **when does someone need to
read it again**.

They are one axis — `health` — computed from four columns, and they are
deliberately *not* part of the state machine. A drug monograph whose annual
review lapsed is still, factually, published; a legal notice past its stated
shelf life is still being served. Making those a `state` would mean the
publishing workflow had to model editorial trust, and the two move
independently.

## The model

Every content type — compiled (`Page`, `Post`, anything from
`mix kiln.gen.content`) and dynamic (the `Entry` tier) — carries:

| Field | Type | Meaning |
|---|---|---|
| `unpublish_at` | timestamp | The embargo end. When it passes, the record expires. |
| `expiry_action` | `:unpublish` \| `:archive` \| `:flag` | What expiry *does*. Default `:unpublish`. |
| `review_after_days` | integer, 1–1095 | Freshness cadence. `nil` (the default) means none. |
| `last_reviewed_at` | timestamp | When a human last attested the content is still correct. |

and computes:

| Calculation | Meaning |
|---|---|
| `effective_review_after_days` | The cadence in force — the record's own, else its type's default. |
| `due_at` | When it next needs re-reading. `NULL` means never. |
| `health` | `:fresh` \| `:due_soon` \| `:due` \| `:overdue` \| `:expired` |

All three are **expression** calculations, computed in Postgres on every read.
That is the design decision, not an implementation detail: a stored `health`
column is wrong for every row between the moment a deadline passes and the
moment a sweep gets to it — which is precisely the window an editor is asking
the question in. Computed in SQL it is right on every read, and it filters and
sorts, so `?filter[health]=overdue` is one `WHERE`, not a table scan in Elixir.

## Expiry: one timestamp, three outcomes

There is no separate `expires_at`. `unpublish_at` is the expiry timestamp, and
`expiry_action` decides what happens when it passes:

* **`:unpublish`** (default) — back to draft, artifacts deleted, `unpublish_at`
  cleared. Recoverable; nothing is lost.
* **`:archive`** — straight to `:archived`, same teardown. For content that
  should leave the working set rather than reappear in the draft list every
  quarter.
* **`:flag`** — *nothing happens to the row*. It stays published and
  `unpublish_at` stays in the past, which is exactly what makes `health` read
  `:expired` from then on. For content that must not silently vanish from a live
  site but does need a human told its stated shelf life has run out.

The first two run as AshOban triggers on the same minute cron as scheduled
publishing, partitioned in SQL by `expiry_action` so neither can pick up the
other's rows — or a `:flag` row, which belongs to neither. `:flag` needs no
worker at all: the signal is the calculation.

## Freshness: the cadence and the attestation

`due_at` is the last attestation plus the cadence — or, for content published
under a cadence but never yet reviewed, the *publish* plus the cadence. Nothing
needs backfilling for that to work; a record with a cadence and no
`last_reviewed_at` starts its clock at `published_at`.

`health` then reads, for published content:

```
expired    unpublish_at has passed
overdue    due_at passed more than 7 days ago
due        due_at passed within the last 7 days
due_soon   due_at falls within the next 7 days
fresh      everything else — including all unpublished content
```

Unpublished content is always `:fresh`. Only live content can mislead a reader.

The seven days is one constant used symmetrically on both sides of the deadline,
rather than two arbitrary numbers.

### Marking reviewed

`mark_reviewed` is its own action — `CMS.mark_page_reviewed!/2`,
`CMS.mark_post_reviewed!/2`, `CMS.mark_entry_reviewed!/2`, or
`ContentTypes.transition(type, "mark_reviewed", record, opts)` for generic
dispatch. It takes no input and stamps `last_reviewed_at` to now.

`last_reviewed_at` is **not** in `default_accept`, so no ordinary save, API
client, or automation can write it. That is the whole point: the column means "a
human said this is still right", and a field an autosave could set would mean
"someone had this open". The action name lands on the PaperTrail version
(`version_action_name: :mark_reviewed`), so *who attested, and when* is
answerable from history rather than inferred.

Version restore never writes any of the four lifecycle columns. They are
reported in the diff — a cadence change is worth seeing — but restoring an old
version must not move a deadline nobody re-set, and for `last_reviewed_at` it
would forge an attestation outright. See `KilnCMS.CMS.VersionFields`.

## Per-type defaults

`TypeDefinition.default_review_after_days` lets an operator say "every clinical
monograph is re-read yearly" once, on the type, instead of on each of four
hundred entries. An entry that sets its own `review_after_days` overrides it;
`nil` on both means the type has no cadence.

It is resolved in `effective_review_after_days`, so raising a type's default
moves every inheriting entry's `due_at` on the next read — no backfill.

**This applies to the dynamic entry tier only.** Compiled types have no
`TypeDefinition` row to inherit from, so for a `Page` or a `Post` the effective
cadence is the per-record one. The alternative considered and rejected was a
site-wide default: a fallback that reaches across every type at once is the
shape that silently re-enables a cadence a team deliberately cleared.

## The editorial calendar

`/editor/calendar` plots everything time-bound in one org and one window:

| Lane | Comes from |
|---|---|
| Scheduled publish | a draft/in-review record's `scheduled_at` |
| Scheduled unpublish / archive / expired | a published record's `unpublish_at`, split by `expiry_action` |
| Went live | `published_at` |
| Review due | the `due_at` calculation |
| Task due | an open `Task`'s `due_on` |
| Release go-live / shipped | a `ContentRelease`'s `scheduled_at` and `published_at` |

Nothing is stored. `KilnCMS.CMS.Calendar` derives every event from a column
that already exists, so the calendar cannot disagree with the records it draws
— and a materialized calendar table would need a write path on every one of
those columns and be wrong between the write and the sweep.

Three views share one `at` anchor, so switching keeps your place:

* **Month** — the planning grid. Chips are capped per day cell with a "+N more"
  overflow, so one busy Thursday cannot resize the row.
* **Week** — seven tall columns with times, for when two things land on the
  same afternoon.
* **List** — chronological, the accessible baseline, and the mobile view: the
  grids are `hidden md:block`, because seven columns on a phone is a horizontal
  scroll.

Filters (type, lane, health) are URL-persisted, so a filtered calendar is a
link you can send:

```
/editor/calendar?view=list&at=2026-09-01&health=overdue
```

An unknown value in any filter shows everything rather than nothing — a
hand-edited or stale URL should not render an empty calendar that looks like a
calendar with nothing in it.

The page is live. Any write that moves something plotted here broadcasts on the
org's calendar topic (`KilnCMS.CMS.Changes.BroadcastCalendar`) and every open
calendar re-queries — whether the write came from another editor's session, the
API, or a scheduler. `:autosave` deliberately does not broadcast: one per
debounce would wake every open grid in the org every few seconds while one
person types.

Every query runs as the signed-in editor under their org's tenant, so the
calendar can only show what that person could already read one record at a
time.

### Rescheduling from the grid

On the month and week grids, a chip in a reschedulable lane can be dragged to
another day, or moved with the arrow keys while focused — ←/→ by a day, ↑/↓ by
a week, matching the grid's own geometry. Both paths do the same thing; the
outcome is announced in an `aria-live` region, because a chip moving is not
something a screen reader can otherwise report.

The day moves and the time of day does not: a 09:00 publish dragged to Thursday
is a 09:00 Thursday publish.

| Lane | Drag moves |
|---|---|
| Scheduled publish | `scheduled_at` |
| Scheduled unpublish / archive / expired | `unpublish_at` |
| Release go-live | the release's `scheduled_at` |
| Went live, release shipped | — history; nothing to reschedule |
| Task due | — the chip carries the task's *content* id; reschedule from the task list |
| Review due | — see below |

**Review-due chips do not drag, deliberately.** `due_at` is derived from
`last_reviewed_at` and the cadence, so dragging it could only write one of
those two: moving `last_reviewed_at` forges an attestation, and changing
`review_after_days` alters the cadence permanently in order to move a single
deadline. Neither is what "give me another week" means. Those chips carry a
**Mark reviewed** button instead — which resets the clock honestly — and it
appears only when the health is `:due`, `:overdue` or `:expired`, because a
review falling due next month is not asking for anything.

Two refusals, both returning an inline error and snapping the chip back:

* **Into the past.** Uniform across lanes: a backwards drag is nearly always a
  slip, and every lane's past date means something abrupt — a publish that
  fires within the minute, an embargo end that takes a live page down now.
* **Not in the window.** The move is looked up against the events the editor's
  calendar actually loaded. That is the authorization boundary as much as an
  ergonomic one: the window came from a policy-scoped, org-scoped read, so a
  socket cannot move a record it could not already see.

The write itself is then subject to the record's own policy, so an editor
scoped by `editable_types` to other types cannot move what they cannot edit,
and the calendar route is editor-gated, so a viewer never reaches it at all.

## Turning staleness into work

Health tells you something has gone stale. The remediation loop is what puts it
in somebody's queue.

### The sweep

`KilnCMS.CMS.HealthSweep` runs daily (`KILN_HEALTH_SWEEP_CRON`, 07:30 by
default — before the task digest, so a task it raises is in that morning's
email rather than tomorrow's). It finds published content whose health is
`:overdue` or `:expired`, emits
`[:kiln_cms, :lifecycle, :health_sweep]` telemetry with the counts, and
dispatches one automation event per record:

```
page.health_overdue
recipe.health_expired
```

A sweep exists at all because every other editorial trigger hangs off a write —
something was published, returned to draft, assigned. Freshness lapses because
*time passed*: nobody did anything, which is exactly the problem, so there is no
write to hang it off. Something has to come looking.

**The sweep changes nothing.** It is a read plus an event. It does not touch the
content, does not create tasks, and does not write `health` (which is a
calculation and has nothing to store). What happens next is a rule the team
configured, or nothing at all — which is the point: "overdue" means different
things to a newsroom and to a clinical library, and one hard-coded reaction
would be wrong for one of them.

That also makes it safe to leave enabled everywhere. A site with no review
cadences matches nothing.

`:due` and `:due_soon` deliberately do not fire. A trigger on "falls due next
week" would send the same reminder every day for a week before the deadline,
which is how a team learns to filter the reminders out.

### The rule

`:health_overdue` and `:health_expired` are ordinary `Automation` triggers, so
they are configured in the automation builder like any other, scoped by content
type, and can be disabled. The `:create_task` reaction turns one into an
editorial `Task`:

```elixir
%{
  trigger_event: :health_overdue,
  content_type: "page",
  action: :create_task,
  config: %{
    "assignee_id" => "…",        # fallback when the author can't hold it
    "due_in_days" => 7,          # clamped to 1..365, default 7
    "note" => "Review due — {{title}}"
  }
}
```

Assignment goes to the **content's author** when they are still an editor —
"the person who wrote it should re-read it" — and falls back to the rule's
`assignee_id` otherwise, which is what makes the rule usable on imported content
with no author, or content whose author has since left. If neither can hold a
task, nothing is created and the sweep logs it; a scheduled job does not die
over a misconfigured rule.

**Idempotent per {content, kind}.** The sweep re-fires every day a record stays
overdue — that is what makes it a reminder rather than a one-shot notification
that can be missed — so `:create_task` first asks whether an open
`:lifecycle_review` task already exists on that content. Without that, a
monograph nobody has got to in a fortnight carries fourteen identical tasks, and
the queue meant to surface the problem *is* the problem. Complete the task
without actually re-reading the piece and the next sweep raises a fresh one,
because the content is still overdue.

Lifecycle tasks are tagged `kind: :lifecycle_review` (manual ones are
`:manual`), and they opt out of #501's auto-complete-on-publish: republishing
the same stale document is exactly what the review exists to question.

### On the governance dashboard

`/editor/governance` carries a **Content health** section: counts across
`:due_soon` / `:due` / `:overdue` / `:expired`, the ten most urgent records, and
a CSV export of all of them (`GET /editor/governance/health.csv`, admin-only).

It distinguishes two things a count alone cannot. A site where nothing carries a
review cadence says so — because a panel rendering `0 overdue` for a site that
has never set one is stating something false in a reassuring voice, and "we
checked, nothing is late" is the opposite fact from "we have never asked". Only
once something *is* tracked does the panel report a clean bill.

The counts are recomputed per page load rather than stored, for the same reason
`health` is a calculation: a stored count is wrong from the moment a deadline
passes. It is cheap because the query filters on `health` in Postgres, so a site
with forty thousand fresh pages reads none of them — the result set is the
problem list, not the library.

### In the editor

The content editor's header carries a health pill next to the workflow state
badge — the two are orthogonal, and an editor needs both at a glance: this
document is Published *and* eight months past its review. A **Mark reviewed**
button appears beside it only when the health is `:due`, `:overdue` or
`:expired`.

It is a button of its own rather than something that rides on Save, for the same
reason `last_reviewed_at` is not in `default_accept`: an editor who saves a typo
fix has not re-read the piece.

## Reading it

Health is a normal field on the existing reads — there is no lifecycle
endpoint.

```
GET /api/json/pages?filter[health]=overdue&sort=due_at
```

```graphql
{ pages(filter: {health: {eq: OVERDUE}}) { title health dueAt } }
```

```elixir
CMS.Page
|> Ash.Query.filter(health == :overdue)
|> Ash.Query.sort(due_at: :asc)
|> Ash.read!(actor: editor)
```

Health inherits content's own read policy, so an anonymous consumer only ever
computes it over published, unrestricted content — unpublished health never
leaks.

## Authorization

`review_after_days`, `expiry_action` and `unpublish_at` are ordinary accepted
attributes on `:update`, so they are editor+admin writable exactly like
`scheduled_at`. `mark_reviewed` is an update action and follows the same policy.
The expiry workers run under the `AshOban` interaction bypass, as scheduled
publishing does.

## Related

* `docs/content-releases.md` — coordinated multi-item go-live.
* `docs/governance-dashboard.md` — the audit chain over what shipped when.
* `docs/automation.md` — reacting to editorial events.
