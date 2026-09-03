// TipTap rich-text editor for `rich_text` blocks in the content editor.
//
// The editor's live TipTap JSON is mirrored into a hidden input bound to the
// block's `body` form field (converted to Portable Text by the server-side
// block cast), so it saves through the normal form submit. On top of
// the StarterKit defaults this module adds:
//
//   * an expanded toolbar with live active-state highlighting
//   * a slash-command menu ("/") that both transforms the current text and, in
//     the block editor, inserts a new Kiln block below (B3 — one "/" for both)
//   * links: the Link mark StarterKit v2 leaves out, plus the ⌘K popover that
//     authors them and one href gate mirroring the server's (#823)
//
// Every command here produces only tags already on the server-side allowlist
// (KilnCMS.HTMLSanitizer.RichText) — including the code-block language class,
// which the allowlist admits as `language-<tag>` (#503).
import {Editor, Extension} from "@tiptap/core"
import {Plugin, PluginKey} from "@tiptap/pm/state"
import StarterKit from "@tiptap/starter-kit"
import Link from "@tiptap/extension-link"
import Table from "@tiptap/extension-table"
import TableRow from "@tiptap/extension-table-row"
import TableHeader from "@tiptap/extension-table-header"
import TableCell from "@tiptap/extension-table-cell"

// Tables (#475): StarterKit doesn't include them, so every editor mount adds
// this set. Column resizing stays off in v1 — colwidths wouldn't survive the
// Portable Text round-trip, so offering the drag handle would lie to editors.
// Cells hold paragraphs only (not TipTap's default `block+`): Portable Text
// stores cells as flat lines, so allowing lists/code blocks in a cell would
// let editors author structure that flattens on save. Constraining the schema
// makes what you see in a cell exactly what gets stored (pasted block content
// coerces to paragraphs at parse time).
const cellSchema = {content: "paragraph+"}

const TABLE_EXTENSIONS = [
  Table.configure({resizable: false}),
  TableRow,
  TableHeader.extend(cellSchema),
  TableCell.extend(cellSchema),
]

// Mirror of `KilnCMS.HTMLSanitizer.safe_href/1`: returns the trimmed URL when
// the CMS will store it, `null` when it won't. Allowed are same-origin relative
// paths, in-page `#fragment`s, `http(s)://` and `mailto:` — everything else
// (`javascript:`, `data:`, `ftp:`, protocol-relative `//host`, its backslash
// twin `/\host` (browsers treat `\` as `/`), paths containing `..`) is
// rejected.
//
// This has to agree with the server (#823, #921). `PortableText.sanitize_def/1`
// blanks the href of any link mark it doesn't like, and a blanked href renders
// as plain text — so an href the editor accepts but the server rejects is a
// link the author watches vanish on the next reload. Rejecting it here instead
// says so while they can still fix it.
function safeHref(url) {
  if (typeof url !== "string") return null
  const trimmed = url.trim()
  if (!trimmed) return null

  // Fragment and relative first, exactly as the server orders it: `#section`
  // and `/blog/x` never reach the URL parser.
  if (trimmed.startsWith("#")) return trimmed

  if (
    trimmed.startsWith("/") &&
    !trimmed.startsWith("//") &&
    !trimmed.includes("\\") &&
    !trimmed.includes("..")
  ) {
    return trimmed
  }

  let parsed
  try {
    parsed = new URL(trimmed)
  } catch {
    return null
  }

  // The server's `javascript:` substring check, kept for the same reason: a
  // `mailto:` whose body smuggles one in.
  if (trimmed.toLowerCase().includes("javascript:")) return null

  const scheme = parsed.protocol.replace(/:$/, "")

  // `parsed.host` is not enough to decide an http(s) URL names a host (#833).
  // WHATWG parsing is lenient where `URI.parse/1` is literal, and it invents
  // an authority out of the path: `new URL("http:///path").host` is `"path"`,
  // and `http:example.com` becomes `http://example.com/` — both of which the
  // server refuses, so accepting them here puts the author back in the
  // vanishing-link bug this mirror exists to prevent. Require the authority to
  // be written out, with something other than a slash immediately after `//`.
  if (scheme === "http" || scheme === "https") {
    return /^https?:\/\/[^/\s]/i.test(trimmed) && parsed.host ? trimmed : null
  }

  if (scheme === "mailto") return trimmed
  return null
}

// Pasting a URL over a selection turns that selection into a link. This is our
// own handler rather than the Link extension's `linkOnPaste`, for two reasons:
// upstream applies the mark with a bare `setMark`, which skips the `href` gate
// entirely (it would happily make an `ftp://` link the server then blanks —
// the same silent loss as #823 itself), and it detects URLs with linkify,
// which doesn't consider `/refunds` a URL at all. In a CMS an internal path is
// the most common thing an author pastes.
const LinkOnPaste = Extension.create({
  name: "kilnLinkOnPaste",

  addProseMirrorPlugins() {
    const {editor} = this

    return [
      new Plugin({
        key: new PluginKey("kilnLinkOnPaste"),
        props: {
          handlePaste: (view, event) => {
            if (view.state.selection.empty) return false

            const text = ((event.clipboardData && event.clipboardData.getData("text/plain")) || "").trim()
            // A bare URL, not a sentence that happens to contain one — pasting
            // prose over a selection must stay an ordinary paste.
            if (!text || /\s/.test(text)) return false

            const href = safeHref(text)
            if (!href) return false

            // `setLink` (not `setMark`) so this path goes through the same
            // `isAllowedUri` gate as the toolbar and ⌘K.
            return editor.commands.setLink({href})
          },
        },
      }),
    ]
  },
})

