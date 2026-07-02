// TipTap rich-text editor for `rich_text` blocks in the content editor.
//
// The editor's HTML is mirrored into a hidden input bound to the block's
// `content` form field, so it saves through the normal form submit. On top of
// the StarterKit defaults this module adds:
//
//   * an expanded toolbar with live active-state highlighting
//   * a slash-command menu ("/") for common block transforms
//
// Every command here produces only tags already on the server-side allowlist
// (KilnCMS.HTMLSanitizer.RichText), so no sanitizer changes are needed.
import {Editor} from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"

// Toolbar buttons. `active` (optional) lights the button when the mark/node is
// applied at the cursor; `run` receives a focused command chain.
const TOOLBAR = [
  {label: "B", title: "Bold (⌘B)", active: e => e.isActive("bold"), run: c => c.toggleBold()},
  {label: "I", title: "Italic (⌘I)", active: e => e.isActive("italic"), run: c => c.toggleItalic()},
  {label: "S", title: "Strikethrough (⌘⇧S)", active: e => e.isActive("strike"), run: c => c.toggleStrike()},
  {label: "</>", title: "Inline code (⌘E)", active: e => e.isActive("code"), run: c => c.toggleCode()},
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
]

const toolbarButton = (editor, item) => {
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
    item.run(editor.chain().focus()).run()
  })
  return b
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
  constructor(editor) {
    this.editor = editor
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
    const items = SLASH_COMMANDS.filter(cmd => {
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
    cmd.run(this.editor.chain().focus().deleteRange(range)).run()
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
    buildEditor(hook, [StarterKit], hook.el.dataset.content || "")
  }
}

// Collaborative variant: acquire the page-shared Y.Doc for this document's
// topic, wait for the server state, then mount TipTap bound to this block's
// XmlFragment. Only the first peer seeds an empty fragment from the stored
// HTML — later joiners take their content from the CRDT.
async function mountCollab(hook, {token, topic, fragment}) {
  const [{acquireDoc}, {default: Collaboration}] = await Promise.all([
    import("./collab.js"),
    import("@tiptap/extension-collaboration"),
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
    Collaboration.configure({document: handle.doc, field: fragment}),
  ])

  // The Collaboration extension ignores the Editor `content` option, so the
  // first peer seeds the empty fragment explicitly — as a normal transaction
  // (emitUpdate: true), which both syncs it into the CRDT and refreshes the
  // HTML mirror.
  if (seed) hook.editor.commands.setContent(seed, true)
}

// `content` seeds the editor; omit it under collaboration, where the CRDT
// owns the document (TipTap ignores the option there anyway — see mountCollab).
function buildEditor(hook, extensions, content = null) {
  const input = hook.el.querySelector("[data-input]")
  const toolbarEl = hook.el.querySelector("[data-toolbar]")

  // Reflect the cursor's active marks/nodes on the toolbar buttons.
  const syncToolbar = () => {
    if (!hook.toolbarButtons) return
    hook.toolbarButtons.forEach(({item, b}) => {
      if (!item.active) return
      const on = item.active(hook.editor)
      b.classList.toggle("bg-base-300", on)
      b.setAttribute("aria-pressed", on ? "true" : "false")
    })
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
    onUpdate: ({editor}) => {
      input.value = editor.getHTML()
      hook.slash.update()
      syncToolbar()
      // Debounced phx-change so the live preview reflects rich-text edits.
      clearTimeout(hook._debounce)
      hook._debounce = setTimeout(() => {
        input.dispatchEvent(new Event("input", {bubbles: true}))
      }, 300)
    },
    onSelectionUpdate: () => {
      hook.slash.update()
      syncToolbar()
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
  hook.slash = new SlashMenu(editor)
  input.value = editor.getHTML()

  hook.toolbarButtons = TOOLBAR.map(item => {
    const b = toolbarButton(editor, item)
    toolbarEl.appendChild(b)
    return {item, b}
  })
  syncToolbar()
}
