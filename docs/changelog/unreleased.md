# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="reserved-route-slugs-upgrade"></a>

- **List the records a newly reserved route already shadowed (#2898).** Run `mix kiln.reserved_paths`, or in a release `bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'`. It lists every page whose slug, and every record whose path alias starts with, one of `developers`, `ready`, `setup`, `sign-in`, `sign-out`, `actor`, `ap`, `mcp`, `password-reset`, or the first segment of an installed plugin's public route. Those URLs were never served: the built-in route answered first. Nothing is renamed for you; give each a new slug or alias in the editor, and add a redirect if the old URL was ever linked. The records still read and save as before; only a change to the slug or alias is checked. No migration; the command is read-only.

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

<a id="reserved-route-slugs"></a>

- **A slug that a built-in route already answers is refused (#2898).** This was a 1.13.0 known issue. `KilnCMS.CMS.ContentTypes.reserved_path_segments/0` is the list the slug, path-alias and content-type validations check, and it had fallen behind the router: `GET /developers`, `/ready`, `/setup`, `/sign-in`, `/sign-out`, `/actor`, `/ap/...`, `/mcp` and `/password-reset/:token` are all declared ahead of the `/:slug` catch-all. A page slugged `developers` saved without error, and `/developers` kept serving the developer page.
  - **What changes.** Those segments are reserved. A page slug, a path alias's first segment, or a dynamic content type's path segment equal to one is refused with the existing reserved-slug error. A title-derived or regenerated slug steps around them (`developers-2`). Installed plugins' public and plug routes are declared ahead of `/:slug` too, so their first segments are reserved as well.
  - **Kept in step.** `KilnCMSWeb.ReservedRouteSegmentsTest` reads the compiled route table and fails when a GET route ahead of `/:slug` has an unreserved first segment. Names with a dot (`sitemap.xml`, `llms.txt`) are skipped: no slug or alias can contain one. `forms` and `newsletter` stay free, because every route under them is three segments deep and answers neither `/forms` nor `/forms/<slug>`.
  - **Unchanged.** Post and entry slugs live under `/blog/` or their type's segment, which no such route reaches, so `developers` is still a valid post slug. A dynamic type that already used a newly reserved segment can still be edited: its segment is checked only when it changes.
  - **No migration; rolling the pin back is safe.** Existing records are not changed; see the upgrade note for listing them.