// Links (#823). StarterKit v2 has no Link mark — it only moved into StarterKit
// in v3 — so before this every editor mount parsed the anchors out of the HTML
// it was seeded with, and the autosave persisted prose with the links gone.
//
// `autolink` stays OFF deliberately: it rewrites what the author typed, turning
// a bare "example.com" mentioned in passing into a live link nobody asked for.
// That is the same class of silent mutation as the bug being fixed, and it
// feeds `Kiln.Advisory.Checks.LinkText`'s `link_text_bare_url` warning with
// links the author never made. Pasting (above) is an explicit gesture over an
// explicit selection, so that one is on.
const LINK_EXTENSIONS = [
  Link.configure({
    // Clicking a link inside the editor should put the caret in it, not
    // navigate away from the page being edited.
    openOnClick: false,
    linkOnPaste: false,
    autolink: false,
    // Portable Text stores a link as an href and nothing else, so rendering
    // `target`/`rel` here would show authors attributes that don't survive the
    // save. Null clears the extension's defaults rather than adding to them.
    HTMLAttributes: {target: null, rel: null, class: null},
    // The extension consults this when parsing seeded HTML, when rendering,
    // and inside `setLink` — one gate covering every way a link can appear.
    isAllowedUri: url => safeHref(url) !== null,
  }),
  LinkOnPaste,
]

// Code-block language choices (#503). The value is the tag stored on the
// Portable Text block and delivered raw on the `:json` surface; the server
// highlights the ones Makeup has a lexer for (see KilnCMS.Highlight) and the
// rest fall back to a plain <pre> that still carries the language class for
// client-side highlighters. "" = untagged plain text.
const LANGUAGES = [
  ["", "Plain text"],
  ["elixir", "Elixir"],
  ["heex", "HEEx"],
  ["eex", "EEx"],
  ["erlang", "Erlang"],
  ["js", "JavaScript"],
  ["ts", "TypeScript"],
  ["html", "HTML"],
  ["css", "CSS"],
  ["json", "JSON"],
  ["bash", "Shell"],
  ["sql", "SQL"],
  ["python", "Python"],
  ["ruby", "Ruby"],
  ["go", "Go"],
  ["rust", "Rust"],
  ["yaml", "YAML"],
]

// Toolbar buttons. `active` (optional) lights the button when the mark/node is
// applied at the cursor; `run` receives a focused command chain. `prompt`
// entries open the hook's floating link editor instead — the href can't come
// from a command chain, it has to be typed.
const TOOLBAR = [
  {label: "B", title: "Bold (⌘B)", active: e => e.isActive("bold"), run: c => c.toggleBold()},
  {label: "I", title: "Italic (⌘I)", active: e => e.isActive("italic"), run: c => c.toggleItalic()},
  {label: "S", title: "Strikethrough (⌘⇧S)", active: e => e.isActive("strike"), run: c => c.toggleStrike()},
  {label: "</>", title: "Inline code (⌘E)", active: e => e.isActive("code"), run: c => c.toggleCode()},
  {label: "Link", title: "Link (⌘K)", active: e => e.isActive("link"), prompt: true},
  {label: "H1", title: "Heading 1 (⌘⌥1)", active: e => e.isActive("heading", {level: 1}), run: c => c.toggleHeading({level: 1})},
  {label: "H2", title: "Heading 2 (⌘⌥2)", active: e => e.isActive("heading", {level: 2}), run: c => c.toggleHeading({level: 2})},
  {label: "H3", title: "Heading 3 (⌘⌥3)", active: e => e.isActive("heading", {level: 3}), run: c => c.toggleHeading({level: 3})},
  {label: "• List", title: "Bullet list (⌘⇧8)", active: e => e.isActive("bulletList"), run: c => c.toggleBulletList()},
  {label: "1. List", title: "Numbered list (⌘⇧7)", active: e => e.isActive("orderedList"), run: c => c.toggleOrderedList()},
  {label: "❝", title: "Quote (⌘⇧B)", active: e => e.isActive("blockquote"), run: c => c.toggleBlockquote()},
  {label: "{ }", title: "Code block (⌘⌥C)", active: e => e.isActive("codeBlock"), run: c => c.toggleCodeBlock()},
  {label: "―", title: "Divider", run: c => c.setHorizontalRule()},
  {label: "↺", title: "Undo (⌘Z)", run: c => c.undo()},
  {label: "↻", title: "Redo (⌘⇧Z)", run: c => c.redo()},
]

