# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Fixed

<a id="media-jobs-without-an-org-id-run-under-the-default-org"></a>

- **Media jobs without an `org_id` run under the default organization instead
  of silently doing nothing.** `VariantWorker`, `AVWorker` and `AVStripWorker`
  read their item with the job's `org_id` as the tenant, and a job without one
  used a `nil` tenant. Under strict tenancy that read failed and the job
  returned `:ok` having done nothing. The in-admin image editor enqueued its
  variant regeneration that way, so under strict tenancy an edited image kept
  its old variants. The editor now passes the item's `org_id`, like every other
  enqueue site. A job that still arrives without one runs under the default
  organization and logs a warning naming the worker. This is the fallback the
  firing, search and webhook workers already use
  (`KilnCMS.Media.Ingest.job_org_id/2`). The read stays tenant-scoped, so an
  item on another site is not found rather than read across organizations.
  (#1658)
