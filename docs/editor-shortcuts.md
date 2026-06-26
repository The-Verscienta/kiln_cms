# Rich-text editor: keyboard shortcuts & slash commands

The content editor's `rich_text` blocks use [TipTap](https://tiptap.dev)
(ProseMirror) with the StarterKit extensions, wired up in
[`assets/js/rich_text.js`](../assets/js/rich_text.js). This is the reference for
the formatting shortcuts and the slash-command menu.

Everything the editor can produce is constrained server-side by
[`KilnCMS.HTMLSanitizer.RichText`](../lib/kiln_cms/html_sanitizer/rich_text.ex) —
the toolbar, shortcuts, and slash commands all emit only tags on that allowlist.

## Keyboard shortcuts

`⌘` is the Command key on macOS; use `Ctrl` on Windows/Linux. `⇧` is Shift,
`⌥` is Option/Alt.

| Action | macOS | Windows / Linux |
| --- | --- | --- |
| Bold | `⌘B` | `Ctrl B` |
| Italic | `⌘I` | `Ctrl I` |
| Strikethrough | `⌘⇧S` | `Ctrl ⇧ S` |
| Inline code | `⌘E` | `Ctrl E` |
| Heading 1 | `⌘⌥1` | `Ctrl Alt 1` |
| Heading 2 | `⌘⌥2` | `Ctrl Alt 2` |
| Heading 3 | `⌘⌥3` | `Ctrl Alt 3` |
| Paragraph (clear heading) | `⌘⌥0` | `Ctrl Alt 0` |
| Bullet list | `⌘⇧8` | `Ctrl ⇧ 8` |
| Numbered list | `⌘⇧7` | `Ctrl ⇧ 7` |
| Blockquote | `⌘⇧B` | `Ctrl ⇧ B` |
| Code block | `⌘⌥C` | `Ctrl Alt C` |
| Hard line break | `⇧↵` | `⇧ ↵` |
| Undo | `⌘Z` | `Ctrl Z` |
| Redo | `⌘⇧Z` | `Ctrl ⇧ Z` |

These are the StarterKit defaults; the toolbar above each editor exposes the
same commands as buttons and highlights the ones active at the cursor.

## Slash commands

Type `/` at the **start of an empty paragraph** to open the command menu. Keep
typing to filter (e.g. `/h2`, `/quote`, `/code`), then:

- `↑` / `↓` — move the selection
- `↵` or `Tab` — apply the highlighted command
- `Esc` — dismiss the menu

Selecting a command removes the typed `/query` and transforms the current block.

| Command | Transforms the block into | Matches (keywords) |
| --- | --- | --- |
| Text | Plain paragraph | paragraph, text, body |
| Heading 1 | `<h1>` | h1, title, big |
| Heading 2 | `<h2>` | h2, subtitle |
| Heading 3 | `<h3>` | h3 |
| Bullet list | `<ul>` | ul, unordered, bullet |
| Numbered list | `<ol>` | ol, ordered, numbered |
| Quote | `<blockquote>` | blockquote, citation |
| Code block | `<pre><code>` | code, pre, snippet |
| Divider | `<hr>` | hr, horizontal, rule, separator, line |

The slash menu only triggers when `/` is the first character of a paragraph, so
typing a slash mid-sentence (e.g. "and/or") never opens it.

## Extending

To add a command, edit the `TOOLBAR` and/or `SLASH_COMMANDS` arrays in
[`assets/js/rich_text.js`](../assets/js/rich_text.js). If a new command can emit
a tag that isn't already allowed, add that tag to
[`KilnCMS.HTMLSanitizer.RichText`](../lib/kiln_cms/html_sanitizer/rich_text.ex)
and cover it in
[`test/kiln_cms/html_sanitizer_test.exs`](../test/kiln_cms/html_sanitizer_test.exs) —
otherwise the server will strip it on save.