// Slash-command menu entries. `keywords` widen what the typed query matches.
const SLASH_COMMANDS = [
  {label: "Text", hint: "Plain paragraph", keywords: "paragraph text body", run: c => c.setParagraph()},
  {label: "Heading 1", hint: "Large section heading", keywords: "h1 title big", run: c => c.setNode("heading", {level: 1})},
  {label: "Heading 2", hint: "Medium section heading", keywords: "h2 subtitle", run: c => c.setNode("heading", {level: 2})},
  {label: "Heading 3", hint: "Small section heading", keywords: "h3", run: c => c.setNode("heading", {level: 3})},
  {label: "Bullet list", hint: "Unordered list", keywords: "ul unordered bullet", run: c => c.toggleBulletList()},
  {label: "Numbered list", hint: "Ordered list", keywords: "ol ordered numbered", run: c => c.toggleOrderedList()},
  {label: "Quote", hint: "Blockquote", keywords: "blockquote citation", run: c => c.toggleBlockquote()},
  {label: "Code block", hint: "Preformatted code", keywords: "code pre snippet", run: c => c.toggleCodeBlock()},
  {label: "Divider", hint: "Horizontal rule", keywords: "hr horizontal rule separator line", run: c => c.setHorizontalRule()},
  {label: "Table", hint: "3×3 table with header row", keywords: "table grid rows columns cells", run: c => c.insertTable({rows: 3, cols: 3, withHeaderRow: true})},
]

// Row/column controls for the caret's table (#475). Shown only while the
// selection is inside a table — same show-on-context pattern as the code-block
// language select. Each entry is a plain TipTap chain command.
const TABLE_CONTROLS = [
  {label: "+Row", title: "Add row below", run: c => c.addRowAfter()},
  {label: "−Row", title: "Delete row", run: c => c.deleteRow()},
  {label: "+Col", title: "Add column right", run: c => c.addColumnAfter()},
  {label: "−Col", title: "Delete column", run: c => c.deleteColumn()},
  {label: "Hdr", title: "Toggle header row", run: c => c.toggleHeaderRow()},
  {label: "✕ Table", title: "Delete table", run: c => c.deleteTable()},
]

// Returns {el, sync}: a hidden button group appended to a toolbar, revealed
// while the caret is inside a table.
function tableControls(editor) {
  const group = document.createElement("span")
  group.setAttribute("role", "group")
  group.setAttribute("aria-label", "Table controls")
  group.className = "inline-flex gap-1"
  group.hidden = true

  TABLE_CONTROLS.forEach(item => {
    const b = document.createElement("button")
    b.type = "button"
    b.textContent = item.label
    b.title = item.title
    b.setAttribute("aria-label", item.title)
    b.className = "rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
    b.addEventListener("click", e => {
      e.preventDefault()
      item.run(editor.chain().focus()).run()
    })
    group.appendChild(b)
  })

  const sync = () => {
    group.hidden = !editor.isActive("table")
  }

  return {el: group, sync}
}

// Slash commands that insert a *new* Kiln block below the current one (B3). They
// cover block types prose can't represent; choosing one clears the "/query" and
// asks the server to add the block via the same anchored `add_block` path the
// inline "+" uses. Offered only where `onInsert` is wired (the block editor), not
// the in-context page editor, whose LiveView speaks a different event vocabulary.
const SLASH_INSERTS = [
  {label: "Image", hint: "Insert an image block", keywords: "photo picture media", insert: "image"},
  {label: "Columns", hint: "Insert a columns block", keywords: "layout grid side by side", insert: "columns"},
  {label: "FAQ", hint: "Insert an FAQ block", keywords: "faq questions answers", insert: "faq"},
  {label: "How-to", hint: "Insert a how-to block", keywords: "howto steps guide", insert: "how_to"},
  {label: "Claim", hint: "Insert a claim block", keywords: "claim citation source", insert: "claim"},
  {label: "Embed", hint: "Insert an embed block", keywords: "embed iframe video external", insert: "embed"},
]
const toolbarButton = (hook, item) => {
  const b = document.createElement("button")
  b.type = "button"
  b.textContent = item.label
  b.title = item.title
  // The visible label is a terse glyph ("B", "</>", "↺"), so give the button an
  // explicit accessible name — `title` alone is not reliably announced (#170).
  b.setAttribute("aria-label", item.title)
  b.className = "rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
  b.addEventListener("click", e => {
    e.preventDefault()
    if (item.prompt) {
      hook.linkPrompt.open()
    } else {
      item.run(hook.editor.chain().focus()).run()
    }
  })
  return b
}

// Unique per-instance ids, same reason as the slash menu's: several editors can
// be mounted at once and each popover labels its own input.
let linkPromptCount = 0

