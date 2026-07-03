// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/kiln_cms"
import topbar from "../vendor/topbar"
import Sortable from "../vendor/sortable"
import {FocusTrap} from "./focus_trap"

const Hooks = {
  FocusTrap,
  // Warn before discarding unsaved editor changes. The server keeps
  // `data-dirty` on the form in sync with its save state; this hook guards
  // full page unloads (tab close, hard reload, plain links) via `beforeunload`
  // and in-app LiveView navigation (e.g. "← All content") by confirming
  // clicks on live links while dirty.
  UnsavedGuard: {
    mounted() {
      this.beforeUnload = e => {
        if (this.dirty()) {
          e.preventDefault()
          e.returnValue = ""
        }
      }
      window.addEventListener("beforeunload", this.beforeUnload)

      this.onClick = e => {
        if (!this.dirty()) return
        const link = e.target.closest && e.target.closest("a[data-phx-link]")
        if (!link || link.target === "_blank") return
        const message =
          this.el.dataset.unsavedMessage || "You have unsaved changes. Leave without saving?"
        if (!window.confirm(message)) {
          e.preventDefault()
          e.stopImmediatePropagation()
        }
      }
      document.addEventListener("click", this.onClick, true)
    },
    destroyed() {
      window.removeEventListener("beforeunload", this.beforeUnload)
      document.removeEventListener("click", this.onClick, true)
    },
    dirty() {
      return this.el.dataset.dirty === "true"
    },
  },
  // Bridge between a UTC-stored datetime attribute and a `datetime-local`
  // input: the visible input shows/edits the editor's local wall-clock time, a
  // hidden form input carries the ISO-8601 UTC instant the server stores.
  // Without this, a non-UTC editor's entry was silently stored as UTC and
  // published hours off.
  UtcDatetimeInput: {
    mounted() {
      this.local = this.el.querySelector("[data-local-input]")
      this.hidden = this.el.querySelector("[data-utc-input]")

      if (this.hidden.value) {
        const d = new Date(this.hidden.value.replace(" ", "T"))
        if (!isNaN(d)) this.local.value = this.toLocalValue(d)
      }

      this.local.addEventListener("input", () => {
        this.hidden.value = this.local.value ? new Date(this.local.value).toISOString() : ""
        this.hidden.dispatchEvent(new Event("input", {bubbles: true}))
      })
    },
    toLocalValue(d) {
      const pad = n => String(n).padStart(2, "0")
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
    },
  },
  // Render a <time datetime="..."> element's instant in the viewer's local
  // timezone (the server-rendered text stays as a UTC fallback without JS).
  LocalTime: {
    mounted() {
      this.format()
    },
    updated() {
      this.format()
    },
    format() {
      const d = new Date(this.el.dateTime)
      if (!isNaN(d)) {
        this.el.textContent = d.toLocaleString(undefined, {dateStyle: "medium", timeStyle: "short"})
      }
    },
  },
  Clipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        navigator.clipboard
          .writeText(this.el.dataset.clipboardText || "")
          .then(() => this.pushEvent("copied", {}))
      })
    },
  },
  // TipTap (and ProseMirror underneath) is admin-editor-only and heavy, so the
  // implementation is loaded on demand the first time a rich_text block mounts
  // — public pages never download it (audit P-M6). The dynamic import is what
  // makes esbuild split ./rich_text (+ deps) into its own chunk.
  RichText: {
    mounted() {
      import("./rich_text").then(({mount}) => {
        if (!this._destroyed) mount(this)
      })
    },
    destroyed() {
      this._destroyed = true
      this.slash && this.slash.destroy()
      this.editor && this.editor.destroy()
      // Collab prototype: drop this block's claim on the shared Y.Doc (the
      // channel is left once the last block releases it).
      this.collab && this.collab.release()
    },
  },
  // Notion-style slash-command block inserter (#29). The server renders the
  // trigger button + a menu of real `add_block` buttons (one per registered
  // block type); this hook layers on open/close, type-to-filter, and full
  // keyboard navigation (↑/↓/Enter/Esc, plus a global "/" shortcut). Selecting
  // an option clicks its underlying button, so insertion still flows through the
  // LiveView and the menu works even without JS.
  BlockInserter: {
    mounted() {
      this.trigger = this.el.querySelector("[data-inserter-trigger]")
      this.menu = this.el.querySelector("[data-inserter-menu]")
      this.search = this.el.querySelector("[data-inserter-search]")
      this.list = this.el.querySelector("[data-inserter-list], #block-inserter-list")
      this.empty = this.el.querySelector("[data-inserter-empty]")
      this.activeIndex = 0

      this.trigger.addEventListener("click", () => this.toggle())

      this.search.addEventListener("input", () => this.filter())
      this.search.addEventListener("keydown", e => this.onSearchKey(e))

      // Selecting an option (click or Enter→click) inserts then closes.
      this.options().forEach(opt =>
        opt.addEventListener("click", () => this.close({focusTrigger: false})),
      )

      // Click outside closes the menu.
      this.onDocClick = e => {
        if (this.isOpen() && !this.el.contains(e.target)) this.close({focusTrigger: false})
      }
      document.addEventListener("click", this.onDocClick)

      // Global "/" opens the inserter — unless the user is typing in a field
      // (mirrors the ⌘K palette guard so it never hijacks text entry).
      this.onDocKey = e => {
        if (e.key !== "/" || this.isOpen()) return
        const t = e.target
        const tag = (t.tagName || "").toLowerCase()
        if (tag === "input" || tag === "textarea" || t.isContentEditable) return
        e.preventDefault()
        this.open()
      }
      document.addEventListener("keydown", this.onDocKey)
    },

    destroyed() {
      document.removeEventListener("click", this.onDocClick)
      document.removeEventListener("keydown", this.onDocKey)
    },

    options() {
      return Array.from(this.el.querySelectorAll("[data-inserter-item]"))
    },

    visibleOptions() {
      return this.options().filter(o => !o.closest("[data-inserter-option]").hidden)
    },

    isOpen() {
      return !this.menu.hidden
    },

    toggle() {
      this.isOpen() ? this.close() : this.open()
    },

    open() {
      this.menu.hidden = false
      this.trigger.setAttribute("aria-expanded", "true")
      this.search.value = ""
      this.filter()
      this.search.focus()
    },

    close({focusTrigger = true} = {}) {
      this.menu.hidden = true
      this.trigger.setAttribute("aria-expanded", "false")
      if (focusTrigger) this.trigger.focus()
    },

    filter() {
      const q = this.search.value.trim().toLowerCase()
      this.options().forEach(opt => {
        const li = opt.closest("[data-inserter-option]")
        const label = (li.dataset.label || "").toLowerCase()
        const type = (opt.getAttribute("phx-value-type") || "").toLowerCase()
        li.hidden = q !== "" && !label.includes(q) && !type.includes(q)
      })
      const visible = this.visibleOptions()
      this.empty.hidden = visible.length > 0
      this.activeIndex = 0
      this.highlight()
    },

    highlight() {
      const visible = this.visibleOptions()
      this.options().forEach(o => o.setAttribute("aria-selected", "false"))
      const active = visible[this.activeIndex]
      if (active) {
        active.setAttribute("aria-selected", "true")
        active.scrollIntoView({block: "nearest"})
        this.search.setAttribute("aria-activedescendant", active.id)
      } else {
        this.search.removeAttribute("aria-activedescendant")
      }
    },

    move(delta) {
      const count = this.visibleOptions().length
      if (count === 0) return
      this.activeIndex = (this.activeIndex + delta + count) % count
      this.highlight()
    },

    onSearchKey(e) {
      switch (e.key) {
        case "ArrowDown":
          e.preventDefault()
          this.move(1)
          break
        case "ArrowUp":
          e.preventDefault()
          this.move(-1)
          break
        case "Enter": {
          e.preventDefault()
          const active = this.visibleOptions()[this.activeIndex]
          if (active) active.click()
          break
        }
        case "Escape":
          e.preventDefault()
          this.close()
          break
      }
    },
  },
  // Drag-and-drop reordering for editor block lists. On drop it reads the new
  // order of `data-sort-id`s and pushes a "reorder" event to the LiveView.
  Sortable: {
    mounted() {
      this.sorter = Sortable.create(this.el, {
        animation: 150,
        handle: "[data-drag-handle]",
        ghostClass: "opacity-40",
        onEnd: () => {
          const order = Array.from(this.el.children)
            .map(c => c.dataset.sortId)
            .filter(id => id !== undefined)
          this.pushEvent("reorder", {order})
        },
      })
    },
    destroyed() {
      this.sorter && this.sorter.destroy()
    },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// ⌘K / Ctrl-K opens the editor search palette from anywhere (no-op if already
// there). Skipped while typing in an input so it doesn't hijack the field.
// Prefer the hidden `navigate` link rendered in the app layout so connected
// LiveViews jump there without a full page reload (#139); fall back to a normal
// load when the link isn't present (e.g. public pages).
window.addEventListener("keydown", e => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
    const tag = (e.target.tagName || "").toLowerCase()
    if (tag === "input" || tag === "textarea" || e.target.isContentEditable) return
    if (window.location.pathname === "/editor/search") return
    e.preventDefault()
    const link = document.getElementById("cmdk-search-link")
    if (link) {
      link.click()
    } else {
      window.location.href = "/editor/search"
    }
  }
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

