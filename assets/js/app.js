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
import {Editor} from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"

// Drag-and-drop reordering for editor block lists. On drop it reads the new
// order of `data-sort-id`s and pushes a "reorder" event to the LiveView.
// TipTap rich-text editor for rich_text blocks. The editor's HTML is mirrored
// into a hidden input bound to the block's `content` form field, so it saves
// through the normal form submit.
const richTextButton = (editor, label, isActive, run) => {
  const b = document.createElement("button")
  b.type = "button"
  b.textContent = label
  b.className = "rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
  b.addEventListener("click", e => {
    e.preventDefault()
    run(editor.chain().focus()).run()
  })
  return b
}

const Hooks = {
  Clipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        navigator.clipboard
          .writeText(this.el.dataset.clipboardText || "")
          .then(() => this.pushEvent("copied", {}))
      })
    },
  },
  RichText: {
    mounted() {
      const input = this.el.querySelector("[data-input]")
      const editor = new Editor({
        element: this.el.querySelector("[data-editor]"),
        extensions: [StarterKit],
        content: this.el.dataset.content || "",
        onUpdate: ({editor}) => {
          input.value = editor.getHTML()
          // Debounced phx-change so the live preview reflects rich-text edits.
          clearTimeout(this._debounce)
          this._debounce = setTimeout(() => {
            input.dispatchEvent(new Event("input", {bubbles: true}))
          }, 300)
        },
      })
      this.editor = editor
      input.value = editor.getHTML()

      const toolbar = this.el.querySelector("[data-toolbar]")
      ;[
        ["B", c => c.toggleBold()],
        ["I", c => c.toggleItalic()],
        ["H2", c => c.toggleHeading({level: 2})],
        ["• List", c => c.toggleBulletList()],
        ["1. List", c => c.toggleOrderedList()],
        ["❝", c => c.toggleBlockquote()],
      ].forEach(([label, run]) => toolbar.appendChild(richTextButton(editor, label, null, run)))
    },
    destroyed() {
      this.editor && this.editor.destroy()
    },
  },
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