// The floating link editor (#823) — ⌘K, or the toolbar's "Link" button.
//
// A hand-rolled popover rather than `window.prompt`: prompt() can't explain why
// a URL was rejected, blocks the whole tab, and is suppressed outright in some
// embedded contexts. It follows the slash menu's shape — one element in
// document.body, positioned at the caret — so it escapes the block card's
// overflow the same way.
class LinkPrompt {
  constructor(editor) {
    this.editor = editor
    this.open_ = false
    this.id = `rt-link-prompt-${++linkPromptCount}`

    this.el = document.createElement("div")
    this.el.id = this.id
    this.el.className = "rt-link-prompt"
    this.el.setAttribute("role", "dialog")
    this.el.setAttribute("aria-label", "Link")
    this.el.hidden = true

    this.input = document.createElement("input")
    this.input.type = "text"
    this.input.className = "rt-link-input"
    this.input.placeholder = "https://example.com or /page"
    this.input.setAttribute("aria-label", "Link URL")
    this.input.addEventListener("keydown", e => {
      if (e.key === "Enter") {
        e.preventDefault()
        this.submit()
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.close()
      }
    })

    this.applyBtn = this.button("Apply", () => this.submit())
    this.removeBtn = this.button("Remove", () => this.unlink())

    this.error = document.createElement("p")
    this.error.className = "rt-link-error"
    // The message names the one thing that went wrong with what was typed, so
    // it should interrupt rather than wait for the next focus move.
    this.error.setAttribute("role", "alert")
    this.error.hidden = true

    this.el.append(this.input, this.applyBtn, this.removeBtn, this.error)
    document.body.appendChild(this.el)

    this.onKeyDown = this.onKeyDown.bind(this)
    this.onDocumentMouseDown = this.onDocumentMouseDown.bind(this)
    // Capture, like the slash menu, so ⌘K is claimed before ProseMirror (and
    // the browser's own ⌘K) sees it.
    editor.view.dom.addEventListener("keydown", this.onKeyDown, true)
    document.addEventListener("mousedown", this.onDocumentMouseDown)
  }

  button(label, onClick) {
    const b = document.createElement("button")
    b.type = "button"
    b.textContent = label
    // Don't let the browser move focus to the button on mousedown: the click
    // ends with the caret back in the prose, and a stranded focus ring on a
    // now-hidden popover leaves a keyboard user with nowhere to tab from.
    b.addEventListener("mousedown", e => e.preventDefault())
    b.addEventListener("click", e => {
      e.preventDefault()
      onClick()
    })
    return b
  }

  open() {
    const {editor} = this
    // Editing an existing link acts on the whole link, not the fragment the
    // caret happens to sit in — otherwise "Apply" splits one link into two.
    if (editor.isActive("link")) editor.chain().extendMarkRange("link").run()

    this.input.value = editor.getAttributes("link").href || ""
    this.removeBtn.hidden = !editor.isActive("link")
    this.error.hidden = true
    this.open_ = true
    this.el.hidden = false
    this.position()
    this.input.focus()
    this.input.select()
  }

  close({focus = true} = {}) {
    if (!this.open_) return
    this.open_ = false
    // Put the caret back BEFORE hiding, and with `view.focus()` rather than
    // `commands.focus()`. Hiding an element that still contains the focused
    // input makes the browser reset focus to <body> in a later task, which
    // would undo a focus call made after it; and `commands.focus()` defers to a
    // requestAnimationFrame, so it loses that race too. Either way an author
    // who applied a link with Enter would be left typing into nothing.
    if (focus) this.editor.view.focus()
    this.el.hidden = true
  }

  position() {
    const coords = this.editor.view.coordsAtPos(this.editor.state.selection.from)
    this.el.style.top = `${window.scrollY + coords.bottom + 4}px`
    this.el.style.left = `${window.scrollX + coords.left}px`
  }

  submit() {
    const href = safeHref(this.input.value)

    if (!href) {
      this.error.textContent =
        "Use an http(s):// URL, a mailto: address, a path starting with /, or a #section."
      this.error.hidden = false
      return
    }

    const {editor} = this

    if (editor.state.selection.empty && !editor.isActive("link")) {
      // Nothing selected and no link under the caret, so there is no text to
      // wrap: insert the URL as its own label. The advisory panel will (rightly)
      // ask for a better one — `link_text_bare_url` — but an author who pressed
      // ⌘K on an empty line gets a link rather than nothing.
      editor
        .chain()
        .focus()
        .insertContent([{type: "text", text: href, marks: [{type: "link", attrs: {href}}]}])
        .run()
    } else {
      editor.chain().focus().extendMarkRange("link").setLink({href}).run()
    }

    this.close()
  }

  unlink() {
    this.editor.chain().focus().extendMarkRange("link").unsetLink().run()
    this.close()
  }

  onKeyDown(e) {
    if (!(e.metaKey || e.ctrlKey) || e.altKey) return
    if (e.key !== "k" && e.key !== "K") return
    e.preventDefault()
    e.stopPropagation()
    this.open()
  }

  // Clicking anywhere else dismisses the popover, so it can't be left stranded
  // over the page after the author moves on. Focus stays where they clicked.
  onDocumentMouseDown(e) {
    if (!this.open_ || this.el.contains(e.target)) return
    this.close({focus: false})
  }

  destroy() {
    this.editor.view.dom.removeEventListener("keydown", this.onKeyDown, true)
    document.removeEventListener("mousedown", this.onDocumentMouseDown)
    this.el.remove()
  }
}

