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
// So there is a second listener, on `document`, and it stands down unless the
// press belongs to it: focus must be inside **no** panel (otherwise that
// panel's own listener has it — including when the person is in an older dialog
// while a newer one is open), the press must not already be handled, and this
// trap must be the innermost one open.
//
// "Innermost" is decided by DOM position, not mount order. Mount order looks
// equivalent and is not: within one LiveView patch, added hooks mount during
// `patch.perform()` while discarded ones are torn down afterwards, so
// re-rendering an *outer* dialog while an inner one is open would leave the
// outer mounted last and let Escape close the parent out from under the child.
//
// ## Why focus is not dragged back
//
// The obvious companion — recapture focus on `focusout` — is deliberately not
// here. A native `<select>` blurs its element while its dropdown is open in some
// browsers, so a recapture would close the dropdown the person just opened.
// `relatedTarget` is `null` when focus lands on `<body>`, which is the case
// worth handling, so the two cannot be told apart.
//
// That trade is not free, and the honest statement of what it costs: in those
// same browsers, an Escape meant for an open dropdown reaches `document` with
// focus on `<body>` and closes the dialog instead. No `<.modal>` in the tree
// contains a `<select>` today, so neither failure is currently reachable — but
// whichever way this is resolved, it is one control's behaviour, while Escape
// being dead everywhere was every keyboard user's.
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), ' +
  'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

// Every mounted trap. Module-level so the document listener can tell which
// dialog a press belongs to; `destroyed()` removes, so it cannot leak.
const traps = new Set()

// The innermost open dialog: the one no other panel contains. Falls back to the
// last in document order, which is where a sibling overlay renders.
//
// `isConnected` is the load-bearing part, not a tidy-up. `destroyed()` runs on a
// channel round-trip, so after live navigation a torn-down view's hook is still
// listening while its panel is already detached — and would otherwise answer for
// the page that replaced it, pushing a close event at a dead view and swallowing
// the press.
function innermost() {
  const open = [...traps].filter(trap => trap.el.isConnected)
  return open.reduce((deepest, trap) => {
    if (!deepest) return trap
    if (deepest.el.contains(trap.el)) return trap
    if (trap.el.contains(deepest.el)) return deepest
    // Siblings: later in the document is the one rendered on top.
    const after = deepest.el.compareDocumentPosition(trap.el)
    return after & Node.DOCUMENT_POSITION_FOLLOWING ? trap : deepest
  }, null)
}

export const FocusTrap = {
  mounted() {
    this._opener = document.activeElement
    traps.add(this)

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
      // Something else already handled this press: the TipTap slash menu, the
      // link prompt and the block-inserter search all `preventDefault()`
      // without stopping propagation, and all three live outside every panel,
      // so without this one Escape could dismiss a widget AND close the dialog.
      //
      // Defensive, and honestly so: none of those three is reachable with a
      // `<.modal>` open today (the scrim eats clicks and Tab is trapped), and
      // no test here distinguishes this line — the spec passes with and without
      // it. Kept because it is free and the class of bug is real; not claimed as
      // verified.
      if (e.defaultPrevented) return
      if (innermost() !== this) return
      if ([...traps].some(trap => trap.el.contains(document.activeElement))) return
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
    traps.delete(this)

    // Restore focus to whatever opened the dialog, if it's still around.
    if (this._opener && typeof this._opener.focus === "function") {
      this._opener.focus()
    }
  },
}
