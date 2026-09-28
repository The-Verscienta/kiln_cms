# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Fixed

<a id="a-media-job-with-no-org-id-is-cancelled-not-silently-skipped"></a>

- **Edited images get new variants under strict tenancy, and a media job with no
  `org_id` is cancelled with a logged error instead of doing nothing silently.**
  `VariantWorker`, `AVWorker` and `AVStripWorker` read their item with the
  job's `org_id` as the tenant. A job without one used a `nil` tenant, and
  under strict tenancy that read failed, so the job returned `:ok` having done
  nothing. The in-admin image editor enqueued its variant regeneration that
  way, so an edited image kept its old variants. The editor now passes the
  item's `org_id`, as every other enqueue site already did. The workers now
  treat a job with no `org_id` as a bug in whatever enqueued it: they log an
  error naming the worker and the item and return `{:cancel, reason}` to Oban
  (`KilnCMS.Media.Ingest.job_tenant/2`). They do not guess the default
  organization. If such a job was queued before this release, it shows as
  cancelled; `mix kiln.media.regenerate_variants --all` re-derives variants. (#1658)

<a id="an-old-newsletter-confirmation-link-no-longer-re-subscribes"></a>

- **An old newsletter confirmation link no longer re-subscribes a reader who
  unsubscribed.** Confirmation now only moves a subscriber from pending to
  confirmed. When the subscriber has unsubscribed since, both the link's page
  and its button show a neutral "this link is no longer valid, subscribe
  again" page and change nothing. The page names no address and no status. The
  `Subscriber` `:confirm` action enforces the rule itself, so an unsubscribe
  that lands between the lookup and the write still wins. Confirming an
  already-confirmed subscriber again is a no-op that keeps the original
  `confirmed_at`. (#1690)

## Security

<a id="newsletter-sign-up-honeypot-matches-forms"></a>

- **The newsletter sign-up honeypot and public forms trip on the same rule.**
  The two surfaces render the same hidden `website` input but checked it
  differently: forms trimmed a string value first, so a whitespace-only value
  passed as human, while newsletter sign-up had its own inline test. Both now
  call `KilnCMS.Forms.honeypot_tripped?/1`, and it is the stricter reading:
  only an absent field or the empty string an untouched input submits counts
  as a human. Any other value trips it, including whitespace-only strings and
  non-string values such as a list or a map. A tripped honeypot still reports
  success and stores nothing on both surfaces. (#1657)
