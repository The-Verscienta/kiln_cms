# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

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

## Fixed

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
