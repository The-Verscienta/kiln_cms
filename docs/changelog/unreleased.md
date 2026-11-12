# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="slack-webhooks-upgrade"></a>

- **Run `mix ash.migrate`; before rolling back to 1.9, deactivate every Slack-format webhook endpoint.**
  One additive migration: `webhook_endpoints.format` (`text NOT NULL DEFAULT
  'kiln'`, so every existing endpoint stays Kiln-format) and
  `notifications.details` (a nullable map on the bell rows of security
  alerts). Neither is read by 1.9, so the columns can stay after a rollback.
  What a mixed or rolled-back cluster does with a Slack-format endpoint:
  - **During a rolling deploy**, a node still on 1.9 that runs a delivery to a
    Slack endpoint posts Kiln's JSON envelope; Slack answers 400 and the job
    is retried, normally by a node on the new release. A 1.9 console can also
    tick content events on a Slack endpoint, which the new release refuses;
    the new release never queues content events for it, and one queued by a
    1.9 node is posted as a neutral line naming the event.
  - **After rolling back to 1.9**, every Slack endpoint is sent the Kiln
    envelope, Slack refuses each delivery, and after 10 exhausted deliveries
    the endpoint is auto-disabled with a `webhook_auto_disabled` silencing
    notice to the site's admins. Untick **Active** on (or delete) each Slack
    endpoint first.
  - **Rolling forward again** after a newer release added a format this one
    doesn't know, such an endpoint's deliveries fail with "endpoint format
    not supported by this release" rather than being sent.
  Platform security alerts raised after the upgrade carry `content_type`
  `platform_security_alert`; 1.9 shows them in the default site's bell as
  before. (Part of #2245.)

## Added

<a id="slack-webhook-format"></a>

- **A webhook endpoint can be Slack-format: it posts the site's security alerts and silencing notices into a chat channel as a readable message.**
  Choose **Format** → **Slack (incoming webhook)** under **Add a webhook**
  on `/editor/webhooks`; the event list narrows to the `security` group with
  every event ticked. The body is an incoming-webhook message (`text`,
  `blocks`, unfurling off), so Mattermost, Rocket.Chat and Discord's `/slack`
  URL take it too. It says the alert's English headline, the site, when, and
  links to the security log, with the site name, address and event name in
  code spans and Slack's control characters escaped, so a site name cannot
  `@channel` or add a link. A ping says "KilnCMS webhook test for (site)" and
  carries no URL; a Kiln-format ping is unchanged and still carries
  `endpoint_url`. The format is set when the endpoint is added and can't be
  changed (`format` is accepted by `:create` only). A Slack endpoint takes
  `security.*` events only (refused otherwise with "Slack endpoints can only
  receive security events") and never receives content events or
  retractions. Deliveries are still signed over the body sent, but Slack
  checks no signature, so the URL is the credential: the row shows no signing
  secret and no **Rotate secret**, and URLs are now masked (next entry).
  `WebhookEndpoint` gains a public `format` attribute (`:kiln` | `:slack`),
  and `url` and `WebhookDelivery.endpoint_url` are now `sensitive?`. See
  [Send alerts to Slack](../security-alerts.md#send-alerts-to-slack). (Part
  of #2245.)

## Changed

<a id="form-field-name-website-reserved"></a>

- **No form field of any type can be named `website` any more, and the form builder flags a field that already is.**
  `website` is the name of the hidden spam-trap input every public form
  carries, and a submission that fills it is discarded with a fake success.
  A field of your own with that machine name is filled by real visitors, so
  every submission that answered it was silently thrown away. 1.9 refused the
  name only on the field types it added; it is now refused on every type,
  when a field is added, renamed or has its type changed. A field that
  already carries the name keeps working as before (label, order,
  **Required** and other edits still save), but the builder shows
  **Reserved name** under it on the preview and a note under **Machine
  name** in its settings until it is renamed; its type can't be changed
  until then, as 1.9 already refused for the new types. Admins: open each
  form in the builder and rename any flagged field
  ([Fix a field named website](../forms.md#fix-a-field-named-website)). The
  spam trap itself is unchanged: `GET /api/forms/<slug>` still reports
  `"honeypot_field": "website"`. `FormField` has no JSON:API or GraphQL
  write surface, so only code that calls `KilnCMS.CMS.create_form_field`
  or `update_form_field` with that name sees the new refusal, *is reserved
  for spam protection* on `name`. (#2267)

<a id="webhook-url-masking"></a>

- **Webhook URLs are shown masked wherever Kiln shows, exports or logs them, and the edit form no longer pre-fills the URL.**
  An incoming-webhook URL (Slack, Teams, Discord, Zapier) carries its own
  token, so the URL itself is a credential. Every endpoint's URL, whatever its
  format, is now shown as `scheme://host[:port]` followed by `/…/` and the last
  four characters of the path and query, or the host alone when those are
  shorter than 16 characters; a user name and password are never shown
  (`KilnCMS.Webhooks.display_url/1`). This covers the Webhooks list, Recent
  deliveries, the secret buttons' accessible labels, the governance trail's
  propagation endpoints and **Retractions not delivered** panel, the trail's
  JSON and CSV exports (same keys, masked values; the JSON now adds
  `endpoint_id` to each propagation endpoint and lost retraction, so two
  endpoints that mask alike can be told apart), the "Retraction not
  delivered" notice and its log line, and URL validation errors. **Reveal
  URL** on a row, or under **Current URL:** in the edit form, re-reads the
  endpoint as the admin and shows the full URL for the open page. The edit
  form's **Endpoint URL** starts blank: leave it blank to keep the URL, or type
  a new one. The database and the delivery ledger keep the full URL, and a
  redelivery is sent to it. A script that read full URLs out of the
  governance exports must now read them from the endpoint itself. Notices
  written before the upgrade keep the full URL in their excerpt.
  (Part of #2245.)

<a id="webhook-select-all-skips-security"></a>

- **Select all in a webhook's event list no longer ticks the `security.*` events.**
  It is there to mirror content, and an endpoint that took every event that
  way also received security alerts (client addresses, user ids) at a
  receiver nobody chose for them, and every later edit of it sent each admin
  a notice that can't be muted. Select all now ticks every other event and
  keeps a security event only if it was already ticked; the `security`
  group's own **Select all** still ticks them all. On a Slack-format form,
  which offers only security events, Select all ticks them all. (#2642)

## Fixed

<a id="security-alert-gaps-2642"></a>

- **Four gaps in security alerts after 1.9: the inbox's language, exhausted deliveries, platform alerts outside the default console, and IPv6 in the help text.**
  - The inbox showed a translated "Security alert" over an English
    description. Bell rows of security alerts now store the facts behind the
    line (`notifications.details`), and the inbox says it in the reader's
    language; rows from before keep their English line. The email stays
    English by decision: an account stores no preferred language and one
    admin can hold sites in several.
  - An alert that used its 10 delivery attempts was only stamped
    `failed_at`. It now also logs at `error` and emits
    `[:kiln_cms, :security, :alert_failed]` with `reason: :delivery_exhausted`
    and a new `phase` key (`:alert` or `:summary`), once per alert.
  - Platform alerts live in the default site, so a platform admin working in
    another site's console never saw them. The bell and inbox there now show
    one entry, "N unread platform alerts", linking to the default site's
    unread inbox. It is a count and nothing else: another site's console is
    that site's origin (threat model residual risk 16, decision record 0011).
    Platform alerts from before the upgrade are not counted.
  - The **Show the full IP address in alerts** help text now reads "Off, an
    alert shows only the address's network: its /24 for IPv4, its /48 for
    IPv6. The security log keeps the full address either way." (#2642)


<a id="form-duplicate-autoresponder"></a>

- **Duplicating a form whose autoresponder is on and uses `[field:…]` tokens works again, and a field that can't be copied is named instead of dropped.**
  The copy was created with the autoresponder on before any of its fields
  existed, so the token check found no field and refused the whole
  duplicate. The copy is now created with the autoresponder off, its fields
  are copied, its renamed tokens are written, and then it is switched on in a
  separate write checked against the copy's own fields. A field named `website` is copied as `website_2` (or
  the next free name), and the copy's `[field:website]` tokens follow; the
  message says so. A field the copy refuses is listed in an error message,
  and when the copy's autoresponder can't be switched on (its template names
  a field that wasn't copied) it stays off with the reason shown. (#2267)

<a id="form-errors-translated"></a>

- **Number and rating errors on a public form read as translated sentences, such as "Enter a number of at least 0.5.", and the builder explains what a default value does for dropdowns, radio buttons, checkbox groups and ratings.**
  The bounded refusals (at least, at most, step, rating range) and a hidden
  field's "is too long" reached the HTML form as raw English fragments. The
  HTML form now shows them in the form's language, with the bound as the
  server writes it (`0.5`, which is what a number input takes). The JSON
  endpoint `POST /api/forms/<slug>` returns the same English fragments as
  before (`must be at least 0.5`), because clients match on them. The
  builder's **Default value** input now has a hint for a dropdown or radio
  buttons (an exact option match pre-selects it), a checkbox group (that one
  box starts checked) and a rating (a whole number of stars), joining the
  checkbox's, and the hint is announced with the input. (#2269)

<a id="form-error-summary-focus"></a>

- **A public form's error summary links now move focus to radio buttons, checkbox groups and ratings, landing on the group's first option.**
  The links pointed at the group's `<fieldset>`, which cannot take focus,
  so following one scrolled the page but left focus behind, and a keyboard or
  screen-reader user had to find the field again. The link now targets the
  group's first input, with a scroll margin that keeps the group's question
  in view. A hidden field's error is listed as plain text, since a hidden
  input can never take focus. (#2268)

<a id="form-thank-you-site-layout"></a>

- **The thank-you page after a form submission on the site, and its "Form not found" page, now show the site's header, footer and branding, in the form's language.**
  They were a bare card with none of the site around it, unlike the form
  page and its error re-render. Both now render in the site's public layout
  for the same site and language; the 404 is headed **Form not found** and
  says *This form doesn't exist or no longer takes submissions.* A tripped
  spam trap's fake success gets the same page as a real one. The page inside
  an embed's iframe is unchanged. The **Back** link is also left out when
  the referring path starts with `//` or `/\`, which a browser reads as
  another host. (#2338)

<a id="dynamic-type-site-lookup"></a>

- **Custom content types on a site other than the default one are delivered again.**
  Several read paths resolved a content type by name without saying which
  site was asking, and a custom (admin-defined) type then resolves against
  the default site. On any other site that defines a type the default site
  lacks, `GET /api/content/<type>/<slug>` answered 404 for published
  entries, the headless and HTML passphrase unlock could not find the
  document, `/related` and `/api/provenance` answered 404, the visual-editing
  socket refused the connection, and **Visual** in the content editor said
  *No such content to edit*. Each of those now passes the request's site.
  Built-in and overlay-compiled types were never affected.

<a id="storage-copy-and-backup-verify"></a>

- **A copy from storage that fails partway is an error, and `backup.sh verify` fails on a corrupt dump.**
  `KilnCMS.Storage.copy_to_file/3` answered `:ok` when a read failed after
  the first chunk, and ignored a failed write, leaving a short file on
  disk. The direct-upload completion and the audio/video metadata strip took
  that file as the whole upload. It now returns `{:error, reason}` for a
  failed read or write at any offset. Separately, `scripts/backup.sh verify`
  ran `pg_restore --list … && echo "dump: ok"`, which `set -e` does not
  treat as a failure, so a truncated dump with no checksum sidecar verified
  clean with exit 0; it now stops with an error naming the dump.

<a id="sweep-crash-fixes"></a>

- **Crash fixes in the console and the public API.**
  `ContentTypes.get_record/3` raised for a type that no longer resolves (an
  archived custom type, a removed plugin), which took down the Tasks page,
  the calendar and a menu item's Edit for anything still pointing at such an
  entry; it now returns `{:error, :unknown_content_type}`. A nested value in
  a custom-field filter (`custom_filter[name][eq][x]=1`) answered 500 and
  now answers 400. Creating a redirect from `/` crashed the Redirects form.
  A federation inbox body that is valid JSON but not an object is answered
  400. A `return_to` path containing a backslash, a tab or a newline falls
  back to the default instead of answering 500. Moving a block that is no
  longer on the page in the in-context editor is ignored instead of
  crashing the editor.

<a id="sweep-wrong-results"></a>

- **Wrong results fixed.**
  The Home health panel and its CSV export ordered rows by comparing
  `DateTime` structs field by field, so "most overdue first" could list a
  March deadline ahead of a January one and drop the worst rows from the top
  ten. A mention such as `@josé` was cut at the first non-ASCII letter and
  could notify a different member. A form rating field with a maximum below
  1 rendered a descending range of options. Saving in the Presentation
  console broadcast a block shape the pop-out and token previews cannot
  render, crashing them. Group caps on custom-field filters (`_or`/`_and`
  depth and member count) were skipped when the filter was passed with atom
  keys from Elixir or MCP. Links and rich text refuse a relative path that
  hides a `//host` behind a tab or newline.

<a id="sweep-federation-release"></a>

- **A federation delivery whose ledger row could not be read is retried, and the release schedule confirmation moved to the button.**
  The delivery worker treated every failed read of its ledger row as "the
  row was pruned" and finished successfully, so a database timeout dropped
  the activity and left the row pending. Only a not-found is treated that
  way now. On a release with blocked items, the "Schedule anyway?"
  confirmation was attached to the whole form, so clicking the date field
  asked it and cancelling kept the picker from opening; it now asks when
  **Schedule** is pressed. In the editor, a rich-text block's pending
  autosave is cancelled when the block is rebuilt after a conflict reload or
  a version restore, so it can no longer write the pre-reload text back.

<a id="backup-marker-sync-cron-only"></a>

- **A deployment that backs up only with host cron now gets the last-good marker, so `backup.sh prune` keeps the newest verified backup there too.**
  The app wrote `kiln-<stamp>.good` only at the end of an in-app backup or
  before an in-app prune, so a deployment whose backups all come from
  `scripts/backup.sh` never had one, and its prune kept only the newest
  complete set, even when that set came from a failed run (an off-site copy
  that was refused, say). A scheduled job, `KilnCMS.Backups.MarkerSyncWorker`,
  now imports cron's backups into History and moves the markers to the newest
  verified backup of each component, under the backup lock, every 15 minutes.
  While an in-app backup runs it skips the slot, since that backup moves the
  markers itself. A cron backup is marked at the first run that can import it:
  any run once `manifest.json` names its stamp, otherwise once its newest file
  is 10 minutes old, so allow up to about 25 minutes.

  Operators:

  - **Nothing to set** on a single host or a shared volume, as long as the app
    sees the same `BACKUP_DIR` as cron. A node with no backup directory does
    nothing and logs nothing.
  - **The schedule** is `KILN_BACKUP_MARKER_SYNC_CRON` (default
    `*/15 * * * *`, read in every environment). `false` turns it off; an
    unparseable value warns on stderr at boot and turns it off.
    `BACKUP_ENABLED=false` does not stop it: that switch is for the in-app
    backup path, and the marker is for the cron path.
  - **Several hosts, each with its own `BACKUP_DIR`**: with no
    `.kiln-dir-id` (only an in-app backup creates one), each slot syncs the
    directory of the node that picked up the job. With ids, one sync per id
    waits for a node that reads it, for up to about 10 minutes, then logs
    "Backup last-good marker sync for backup directory `<id>` gave up: no
    node with that directory picked it up".
  - **Watch it** with the new `[:kiln_cms, :backups, :last_good, :synced]`
    event (`%{count: 1}`; metadata `dir`, `db`, `media`). A failed run emits
    the existing `[:kiln_cms, :backups, :last_good, :failed]` and logs
    "Backup last-good marker not updated: …", writes and removes no marker, and
    is not retried; the next slot runs the same sync.
  - **Rolling back** to 1.9.x is safe: there is no migration. The job stops,
    and on a cron-only deployment the markers it wrote stay until deleted by
    hand, keeping those units past `BACKUP_KEEP_DAYS`.

  Developers: `KilnCMS.Backups.Chain.sync_last_good/2` runs one sync and
  returns `{:ok, %{db: stamp | nil, media: stamp | nil}}`, `:busy` or
  `{:error, reason}`, never raising. `KilnCMS.Backups.Retention.sync_last_good/2`
  takes a new `import: false` option for a caller that already ran the
  importer. See [The last-good marker](../backups.md#the-last-good-marker).
  (#2554)

<a id="resume-behind-queued-resume-already-fixed"></a>

- **The 1.9.0 known issue "Resume on a failed backup says it is queued but never runs" was already fixed in 1.9.0.**
  1.9.0 listed it as open, but #2688 in that release made a Resume asked for
  while a backup runs and another run's resume is queued be refused with
  *A backup is running and a resume of `<stamp>` is queued after it, so this
  resume was not queued. Try again once the queue clears.* It names the
  queued run, and the queue is left as it was. Once the queued resume starts,
  the refused one can be asked for again. Nothing changes on upgrade; a test
  now pins the whole sequence. (#2671)


<a id="release-eval-read-through"></a>

- **`bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'` runs again: release tasks under `eval` read through the content cache instead of crashing.**
  1.9's upgrade note asks operators to run `reserved_paths/0` in a release,
  and the documented `eval` form raised `ArgumentError` (no
  `:cachex_overseer_table`). `eval` starts only the repo
  (`Ecto.Migrator.with_repo/2`), and the audit's slug lookup reads through
  `KilnCMS.Cache`. Every task's `load_app` now turns the cache off when the
  app is not serving (`read_through_unless_serving/1`), so any `eval` task
  reads the database directly. Called over `rpc` on a running node, the live
  cache is untouched. Found on Verscienta's production upgrade to 1.9.2.
