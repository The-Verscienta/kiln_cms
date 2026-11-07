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

## Delete permanently

On the Trash page, **Delete permanently** removes one document and **Empty
trash** removes everything in the list; both ask first and cannot be undone.
Without either, a nightly job (03:00 UTC) purges anything that has been in the
trash longer than the retention period. A document that a reference field set
to keep linked records from being deleted (`on_target_delete: :restrict`)
still points at is never purged; it stays in the trash until the link is
removed ([extending-content.md](extending-content.md)).

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

## Known limitation

Trashing a document does not stop a writer that still has it open. Another
editor session, the in-context editor, the API or MCP can keep saving into a
trashed row, and **Publish changes** in an editor still open on a live
document can publish it again. The fix is tracked in
[#2332](https://github.com/The-Verscienta/kiln_cms/issues/2332). Until then,
check that nobody else is editing a document before you trash it.

## For operators

- The retention period is `config :kiln_cms, :trash, retention_days: 30`,
  read at compile time: change it in `config/config.exs` and rebuild. The
  prompts above show the configured number, except the bulk prompt, which
  always says 30 days.
- Trashing fires the `<type>.deleted` webhook with a tombstone payload, and
  restoring fires `<type>.restored` (see [webhooks.md](webhooks.md)).
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
