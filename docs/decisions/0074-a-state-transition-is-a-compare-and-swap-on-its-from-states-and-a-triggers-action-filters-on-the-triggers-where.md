# 0074. A state transition is a compare-and-swap on its from-states, and an action a trigger runs filters on the trigger's `where`

- **Status** — accepted (2026-11-19).
- **References** — [#3076](https://github.com/The-Verscienta/kiln_cms/issues/3076)
  (this record), written from three changes that each rediscovered the rule:
  [#879](https://github.com/The-Verscienta/kiln_cms/issues/879) (the manual
  content transitions), [#2745](https://github.com/The-Verscienta/kiln_cms/issues/2745)
  (every `ContentRelease` transition, with the cron's `:start_scheduled`) and
  [#2746](https://github.com/The-Verscienta/kiln_cms/issues/2746) (the
  scheduled content actions), with
  [#2740](https://github.com/The-Verscienta/kiln_cms/issues/2740) (release
  items written during a go-live) alongside. Related:
  [#923](https://github.com/The-Verscienta/kiln_cms/issues/923) (the 409 for
  a lost race), [#2532](https://github.com/The-Verscienta/kiln_cms/issues/2532)
  (why `lock_version` is not enough).
- **Changelog** — #879 shipped in
  [v0.6.0](../changelog/v0.6.0.md#a-losing-workflow-transition-race-now-returns-a-409-not-an-opaque-400-plus-a);
  #2745 and #2740 in v1.11.0
  ([release transitions](../changelog/v1.11.0.md#release-transitions-on-the-row),
  [release items](../changelog/v1.11.0.md#release-items-during-go-live));
  #2746 in v1.11.0
  ([scheduled content](../changelog/v1.11.0.md#scheduled-content-on-the-row)).
  This record adds no behavior.

## The problem

`AshStateMachine` decides whether a transition is allowed by looking at the
struct the caller holds. `AshStateMachine.transition_state/2` reads
`changeset.data.state` and finds a transition whose `from` contains it. That
is a check against a copy. Between the caller's read and the `UPDATE`, the
row can have moved: a colleague approved, the minute cron claimed a release,
an admin unscheduled it. The held struct still says the old state, the
machine says yes, and the `UPDATE` (which names only the primary key) writes
over the move. Every one of the three changes was that bug:

- #879: two actors racing `:publish`, `:archive` and the other workflow
  transitions on `KilnCMS.CMS.Content` both passed the machine.
- #2745: a console page held open since 08:59 still said `:scheduled` at
  09:00:05, after the cron had claimed the release, so "Publish now" enqueued
  a second go-live. The cron's own claim had the mirror problem: an admin who
  unscheduled the release after the scheduler read it could not stop it.
- #2746: a scheduled publish, unpublish or archive ran after a person had
  published, archived or rescheduled the same record in the seconds between
  the worker's read and its write, and wrote over that decision.

The rule lived only in comments on the actions, so each new state machine or
trigger would have repeated it.

## The decision

**Every transition action filters its `UPDATE` on its own from-states, so the
write is a compare-and-swap on the row. An action an AshOban trigger runs
filters on that trigger's `where`, word for word.** A miss matches no row, and
Ash returns `Ash.Error.Changes.StaleRecord`.

In a resource this is `change filter(expr(^ref(:state) == :published))` (or
`in [...]`, or `!=` where the from-states are the complement) placed before
`change transition_state(...)`. The filter states the same from-states the
`transitions` block gives that action, so a reader can compare the two. For
a trigger action the filter is the trigger's `where` copied verbatim, with
`^ref(:field)` for the resource form.

### Why `lock_version` or the held struct is not enough

- **The machine checks the struct, not the row.** `transition_state/2`'s
  non-atomic `change/3` compares against `changeset.data`. These actions use
  `require_atomic? false`, so the atomic version in
  AshStateMachine's built-in `transition_state` change (which would put the
  from-state check in SQL) never runs. The filter supplies what the atomic
  path would have.
- **`optimistic_lock(:lock_version)` does not move with the state.** The
  workflow writes (`:publish`, `:publish_scheduled`, `:unpublish`,
  `:unpublish_scheduled`, `:archive`, `:unarchive`) keep `lock_version`, so a
  struct held across one of them still passes the lock while its `state` no
  longer describes the row
  (`KilnCMS.CMS.Changes.StateUnchangedSinceRead`, #2532). Where a lock is
  used (`:autosave`, `:restore_version`) it protects the text, and the state
  filter protects the transition. `:restore_version` carries both.
- **`ContentRelease` has no lock to lean on.** Its state is the only thing
  that matters, and the cron and a console click are the racers.
- **A validation reads the same struct.** `validate attribute_equals` sees
  what the caller loaded. Only a predicate in the `UPDATE`'s `WHERE` is
  evaluated against the row the database holds when it writes.

### A trigger action filters on the trigger's `where`

AshOban applies the trigger's `where` when the scheduler selects due rows and
again when the worker re-reads the record to run the action
(`worker_read_action`). Then the action runs, and the checkpoint, claim and
compliance checks before its write can take a long time. A change in that
window is not seen by the read.

So the action carries the same predicate as the trigger, and the trigger and
the action are written to agree: `:go_live` and `:start_scheduled` on
`ContentRelease` (`state == :scheduled and not is_nil(scheduled_at) and
scheduled_at <= now()`), and `:publish_scheduled`, `:unpublish_scheduled` and
`:archive_scheduled` on `KilnCMS.CMS.Content`, whose `unpublish`/`archive`
pair partition on `expiry_action` in both places. `:start_scheduled` is its
own action for this reason: `:start` also serves "Publish now" and must
accept an `:open` release, so its filter is wider than the trigger's `where`
and an unscheduled release would still match it.

Where two triggers partition rows by a predicate, the filter on each action
is what keeps the partition true at write time and not just at scan time.

### What a `StaleRecord` means to AshOban

AshOban's worker treats exactly one error shape as "this record no longer
applies": an `Ash.Error.Invalid` whose `errors` list is a single
`Ash.Error.Changes.StaleRecord` (and the same for
`AshOban.Errors.TriggerNoLongerApplies`, or a read that returns nothing). It
returns `{:cancel, :trigger_no_longer_applies}`, so the job is canceled, not
retried and not raised (`deps/ash_oban`, its scheduler transformer (`define_schedulers.ex`),
version 0.8.14 here). That is the answer wanted for a scheduled action:
somebody decided differently, and re-running the job would undo their
decision. Nothing fires on a canceled job, because the side effects of these
actions (webhooks, artifacts, embedding, subscriber mail) are changes that
run on a committed write. A new date or `expiry_action` stays.

Two consequences for whoever writes the action:

- Do not let a second error ride along with the `StaleRecord`. Any other error
  in the list is raised, the job retries, and the retry hits the same wall.
- A trigger action that does not filter will not be canceled by the race: it
  will be written, which is the bug.

### How a LiveView answers a stale result

Reload and say so. A stale result is not a failure of the request, and
retrying it as it stands would repeat it. The answer is to re-read the row,
show where it stands now, and tell the person their action did not apply:

- Content transitions: `KilnCMSWeb.WorkflowMessages.error/3` answers a
  `NoMatchingTransition` or a `StaleRecord` with "Someone else changed this
  item's status first — reload to see where it stands." It is shared by the
  list (`KilnCMSWeb.EditorLive`) and the editor
  (`KilnCMSWeb.ContentEditorLive`) so the two cannot drift.
- Releases: `KilnCMS.CMS.Releases.stale?/1` recognizes both shapes, and
  `KilnCMSWeb.ReleaseLive` and `KilnCMSWeb.CalendarLive` reload and flash
  "This release changed since you opened it. It's been reloaded."
- Headless clients: `KilnCMSWeb.AshStateMachineErrors` gives
  `NoMatchingTransition` and `StaleRecord` a 409 with the stable code
  `invalid_state_transition` (#923), not the opaque 400 and logged
  stacktrace the missing protocol implementation produced.

`NoMatchingTransition` and `StaleRecord` are the same race seen at two
moments: the first when the held struct was already out of date at request
time, the second when the row moved during the request. Both get the same
answer, and a caller should not tell them apart.

## Where the rule holds, and where it does not

`AshStateMachine` is used by three resources. The other files `rg "AshStateMachine" lib`
returns are error and message modules, helper modules and comments:

- **`KilnCMS.CMS.Content`** (the `state_machine` block is in the macro that
  every content type is built from). Holds. All ten transition actions
  carry a state filter: `:submit_for_review`, `:return_to_draft`, `:publish`,
  `:publish_scheduled`, `:unpublish`, `:unpublish_scheduled`,
  `:archive_scheduled`, `:archive`, `:unarchive` and
  `:restore_imported_state` (the ten in the `transitions` block), plus `:autosave`, which is not a transition but
  refuses a published row by the same filter. The triggers' filters match
  their `where` as above. `:purge_trashed`'s `:purge` filters on the row
  still being trashed (`not is_nil(archived_at)`), which is the mirror of
  `:restore`, but not on the retention window the trigger's `where` names.
  `:sweep_untitled`'s `:destroy` filters on `archived_at` being nil, not on
  the draft/untitled/idle predicate the trigger's `where` names. Neither is a
  state transition, so neither is changed here, but both are the trigger
  half of the rule not holding. See the gap below.
- **`KilnCMS.CMS.ContentRelease`**. Holds. Every transition, and `:destroy`,
  filters on its from-states (#2745), including the system actions
  `:mark_published`, `:mark_failed`, `:reopen`, `:start_rollback`,
  `:mark_rolled_back`, `:mark_rollback_failed` and `:abandon`. `KilnCMS.CMS.ReleaseItem`
  is not a state machine (it has a `status` attribute) but its
  `:mark_applied` and `:mark_skipped` filter on `status == :pending`, and its
  add, cancel and set-action writes check the release inside their own
  transaction with the row locked `FOR SHARE`
  (`KilnCMS.CMS.Validations.ReleaseOpenForEdit`, #2740). That is the same idea
  by a different mechanism: the claim's row lock and the item write
  serialize, so an add either lands before the claim and ships with the
  release or is refused.
- **`KilnCMS.Experiments.Experiment`**. **Does not hold.** `:start`,
  `:conclude` and `:archive` have no filter. `:start` is protected from its
  worst race (two running experiments on one document) by a partial unique
  index, `content_experiments_one_running_per_document`, not by the
  transition. `:conclude` and `:archive` pass on the struct alone, so a second
  `:conclude` from a struct loaded before the first has the machine's yes and
  nothing in the `UPDATE` refuses it: it would overwrite `winner_variant_id`
  and run `KilnCMS.Experiments.Changes.NotifyConcluded` again. It has no trigger and
  no concurrent writer other than people, which is why nobody has met it, but
  the rule is not satisfied. Not changed in this record.
- **`KilnCMS.CMS.VersionFields`** only mentions `AshStateMachine` in a comment
  about why a restore must not write `state`. It is not a state machine.
  `KilnCMS.CMS.Releases` is a module of release logic, not a resource; it
  carries `stale?/1`.

## Rejected alternatives

- **Rely on `optimistic_lock(:lock_version)`.** It does not move with the
  state, as above. Bumping `lock_version` on every workflow write would make
  an editor's open form stale on every publish, which is a behavior change
  for people typing, not a fix for the race.
- **Run the transitions atomically (`require_atomic? true`).** The atomic path
  would check the from-state in SQL, but these actions set
  `require_atomic? false`: their changes (working-copy fold, artifact fire,
  webhooks, embedding, claim gates) run in Elixir around the write.
- **Re-read the record inside the action and compare.** It narrows the window
  without closing it, and costs a query. A `WHERE` predicate on the write is
  one statement and cannot be skipped by a later edit to the action's body.
- **`SELECT ... FOR UPDATE` around every transition.** AshOban can lock on
  read (`lock_for_update?`) but the manual transitions have no transaction
  around the read. Holding row locks across the console would serialize
  editors. A filter costs nothing when nobody races. (Locks are used where a
  second table is involved: release items, #2740.)
- **Let a scheduled action write and undo it.** A canceled job that never
  fires is simpler than a webhook that has to be retracted.
- **Retry the job on `StaleRecord`.** The row moved because someone decided
  something; retrying re-asserts the old decision.

## What is accepted

- **The filter is written by hand, twice.** The `transitions` block and the
  filter state the same from-states in two places, and a trigger's `where`
  and its action's filter in two more. Nothing here derives one from the
  other, and a hand-written copy can drift. Comments on the actions name the
  other half.
- **`StaleRecord` does not say what the row is now.** It carries only the
  resource, so a caller that wants the current state must re-read, which the
  LiveViews do.
- **No check enforces the rule.** A new transition action without a filter
  passes compile and every existing test. See the follow-up below.
- **The trigger half is not met everywhere.** `:purge` and `:destroy` on
  `KilnCMS.CMS.Content` filter on the row's trash state, not on the whole
  trigger `where`, as above.

## Follow-ups

- A test over every resource with `AshStateMachine` that fails when a
  transition action (an action named in a `transition ... from:` entry) has
  no `Ash.Resource.Change` of `Ash.Resource.Change.Builtins.filter/1`, with a
  reason-carrying allowlist for deliberate exceptions. It was left out of this
  record's change on purpose. `Experiment`'s `:conclude` and `:archive` would
  be the first findings: add filters, or allowlist them with a reason.
- Whether the two non-transition trigger actions above should filter on the
  whole `where`.
