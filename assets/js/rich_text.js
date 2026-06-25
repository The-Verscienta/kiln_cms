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
  b.className = "rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
  b.addEventListener("click", e => {
    e.preventDefault()
    item.run(editor.chain().focus()).run()
  })
  return b
}

// A lightweight slash-command menu. Rendered into a single floating element
// (positioned at the caret) and driven entirely from the editor's update
// events — no extra TipTap extensions or popup dependencies.
class SlashMenu {
  constructor(editor) {
    this.editor = editor
    this.open = false
    this.items = []
    this.active = 0
    this.range = null

    this.el = document.createElement("div")
    this.el.className = "rt-slash-menu"
    this.el.setAttribute("role", "listbox")
    this.el.hidden = true
    document.body.appendChild(this.el)

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
  }

  hide() {
    if (!this.open) return
    this.open = false
    this.el.hidden = true
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

export const RichText = {
  mounted() {
    const input = this.el.querySelector("[data-input]")
    const toolbarEl = this.el.querySelector("[data-toolbar]")

    const editor = new Editor({
      element: this.el.querySelector("[data-editor]"),
      extensions: [StarterKit],
      content: this.el.dataset.content || "",
      onUpdate: ({editor}) => {
        input.value = editor.getHTML()
        this.slash.update()
        this.syncToolbar()
        // Debounced phx-change so the live preview reflects rich-text edits.
        clearTimeout(this._debounce)
        this._debounce = setTimeout(() => {
          input.dispatchEvent(new Event("input", {bubbles: true}))
        }, 300)
      },
      onSelectionUpdate: () => {
        this.slash.update()
        this.syncToolbar()
      },
    })
    this.editor = editor
    this.slash = new SlashMenu(editor)
    input.value = editor.getHTML()

    this.toolbarButtons = TOOLBAR.map(item => {
      const b = toolbarButton(editor, item)
      toolbarEl.appendChild(b)
      return {item, b}
    })
    this.syncToolbar()
  },

  // Reflect the cursor's active marks/nodes on the toolbar buttons.
  syncToolbar() {
    if (!this.toolbarButtons) return
    this.toolbarButtons.forEach(({item, b}) => {
      if (!item.active) return
      const on = item.active(this.editor)
      b.classList.toggle("bg-base-300", on)
      b.setAttribute("aria-pressed", on ? "true" : "false")
    })
  },

  destroyed() {
    this.slash && this.slash.destroy()
    this.editor && this.editor.destroy()
  },
}
