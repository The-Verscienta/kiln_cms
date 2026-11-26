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

<a id="plugin-typed-filters"></a>

- **A filter on a plugin field type with a numeric GraphQL kind compares numbers (#2855).** A `custom_filter`, `customWhere` or MCP `custom_filter` operand on a plugin `Kiln.FieldType` was always compared as the text sent. A type whose `graphql_kind/1` is `:int` stores a JSON number, so `eq` (`"42"` is not jsonb `42`) and `in` never matched, and `gt`/`lt` compared a string against numbers, which jsonb orders apart from them. Sorting already compared the stored jsonb, so it was right for numbers.
  - **What changes.** The operand is cast by the type's GraphQL kind, as KilnCMS's own field of that kind casts it: `:int` as an integer, `:float` as a float, `:boolean` as a boolean, `:date` as an ISO 8601 date. `custom_filter[score][gt]=9` finds a stored `10`, and a `customWhere` `int` condition on such a field matches what it names.
  - **Now refused.** An operand that is not of that kind (`custom_filter[score][gt]=ten`) is a `400` `invalid_argument`, and `contains`, `starts_with` and `ilike` on such a field are a `400`, as on a core `integer` field. A stored value of another JSON type never fails a read.
  - **Unchanged.** A type whose kind is `:string`, `:datetime` or `:json`, or that has no `graphql_kind/1`, still compares the text sent: a plugin's date-time spelling is its own. The console's list filters don't offer plugin fields, as before. See [extending-content.md](../extending-content.md#filters-on-a-plugin-field-type).
  - **No migration; rolling the pin back is safe.** An older release compares such operands as text again.
