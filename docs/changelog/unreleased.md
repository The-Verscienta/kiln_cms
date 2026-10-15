# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="kilncmsdev-now-publishes-kilns-security-policy-at-security-and-a-security"></a>

- **kilncms.dev now publishes Kiln's security policy at `/security`, and a
  security notice per published GitHub advisory at
  `/security-notices/<ghsa-id>`, with a feed.** A new workflow,
  `publish-security.yml`, runs `scripts/publish_security.exs` daily, when a
  release is published, and when `.github/SECURITY.md` changes on `main`.
  The page is `SECURITY.md`, with its relative links pointed at GitHub, plus
  the list of notices. Each notice is an entry of a `security_notice`
  content type whose custom fields are `package`, `affected_versions`,
  `patched_versions`, `severity`, `advisory_id`, `cve_id`, `published_on`
  and `advisory_url`. `package` is `kiln_cms` for the core and a plugin's
  Hex name for a plugin's notice, so the plugin registry (#1447) can share
  the type and its feed at `/security-notices/feed.xml`. A withdrawn advisory
  is not published, and the script never unpublishes a notice. The type is a
  one-time setup on the site; the script names any field it is missing.
  `SECURITY.md` and the README link to the page and the feed. Nothing
  changes for a self-hosted instance: the script and workflow publish to
  kilncms.dev only. The per-site `security.txt` this issue also asked for
  shipped in 1.1.0 (#1881).
  ([#1873](https://github.com/The-Verscienta/kiln_cms/issues/1873))

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

<a id="regeneration-pixel-cap"></a>

- **Regenerating variants skips images over the pixel cap instead of
  re-reading each original on every run.** An image recorded over
  `max_pixels` (50 MP) can never be given variants: its job reads the
  original and refuses it, as the transform route refuses it from the same
  recorded size. The missing-only run still enqueued it every time, and for
  an image backend's item each of those reads is an API download. A 52.9 MP
  photo adopted from a Sanity import cost one on every run. `Regeneration.run/2`
  now counts such images in `over_pixel_cap` without enqueuing them, and
  `mix kiln.media.regenerate_variants` reports the count.
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))
