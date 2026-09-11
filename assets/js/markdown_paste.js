// Markdown into a rich-text block: paste it, or drop a `.md` file on the block.
//
// The conversion is the SERVER's (`KilnCMS.Markdown` via the LiveView's
// `markdown_paste` event), not a client-side Markdown library: one converter
// and one sanitizer for paste, `.md` import and the API's `body_markdown`, so
// the three can't disagree about what a table or a raw `<script>` becomes.
// This module only decides WHEN to ask — and then inserts the reply as one
// editor transaction, with a notice offering Undo and "Paste as plain text",
// because a heuristic will sometimes be wrong and the author should be one
// click from what they meant.
import {Extension} from "@tiptap/core"
import {Plugin, PluginKey} from "@tiptap/pm/state"

// Mirror of `KilnCMS.Markdown.max_bytes/0`. Past it the server refuses, so a
// paste that size goes in as plain text without the round trip.
const MAX_BYTES = 1_000_000
const MD_FILE = /\.(md|markdown|mdown|mkd)$/i
// No reply by then (a dropped line) → paste the text as it came.
const REPLY_TIMEOUT_MS = 5000
const NOTICE_MS = 10000

// Does this plain text read as Markdown? One strong block-level signal is
// enough (a heading, a fence, a table rule, two list items, two quote
// lines); otherwise an inline link, bold run or code span. Prose with a
// stray `*` or a single "- " line stays prose — and the notice's "Paste as
// plain text" covers the misses either way.
export function looksLikeMarkdown(text) {
  if (!text || text.length < 3) return false

  let listLines = 0
  let quoteLines = 0
  for (const line of text.split(/\r?\n/)) {
    if (/^ {0,3}#{1,6}\s+\S/.test(line)) return true
    if (/^ {0,3}(```|~~~)/.test(line)) return true
    if (/^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line)) return true
    if (/^\s*([-*+]|\d{1,9}[.)])\s+\S/.test(line)) listLines++
    if (/^ {0,3}>\s?\S/.test(line)) quoteLines++
  }
  if (listLines >= 2 || quoteLines >= 2) return true

  return /\[[^\]\n]+\]\((?:https?:\/\/|\/|#|mailto:)[^)\s]*\)|!\[[^\]\n]*\]\([^)\s]+\)|\*\*[^*\n]+\*\*|__[^_\n]+__|`[^`\n]+`/.test(
    text,
  )
}

const isMarkdownFile = file => MD_FILE.test(file.name || "") || file.type === "text/markdown"

// VS Code (and editors built on it) put syntax-coloured HTML on the clipboard
// beside the plain text. Pasting that HTML gives a slab of monospace spans;
// the plain text is the document the author copied.
const fromCodeEditor = data => Array.from(data.types || []).includes("vscode-editor-data")

const byteLength = text => new Blob([text]).size

// The text as the browser's own plain paste would put it: one paragraph per
// line, never parsed as HTML.
const plainNodes = text =>
  text.split(/\r?\n/).map(line => ({
    type: "paragraph",
    content: line ? [{type: "text", text: line}] : [],
  }))

// The floating "Pasted as Markdown" notice — one per editor, in document.body
// like the slash menu and link prompt, so the block card's overflow can't
// clip it. `role="status"` so the conversion is announced, not just shown.
class PasteNotice {
  constructor({onUndo, onPlain}) {
    this.el = document.createElement("div")
    this.el.className =
      "rt-paste-notice fixed z-50 flex items-center gap-2 rounded-md border border-base-content/20 bg-base-100 px-3 py-1.5 text-xs shadow-lg"
    this.el.setAttribute("role", "status")
    this.el.hidden = true

    this.message = document.createElement("span")
    this.undoBtn = this.button("Undo", onUndo)
    this.plainBtn = this.button("Paste as plain text", onPlain)
    this.closeBtn = this.button("✕", () => this.hide())
    this.closeBtn.setAttribute("aria-label", "Dismiss")

    this.el.append(this.message, this.undoBtn, this.plainBtn, this.closeBtn)
    document.body.appendChild(this.el)
  }

  button(label, onClick) {
    const b = document.createElement("button")
    b.type = "button"
    b.textContent = label
    b.className = "btn btn-ghost px-2 py-0.5 text-xs"
    // Keep the caret in the prose: the buttons act on it.
    b.addEventListener("mousedown", e => e.preventDefault())
    b.addEventListener("click", e => {
      e.preventDefault()
      onClick()
    })
    return b
  }

  show(message, coords, {actions = true} = {}) {
    this.message.textContent = message
    this.undoBtn.hidden = !actions
    this.plainBtn.hidden = !actions
    this.el.style.top = `${coords.bottom + 6}px`
    this.el.style.left = `${Math.max(8, coords.left)}px`
    this.el.hidden = false
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.hide(), NOTICE_MS)
  }

  hide() {
    clearTimeout(this.timer)
    this.el.hidden = true
  }

  destroy() {
    clearTimeout(this.timer)
    this.el.remove()
  }
}

// The TipTap extension for one block editor. `hook` is the RichText hook,
// the channel the conversion request goes out on.
export function markdownPaste(hook) {
  return Extension.create({
    name: "kilnMarkdownPaste",

    addStorage() {
      // `last`: the most recent conversion — the document just before it
      // (`prior`) and just after it (`doc`), the range it targeted, and the
      // source text. Undo and "Paste as plain text" act only while the
      // document is still exactly `doc`; any later edit retires the notice,
      // so nothing stale is ever written through.
      return {notice: null, last: null}
    },

    onCreate() {
      const editor = this.editor
      const storage = this.storage

      // Put back what the conversion replaced. The changed span is found by
      // DIFFING the two documents, not by mapping the caret through the
      // insertion's steps: ProseMirror may land a block after the paragraph
      // the caret was in rather than at the caret, and a mapped caret then
      // names an empty range — an Undo that removes nothing.
      const restore = last => {
        const start = last.prior.content.findDiffStart(last.doc.content)
        if (start == null) return
        let {a: endPrior, b: endDoc} = last.prior.content.findDiffEnd(last.doc.content)
        // Repeated content can make the end diff overlap the start.
        if (endPrior < start) {
          endDoc += start - endPrior
          endPrior = start
        }
        if (endDoc < start) {
          endPrior += start - endDoc
          endDoc = start
        }
        editor
          .chain()
          .focus()
          .command(({tr}) => {
            tr.replace(start, endDoc, last.prior.slice(start, endPrior))
            return true
          })
          .run()
      }

      const take = () => {
        const last = storage.last
        storage.last = null
        storage.notice.hide()
        return last && editor.state.doc.eq(last.doc) ? last : null
      }

      storage.notice = new PasteNotice({
        onUndo: () => {
          const last = take()
          if (last) restore(last)
        },
        onPlain: () => {
          const last = take()
          if (!last) return
          restore(last)
          // The document is `prior` again, so the targeted range is valid.
          editor.chain().focus().insertContentAt(last.range, plainNodes(last.text)).run()
        },
      })
    },

    onUpdate() {
      const {last, notice} = this.storage
      if (last && !this.editor.state.doc.eq(last.doc)) {
        this.storage.last = null
        notice && notice.hide()
      }
    },

    onDestroy() {
      this.storage.notice && this.storage.notice.destroy()
    },

    addProseMirrorPlugins() {
      const editor = this.editor
      const storage = this.storage

      // Insert `content` over the range the paste targeted — or, if the
      // document moved while the server answered, over the caret as it is now.
      const land = (content, at, before, notice) => {
        const range = editor.state.doc.eq(before)
          ? at
          : {from: editor.state.selection.from, to: editor.state.selection.to}
        const prior = editor.state.doc

        editor.chain().focus().insertContentAt(range, content).run()

        if (!notice) return
        storage.last = {prior, range, text: notice.text, doc: editor.state.doc}
        storage.notice.show(notice.message, editor.view.coordsAtPos(editor.state.selection.to))
      }

      const convert = (view, text) => {
        const before = view.state.doc
        const at = {from: view.state.selection.from, to: view.state.selection.to}
        let settled = false
        const plain = () => {
          if (settled) return
          settled = true
          land(plainNodes(text), at, before, null)
        }

        if (byteLength(text) > MAX_BYTES) return plain()

        const timer = setTimeout(plain, REPLY_TIMEOUT_MS)
        hook.pushEvent("markdown_paste", {text}, reply => {
          clearTimeout(timer)
          if (settled) return
          const content = reply && reply.doc && reply.doc.content
          if (!Array.isArray(content) || content.length === 0) return plain()
          settled = true
          land(content, at, before, {text, message: "Pasted as Markdown."})
        })
      }

      return [
        new Plugin({
          key: new PluginKey("kilnMarkdownPaste"),
          props: {
            handlePaste: (view, event) => {
              const data = event.clipboardData
              if (!data || (data.files && data.files.length)) return false
              // ⌘⇧V is "paste as plain text": plain means plain.
              if ((view.input && view.input.shiftKey) || view.shiftKey) return false
              // Inside a code block the text IS the content, `#` and all.
              if (editor.isActive("codeBlock")) return false
              if (data.getData("text/html") && !fromCodeEditor(data)) return false

              const text = data.getData("text/plain")
              if (!looksLikeMarkdown(text)) return false

              event.preventDefault()
              convert(view, text)
              return true
            },

            handleDrop: (view, event) => {
              const files = Array.from((event.dataTransfer && event.dataTransfer.files) || [])
              const file = files.find(isMarkdownFile)
              if (!file) return false
              // Claimed even when refused below: unclaimed, the browser opens
              // the file in this tab and the unsaved edits go with the page.
              event.preventDefault()

              const coords = {left: event.clientX, top: event.clientY, bottom: event.clientY}
              if (file.size > MAX_BYTES) {
                storage.notice.show("That file is too large to convert (the limit is 1 MB).", coords, {
                  actions: false,
                })
                return true
              }

              const pos = view.posAtCoords({left: event.clientX, top: event.clientY})
              if (pos) editor.commands.setTextSelection(pos.pos)
              file.text().then(text => convert(view, text))
              return true
            },
          },
        }),
      ]
    },
  })
}
