# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="before-upgrading-to-10-let-queued-webhook-and-newsletter-jobs-from-before-012"></a>

- **Before upgrading to 1.0, let queued webhook and newsletter jobs from before
  0.12 drain, and move accounts off the legacy audiences fallback;
  `mix kiln.deprecations` says what is left.** Nothing changes in 0.12 itself.
  1.0 removes what 0.12 deprecates (#1543), and two of those removals would
  strand data rather than break a compile. First, 1.0 no longer runs webhook
  delivery, newsletter send or newsletter mail jobs enqueued without an
  `org_id` (anything a release before multi-tenancy queued, and the pre-ledger
  webhook shape). Second, 1.0 no longer reads `User.audiences` for an account
  with no organization membership, so such an account loses its gated
  content. `mix kiln.deprecations` lists both and exits non-zero while either
  is non-empty, so it can gate an upgrade script; in a release, run
  `bin/kiln_cms eval 'KilnCMS.Release.deprecations()'`. Let the jobs drain (or
  cancel them), and run `mix kiln.deprecations --migrate-audiences` to give
  each listed account a membership on the default organization carrying its
  audiences and standing role
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

## Changed

<a id="an-unknown-option-to-use-kilncmscmscontent-now-warns-at-compile-time-instead-of"></a>

- **An unknown option to `use KilnCMS.CMS.Content` now warns at compile time
  instead of being silently ignored.** The macro read its options with
  `Keyword.get/3` and never looked at the rest, so a typo (`exerpt?: true`) or
  an option an overlay made up compiled clean and did nothing. It would also
  start doing something the day a release added an option by that name. Any
  key outside the options the macro reads now raises a compiler warning at the
  overlay's own `use` line, naming the key and the accepted set. It is a
  warning, not an error, so no overlay that compiles today stops compiling;
  2.0 makes it an error
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

## Fixed

<a id="a-429s-retry-after-is-rounded-up-never-0"></a>

- **A 429's `retry-after` is rounded up, never 0.** The per-IP rate limiter
  truncated the time left in its fixed window to whole seconds, so a client
  refused in the window's last second was told `retry-after: 0` and retried
  straight back into the closed window. The docs publisher honours the header:
  it spent all three retries within a few milliseconds and failed the v0.11.0
  docs sync a moment before the window reopened. The plug now rounds the same
  way `AccountThrottle.retry_after_seconds/1` already did for the second-factor
  budget — up, and never below one. `scripts/publish_docs.exs` also waits at
  least a second on any 429 and retries up to five times, since a full sync
  (~3 requests a guide) is larger than the `:api` bucket and keeps talking to
  sites that haven't picked this fix up.

## Deprecated

<a id="published-on-use-kilncmscmscontent-is-deprecated-and-removed-at-10"></a>

- **`published?:` on `use KilnCMS.CMS.Content` is deprecated, and removed at
  1.0.** The option has been ignored since every content type gained the
  `:published` read (#300); it is now a compiler warning at the overlay's
  `use` line. Remove it. `mix kiln.gen.content --published` no longer writes
  it; the flag still adds the `list_published_*` interface, and the core
  `Post` no longer passes it
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

<a id="the-editorpagesid-and-editorpostsid-editor-routes-are-deprecated-and-removed-at"></a>

- **The `/editor/pages/:id` and `/editor/posts/:id` editor routes are
  deprecated, and removed at 1.0; use `/editor/content/page/:id` and
  `/editor/content/post/:id`.** Both still open the editor, and each visit logs
  a warning naming the replacement (a route has nowhere to carry
  `@deprecated`). Nothing in the core links to them any more: workflow mail,
  task mail, the notification bell and the inbox now link pages and posts
  through `/editor/content/`, like every other type. Mail sent before this
  release still carries the old links, which is why they last until 1.0
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

<a id="the-useraudiences-fallback-for-an-account-with-no-organization-membership-is"></a>

- **The `User.audiences` fallback for an account with no organization
  membership is deprecated, and removed at 1.0.** Such an account reads gated
  content through the global `User.audiences` column, on every site. That is
  the pre-multi-tenancy model, and the one gap in the per-org audience rule.
  It still grants access, and now logs a warning once per account per boot.
  `mix kiln.deprecations` lists the affected accounts, and
  `--migrate-audiences` gives each a default-organization membership carrying
  its audiences and standing role. After that, change a migrated account's
  audiences on its membership (or comp it a tier): the checkboxes on
  `/editor/accounts` still write the global column. See the Upgrade notes
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

<a id="webhook-and-newsletter-jobs-enqueued-without-orgid-and-pre-ledger-webhook-jobs"></a>

- **Webhook and newsletter jobs enqueued without `org_id`, and pre-ledger
  webhook jobs, are deprecated, and not run by 1.0.** `Webhooks.DeliveryWorker`,
  `Newsletter.SendWorker` and `Newsletter.MailWorker` still run them against
  the default organization, and log a warning each time. Every job this
  release enqueues carries `org_id`. Let the queue drain before upgrading to
  1.0; see the Upgrade notes
  ([#1538](https://github.com/The-Verscienta/kiln_cms/issues/1538)).

