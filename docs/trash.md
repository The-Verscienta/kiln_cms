# Trash and restore

Deleting a page, post or entry in Kiln moves it to the **trash**: a soft
delete that takes it out of the content list, the API and the live site, but
keeps the row. An admin can bring it back from the Trash page until the
nightly purge removes it for good, 30 days after it was trashed by default.

Only an **admin** can move content to the trash, restore it or delete it
permanently. The document's state doesn't matter: a draft, a page in review
and a live page are trashed the same way. Editors and viewers are not offered
any of the controls below, and a request that bypasses the screen is refused
by the same policy.

## Move a document to the trash

There are three places to do it. All three run the same soft delete.

### From the content list

1. Open the content list (`/editor`) and find the document.
2. Click the row's **⋯** button (*More actions*, shown on hover or focus).
   The row menu opens.
3. Click **Move to trash**, the last item, below a divider and in red.
4. The browser asks to confirm: *Move “Title” to trash? Admins can restore it
   from Trash for 30 days.* For a published document the prompt adds that it
   comes off the live site now, and that restoring it puts it back on the
   site. Click **OK**.
5. The row leaves the list and the flash reads *Moved “Title” to trash.* If the
   row was ticked for a bulk action, it drops out of the selection; the rest of
   the selection stays.

### From the editor

1. Open the document in the editor.
2. In the inspector rail, choose the **Settings** tab and scroll to the
   **Trash** section at the end. Its note says what trashing this document
   will do.
3. Click **Move to trash** and confirm the same prompt as above.
4. Kiln saves any edit still waiting for autosave first, so the copy in the
   trash is the one you were looking at. It then trashes the document and
   takes you back to the content list with *Moved “Title” to trash.* If that
   save fails, nothing is trashed and you stay in the editor (see below).

The editor only saves what autosave would have saved. On a published
document, Settings-tab changes wait for the **Save** button, and those are not
saved first, the same as for Publish changes, Unpublish and the other workflow
buttons. Save them before trashing if you want them back on restore.

### Several at once

1. In the content list, tick the rows to remove. The bulk bar appears in the
   list header.
2. Click **Delete**. A confirmation strip appears: *Move N selected item(s) to
   trash? Admins can restore them from Trash for 30 days.*
3. Click **Delete** in the strip. The flash says how many moved and how many
   were skipped.

## Restore a document

1. Open **Trash** (`/editor/trash`, listed under *Organization* in the
   console). Trashed documents of every content type on this site are listed,
   most recently trashed first.
2. Click **Restore** on the row. The flash reads *Restored.*

The document comes back in the state it was trashed in. A published document
goes straight back on the live site: its rendered pages are rebuilt and the
search index picks it up again. A draft comes back as a draft.

