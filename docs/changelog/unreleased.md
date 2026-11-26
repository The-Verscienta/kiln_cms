# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Fixed

<a id="publish-shows-unpublish-date"></a>

- **Publishing a draft without opening the editor shows its scheduled unpublish date (#2892).** This was a 1.13.0 known issue. A draft can carry a takedown date, **Scheduled unpublish at** in the editor (`unpublish_at`, with `expiry_action` saying what happens then), and [ADR 0051](../decisions/0051-taking-content-down-needs-the-same-approval-as-putting-it-up.md) leaves it ungated on a draft because whoever publishes the draft approves the date with the page. Only the editor showed it. An admin who approved a draft from the content list, the bulk bar or a release never saw the date, and the page came down at it.
  - **The content list.** A draft or in-review row with a date shows it beside its **Publish** or **Approve** button, as published rows already did: **Unpublishes**, **Archives** or **Flagged expired**, by the record's expiry action, then the time.
  - **The bulk bar.** The **Publish** confirm says how many of the selected drafts have a date ("2 of these have a scheduled unpublish date") and lists them soonest first, up to ten. Selected rows off the current page or filter are counted too.
  - **Releases.** Each pending publish item for a draft with a date shows it under the title, and the panel with **Schedule** and **Publish now** totals them.
  - **Unchanged.** Publishing works as before; nothing is asked or refused that wasn't. No migration; rolling the pin back is safe.

<a id="markdown-inline-image"></a>

- **An image that is not alone on its line of Markdown is kept (#2771).** This was a 1.13.0 known issue. `KilnCMS.Markdown.to_blocks/2` and `parse_document/2` rendered every image as `<img>` and left it to the HTML adapter, which lifts an image into an image block only when it is the whole of a top-level paragraph. Anywhere else, mid-sentence (`Our logo ![Acme](https://x.test/a.png) is blue`), two to a line, or in a list item, quote or table cell, the adapter had no inline node for it and dropped the picture and its alt text with no error. The stored text read "Our logo is blue".
  - **What changes.** Such an image stays where it was, as a link to the picture labelled with its alt text (or with its URL when it has no alt text). That is what pasting Markdown into a rich-text block already did. An image inside a link (`[![CI](badge.svg)](https://ci.example)`) becomes the link's text, and the outer link stays.
  - **Where.** Every path through the converter: the editor's Markdown view and `.md` import, `body_markdown` writes over JSON:API, GraphQL and MCP, and anything else that calls `KilnCMS.Markdown`.
  - **Unchanged.** An image alone in its paragraph, linked or not, still becomes an `image` block with its alt text and title as caption. Content stored before the fix is not repaired: the dropped image was never saved, so import that Markdown again.
  - **No migration; rolling the pin back is safe.** An older release drops such images again on the next Markdown write.

<a id="duplicate-rich-text-body"></a>

- **A duplicated text block keeps its text when it is saved (#2778).** This was a known issue in 1.13.0. A rich-text block's prose is held by the editor's server session, keyed by the block's id, and added back into the form on every keystroke, save and autosave; the form itself carries only an empty HTML field for it. Duplicating a block gave the copy a new id but never registered its prose under that id, so the first keystroke anywhere in the form, or the save itself, stored the copy empty while its editor still showed the text.
  - **What happens now.** The copy's prose is registered under its own id the moment it is made, taken from what the original holds at that point, typed but unsaved text included. Save, autosave and *Publish changes* store it, and editing the original afterwards leaves the copy's text alone.
  - **Other copy paths checked.** Duplicating a columns block already copied its nested blocks' text, which lives in the columns block's own state, and keeps doing so. Duplicating a whole document copies the saved record on the server and never read the editor's state. Copy and paste between blocks goes through the editor's normal typing path.
  - **No migration; rolling the pin back is safe.** A copy saved empty on an earlier release stays empty; its original, or a version in the document's history, still holds the text to copy back.

