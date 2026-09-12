# Markdown: paste, import, and the API

Kiln stores content as typed blocks whose prose is Portable Text — not as
Markdown. But a lot of writing starts life as Markdown: a README, a note, a
draft from a chat assistant, a docs folder. Kiln converts it on the way in, so
it lands as real headings, lists, tables and image blocks instead of literal
`#` and `*` characters.

One converter, `KilnCMS.Markdown`, does this everywhere — the editor's paste
and import, and the write API's `body_markdown` argument — so the same text
always produces the same blocks.

## Pasting Markdown into a text block

Paste Markdown into a rich-text block and it converts as it lands. A small
notice appears under the pasted text:

> Pasted as Markdown. **Undo** · **Paste as plain text** · ✕

- **Undo** takes the paste back out, leaving the block as it was.
- **Paste as plain text** swaps the conversion for the literal text you
  copied, one paragraph per line.

The notice goes away after a few seconds, or as soon as you keep typing.
**⌘Z** undoes the paste as usual.

The editor only converts text that *reads* as Markdown: a heading line
(`## Title`), a fenced code block, a table's `|---|` rule, two or more list or
quote lines, or an inline link, `**bold**` run or `` `code` `` span. Ordinary
prose with a stray asterisk pastes as prose.

It never converts when:

- **You paste as plain text** (**⌘⇧V** / **Ctrl+Shift+V**).
- **The caret is in a code block**, where `#` and `*` are content.
- **The clipboard carries formatted HTML**, for example a copy from a web page
  or a word processor. That pastes with its own formatting, as before. The
  exception is a copy from VS Code (and editors built on it): it puts
  syntax-coloured HTML on the clipboard beside the plain text, and the plain
  text is what you meant.

A text block holds prose only. An image in pasted Markdown arrives as a link
to the picture, labelled with its alt text. To get a real image block, use
**Import Markdown** (below) or add an image block.

## Dropping a `.md` file on a text block

Drag a `.md` (or `.markdown`) file onto a rich-text block and its contents
convert into that block at the drop point, the same way a paste does. The
same notice appears, with the same Undo.

## Importing a `.md` file

**Import Markdown**, beside the *Blocks* heading, reads a Markdown file into
the document you are editing. Nothing changes until you confirm. First a
dialog shows:

- **how many blocks** the file converts to;
- the **title**, **slug** and **excerpt** the file supplies, each with a
  checkbox, so you can keep the ones you already have;
- if the document already has blocks, a choice between **Replace existing
  blocks** and **Add after existing blocks**.

The import changes the editor, not the stored record. It is saved like any
other edit, by autosave on a draft or by **Save**.

Where the metadata comes from:

- **Title.** The front matter's `title`, or else a leading `# H1`, meaning the
  very first thing in the file. A heading further down is a section, not the
  document's name. A leading H1 that becomes the title, or that repeats the
  front-matter title, is removed from the body, so it isn't printed twice.
- **Slug.** The front matter's `slug`. If there isn't one, a new title
  re-derives the slug the way typing a title does, unless you have pinned the
  slug yourself.
- **Excerpt.** The front matter's `excerpt`, or its `description`. It is only
  offered on content types that have an excerpt.

Front matter is the usual block of `key: value` lines between `---` fences at
the very top of the file. Keys other than those three are ignored, and front
matter is never imported as text.

Unlike a paste, an import keeps images: a standalone image becomes an **image
block** (its alt text and its `"title"` as the caption), and a YouTube or Vimeo
link on a line of its own becomes an **embed block**. Imported images still
point at their original URLs. Pick them from the media library afterwards if
the file came from somewhere you don't control.

The limit is 1 MB per file. Import Markdown needs write access to the
document, the same as every other editor control.

## What converts