It also comes back with every field conversion (`mix kiln.fields.convert`)
and media snapshot refresh (`mix kiln.media.resnapshot`) an operator ran
while it was in the trash: both tasks process trashed documents too
(#2533), so a field deleted in the meantime does not take the document's
values with it. Two other background passes still skip the trash: the
daily refresh of date-based computed fields, which the next save or daily
run catches up, and `mix kiln.occurrences.backfill`.

A trashed draft is never published by its schedule. If its **Scheduled
publish at** time passed while it was in the trash, restoring it publishes it
on the scheduler's next run, within about a minute. A trashed document can't
be edited, so the date can't be cleared beforehand: if it should not go live,
unpublish it once it has.

## Delete permanently

On the Trash page, **Delete permanently** removes one document and **Empty
trash** removes everything in the list; both ask first and cannot be undone.
Without either, a nightly job (03:00 UTC) purges anything that has been in the
trash longer than the retention period. A document that a reference field set
to keep linked records from being deleted (`on_target_delete: :restrict`)
still points at is never purged; it stays in the trash until the link is
removed ([extending-content.md](extending-content.md)).

Only a document that is still in the trash can be deleted permanently. If
another admin restores it after your Trash page loaded, your **Delete
permanently** is refused and the document stays on the site, rather than
being hard-deleted while live. **Empty trash** reads the trash afresh as it
goes, so a document restored or deleted by someone else while it runs is not
counted as deleted or as skipped.

The media library's trash (**Media**, then **Trash**, admins only) works the
same way: **Delete permanently** removes a file that is still in the trash,
along with its stored original, variants and cached transforms. If someone
restored the file after your list loaded, the file and everything stored for
it stay, including a file that was trashed while its upload was still being
processed. **Restore** there likewise acts only on a file still in the
trash. Either way, a refused click says what happened (see
[What can go wrong](#what-can-go-wrong)) and the trash list reloads.

## What can go wrong

- *You don't have permission to do that.* The trash was asked for by someone
  the policy refuses, usually because their role changed after the page
  loaded. Nothing was written.
- *Couldn't move that to trash. It may already be gone.* (content list) The
  document was trashed or deleted by someone else since the list loaded, or
  belongs to another site.
- *Couldn't save your latest changes — fix the errors below, then try again.*
  (editor) An edit waiting for autosave failed validation, so the trash did not
  run. Fix the field it points to, or undo the edit, and try again.
- *Save your changes before changing this content's state.* (editor) The
  document has edits that autosave doesn't cover: it is in review or archived,
  which don't autosave, or the editor is showing a save conflict. Save the
  edits (or reload after a conflict) and try again.
- *Someone else already moved this to the trash or deleted it.* (editor) You
  clicked **Move to trash** on a document another admin had already trashed
  or deleted since you opened it. Nothing more was done, and the editor takes
  you back to the content list.
- *This content was moved to the trash or deleted.* (any editor) Someone
  trashed or permanently deleted the document while you had it open. See
  [If someone is still editing it](#if-someone-is-still-editing-it).
- *Someone else already restored that item.* (Trash page) You clicked
  **Restore** or **Delete permanently** on a document another admin restored
  after your Trash page loaded. Nothing more was done: a second restore would
  rebuild its pages and send `restored` twice, and a permanent delete would
  remove a live document. The list reloads without the row, and the
  document is back in the content list.
- *That item is no longer in the trash — someone permanently deleted it.*
  (Trash page) Another admin, or the nightly purge, deleted the document for
  good after your Trash page loaded. The list reloads without the row.
- *Couldn't restore that item.* or *Couldn't delete that item.* (Trash page)
  The action was refused for another reason, and the row stays in the list.
  Usually your role changed after the page loaded. For a restore, another
  document may now hold a value this one has in a field set to be unique.
  Delete permanently on a document that a "Don't allow it" reference field
  still links to says which field instead (see
  [Delete permanently](#delete-permanently)).
- *Someone else already restored that item.* (Media, Trash view) You
  clicked **Restore** or **Delete permanently** on a file another admin
  restored after the trash list loaded. Nothing more was done: the file is
  back in the library with all its stored files. The trash list reloads
  without the row.
- *That item is no longer in the trash — someone permanently deleted it.*
  (Media, Trash view) You clicked **Restore** or **Delete permanently** on a
  file another admin deleted for good after the trash list loaded. The trash
  list reloads without the row.
- *You don't have permission to restore media.* or *You don't have
  permission to delete media.* (Media, Trash view) The policy refused you,
  usually because you are no longer an admin of the site. Nothing was
  written, and the row stays in the list.
- *Couldn't restore that item.* or *Couldn't delete that item.* (Media,
  Trash view) The action failed for another reason. Nothing was written, and
  the row stays in the list.

## If someone is still editing it

Trashing a document does not close it in other people's editors, but nothing
they do afterwards can write into it (#2332). This holds for the content
editor, the in-context editor, the Presentation console, the API, MCP and
background jobs. A live document trashed under an open editor stays off the
site: **Publish changes** cannot put it back.

The other editor finds out the next time it tries to write: an autosave after
they type, **Save**, a workflow button such as **Publish changes**, or
**Reload latest** on a save conflict. Until then their screen looks as it did.
When it happens:

1. The flash reads *This content was moved to the trash or deleted.* and a
   banner says *This content was moved to the trash or deleted, so your
   changes can't be saved. Copy anything you need before leaving.*
2. The text they typed stays on screen. Autosave stops and **Save** stays
   disabled. The banner offers **Back to content** (the content list) instead
   of **Reload latest**, since there is no saved version to reload.
3. They copy what they need and click **Back to content**.

To get the document back, an admin restores it from Trash (see
[Restore a document](#restore-a-document)). The edits made after the trash
were never saved, so paste them in again after the restore.

## For operators

- The retention period is `config :kiln_cms, :trash, retention_days: 30`,
  read at compile time: change it in `config/config.exs` and rebuild. The
  prompts above show the configured number, except the bulk prompt, which
  always says 30 days.
- Trashing fires the `<type>.deleted` webhook with a tombstone payload, and
  restoring fires `<type>.restored` (see [webhooks.md](webhooks.md)). Between
  the two, the document sends nothing: no `updated`, `unpublished` or
  `archived` from an editor or job still holding it, no second `deleted` and
  no second `restored`.
- No migration or environment variable is involved.

## For developers

- `KilnCMS.CMS.ContentTypes.can_destroy?/4` asks the destroy policy for one
  record, through the type's generated `can_destroy_<type>?` helper
  (`can_destroy_entry?` for a dynamic type). Pass `tenant:` in the options.
  Use it to decide whether to draw a trash control, and check again in the
  handler that runs the write.

  ```elixir
  ContentTypes.can_destroy?(:page, page, current_user, tenant: org)
  #=> true for an admin of `org`, false for an editor
  ```

- `KilnCMSWeb.ContentTrash` holds the write (`trash/4`, a thin wrapper over
  `ContentTypes.destroy/3`) and the copy both screens use: the confirm prompt,
  the Settings-tab note, the flashes and `retention_days/0`.
- Over the API, the same soft delete is `DELETE` on the record
  ([json-api.md](json-api.md)).
- A trashed row takes no update. `KilnCMS.CMS.Changes.RefuseTrashed` is
  registered `on: [:update]` in the `changes` block of every resource built
  with `use KilnCMS.CMS.Content`, so it covers every update action, including
  ones an overlay adds. It filters the write on the row
  (`is_nil(archived_at)`), not on the struct the caller holds, so a struct
  loaded before the trash is refused too. A refused write raises
  `Ash.Error.Changes.StaleRecord`, and nothing after it runs: no artifacts
  fired, no webhook, no job enqueued.
- Four update actions are exempt, listed by
  `KilnCMS.CMS.Changes.RefuseTrashed.exempt_actions/0`:
  - `:restore`, which instead requires the row to still be trashed (a second
    restore is refused);
  - `:clear_reference_target`, which a purge uses to clear the purged record
    out of every referrer, trashed ones included, without re-firing or
    announcing a trashed referrer;
  - `:convert_custom_field` and `:resnapshot_media`, the writes of
    `KilnCMS.CMS.FieldConversion` and `KilnCMS.Media.Resnapshot` (#2533).
    Both tasks read the live rows and then the trashed ones
    (`ContentTypes.list_trashed!/2`), so a contract step reaches every row.
    They fire artifacts only when the row the `UPDATE` returned is out of
    the trash (`KilnCMS.CMS.Changes.FireArtifacts` with
    `skip_trashed: true`), judged on that row rather than the struct read
    earlier, because a trash or restore in between bumps no
    `lock_version`.

  `:destroy` (the trash itself) also refuses a row that is already trashed.
  An overlay action that must write a trashed row has no opt-out.
- `:purge` (the hard delete) takes only a row that is still trashed (#2531).
  It filters the delete on the row (`not is_nil(archived_at)`), so a struct
  loaded while the record was in the trash is refused once someone restores
  it. The refusal is an `Ash.Error.Invalid` holding an
  `Ash.Error.Changes.StaleRecord`, the same as for a row that is already
  gone, and the purge's hooks roll back with it: no chunk embeddings or
  reference edges are touched. Code that hard-deletes a live record (a test,
  an overlay's cleanup) must trash it first:

  ```elixir
  :ok = CMS.destroy_page!(page, actor: admin)
  :ok = CMS.purge_page!(page, actor: admin)
  ```

  `KilnCMS.CMS.MediaItem`'s `:purge` (`CMS.purge_media_item`) takes only a
  trashed item too, quarantined or not (#2610). The media pipeline's purge of
  an upload it refused or that never finished processing, which is never
  trashed, is a separate action, `:purge_quarantined`
  (`CMS.purge_quarantined_media_item`). It takes only a row that is still
  quarantined, and only `KilnCMS.Media.system/0` may run it: every person,
  admins included, is refused (`Ash.Error.Forbidden`), and the system actor
  may not run `:purge`. A caller that deletes stored files should do so only
  after the purge returns `:ok`, as the media library does.
- `KilnCMS.CMS.MediaItem`'s `:restore` (`CMS.restore_media_item`) takes only
  a row that is still trashed (#2611), like content's. A struct loaded while
  the item was in the trash gets the same `StaleRecord` once someone has
  restored or purged it, instead of a restore that "succeeds" on a live item.
  The media trash tells the two apart with one ordinary read by id
  (`CMS.get_media_item`): found means restored, not found means deleted.
- `KilnCMS.CMS.ContentTypes.can_restore?/4` and
  `KilnCMS.CMS.ContentTypes.can_purge?/4` ask the `:restore` and `:purge`
  policies for one record, like `can_destroy?/4` above. The Trash page asks
  them before it re-reads the row, so a refused actor gets the generic
  message rather than one that says the row is gone.
- The API answers for a trashed id did not change: JSON:API, GraphQL and MCP
  read the record first, find nothing and answer not-found. Only a write that
  lands between that read and someone else's trash is now refused instead of
  written.
