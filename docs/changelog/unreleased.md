# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="image-picker-upload"></a>

- **The editor's image picker has its own Upload button and drop zone.**
  The picker could only choose an image already in the media library, or
  import one from Unsplash. To use a new photo as a featured image, an editor
  had to leave the document for **Media**, upload it, come back, open the
  picker again and find it. The Library tab now starts with an upload area:
  click it to choose a file, or drop one on it. The finished upload is used
  the same way a library pick is. For the featured image, the social image,
  an image block or a media field, it is set and the picker closes. For a
  gallery, the input takes several files, each joins the selection in upload
  order, and the picker stays open until **Add to gallery**. Every upload is
  also added to the media library. Uploads use the same pipeline as the
  media library's own (`Ingest`: size cap, metadata strip, derivatives), with
  the same image types and size limit as pasting into a text block. The file
  is checked as an image on the server before anything is stored, so a PDF
  renamed `.png` is refused rather than becoming a featured image. Closing
  the picker cancels an upload that hasn't finished. Only editors who can
  edit the document see the upload area. The Branding page's image drawer is
  unchanged. (#2791)

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

<a id="featured-image-older-than-picker-window"></a>

- **The editor's Featured image field shows an image older than the org's 500 most recent uploads, with its Remove link.**
  The Settings tab looked the attached image up only in the media picker's
  window (the 500 newest images), so on a large library an older featured
  image showed **None selected**, with no thumbnail and no **Remove** link,
  though the record, the API and the site all had it. Editors could take the
  record for imageless and pick a duplicate, and could not clear the image
  without first choosing another. The field now resolves the image the way
  the editor's preview already did: the window first, then the database.
  Saving never lost the image; only the display was wrong.
