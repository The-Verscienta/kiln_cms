// Focus and Escape for modal dialogs / drawers (#169, #693, #1046).
//
// Attach with `phx-hook="FocusTrap"` on a panel that also carries
// `role="dialog" aria-modal="true" aria-labelledby="…" tabindex="-1"`. On mount
// it remembers the element that opened the dialog, moves focus inside, and traps
// Tab/Shift+Tab within the panel. On teardown (the LiveView removes the panel on
// close/Escape) it restores focus to the opener.
//
// Escape lives here rather than in a `phx-keydown` attribute, and it has to
// (#693). LiveView's key binding reads the attribute off the EXACT event target
// — `bind()` in phoenix_live_view.esm.js does `e.target.getAttribute(binding)`
// and does not walk ancestors — so `phx-keydown` on the panel never fires,
// because this hook has just moved focus to a button inside it. Only
// `phx-window-keydown` would fire, and that is the thing #693 is about: two open
// dialogs both bound to the window meant one Escape press dispatched two close
// events while two traps fought over focus.
//
// A plain listener on the panel gets the bubbled event from whichever descendant
// holds focus, and the dialogs are DOM siblings, so exactly one of them sees any
// given press — the one the person is actually in.
//
// ## Escape when focus is outside every panel (#1046)
//
// The panel listener only fires while `document.activeElement` is the panel or a
// descendant, and focus leaves for reasons that are nobody's fault: **Safari
// does not focus a `<button>` on click**, a LiveView patch can remove the
// focused node, browser chrome hands focus back to `<body>`. Escape then did
// nothing — a keyboard-accessibility regression against the `phx-window-keydown`
// this replaced.
//
// So there is a second listener, on `document`, and the reason it does not
// reintroduce the double-close #693 fixed is the `stack` below: it acts only for
// the most recently mounted trap, and only when focus is inside **no** panel. If
// focus is inside some dialog, that dialog's own listener has the press and this
// one stands down — including when the person is in an older dialog while a
// newer one is open, which is the case a "topmost wins" rule alone gets wrong.
//
// ## Why focus is not dragged back
//
// The obvious companion — recapture focus on `focusout` — is deliberately not
// here. A native `<select>` blurs its element while its dropdown is open in some
// browsers, so a recapture closes the dropdown the person just opened; the
// audience picker in the media drawer is exactly that shape. `relatedTarget` is
// `null` when focus lands on `<body>`, which is the case worth handling, so it
// cannot tell the two apart. Escape working from anywhere is the accessibility
// requirement; dragging focus around is not, and it breaks a control that works
// today.
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), ' +
  'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

// Mounted traps, innermost last. Module-level so the document listener can tell
// which dialog a press belongs to; `destroyed()` removes, so it cannot leak.
const stack = []

export const FocusTrap = {
  mounted() {
    this._opener = document.activeElement
    stack.push(this)

    this._onKeydown = e => {
      if (e.key === "Escape") {
        if (!this.close()) return
        e.preventDefault()
        // Nothing above this dialog should also act on the press.
        e.stopPropagation()
        return
      }

      if (e.key !== "Tab") return
      const items = this.focusable()
      if (items.length === 0) {
        e.preventDefault()
        this.el.focus()
        return
      }
      const first = items[0]
      const last = items[items.length - 1]
      const active = document.activeElement
      // Wrap focus at both ends, and pull stray focus back into the panel.
      if (e.shiftKey && (active === first || !this.el.contains(active))) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && (active === last || !this.el.contains(active))) {
        e.preventDefault()
        first.focus()
      }
    }

    // Only fires when the press reached `document` without passing through any
    // panel — i.e. focus is outside all of them.
    this._onDocumentKeydown = e => {
      if (e.key !== "Escape") return
      if (stack[stack.length - 1] !== this) return
      if (stack.some(trap => trap.el.contains(document.activeElement))) return
      if (this.close()) e.preventDefault()
    }

    this.el.addEventListener("keydown", this._onKeydown)
    document.addEventListener("keydown", this._onDocumentKeydown)

    // Move focus into the dialog (first focusable, else the panel itself).
    const items = this.focusable()
    ;(items[0] || this.el).focus()
  },

  // Push the close event if this dialog opted into one. Without
  // `data-close-event` Escape does nothing, which is right for a dialog that
  // must be dismissed deliberately. Returns whether it acted, so the caller
  // knows whether to swallow the press.
  close() {
    const event = this.el.dataset.closeEvent
    if (!event) return false
    this.pushEvent(event)
    return true
  },

  focusable() {
    return Array.from(this.el.querySelectorAll(FOCUSABLE)).filter(
      el => el.offsetParent !== null || el === document.activeElement,
    )
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
    document.removeEventListener("keydown", this._onDocumentKeydown)

    const at = stack.indexOf(this)
    if (at !== -1) stack.splice(at, 1)

    // Restore focus to whatever opened the dialog, if it's still around.
    if (this._opener && typeof this._opener.focus === "function") {
      this._opener.focus()
    }
  },
}