| Markdown | Becomes |
|---|---|
| `#` … `######` headings (and underlined setext headings) | Headings, same level |
| `**bold**`, `*italic*`, `~~strike~~`, `` `code` `` | The same marks |
| `[text](url)` and bare `https://…` links | Links (see below for which URLs are kept) |
| `-`/`*`/`+` and `1.` lists, nested | Bullet and numbered lists, nesting kept |
| GFM tables | Tables, with the header row |
| Fenced code (` ```elixir `) and indented code | Code blocks, language kept |
| `>` quotes | Blockquotes |
| `---` / `***` | Dividers |
| `![alt](url "caption")` on its own line | An image block (import and API); a link (paste) |
| A YouTube or Vimeo URL on its own line | An embed block (import and API) |
| `&copy;`, `&#8212;` … | The characters they name |

Some things don't carry across. GFM task-list checkboxes (`- [ ]`) stay as
text, footnotes aren't interpreted, and table column alignment is dropped,
because stored rich text has nowhere to keep it.

## What is removed

Markdown can carry raw HTML, and its link syntax accepts any URL. Nothing in
it is trusted:

- **Raw HTML** goes through the same allowlist stored rich text is held to. A
  `<b>` or `<br>` survives; event-handler attributes, `<iframe>`s and anything
  outside the list don't. `<script>` and `<style>` are dropped along with
  their contents.
- **A link** keeps its URL only if it is `http(s)://`, `mailto:`, a
  same-site `/path` or a `#fragment`, the same rule as the editor's link
  dialog. Otherwise the words stay and the link goes: `javascript:` URLs
  become plain text.
- **An image** keeps its URL only if it is `http(s)://` or a same-site path.
  Otherwise only its alt text remains.

## Writing Markdown through the API

The content write actions (`create`/`update` on pages, posts and entries) take
the body as Markdown in a **`body_markdown`** argument, as an alternative to
`block_tree`. It is available over JSON:API, GraphQL and the MCP authoring
tools:

```http
POST /api/json/posts
Content-Type: application/vnd.api+json
Authorization: Bearer <read-write key>

{
  "data": {
    "type": "post",
    "attributes": {
      "title": "Release notes",
      "body_markdown": "## What's new\n\n- Faster search\n- **Markdown** import"
    }
  }
}
```

- **Send one or the other.** Sending both `body_markdown` and `block_tree` is
  refused with a 400. On an update, omit both to leave the body untouched.
  Empty Markdown (`""`) clears the body, like `[]` does.
- **The whole body is replaced.** The blocks it produces carry no `_id`s, so a
  `body_markdown` update replaces the body wholesale, the same as a
  `block_tree` sent without ids (see
  [Writing body content](json-api.md#writing-body-content-the-block_tree-attribute)).
- **The body only.** Front matter is dropped and nothing else is read from
  the Markdown. Title, slug and excerpt are their own attributes.
- **Grants and limits.** It needs the same `blocks` field grant as
  `block_tree`, and the limit is 1 MB.

## For developers

`KilnCMS.Markdown` is the public converter. Reuse it rather than adding a
second one, for example in a script that publishes a folder of `.md` files:

- `KilnCMS.Markdown.parse_document/2` — a whole document:
  `%{title:, slug:, excerpt:, front_matter:, blocks:}`, following the
  title/H1 rules above.
- `KilnCMS.Markdown.to_blocks/2` — the body as `block_tree`-ready block maps.
  Pass `:media_resolver` to point images at media-library items you sideloaded.
- `KilnCMS.Markdown.to_html/2` — sanitized HTML.
- `KilnCMS.Markdown.to_tiptap/1` — prose-only TipTap JSON, the paste shape.

The parser is `earmark_parser`, the pure-Elixir parser `ex_doc` uses, so it
adds no native code to the release. Its AST is rendered by `KilnCMS.Markdown`
itself and then passed through `KilnCMS.Blocks.Html`, the adapter the
WordPress and portability importers use, so a Markdown table and an imported
HTML table become the same Portable Text.