// A small language dropdown for code blocks (#503). Hidden until the caret is
// inside a codeBlock; changing it writes the node's `language` attribute
// (StarterKit's codeBlock already round-trips it as a `language-…` class).
// Returns {sel, sync} — callers append `sel` to their toolbar and call
// `sync()` from the editor's update/selection events.
function languageSelect(editor) {
  const sel = document.createElement("select")
  sel.title = "Code block language"
  sel.setAttribute("aria-label", "Code block language")
  sel.className = "rounded border border-base-content/20 bg-base-100 px-1 py-0.5 text-xs"
  sel.hidden = true

  LANGUAGES.forEach(([value, label]) => {
    const option = document.createElement("option")
    option.value = value
    option.textContent = label
    sel.appendChild(option)
  })

  // The inline toolbar swallows mousedown (to keep the editor's selection);
  // a native select needs its default mousedown to open, so fence it off.
  sel.addEventListener("mousedown", e => e.stopPropagation())
  sel.addEventListener("change", () => {
    editor.chain().focus().updateAttributes("codeBlock", {language: sel.value || null}).run()
  })

  const sync = () => {
    const active = editor.isActive("codeBlock")
    sel.hidden = !active
    if (!active) return
    const language = editor.getAttributes("codeBlock").language || ""
    // A tag from outside the preset list (API write, pasted content) still
    // shows as itself instead of silently displaying "Plain text".
    if (language && !Array.from(sel.options).some(o => o.value === language)) {
      const option = document.createElement("option")
      option.value = language
      option.textContent = language
      sel.appendChild(option)
    }
    sel.value = language
  }

  return {sel, sync}
}

// Unique per-instance menu ids so aria-controls/aria-activedescendant can
// point at the right floating listbox when several editors are mounted.
let slashMenuCount = 0

// A lightweight slash-command menu. Rendered into a single floating element
// (positioned at the caret) and driven entirely from the editor's update
// events — no extra TipTap extensions or popup dependencies. The combobox
// ARIA lives on the editor's contenteditable (aria-haspopup/expanded/
// controls/activedescendant), mirroring the BlockInserter pattern, so screen
// readers hear the menu open and track the active option (audit U-M8).
class SlashMenu {
  constructor(editor, {onInsert = null} = {}) {
    this.editor = editor
    // Callback that inserts a new Kiln block below (B3). When absent, the menu
    // offers only in-prose transforms.
    this.onInsert = onInsert
    this.open = false
    this.items = []
    this.active = 0
    this.range = null
    this.id = `rt-slash-menu-${++slashMenuCount}`

    this.el = document.createElement("div")
    this.el.id = this.id
    this.el.className = "rt-slash-menu"
    this.el.setAttribute("role", "listbox")
    this.el.setAttribute("aria-label", "Block commands")
    this.el.hidden = true
    document.body.appendChild(this.el)

    editor.view.dom.setAttribute("aria-haspopup", "listbox")
    editor.view.dom.setAttribute("aria-expanded", "false")

    this.onKeyDown = this.onKeyDown.bind(this)
    // Capture phase so Enter/arrows are handled before ProseMirror sees them.
    editor.view.dom.addEventListener("keydown", this.onKeyDown, true)
  }

  // Recompute menu state from the current selection. Triggers when the text of
  // the cursor's block starts with "/" (e.g. "/", "/head"). The slash must be
  // the first character of the block so it never fires mid-sentence.
  update() {
    const {state} = this.editor
    const {selection} = state
    if (!selection.empty) return this.hide()

    const {$from} = selection
    if ($from.parent.type.name !== "paragraph") return this.hide()

    const before = $from.parent.textBetween(0, $from.parentOffset, "\n", "\0")
    const match = /^\/(\S*)$/.exec(before)
    if (!match) return this.hide()

    const query = match[1].toLowerCase()
    // Text transforms always; block inserts too when this editor can add blocks.
    const commands = this.onInsert ? SLASH_COMMANDS.concat(SLASH_INSERTS) : SLASH_COMMANDS
    const items = commands.filter(cmd => {
      if (!query) return true
      return (cmd.label + " " + cmd.keywords).toLowerCase().includes(query)
    })
    if (items.length === 0) return this.hide()

    // Range of the "/query" text, so it can be deleted before applying.
    this.range = {from: $from.pos - match[0].length, to: $from.pos}
    this.items = items
    this.active = 0
    this.show()
  }

  show() {
    this.open = true
    this.render()
    this.el.hidden = false
    this.position()
    const dom = this.editor.view.dom
    dom.setAttribute("aria-expanded", "true")
    dom.setAttribute("aria-controls", this.id)
  }

  hide() {
    if (!this.open) return
    this.open = false
    this.el.hidden = true
    const dom = this.editor.view.dom
    dom.setAttribute("aria-expanded", "false")
    dom.removeAttribute("aria-controls")
    dom.removeAttribute("aria-activedescendant")
  }

  position() {
    const {from} = this.editor.state.selection
    const coords = this.editor.view.coordsAtPos(from)
    this.el.style.top = `${window.scrollY + coords.bottom + 4}px`
    this.el.style.left = `${window.scrollX + coords.left}px`
  }

