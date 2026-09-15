// Info flashes ("You are now signed in", "Saved.") close on their own; error
// flashes do not carry this hook and stay until closed. The flash component
// (`KilnCMSWeb.CoreComponents.flash/1`) attaches it for `kind={:info}` only.
//
// Closing runs the element's own `phx-click` — `JS.push("lv:clear-flash")`
// plus the hide transition — so a timed close and a clicked close are the same
// code path and the server's flash is cleared either way.
//
// The clock pauses while the pointer is over the flash or focus is inside it
// (someone reading it, or about to click it) and restarts in full when they
// leave. Under prefers-reduced-motion the element is hidden at once instead of
// animating out.

const DISMISS_MS = 5000

export const FlashAutoDismiss = {
  mounted() {
    this.hovered = false
    this.focused = false
    this.message = this.el.textContent

    this.onEnter = () => { this.hovered = true; this.stop() }
    this.onLeave = () => { this.hovered = false; this.start() }
    this.onFocusIn = () => { this.focused = true; this.stop() }
    this.onFocusOut = e => {
      if (this.el.contains(e.relatedTarget)) return
      this.focused = false
      this.start()
    }

    this.el.addEventListener("mouseenter", this.onEnter)
    this.el.addEventListener("mouseleave", this.onLeave)
    this.el.addEventListener("focusin", this.onFocusIn)
    this.el.addEventListener("focusout", this.onFocusOut)
    this.start()
  },

  // A second info flash can reuse this element (same id) without remounting —
  // give the new message its own full five seconds.
  updated() {
    if (this.el.textContent !== this.message) {
      this.message = this.el.textContent
      this.start()
    }
  },

  destroyed() {
    this.stop()
  },

  start() {
    this.stop()
    if (this.hovered || this.focused || this.el.hidden) return
    this.timer = setTimeout(() => this.dismiss(), DISMISS_MS)
  },

  stop() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  },

  dismiss() {
    const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
    if (reduce) this.el.style.display = "none"
    const js = this.el.getAttribute("phx-click")
    if (js) this.liveSocket.execJS(this.el, js)
  },
}
