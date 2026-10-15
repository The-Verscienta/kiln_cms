# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="release-adopt-image-backend"></a>

- **A release can adopt imported images: `bin/kiln_cms rpc
  'KilnCMS.Release.adopt_image_backend()'`. System → Image backend labels it
  and the Mix task, each with a dry run first.** The page listed
  `mix kiln.media.adopt_image_backend` and a raw `rpc` call one under the
  other, unlabelled, so an operator pasted both into a release's shell, where
  there is no Mix. The `rpc` call printed nothing, and the org ID's inner
  quotes were easy to lose to a `docker exec` or `ssh -C` wrapper, which fails
  as a bare `CompileError` whose cause is only in the server's log.
  `KilnCMS.Release.adopt_image_backend/1` is the task for a release, like the
  importers beside it: it prints the task's report, returns refusals instead of
  raising, and refuses under `eval`, since each adopted row enqueues a job.
  For the default site it takes no org, so its command has no inner quotes;
  `org: "<uuid>"` names another.
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))

## Fixed

<a id="variant-worker-backend-errors"></a>

- **A variant job no longer takes an image backend's failed or rate-limited
  read for a deleted original.** `VariantWorker` treated every failed read of
  the original as "removed, nothing to do" and completed. For a file on disk
  that is usually true; for an image backend, a remote API, it is usually a
  timeout, a 5xx or a rate limit. An adopted row then kept no dimensions or
  variants, and since it was no longer an imported link, nothing enqueued it
  again. A read refused with `{:rate_limited, retry_after_ms}`, the shape
  Kiln's own budgets use, now snoozes the job, which doesn't spend an attempt,
  so a large adoption paces itself under a backend's API budget. Any other
  failed read of a backend-held original is retried, unless the backend says
  `:not_found`. Reads from Kiln's own storage are unchanged.
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))