  render() {
    this.el.replaceChildren()
    this.items.forEach((cmd, i) => {
      const row = document.createElement("button")
      row.type = "button"
      row.id = `${this.id}-option-${i}`
      row.setAttribute("role", "option")
      row.setAttribute("aria-selected", i === this.active ? "true" : "false")
      row.className = "rt-slash-item" + (i === this.active ? " rt-slash-item-active" : "")
      const label = document.createElement("span")
      label.className = "rt-slash-label"
      label.textContent = cmd.label
      const hint = document.createElement("span")
      hint.className = "rt-slash-hint"
      hint.textContent = cmd.hint
      row.append(label, hint)
      // Use mousedown so the click lands before the editor loses focus.
      row.addEventListener("mousedown", e => {
        e.preventDefault()
        this.choose(i)
      })
      this.el.appendChild(row)
    })

    // Keep the screen reader's cursor on the active option while the DOM
    // focus stays in the editor (standard combobox pattern).
    if (this.items.length > 0) {
      this.editor.view.dom.setAttribute(
        "aria-activedescendant",
        `${this.id}-option-${this.active}`
      )
    }
  }

  move(delta) {
    this.active = (this.active + delta + this.items.length) % this.items.length
    this.render()
  }

  choose(i) {
    const cmd = this.items[i]
    if (!cmd) return
    const range = this.range
    this.hide()
    if (cmd.insert) {
      // Block insert (B3): drop the "/query" text, then ask the server to add the
      // new block right after this one. The prose transform path is untouched.
      this.editor.chain().focus().deleteRange(range).run()
      this.onInsert(cmd.insert)
    } else {
      cmd.run(this.editor.chain().focus().deleteRange(range)).run()
    }
  }

  onKeyDown(e) {
    if (!this.open) return
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        this.move(1)
        return
      case "ArrowUp":
        e.preventDefault()
        this.move(-1)
        return
      case "Enter":
      case "Tab":
        e.preventDefault()
        this.choose(this.active)
        return
      case "Escape":
        e.preventDefault()
        this.hide()
        return
    }
  }

  destroy() {
    this.editor.view.dom.removeEventListener("keydown", this.onKeyDown, true)
    this.el.remove()
  }
}

// Attach the TipTap editor to a mounted RichText hook. Called from the thin
// lazily-loading hook in app.js (dynamic import) so this module — and TipTap /
// ProseMirror underneath — stays out of the public-page bundle (audit P-M6).
// State lands on the hook (`hook.editor`, `hook.slash`, `hook.collab`) so its
// destroyed() callback can tear everything down.
//
// When the block carries data-collab-* attributes (the CRDT prototype —
// KilnCMS.Collab.Crdt), the editor binds to a shared Yjs document instead of
// plain local state: concurrent edits from other browsers converge live. The
// HTML mirror (and therefore autosave) works identically in both modes.
export function mount(hook) {
  const {collabToken, collabTopic, collabFragment} = hook.el.dataset

  if (collabToken && collabTopic && collabFragment) {
    mountCollab(hook, {token: collabToken, topic: collabTopic, fragment: collabFragment})
  } else {
    buildEditor(hook, [StarterKit, ...LINK_EXTENSIONS, ...TABLE_EXTENSIONS], hook.el.dataset.content || "")
  }
}

// Collaborative variant: acquire the page-shared Y.Doc for this document's
// topic, wait for the server state, then mount TipTap bound to this block's
// XmlFragment. Only the first peer seeds an empty fragment from the stored
// HTML — later joiners take their content from the CRDT.
async function mountCollab(hook, {token, topic, fragment}) {
  const [{acquireDoc}, {default: Collaboration}, {default: CollaborationCursor}] =
    await Promise.all([
      import("./collab.js"),
      import("@tiptap/extension-collaboration"),
      import("@tiptap/extension-collaboration-cursor"),
    ])

  const handle = acquireDoc(topic, token)
  hook.collab = handle
  const {firstPeer} = await handle.whenReady
  if (hook._destroyed) return

  const frag = handle.doc.getXmlFragment(fragment)
  const seed = firstPeer && frag.length === 0 ? hook.el.dataset.content || "" : null

  buildEditor(hook, [
    // Yjs owns undo/redo semantics under collaboration.
    StarterKit.configure({history: false}),
    ...LINK_EXTENSIONS,
    ...TABLE_EXTENSIONS,
    Collaboration.configure({document: handle.doc, field: fragment}),
    // Remote carets labeled with each collaborator's initials, in the same
    // color as their roster chip / lock badges.
    CollaborationCursor.configure({
      provider: {awareness: handle.awareness},
      user: {
        name: hook.el.dataset.collabUser || "?",
        color: hook.el.dataset.collabColor || "#f43f5e",
      },
    }),
  ])

  // The Collaboration extension ignores the Editor `content` option, so the
  // first peer seeds the empty fragment explicitly — as a normal transaction
  // (emitUpdate: true), which both syncs it into the CRDT and refreshes the
  // HTML mirror.
  if (seed) hook.editor.commands.setContent(seed, true)
}

