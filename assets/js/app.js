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
import {PasskeyEnroll, initPasskeySignIn} from "./passkeys"
import {PushToggle} from "./push"
import {initAdvisoryJump} from "./advisory_jump"

const clamp01 = (n) => Math.min(Math.max(n, 0), 1)

const Hooks = {
  FocusTrap,
  // Passkey enrolment on /editor/settings (#331) — see assets/js/passkeys.js.
  PasskeyEnroll,
  // Web Push opt-in on /editor/settings (#628) — see assets/js/push.js.
  PushToggle,
  // Presentation console (#355): relay the framed external front end's
  // click-to-edit `postMessage` up to the LiveView, and nudge the iframe to
  // refresh after a save. Mirrors embed.js's parent-side security check —
  // trust only messages from THIS iframe's window, and (when known) only from
  // the configured front-end origin.
  //
  // Same-origin previews are sandboxed without allow-same-origin (#1059), so
  // the frame posts with origin "null". contentWindow identity stays the guard;
  // opaqueOrigin marks that null is expected rather than forged.
  PresentationFrame: {
    mounted() {
      this.origin = this.el.dataset.frontendOrigin || null
      this.opaque = this.el.dataset.opaqueOrigin === "true"
      this.onMessage = e => {
        if (e.source !== this.el.contentWindow) return
        if (this.origin && e.origin !== this.origin) {
          if (!(this.opaque && e.origin === "null")) return
        }
        const d = e.data
        if (d && d.source === "kiln-bridge" && d.event === "edit" && d.payload) {
          this.pushEvent("edit_field", d.payload)
        }
      }
      window.addEventListener("message", this.onMessage)
      // Server → iframe: tell bridge.js to re-fetch after a Kiln-side save.
      this.handleEvent("presentation:refresh", () => {
        const win = this.el.contentWindow
        // Opaque frames cannot be addressed by a concrete origin string.
        const target = this.opaque ? "*" : (this.origin || "*")
        if (win) win.postMessage({source: "kiln-console", event: "refresh"}, target)
      })
    },
    destroyed() {
      window.removeEventListener("message", this.onMessage)
    },
  },
  // Deep-link focus from the visual-editing bridge (#355): when the in-context
  // editor is opened as `/editor/site/:type/:slug?focus=<block_id>`, scroll that
  // block into view, focus its editable region, and pulse it so the editor lands
  // exactly on the field the user clicked in their external front end.
  FocusBlock: {
    mounted() {
      const id = this.el.dataset.kilnFocus
      if (!id) return
      // Defer a frame so the block regions (phx-update="ignore") have mounted.
      requestAnimationFrame(() => {
        const wrap = document.getElementById(`block-wrap-${id}`)
        if (!wrap) return
        wrap.scrollIntoView({behavior: "smooth", block: "center"})
        wrap.classList.add("kiln-focus-pulse")
        setTimeout(() => wrap.classList.remove("kiln-focus-pulse"), 1600)
        const editable = wrap.querySelector("[data-kiln-block-id][contenteditable]")
        if (editable) editable.focus()
      })
    },
  },
  // Block-scoped presence: tell the server which block this editor is on, so
  // peers see "Alice is here" beside the block rather than only in the
  // document roster.
  //
  // focusin/focusout, not phx-focus/phx-blur — those bind focus/blur, which do
  // not bubble, so a card whose focusable children are the inputs inside it
  // would never fire them.
  //
  // The blur is deferred a tick and cancelled by any focusin that follows:
  // tabbing from one input to the next inside the same block emits
  // focusout-then-focusin, and sending the intervening null would make the
  // avatar flicker off and on for every field the author moves through.
  BlockPresence: {
    mounted() {
      this.blockId = this.el.dataset.blockId || null
      this.pending = null

      this.onIn = () => {
        clearTimeout(this.pending)
        this.pending = null
        if (this.sent === this.blockId) return
        this.sent = this.blockId
        this.pushEvent("presence_focus", {bid: this.blockId})
      }

      this.onOut = () => {
        clearTimeout(this.pending)
        this.pending = setTimeout(() => {
          this.sent = null
          this.pushEvent("presence_focus", {bid: null})
        }, 120)
      }

      this.el.addEventListener("focusin", this.onIn)
      this.el.addEventListener("focusout", this.onOut)
    },
    updated() {
      // A reorder re-renders this card with a different block's data; keep the
      // id we report in step with what is now inside it.
      this.blockId = this.el.dataset.blockId || null
    },
    destroyed() {
      clearTimeout(this.pending)
      this.el.removeEventListener("focusin", this.onIn)
      this.el.removeEventListener("focusout", this.onOut)
    },
  },
  // The comment composer's `@` autocomplete and typing indicator.
  //
  // The dropdown itself is server-rendered from `@mention_suggestions` — this
  // hook only throttles what reaches the server and puts the caret back after
  // a pick, because a mention the server did not choose is a mention
  // `Mentions.resolve/2` may refuse to resolve.
  MentionAutocomplete: {
    mounted() {
      this.blockId = this.el.dataset.blockId || null
      this.lastTyping = 0

      this.onInput = () => {
        // One typing broadcast per 1.5s per composer, well inside the server's
        // 3s expiry: continuous typing keeps the indicator lit without one
        // message per keystroke going out to every editor on the document.
        const now = Date.now()
        if (now - this.lastTyping > 1500) {
          this.lastTyping = now
          this.pushEvent("comment_typing", {bid: this.blockId})
        }
      }

      // The server owns the draft, so a pick rewrites the textarea's value;
      // restore the caret to the end or the author resumes typing mid-handle.
      this.onInserted = ({value}) => {
        this.el.value = value
        this.el.focus()
        this.el.setSelectionRange(value.length, value.length)
      }

      this.el.addEventListener("input", this.onInput)
      this.handleEvent("mention:inserted", this.onInserted)
    },
    destroyed() {
      this.el.removeEventListener("input", this.onInput)
    },
  },
  // Deep-link focus from an external front end (#355): when the structured
  // editor is opened as /editor/content/:type/:id?focus=<field>, scroll that
  // field's input into view, pulse it, and focus it. Custom fields anchor by
  // their stable input id (custom-field-<name>) and live inside a collapsed
  // <details>, which must be opened first; core fields (title/slug/excerpt/…)
  // anchor by their presence-tracking phx-value-field attribute.
  FocusField: {
    mounted() {
      const name = this.el.dataset.kilnFocus
      if (!name) return
      requestAnimationFrame(() => {
        const target =
          document.getElementById(`custom-field-${name}`) ||
          document.querySelector(`[phx-value-field="${CSS.escape(name)}"]`)
        if (!target) return
        for (let d = target.closest("details"); d; d = d.parentElement.closest("details")) {
          d.open = true
        }
        target.scrollIntoView({behavior: "smooth", block: "center"})
        const wrap = target.closest("div") || target
        wrap.classList.add("kiln-focus-pulse")
        setTimeout(() => wrap.classList.remove("kiln-focus-pulse"), 1600)
        if (typeof target.focus === "function") target.focus({preventScroll: true})
      })
    },
  },
  // Multiplayer preview cursors (#343): report this viewer's pointer position
  // as fractions (0..1) of the preview surface, throttled, so co-viewers can
  // render it at the right spot regardless of their window size. The server
  // broadcasts it to the other viewers (never echoes it back to us).
  PreviewCursors: {
    mounted() {
      this.last = 0
      this.onMove = e => {
        const now = Date.now()
        if (now - this.last < 50) return // ~20 msgs/sec ceiling
        this.last = now
        const rect = this.el.getBoundingClientRect()
        if (rect.width === 0 || rect.height === 0) return
        this.pushEvent("cursor", {
          x: (e.clientX - rect.left) / rect.width,
          y: (e.clientY - rect.top) / rect.height,
        })
      }
      this.onLeave = () => this.pushEvent("cursor_leave", {})
      this.el.addEventListener("mousemove", this.onMove)
      this.el.addEventListener("mouseleave", this.onLeave)
    },
    destroyed() {
      this.el.removeEventListener("mousemove", this.onMove)
      this.el.removeEventListener("mouseleave", this.onLeave)
    },
  },
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
  // Set the focal point on a media preview. Pointer: click position as
  // fractions of the rendered image (the <img> is display:block and unpadded,
  // so its element box equals the rendered image — no letterbox math needed).
  // Keyboard: the container is focusable; arrow keys nudge the point by 5%
  // from its current position (read off data-focal-*, refreshed each render).
  FocalPoint: {
    mounted() {
      this.el.addEventListener("click", (e) => {
        const img = this.el.querySelector("img")
        if (!img) return
        const rect = img.getBoundingClientRect()
        if (rect.width === 0 || rect.height === 0) return
        const x = clamp01((e.clientX - rect.left) / rect.width)
        const y = clamp01((e.clientY - rect.top) / rect.height)
        this.pushEvent("set_focal", {x, y})
      })

      this.el.addEventListener("keydown", (e) => {
        const step = 0.05
        const deltas = {
          ArrowLeft: [-step, 0], ArrowRight: [step, 0],
          ArrowUp: [0, -step], ArrowDown: [0, step],
        }
        const d = deltas[e.key]
        if (!d) return
        e.preventDefault()
        const cx = parseFloat(this.el.dataset.focalX) || 0.5
        const cy = parseFloat(this.el.dataset.focalY) || 0.5
        this.pushEvent("set_focal", {x: clamp01(cx + d[0]), y: clamp01(cy + d[1])})
      })
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

      // The document was published while this collab room was open (#1061).
      // The publish took the room's prose with it, so nothing is lost — but
      // nothing persists from here either, so the editor has to be told rather
      // than left typing into a doc that is going nowhere. Every rich-text
      // block hears it; the LiveView's handler is idempotent.
      this._collabPublished = () => this.pushEvent("collab_published", {})
      window.addEventListener("kiln:collab-published", this._collabPublished)
    },
    destroyed() {
      this._destroyed = true
      window.removeEventListener("kiln:collab-published", this._collabPublished)
      this.slash && this.slash.destroy()
      this.linkPrompt && this.linkPrompt.destroy()
      this.editor && this.editor.destroy()
      // Rich-text hosts remount on every conflict reload / version restore, so
      // a handler left registered would accumulate one dead listener per
      // remount for the life of the session.
      this._assistRef && this.removeHandleEvent(this._assistRef)
      // Collab prototype: drop this block's claim on the shared Y.Doc (the
      // channel is left once the last block releases it).
      this.collab && this.collab.release()
    },
  },
  // The content editor's sticky action bar. Each rich-text block's formatting
  // toolbar sticks just under it while a long block scrolls past, so the bar
  // publishes its stuck bottom edge as `--kiln-action-bar-bottom` for the
  // toolbars' `top` (`.rt-block-toolbar`). Measured, not hard-coded: the bar
  // wraps onto a second line on narrow screens and as the editor roster grows,
  // and a toolbar pinned to a stale height would either float over the bar or
  // leave a strip of prose showing between them.
  EditorActionBar: {
    mounted() {
      this.publish = () => {
        const stuckTop = parseFloat(getComputedStyle(this.el).top) || 0
        document.documentElement.style.setProperty(
          "--kiln-action-bar-bottom",
          `${stuckTop + this.el.offsetHeight}px`,
        )
      }
      this.publish()
      this.observer = new ResizeObserver(this.publish)
      this.observer.observe(this.el)
    },
    destroyed() {
      this.observer && this.observer.disconnect()
      document.documentElement.style.removeProperty("--kiln-action-bar-bottom")
    },
  },
  // In-context editing (#354): a plain-text `contenteditable` region (heading /
  // quote block on the rendered page). Debounced input and blur push the region's
  // text back to the LiveView, which writes it through the block's Ash update.
  // The element is `phx-update="ignore"`, so the browser owns it while editing.
  InlineText: {
    mounted() {
      this.onInput = () => {
        clearTimeout(this._t)
        this._t = setTimeout(() => this.push(), 600)
      }
      this.onBlur = () => {
        clearTimeout(this._t)
        this.push()
      }
      this.el.addEventListener("input", this.onInput)
      this.el.addEventListener("blur", this.onBlur)
    },
    destroyed() {
      clearTimeout(this._t)
      this.el.removeEventListener("input", this.onInput)
      this.el.removeEventListener("blur", this.onBlur)
    },
    push() {
      this.pushEvent("update_block", {
        id: this.el.dataset.kilnBlockId,
        // innerText collapses the contenteditable's markup to the plain string
        // these blocks store.
        value: this.el.innerText.trim(),
      })
    },
  },
  // In-context editing (#354): a rich-text region on the rendered page. Loads the
  // shared TipTap implementation on demand (kept out of the public bundle) and
  // mounts it into this region with a floating formatting toolbar; edits push the
  // sanitized-on-write HTML back to the LiveView.
  InlineRichText: {
    mounted() {
      import("./rich_text").then(({mountInline}) => {
        if (!this._destroyed) mountInline(this)
      })
    },
    destroyed() {
      this._destroyed = true
      this.slash && this.slash.destroy()
      this.linkPrompt && this.linkPrompt.destroy()
      this.toolbar && this.toolbar.remove()
      this.editor && this.editor.destroy()
    },
  },
  // Type-to-filter over the sectioned tag picker. The server renders every tag
  // it wants submittable (see `tag_picker/1` — an unrendered checkbox would be
  // *detached* on save), so narrowing happens purely client-side: matching is
  // hiding, never removing. Sections that end up empty collapse away too.
  //
  // The filter input is inside the content form, so it is deliberately unnamed
  // and wrapped in phx-update="ignore"; `updated()` re-applies the current query
  // after a LiveView patch re-renders the sections underneath it.
  //
  // The whole body — filter box included — is absent while the picker has no
  // sections to show (#524), and a reload can grow one into existence, so the
  // hook re-resolves its handles on every patch rather than once at mount.
  TagFilter: {
    mounted() {
      this.timer = null
      this.bind()
    },

    updated() {
      this.bind()
    },

    destroyed() {
      this.unbind()
      if (this.timer) clearTimeout(this.timer)
    },

    // Wire the filter box, if there is one. Idempotent: the input lives inside
    // phx-update="ignore", so on most patches it is the same node and this is a
    // no-op — but it is a *different* node once the picker goes from an empty
    // state to having sections, and an unbound box is worse than no box at all
    // (it filters nothing, and its keystrokes reach the form's phx-change).
    bind() {
      const input = this.el.querySelector("[data-tag-filter-input]")
      if (input === this.input) return

      this.unbind()
      this.input = input
      if (!input) return

      // stopPropagation is load-bearing, not tidiness: LiveView binds `change`
      // on the *form* and gates only on "is this a form-associated element",
      // never on `name`. Without this the filter box pushes `validate` on every
      // keystroke, which marks the document dirty and schedules a real draft
      // autosave — a DB write and a paper-trail version for a search box.
      //
      // The query itself is a server round-trip (#1149): the mount window is
      // capped, so filtering in the DOM would only ever search the page it has.
      this.onInput = e => {
        e.stopPropagation()
        if (this.timer) clearTimeout(this.timer)
        this.timer = setTimeout(() => {
          this.pushEvent("filter_tags", {q: e.target.value})
        }, 300)
      }
      input.addEventListener("input", this.onInput)
      // Same reason, for the blur-time `change` event.
      this.onChange = e => e.stopPropagation()
      input.addEventListener("change", this.onChange)
      // Enter in a search field would otherwise submit the whole content form.
      this.onKey = e => {
        if (e.key === "Enter") e.preventDefault()
      }
      input.addEventListener("keydown", this.onKey)
    },

    unbind() {
      if (!this.input) return
      this.input.removeEventListener("input", this.onInput)
      this.input.removeEventListener("change", this.onChange)
      this.input.removeEventListener("keydown", this.onKey)
      this.input = null
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
      // (mirrors the ⌘K palette guard so it never hijacks text entry). Only the
      // instance flagged data-inserter-global owns the shortcut, so the inline
      // per-block "+" copies (B2) don't all open at once on "/".
      if (this.el.dataset.inserterGlobal === "true") {
        this.onDocKey = e => {
          if (e.key !== "/" || this.isOpen()) return
          const t = e.target
          const tag = (t.tagName || "").toLowerCase()
          if (tag === "input" || tag === "textarea" || t.isContentEditable) return
          e.preventDefault()
          this.open()
        }
        document.addEventListener("keydown", this.onDocKey)
      }
    },

    destroyed() {
      document.removeEventListener("click", this.onDocClick)
      if (this.onDocKey) document.removeEventListener("keydown", this.onDocKey)
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

  // Drag-to-reorder for one level of the navigation menu tree (#466). Unlike
  // `Sortable`, each list reports which parent it belongs to — a menu renders
  // one list per level, so a bare "reorder" would be ambiguous. Depth changes
  // are the indent/outdent buttons, not the drag: dropping *into* a sibling is
  // hard to hit and impossible with a keyboard, and this tree is the site's
  // navigation.
  MenuSortable: {
    mounted() {
      this.sorter = Sortable.create(this.el, {
        animation: 150,
        handle: "[data-drag-handle]",
        ghostClass: "opacity-40",
        onEnd: () => {
          const order = Array.from(this.el.children)
            .map(c => c.dataset.sortId)
            .filter(id => id !== undefined)
          this.pushEvent("reorder_items", {parent_id: this.el.dataset.parentId || "", order})
        },
      })
    },
    destroyed() {
      this.sorter && this.sorter.destroy()
    },
  },

  // Nested drag-and-drop for a `columns` block's children (#335): one Sortable
  // per column list, all sharing a group so a child can be dragged within a
  // column or across into a sibling column of the same block. On any drop it
  // reports the full new structure — the ordered child ids of every column — so
  // the server rebuilds the tree authoritatively (LiveView then reconciles the
  // DOM back to the server-rendered order, keying on each child's stable id).
  NestedBlockSortable: {
    mounted() {
      this.init()
    },
    updated() {
      // Re-init so a newly added/removed column list gets (or drops) its sorter.
      this.destroySorters()
      this.init()
    },
    destroyed() {
      this.destroySorters()
    },
    init() {
      const blockId = this.el.dataset.blockId
      const group = `nested-cols-${blockId}`
      this.sorters = Array.from(this.el.querySelectorAll("[data-col-list]")).map(list =>
        Sortable.create(list, {
          group,
          animation: 150,
          handle: "[data-child-handle]",
          ghostClass: "opacity-40",
          onEnd: () => {
            const cols = Array.from(this.el.querySelectorAll("[data-col-list]")).map(col =>
              Array.from(col.querySelectorAll("[data-child-id]")).map(c => c.dataset.childId),
            )
            this.pushEvent("col_reorder", {id: blockId, cols})
          },
        }),
      )
    },
    destroySorters() {
      ;(this.sorters || []).forEach(s => s.destroy())
      this.sorters = []
    },
  },

  // Drag-to-reorder for a gallery block's images (#482). A single list, so it
  // needs neither the shared group of NestedBlockSortable nor its re-init on
  // update — but it does report the full new order rather than a delta, for the
  // same reason: the server rebuilds the list authoritatively and LiveView
  // reconciles the DOM back to the server-rendered order.
  //
  // Dragging is an enhancement, not the mechanism: each row also carries move
  // up/down buttons that push the same reorder through the keyboard, so a
  // pointer is never the only way to reorder a gallery.
  GallerySortable: {
    mounted() {
      const blockId = this.el.dataset.blockId
      this.sorter = Sortable.create(this.el, {
        animation: 150,
        handle: "[data-image-handle]",
        ghostClass: "opacity-40",
        onEnd: () => {
          const order = Array.from(this.el.querySelectorAll("[data-image-row]")).map(
            row => row.dataset.imageRow,
          )
          this.pushEvent("gallery_reorder", {bid: blockId, order})
        },
      })
    },
    destroyed() {
      this.sorter && this.sorter.destroy()
    },
  },

  // Drag-and-keyboard rescheduling on the editorial calendar's month/week grid.
  //
  // One hook on the whole grid rather than one per day: the day cells are drop
  // targets for each other, so they have to share a Sortable group, and a hook
  // per cell would create and destroy forty-two of them on every month change.
  //
  // Both paths end in the same server event with the same payload — the target
  // DATE, computed here. The alternative (drag sends a date, keys send a delta)
  // is two payload shapes into one handler, which is how a guard clause ends up
  // silently not matching one of them.
  //
  // Only chips marked `data-reschedulable` move. A go-live that already
  // happened is history, and a review-due date is derived from an attestation
  // and a cadence — there is no honest way to drag it without falsifying one of
  // them, so it stays put and offers "Mark reviewed" instead.
  //
  // That attribute lives on the cell's <li>, and `draggable` below depends on
  // it staying there: Sortable matches the selector against the list's DIRECT
  // CHILDREN, so moving it back down onto the <a> stops every drag from
  // starting — with no error, because "nothing is draggable" is a legitimate
  // state. `e2e/tests/calendar_drag.spec.js` is what notices.
  CalendarDrag: {
    mounted() {
      this.sorters = []
      this.setup()
      // Arrow keys move a focused chip: ←/→ by a day, ↑/↓ by a week, which is
      // what the grid's own geometry implies. Delegated on the container so it
      // survives LiveView patching the cells underneath.
      this.onKeyDown = e => this.nudge(e)
      this.el.addEventListener("keydown", this.onKeyDown)
    },

    updated() {
      this.setup()
    },

    destroyed() {
      this.el.removeEventListener("keydown", this.onKeyDown)
      this.teardown()
    },

    teardown() {
      this.sorters.forEach(s => s.destroy())
      this.sorters = []
    },

    setup() {
      this.teardown()

      this.el.querySelectorAll("[data-calendar-drop]").forEach(list => {
        this.sorters.push(
          Sortable.create(list, {
            group: "calendar",
            animation: 150,
            draggable: "[data-reschedulable]",
            ghostClass: "opacity-40",
            onEnd: evt => {
              const date = evt.to.dataset.calendarDrop
              // Dropped back where it started — nothing moved, so don't write.
              if (!date || date === evt.from.dataset.calendarDrop) return
              this.reschedule(evt.item, date)
            },
          }),
        )
      })
    },

    nudge(e) {
      const chip = e.target.closest("[data-reschedulable]")
      if (!chip) return

      const days = {ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7}[e.key]
      if (days === undefined) return

      // The chip is a link; arrows would otherwise scroll the page under it.
      e.preventDefault()

      const from = chip.dataset.eventDate
      if (!from) return

      // Parse as UTC noon, not midnight: adding days to a midnight Date drifts
      // across a DST boundary in local time and lands on the wrong day.
      const at = new Date(`${from}T12:00:00Z`)
      at.setUTCDate(at.getUTCDate() + days)
      this.reschedule(chip, at.toISOString().slice(0, 10))
    },

    reschedule(chip, date) {
      this.pushEvent("reschedule", {
        id: chip.dataset.eventId,
        type: chip.dataset.eventType,
        kind: chip.dataset.eventKind,
        date: date,
      })
    },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
  dom: {
    // <details> open/closed is client-side state the server template doesn't
    // track, so a patch (e.g. the editor's per-keystroke validate) would reset
    // every accordion to its rendered default. Keep the user's toggle unless
    // the *server-rendered* value itself changed — that still lets the server
    // force a section open (e.g. "Custom fields" when it gains errors).
    // `data-server-open` (last seen server value) is seeded by the document
    // "toggle" listener below and kept current here.
    onBeforeElUpdated(from, to) {
      // The advisory click-to-locate marks (assets/js/advisory_jump.js) are
      // client-side classes on server-rendered elements — the block card, an
      // alt input — and the very act of landing on one triggers a patch
      // (BlockPresence reports the focus; a sidebar field pushes
      // `field_focus`) that would otherwise strip them the instant they
      // appeared. Carry them across; the module removes them itself.
      for (const cls of ["kiln-issue-mark", "kiln-focus-pulse"]) {
        if (from.classList.contains(cls)) to.classList.add(cls)
      }
      if (from.tagName === "DETAILS") {
        const serverOpen = to.hasAttribute("open")
        const prevServerOpen = from.dataset.serverOpen
        if (prevServerOpen !== undefined && (prevServerOpen === "true") === serverOpen) {
          to.toggleAttribute("open", from.open)
        }
        to.dataset.serverOpen = String(serverOpen)
      }
    },
  },
})

// First-toggle seed for the <details> preservation above: before any patch has
// stamped data-server-open, a user toggle means the pre-toggle state was the
// server-rendered one. "toggle" doesn't bubble, so listen in capture phase.
document.addEventListener(
  "toggle",
  e => {
    const el = e.target
    if (el.tagName === "DETAILS" && el.dataset.serverOpen === undefined) {
      el.dataset.serverOpen = String(!el.open)
    }
  },
  true
)

// Clicking a finding in the editor's advisory panels scrolls to and
// highlights what it is about — see assets/js/advisory_jump.js.
initAdvisoryJump()

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

// Passkey sign-in affordance on /sign-in (#331) — progressive enhancement,
// no-op on other pages and on browsers without WebAuthn.
initPasskeySignIn()

// Installable editor PWA (#65). Gated on the manifest link, which the root
// layout emits only for authorised editors/admins — so a public reader browsing
// delivered content never registers a service worker. Failure is silent by
// design: the worker only adds an offline fallback and the install prompt, and
// neither is worth a console error on a browser that refuses (private mode,
// disabled storage, insecure origin).
if ("serviceWorker" in navigator && document.querySelector('link[rel="manifest"]')) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {})
  })
}

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

