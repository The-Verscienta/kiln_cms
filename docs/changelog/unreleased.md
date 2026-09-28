# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="jobs-already-stuck-executing-from-earlier-deploys-run-again-or-are-discarded"></a>

- **Jobs already stuck `executing` from earlier deploys run again (or are
  discarded) within a minute of upgrading.** The new Lifeline rescue (below)
  does not know how old a row is beyond its `attempted_at`, so every
  `executing` row older than three hours that a past deploy stranded is put
  back to `available`, or `discarded` if it had used its last attempt, on the
  first sweep after the upgrade. For most workers that is the point: a
  stranded publish, variant or delivery finally happens. To see what will be
  picked up, run `SELECT id, worker, attempted_at FROM oban_jobs WHERE state =
  'executing' AND attempted_at < now() - interval '3 hours'` before
  upgrading, and cancel any you do not want re-run
  ([#1718](https://github.com/The-Verscienta/kiln_cms/issues/1718)).

## Fixed

<a id="a-job-killed-by-a-deploys-shutdown-is-rescued-after-three-hours-instead-of"></a>

- **A job killed by a deploy's shutdown is rescued after three hours instead of
  staying `executing` for ever.** Stopping a node gives running Oban jobs 15 s
  and then kills them. Kiln ran no rescuer, so the row stayed `executing` for
  good: never retried, never discarded, and for a `unique` worker (fire,
  static export, embeddings, link checks, the occurrence backfill) it blocked
  every later enqueue of the same job. `Oban.Lifeline` now runs, appended to
  the plugin list by `KilnCMS.Application.oban_config/0` next to the injected
  crontab. It moves a job `executing` for longer than
  `KILN_OBAN_RESCUE_AFTER_MINUTES` (default 180) back to `available`, or to
  `discarded` once its attempts are spent. The rescue goes by time alone, so
  the window must exceed the longest legitimate job. That is a backup
  (2 h timeout), and a test now fails if any worker's `timeout/1` comes within
  30 minutes of the window. A rescued job starts over, so the newsletter
  fan-out was made safe to repeat: `MailWorker` is now `unique` on
  `{send, subscriber}` across every state, so a second fan-out run (rescued, or
  an ordinary retry after a crash part-way through) enqueues only the
  recipients the first run missed. Before, it mailed everyone again.
  [`deploy.md`](../deploy.md#jobs-interrupted-by-a-deploy) lists what each
  kind of job does when it is rescued
  ([#1718](https://github.com/The-Verscienta/kiln_cms/issues/1718)).