// In-context editing (#354): mount TipTap directly into a rendered-page region.
// Unlike the block editor's mount (a dedicated widget with a static toolbar and a
// hidden form input), here the region *is* the page content, so the toolbar
// floats above the block on focus and edits push straight to the LiveView via
// `update_block` rather than mirroring into a form input. The pushed HTML is
// re-sanitized on write by the `BlockUnion` cast, so no client-side allowlist is
// needed. State lands on the hook so its destroyed() can tear everything down.
export function mountInline(hook) {
  const seed = hook.el.dataset.content || ""
  // TipTap appends its own contenteditable; clear the no-JS seed HTML first so it
  // isn't left duplicated alongside the editor.
  hook.el.replaceChildren()

  const editor = new Editor({
    element: hook.el,
    extensions: [StarterKit, ...LINK_EXTENSIONS, ...TABLE_EXTENSIONS],
    content: seed,
    editorProps: {
      attributes: {
        "aria-label": hook.el.dataset.editorLabel || "Rich text editor",
        "aria-multiline": "true",
        role: "textbox",
      },
    },
    onUpdate: ({editor}) => {
      hook.slash.update()
      syncInlineToolbar(hook)
      clearTimeout(hook._debounce)
      hook._debounce = setTimeout(() => pushInline(hook), 600)
    },
    onSelectionUpdate: () => {
      hook.slash.update()
      syncInlineToolbar(hook)
    },
    // Stored marks (a toggle on an empty selection) change neither the doc nor
    // the selection — see the same hook in buildEditor.
    onTransaction: ({transaction}) => {
      if (transaction.storedMarksSet) syncInlineToolbar(hook)
    },
    onFocus: () => showInlineToolbar(hook),
    onBlur: () => {
      // Delay so a mousedown on a toolbar button (which momentarily blurs the
      // editor) doesn't hide the toolbar before the command runs.
      clearTimeout(hook._blurTimer)
      hook._blurTimer = setTimeout(() => hideInlineToolbar(hook), 200)
      clearTimeout(hook._debounce)
      pushInline(hook)
    },
  })

  hook.editor = editor
  hook.slash = new SlashMenu(editor)
  hook.linkPrompt = new LinkPrompt(editor)
  buildInlineToolbar(hook)
}

function pushInline(hook) {
  // Rich text pushes the TipTap document (converted to Portable Text by the
  // block cast); plain-text regions keep pushing their HTML/text value.
  const value = hook.el.dataset.kilnBlockMode === "html"
    ? hook.editor.getJSON()
    : hook.editor.getHTML()
  hook.pushEvent("update_block", {id: hook.el.dataset.kilnBlockId, value})
}

// A toolbar floating above the focused region, rendered into document.body (so
// it escapes the region's overflow) and repositioned each time it's shown.
function buildInlineToolbar(hook) {
  const bar = document.createElement("div")
  bar.className = "rt-inline-toolbar"
  bar.setAttribute("role", "toolbar")
  bar.setAttribute("aria-label", "Text formatting")
  bar.hidden = true
  // Keep the editor's selection: pressing a button must not blur the editor.
  bar.addEventListener("mousedown", e => e.preventDefault())

  hook.toolbarButtons = TOOLBAR.map(item => {
    const b = toolbarButton(hook, item)
    bar.appendChild(b)
    return {item, b}
  })

  hook.langSelect = languageSelect(hook.editor)
  bar.appendChild(hook.langSelect.sel)

  // Opening the native select necessarily blurs the editor (its mousedown must
  // run, unlike the buttons above), which arms the 200ms hide timer — and a
  // hidden toolbar force-closes the open dropdown. Keep the toolbar alive
  // while the select has focus; re-arm the hide when focus leaves it.
  const sel = hook.langSelect.sel
  sel.addEventListener("focus", () => clearTimeout(hook._blurTimer))
  sel.addEventListener("blur", () => {
    clearTimeout(hook._blurTimer)
    hook._blurTimer = setTimeout(() => hideInlineToolbar(hook), 200)
  })

  hook.tableControls = tableControls(hook.editor)
  bar.appendChild(hook.tableControls.el)

  document.body.appendChild(bar)
  hook.toolbar = bar
}

function showInlineToolbar(hook) {
  clearTimeout(hook._blurTimer)
  if (!hook.toolbar) return
  hook.toolbar.hidden = false
  const rect = hook.el.getBoundingClientRect()
  hook.toolbar.style.top = `${window.scrollY + rect.top - hook.toolbar.offsetHeight - 6}px`
  hook.toolbar.style.left = `${window.scrollX + rect.left}px`
  syncInlineToolbar(hook)
}

function hideInlineToolbar(hook) {
  if (hook.toolbar) hook.toolbar.hidden = true
}

function syncInlineToolbar(hook) {
  if (!hook.toolbarButtons) return
  hook.toolbarButtons.forEach(({item, b}) => {
    if (!item.active) return
    const on = item.active(hook.editor)
    b.classList.toggle("bg-base-300", on)
    b.setAttribute("aria-pressed", on ? "true" : "false")
  })
  if (hook.langSelect) hook.langSelect.sync()
  if (hook.tableControls) hook.tableControls.sync()
}

