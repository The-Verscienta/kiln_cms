// Bring a required custom field into view when the browser refuses a save
// over it (#2280).
//
// A field in an unselected tab or a collapsed accordion section of the
// content editor's Custom fields panel is only hidden, so it still submits —
// and, when it is `required` and empty, still blocks the submit. The browser
// then wants to point at it, but a control inside `display: none` cannot be
// focused: Chrome logs "An invalid form control is not focusable" and the
// Save button just seems to do nothing.
//
// So on the first `invalid` event of a submit (it does not bubble; this
// listens in the capture phase on the document) the tab or section holding
// the control is shown before the browser looks for it. Shown twice over:
// an inline `display` at once, because LiveView applies JS commands' class
// changes on the next animation frame, after the browser has already
// given up on the control; and through the same JS commands a click would
// run (`liveSocket.execJS` / `liveSocket.js()`), because LiveView re-applies
// those after every patch and drops any other client-side change, so the
// next keystroke's patch would fold the section shut again.
//
// One delegated listener on the document, like reveal_section.js: the panel
// re-renders on every keystroke, and a document listener needs no hook.

const TAB_PANEL = "[data-cf-tab-panel]"
const SECTION_BODY = "[data-cf-section-body]"

export function initRevealInvalidField(liveSocket, root = document) {
  let busy = false
  root.addEventListener(
    "invalid",
    e => {
      // A submit fires `invalid` at every failing control, in order; the
      // browser reports the first, so only its home is opened.
      if (busy) return
      busy = true
      setTimeout(() => { busy = false }, 0)
      reveal(liveSocket, e.target)
    },
    true
  )
}

function reveal(liveSocket, control) {
  if (!control || typeof control.closest !== "function") return

  const panel = control.closest(TAB_PANEL)
  if (panel && panel.classList.contains("hidden")) {
    const tab = document.getElementById(panel.getAttribute("aria-labelledby"))
    if (!tab) return
    liveSocket.execJS(tab, tab.getAttribute("phx-click"))
    showNow(panel)
    return
  }

  const body = control.closest(SECTION_BODY)
  if (body && body.classList.contains("hidden")) {
    const toggle = document.querySelector(`[aria-controls="${body.id}"]`)
    const js = liveSocket.js()
    js.removeClass(body, "hidden")
    if (toggle) js.setAttribute(toggle, "aria-expanded", "true")
    showNow(body)
  }
}

// Visible for the browser's own validation report, which runs before the
// next frame; the inline style is dropped once the JS command's class change
// has landed (frames run their callbacks in the order they were asked for).
function showNow(el) {
  el.style.display = "block"
  requestAnimationFrame(() => el.style.removeProperty("display"))
}
