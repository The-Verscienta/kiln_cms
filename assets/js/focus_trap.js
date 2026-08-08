// Focus and Escape for modal dialogs / drawers (#169, #693).
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
// Opt in with `data-close-event` on the panel; without it Escape does nothing,
// which is right for a dialog that must be dismissed deliberately.
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), ' +
  'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

export const FocusTrap = {
  mounted() {
    this._opener = document.activeElement

    this._onKeydown = e => {
      if (e.key === "Escape") {
        const event = this.el.dataset.closeEvent
        if (!event) return
        e.preventDefault()
        // Nothing above this dialog should also act on the press.
        e.stopPropagation()
        this.pushEvent(event)
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

    this.el.addEventListener("keydown", this._onKeydown)

    // Move focus into the dialog (first focusable, else the panel itself).
    const items = this.focusable()
    ;(items[0] || this.el).focus()
  },

  focusable() {
    return Array.from(this.el.querySelectorAll(FOCUSABLE)).filter(
      el => el.offsetParent !== null || el === document.activeElement,
    )
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
    // Restore focus to whatever opened the dialog, if it's still around.
    if (this._opener && typeof this._opener.focus === "function") {
      this._opener.focus()
    }
  },
}
