# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Fixed

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


<a id="slack-missing-site-name"></a>

- **A Slack webhook message whose payload names no site names the endpoint's site (#2797).** `KilnCMS.Webhooks.SlackFormat` renders a Slack-format endpoint's body at send time from the ledger row's payload, and read the site from its `site_name`. A test ping queued by a 1.9 node while a rolling deploy to 1.10 was under way carries Kiln's ping payload (`message`, `endpoint_url`, `sent_at`) and no `site_name`, so the new node posted "KilnCMS webhook test for `-`". A security alert row without the key would have read "Security alert on `-`".
  - **What changes.** `KilnCMS.Webhooks.DeliveryWorker` fills in a missing or empty `site_name` from the endpoint's site (`KilnCMS.Branding.for_org/1`) before rendering a Slack body. If the renderer is still handed a ping without one, it says "KilnCMS webhook test" with no placeholder.
  - **Unchanged.** The job arguments are the same shape they were in 1.9, so no compatibility clause was needed; only the payload differed. The ledger row keeps the payload as it was queued, and Kiln-format endpoints are sent exactly what they were before.
  - **No migration; rolling the pin back is safe.** An older release renders such a row with `-` again.


<a id="console-small-defects-2"></a>

- **More small console fixes from the November bug sweep (#2786).**
  - **A row deleted behind the page.** **Edit** on `/editor/automation` read the rule with a raising call, so editing one another admin had just deleted crashed the page. It now says "That rule no longer exists." and refreshes the list, as does saving an edit of a rule deleted while the form was open. Deleting a rule closed whatever edit form was open, another rule's half-typed changes included; it now closes only that rule's. On `/editor/billing`, deleting the tier being edited left the form bound to it, so its next save could only fail; the form goes back to adding a tier.
  - **Analytics on a site other than the default.** The most-viewed list looked each content type up without the site, so every admin-defined type on any other site read "(unknown type: …)" with no link. It now shows the entry's title and links to it.
  - **Calendar.** A drag the server refused (into the past, or a move the editor may not make) left the chip on the day it was dropped: the re-read window rendered nothing new, so the browser got no patch. Every day's drop list now re-renders from what is saved. A `?type[a]=b` in the address crashed the page; a type filter that is not a plain value now shows every type.
  - **Custom fields.** Editing a field whose type has no default input (a color or email field, say) cleared the default it had been given through the API; it is kept while the type stays the same. A new sub-field of a group, or a new item type, took its siblings' count as its position, which after a delete is a position a sibling already has; it now goes after the last one. "A copy of another field" offered nothing for a Person field; it lists the site's other Person fields, and a private field copies only into a private one, as the save already required.
  - **Claim checking.** A save the site refused (a phrase over the length limit, say) reseeded the form from what was saved, so everything typed was lost. The form now keeps it beside the error.
  - **Taking over a field on a live document.** A takeover flushes the holder's queued autosave first, but only did so for drafts. A live document autosaves into its working copy, so the holder's edit stayed queued, the taker kept editing the text from when the page opened, and the next save met a conflict. The holder's edit is now saved to the working copy before the field moves, the taker gets the saved text, and the takeover dialog says nothing is lost.
  - **Not changed.** A `?to=9999-12-31` date filter on `/editor` was reported as a crash; it lists as expected.
  - **No migration; rolling the pin back is safe.**


<a id="fallback-mode-refire"></a>

- **Changing a custom field's localization to or from `:fallback` re-fires the type's locale variants (#2905).** A `:fallback` field that a variant leaves empty is filled from the next locale along the site's chain when the variant is fired, and the fired `:json` body names it under `inherited_fields`. Saving the chain at `/editor/locales` and publishing a variant re-fired the documents that inherit; changing the field's mode on the Fields screen re-fired nothing. A French page whose tagline was empty kept serving it empty, with no `inherited_fields`, after the field became `:fallback`, and kept serving the English tagline after it stopped being one, until that page was next published.
  - **What changes.** `KilnCMS.CMS.Changes.BustTypeRegistry` now re-fires the field's type when its `localization` changes to or from `:fallback`, and when a `:fallback` field is deleted. Only the type's published rows outside the default locale are queued (`KilnCMS.Firing.Sweep.sweep_type/3` with `only: :translations`): the default locale ends every chain, so it never inherits. A site with no translations queues nothing.
  - **Unchanged.** A switch between `:localized` and `:shared` re-fires nothing; a shared value is copied into the variants when the source publishes, as before. Creating a field as `:fallback` re-fires nothing either: no document holds a value for it yet.
  - **No migration; rolling the pin back is safe.** An artifact fired with the old answer on an earlier release is corrected by `mix kiln.refire_all`, or by publishing the variant.
