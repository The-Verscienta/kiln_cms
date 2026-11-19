# 0077. A job carries ids or sealed data, and its private arg keys are dropped when it finishes

- **Status** — accepted (2026-11-19).
- **References** —
  [#3026](https://github.com/The-Verscienta/kiln_cms/issues/3026) (this
  record), [#2992](https://github.com/The-Verscienta/kiln_cms/issues/2992)
  (form and automation job args; the registry),
  [#3019](https://github.com/The-Verscienta/kiln_cms/issues/3019) (workflow
  and task mail, the registry's second user), building on
  [#1843](https://github.com/The-Verscienta/kiln_cms/issues/1843) (sealed
  mail). The guide is
  [data-flows.md](../data-flows.md#job-args-retention).
- **Changelog** — v1.11.0, under Fixed
  ([form and automation jobs](../changelog/v1.11.0.md#form-automation-job-args),
  [workflow and task mail](../changelog/v1.11.0.md#workflow-task-mail-erased-recipient)).

## The problem

An Oban job's `args` are kept in three places the worker does not control: the
`oban_jobs` row, which Oban's Pruner deletes 7 days after the job finishes;
the `job:start`, `job:stop` and `job:exception` lines the logger attached in
`KilnCMS.Application` prints at `info` for every run, args included; and the
`extra` of a Sentry event the job raises, where the Oban integration attaches
the args. For most jobs that is harmless, because the args are ids.

Four kinds of job were not harmless. Form notification and autoresponder
jobs carried the visitor's submission (and the autoresponder its `to`
address). Automation `DispatchWorker` and `RuleWorker` jobs carry the
event's document, drafts included. Workflow and task mail jobs carried the
recipient's address, the content's title, the actor's name and a comment
excerpt or task note. Mail jobs had already been fixed one at a time in
#1843 (`KilnCMS.Mail.open_args/1`, `forget_body/1`, `KilnCMS.Mail.Scrub`).
Each of the others was a copy of that fix, and a new worker would have been a
fifth, unless something said what a job may carry.

Deleting the submission or erasing the person did not reach any of these
copies.

## The decision

**A job's args carry ids, which the worker reads back when it runs, or data
sealed with `KilnCMS.Jobs.PrivateArgs.seal/1`. Whatever private data a job
does carry sits under keys named in `KilnCMS.Jobs.PrivateArgs.registry/0`,
and those keys are dropped from the row when the job finishes.**

### The registry

`KilnCMS.Jobs.PrivateArgs` holds one map: the worker's name as Oban stores it
(a string, so a lookup by a stored name never creates an atom) to the arg
keys that hold private data. As it stands:

| Worker | Keys |
| --- | --- |
| `Forms.NotificationWorker` | `data` |
| `Forms.AutoresponderWorker` | `data`, `to` |
| `Automation.DispatchWorker`, `Automation.RuleWorker` | `payload`, `sealed` |
| `Notifications.WorkflowMailWorker` | `to`, `title`, `actor_name`, `excerpt` |
| `Notifications.TaskMailWorker` | `to`, `note`, `actor_name` |

Three consumers read the registry, so one entry covers all of them:

- **`finishing/3`** wraps the worker's `perform`. When the outcome finishes
  the job (`:ok`, `{:ok, _}`, `:discard`, `{:cancel, _}`, or an error or raise
  on the last attempt) it drops the keys from the row with a
  `args - keys` update, and then returns or re-raises the outcome. A
  `{:snooze, _}` and a failure with attempts left keep them, because the job
  runs again and needs them. The drop is best-effort: a failure is logged and
  swallowed, since the work is done and a raise would run it twice.
- **`KilnCMS.Jobs.PrivateArgsScrub`** drops the keys from completed,
  cancelled and discarded rows that still hold them, and never touches a job
  still waiting to run. It covers what `finishing/3` cannot: rows finished
  under a release before the key was registered, and a job killed mid-run,
  which `Oban.Lifeline` discards hours later without running the job's code.
  It runs ten minutes after boot and daily (`:private_args_scrub_cron`), and
  by hand with `KilnCMS.Release.scrub_job_args/0`.
- **`KilnCMS.SentryFilter`** drops the keys from an event's `extra.args`,
  matched by `extra.worker`, and drops the variables of every stack frame
  for a registered worker, because a clause error in the worker's own
  helpers quotes the same payload in its frames.

Registering a key is therefore the one step a new worker takes. A worker that
carries personal data or free text registers; a worker whose args are ids
does not.

### Ids first, sealing when the data cannot be read back

Where the worker can read the data back, it does, and the row never holds it:
form mail carries the form, site and submission ids; workflow and task mail
carry the recipient's `user_id`, the content, the actor and the comment or
task ids (#3019). The registered keys for those workers name what jobs
**queued by an earlier release** still carry, so they are dropped when such a
job finishes and by the scrub. Reading back also lets the worker check the
world as it is when it runs: workflow and task mail reaches only an account
that still exists and still holds the address it was queued for.

Where the job needs a snapshot that cannot be read back by id, as an
automation rule's reaction needs the document as it was when the event fired,
the data is sealed. `seal/1` encrypts with `KilnCMS.Keys.Vault`, a key
derived from `SECRET_KEY_BASE`, and `open/1` refuses what does not open under
any key the deployment knows, which the worker turns into a cancel with
`describe_unreadable/0`. `Automation.job_payload/1` reads either shape
(`"payload"` in the clear, `"sealed"`), so a later release can switch the
writers to sealed while a rolling deploy runs both. **That switch has not
been made:** the automation writer (`Automation.handle_event/3`) still
writes the payload in the clear, and until a job finishes it is readable in
its pending row and in Oban's log lines. data-flows.md says so, and #2992
stays open for it.

## What was rejected

- **Filtering Oban's logger.** The log lines are one of the three places, and
  the default logger is attached in one line, so it looks like the cheapest
  fix. It fixes the one place and leaves the row and the Sentry event, and it
  means replacing `Oban.Telemetry.attach_default_logger/1` with a handler of
  our own that must be kept in step with Oban's event shapes. Keeping args
  out of the row in the first place (ids) or encrypted (sealed) covers the log
  lines as a consequence, because there is nothing readable to print.
- **Scrubbing by queue.** Dropping args from every job in a queue is blind to
  what a job needs: it would remove args a retrying or scheduled job still has
  to read, and it would hide a new worker's private data only if someone
  remembered to put it in the right queue. Queues are chosen for concurrency
  and backpressure, not for what a payload holds. The registry is keyed by
  worker and key, so the scrub reads and writes only the rows and keys a
  worker declared, and `PrivateArgsScrub` never reads a row of any other
  worker, whatever its args are called.
- **Sealing form data instead of re-reading it.** Sealing would have needed
  no change to the workers' shape. But the submission is already stored, and
  re-reading it means the job holds nothing to leak, deleting the submission
  also removes what the job would have sent, and the worker sees the record as
  it is now. A sealed copy would outlive a deletion until the job finished,
  and ties every job to `SECRET_KEY_BASE`: a rotation without
  `PREVIOUS_SECRET_KEY_BASE` strands every pending one. Sealing stays for
  data that has no record to read back.
- **One shared mechanism with mail.** `KilnCMS.Mail` keeps its own keys
  (`forget_body/1`, `KilnCMS.Mail.Scrub`) for the account mail it queues,
  and this module says so. Mail's message keys, its delivery-panel addresses
  and its erasure handling were built first and carry rules of their own, such
  as the address staying in the row until erasure. Folding them into the
  registry would have changed a shipped behavior to tidy a design. Mail
  jobs are not registered; every other worker's keys are.

## Consequences

- A new worker that would put personal data or free text in its args
  registers its keys in `PrivateArgs`, wraps its `perform` in `finishing/3`,
  and prefers ids to sealed data. A reviewer can check this from the worker's
  `new/1` call sites.
- The registry is a list of names, and nothing checks that a worker which
  carries private data is in it. Registering is a convention, as the guide's
  "Job args retention" list is. A check that flags an unregistered worker is
  not built.
- A registered key is dropped only when the job finishes. A job's args are
  readable while it is pending and in the log lines of a run that does not
  finish it; that is the cost of keeping them for the retry.
- The Pruner's 7 days remain the bound for everything that is not private.
