# 0094. A backup report is enqueued in the run's terminal write (transactional outbox)

- **Status** — accepted (2026-11-27).
- **References** — [#2229](https://github.com/The-Verscienta/kiln_cms/issues/2229)
  (backup reports and alerts; this is its part A, the email and the bell);
  [ADR 0033](0033-backup-history-is-rows-only-the-backup-pipeline-writes-and-the-files-stay-the-truth.md)
  (History is rows the pipeline writes);
  [ADR 0045](0045-a-backup-run-write-never-shares-the-lock-transaction-except-cancel.md)
  (a Cancel is the one Run write inside the backup lock's transaction);
  [ADR 0092](0092-a-backup-runs-log-is-shown-and-downloaded-redacted-refused-while-the-console-shares-an-origin-without-an-audit-event.md)
  (the log is redacted again when read).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

#2229 asks for a report after each backup run: an email to the platform
admins who opted in (owner decisions, 2026-11-17: per admin, failures on by
default), and a bell row for a failed or partly off-site run. Until now a
failed backup was silent unless someone opened the Backups page.

Four questions outlive the release: where the report is triggered, what a
report job carries, what makes a report idempotent, and what happens to a
run that failed and later recovered.

A run gets its outcome from many places: the recorder's `finish`, `fail`
and `skip`, the stale-run sweep, a refused resume that fails a stale
`running` run, a platform admin's Cancel and Cancel of a resume, the cron
importer and its re-evaluation of an Interrupted row. Every one of them goes
through a `KilnCMS.Backups.Run` action.

## The decision

### The terminal write enqueues the report, in its own transaction

`KilnCMS.Backups.Run.Changes.AfterOutcome` is on every action that can give
a run its outcome (`:finish`, `:fail`, `:skip`, `:cancel`, `:cancel_resume`,
`:note_resume_refused`, `:import`, `:reevaluate_interrupted`). Its
`after_action` hook inserts one `KilnCMS.Backups.ReportWorker` job when the
status the write leaves is terminal (`succeeded`, `failed`, `skipped`,
`canceled`) and new for the row: a changed status, or a changed
`finished_at` (an Interrupted import re-evaluated as another failure). The insert is a plain `INSERT` into
`oban_jobs` on the action's own connection, inside its transaction: a
transactional outbox.

- **The report and the outcome commit or fail together.** A job exists
  exactly when the outcome commits. A write that rolls back (a Cancel
  refused inside the backup lock's transaction, ADR 0045, or an outer
  transaction that aborts) leaves no job, and a node that dies after the
  `COMMIT` cannot lose one. An insert that fails fails the write with it;
  it is not swallowed. The precedent is the `backup_canceled` audit event,
  which `KilnCMS.Security.Changes.Record` writes in `mode: :in_transaction`
  on the same action.
- **A racing writer reports nothing.** A second terminal write gets
  `StaleRecord` from the action's own filter (`status == :running`,
  `Changes.OwnChain`), so its hook never runs. A write that leaves the
  status as it was (a refused resume, or a canceled resume, of a run that
  is already `failed`) is not new and enqueues nothing.
- **The job is not `unique`.** Oban's uniqueness check takes an advisory
  try-lock that can make the insert do nothing, which would drop a failure
  alert silently. The outbox already gives exactly one job per committed
  terminal write.
- **A failed run's job is scheduled a minute out.** A backup interrupted
  from outside its step is failed at once and its log and destinations are
  added later (`:record_interrupted`, #3078). The report reads the run when
  it runs, so that record has usually landed.
- **Re-sends are not reported.** `:record_resend` changes a succeeded run's
  off-site outcome but is not a run; a partly off-site row stays as it was.

### Ids only, read back when the job runs

The fan-out job carries the run's id and the `finished_at` of the outcome
it reports. It reads the run as `KilnCMS.Backups.system/0` with
`authorize_with: :error`: a refused read fails the job, which retries, and
is never taken for "gone". A run whose `finished_at` is not the job's has a
newer outcome with its own job, so the older job sends nothing, with one
exception: a failure resumed before its report ran (its job waits a minute).
When the run's `last_failed_at` is the job's `finished_at`, it is reported
as the failure it was, saying it has been resumed since, whether the resume
is still running, succeeded or was canceled.

It writes the bell rows (failed and partly off-site runs, every platform
admin, whatever their email preference) and queues one
`KilnCMS.Backups.ReportMailWorker` job per platform admin whose
`User.notify_on_backup` admits the run's class. That job carries the run's
id, the `finished_at` and the recipient's id, and checks again when it runs
that the recipient exists, is not erased, is still a platform admin
(`RoleGrant.effective_role/1` on the account as read now), still wants the
report, and is not on the instance suppression list. The email is built
then, so a retry that waits hours sends what is true at that time, and no
error text or address is ever written to a job row.

### Idempotent where the effects are

The mail job is unique on the run, the `finished_at` and the recipient, in
every state, and is inserted outside any transaction, so a fan-out that runs
twice queues one email per admin. The bell rows collapse: while a backup
notice is unread, a newer one refreshes its excerpt and details (a
system-only `:refresh` action on `KilnCMS.Notifications.Notification`, under
the same advisory lock as the other collapsing events) instead of adding a
row.

### A failure that recovers says so

`AfterOutcome` also sets `Run.last_failed_at` on a write that leaves the
run `failed`. A resume keeps it. When a run that carries it succeeds, the
report is a recovery (`KilnCMS.Backups.Report.recovered?/1`): it goes to
those whose `notify_on_backup` admits its class (every run for a full
success; failures too when the recovered run is only partly off-site) and to
every admin a failure report of that run was queued for (a `ReportMailWorker` job for an earlier outcome of the
run, not canceled or discarded) who still wants failure mail (an admin who chose Off since hears nothing more), and each admin's unread `:backup_failed`
row about that run is marked read. A recovery whose failure has not been
fanned out yet snoozes until it has, so the order of the two reports holds.
Finished jobs are pruned after a week: a recovery later than that is mailed
by preference only. An imported run that recovers (an Interrupted row that
finished after all) says exactly that, never "resumed". A row that has
since been refreshed to another run's failure stays unread.

The column is on the run rather than derived from its log or its jobs: the
log keeps its first 50 and last 149 entries and may drop the resume line,
and finished jobs are pruned after a week.

### Cron runs too, but not old ones

Imported runs are reported (owner decision, 2026-11-27), when the importer
inserts a terminal row or a re-evaluation changes one's status or its
`finished_at`. An upsert
that hits an existing stamp hands back the existing row, so the hook
compares ids and stays quiet. An imported run that finished more than 48
hours ago is imported without a report, so pointing a fresh install at a
directory of old backups does not mail one report per backup. A burst of
new rows is bounded too: when its report job runs, an imported run that
succeeded or was skipped is not reported if a newer imported run has an
outcome, so ten cron successes imported in one pass mail one report. A failed or partly off-site import, and
a recovered one, is always reported.

### Rolling deploys

Oban runs each job once, on whichever node fetches it. A node from the
release before has no such worker, so the job fails there and retries. Both
workers take 20 attempts on the mail backoff (`KilnCMS.Mail.backoff_seconds/1`,
about five days), so a long deploy does not discard them. A run that an
older node finishes during the deploy enqueues no report.

## Rejected

- **Sending from `Steps.settled/2` or from a step.** That is telemetry: it
  fires even when the write failed, sends before the commit, and repeats on
  retries.
- **An insert after the commit (`after_transaction`).** A crash between the
  commit and the insert loses the failure alert.
- **A unique fan-out job.** Its try-lock can drop the insert; see above.
- **Rendering the email when the run ends (`Mail.enqueue!`).** It would seal
  error text into job args, double-send on a retried fan-out, and send stale
  content to someone demoted or opted out since.
- **Reusing the platform security alerts.** They cannot be muted, which the
  owner's per-admin choice rules out.
- **A `:partial` run status.** An older release cannot read a status it
  does not know; `offsite_status` already says it.
- **Deriving "recovered" from the log or from finished jobs**, above.