// `content` seeds the editor; omit it under collaboration, where the CRDT
// owns the document (TipTap ignores the option there anyway — see mountCollab).
function buildEditor(hook, extensions, content = null) {
  const toolbarEl = hook.el.querySelector("[data-toolbar]")

  // Prose flows to the server as the TipTap document via a debounced
  // rich_text_body push (converted to Portable Text there) — NOT through a
  // form input: AshPhoenix drops params for fields the rendered form doesn't
  // know. The server-rendered legacy_html input stays untouched as the no-JS
  // fallback; the server clears it when a pushed body lands.
  const pushBody = () => {
    hook.pushEvent("rich_text_body", {
      id: hook.el.dataset.blockId || null,
      idx: hook.el.dataset.blockIndex,
      doc: hook.editor.getJSON(),
    })
  }

  // Reflect the cursor's active marks/nodes on the toolbar buttons.
  const syncToolbar = () => {
    if (!hook.toolbarButtons) return
    hook.toolbarButtons.forEach(({item, b}) => {
      if (!item.active) return
      const on = item.active(hook.editor)
      b.classList.toggle("bg-base-300", on)
      b.setAttribute("aria-pressed", on ? "true" : "false")
    })
    if (hook.langSelect) hook.langSelect.sync()
    if (hook.tableControls) hook.tableControls.sync()
  }

  const editor = new Editor({
    element: hook.el.querySelector("[data-editor]"),
    extensions,
    ...(content != null ? {content} : {}),
    // Name the contenteditable surface for assistive tech — without this a
    // screen reader lands in an unlabeled editable region (#170). The label
    // can be overridden per block via `data-editor-label`.
    editorProps: {
      attributes: {
        "aria-label": hook.el.dataset.editorLabel || "Rich text editor",
        "aria-multiline": "true",
        role: "textbox",
      },
    },
    onUpdate: () => {
      hook.slash.update()
      syncToolbar()
      // Debounced push so the live preview reflects rich-text edits.
      clearTimeout(hook._debounce)
      hook._debounce = setTimeout(pushBody, 300)
    },
    onSelectionUpdate: () => {
      hook.slash.update()
      syncToolbar()
    },
    // Toggling a mark on an EMPTY selection only sets a stored mark (the next
    // keystroke will be bold) — the document and selection are untouched, so
    // neither callback above fires and the button stays un-pressed until the
    // author types. `isActive` already reads stored marks; this just re-syncs
    // on the one transaction kind the other two callbacks can't see. Gated on
    // `storedMarksSet` so the per-transaction cost is a boolean check.
    onTransaction: ({transaction}) => {
      if (transaction.storedMarksSet) syncToolbar()
    },
    // Collaborative locking (#140): broadcast focus/blur on this block's field
    // so other editors get the same lock ring + "who's editing" badge that the
    // title/slug/DSL inputs already use. data-lock-field is the form field name.
    onFocus: () => {
      const field = hook.el.dataset.lockField
      if (field) hook.pushEvent("field_focus", {field})
    },
    onBlur: () => {
      if (hook.el.dataset.lockField) hook.pushEvent("field_blur", {})
    },
  })
  hook.editor = editor
  // The block editor can spawn new blocks from "/": choosing a block-insert
  // command adds it right after this block (anchored by the block's stable id —
  // the same B2 add_block path the inline "+" uses).
  hook.slash = new SlashMenu(editor, {
    onInsert: type =>
      hook.pushEvent("add_block", {type, after: hook.el.dataset.blockId}),
  })
  hook.linkPrompt = new LinkPrompt(editor)

  // Block-level AI assist (#60). The server never writes generated prose into
  // the block itself — it would force the document back into TipTap mid-edit,
  // throwing away the author's cursor and undo stack and desynchronizing
  // anyone collaborating. It pushes the accepted suggestion here instead and we
  // apply it as an ordinary editor transaction: undoable, and correct under
  // collaboration because Yjs sees it like any other local edit.
  //
  // `push_event` reaches EVERY mounted hook that registered a handler, so the
  // block id filter is what stops one block's suggestion landing in all of
  // them. The ref is kept so destroyed() can drop the handler.
  hook._assistRef = hook.handleEvent("assist:apply", ({block_id, mode, paragraphs}) => {
    if (!block_id || block_id !== hook.el.dataset.blockId) return
    if (!Array.isArray(paragraphs) || paragraphs.length === 0) return

    // Plain text nodes only — never parsed as HTML. An empty string would make
    // an invalid text node, so a blank paragraph becomes an empty paragraph.
    const content = paragraphs.map(text => ({
      type: "paragraph",
      content: text ? [{type: "text", text: String(text)}] : [],
    }))

    const chain = hook.editor.chain().focus()
    if (mode === "replace") {
      // `emitUpdate: true` — setContent defaults to setting `preventUpdate` on
      // the transaction, so onUpdate never fires and the toolbar's active-mark
      // state and the slash menu keep describing the discarded document until
      // the next keystroke. Same argument, same reason, as the collab seed above.
      chain.setContent({type: "doc", content}, true).run()
    } else {
      chain.insertContent(content).run()
    }

    // Don't wait out the debounce: the server has just been told the record is
    // dirty, and an autosave firing before the body arrives would persist the
    // block without the text the author just accepted.
    clearTimeout(hook._debounce)
    pushBody()
  })

  hook.toolbarButtons = TOOLBAR.map(item => {
    const b = toolbarButton(hook, item)
    toolbarEl.appendChild(b)
    return {item, b}
  })
  hook.langSelect = languageSelect(editor)
  toolbarEl.appendChild(hook.langSelect.sel)
  hook.tableControls = tableControls(editor)
  toolbarEl.appendChild(hook.tableControls.el)
  syncToolbar()
}
