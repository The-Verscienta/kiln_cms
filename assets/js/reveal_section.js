// Bring a section of the page into view after the click that asks for it has
// been answered by the server. A trigger carries `data-kiln-reveal="<id>"`
// alongside its ordinary `phx-click`; the click still does whatever the server
// does with it (the editor's a11y chip switches the inspector to Settings), and
// this module then waits for `<id>` to be in the document and rendered, opens
// any `<details>` around it, scrolls it into view and moves focus to it — so a
// keyboard user lands on the section rather than back on the button.
//
// Waiting is the point: when the inspector is showing Preview or History, the
// Settings panel (and the section inside it) does not exist until the server
// has patched it in, so a lookup at click time would find nothing.
//
// One delegated listener on the document, like advisory_jump.js: the chip
// re-renders on every keystroke, and a document listener needs no stable hook.

const PULSE_CLASS = "kiln-focus-pulse"
const PULSE_MS = 1600
const WAIT_MS = 3000

export function initRevealSection(root = document) {
  root.addEventListener("click", e => {
    const trigger = e.target.closest("[data-kiln-reveal]")
    if (!trigger) return
    revealWhenReady(trigger.dataset.kilnReveal)
  })
}

export function revealWhenReady(id, deadline = performance.now() + WAIT_MS) {
  const target = document.getElementById(id)
  if (target && rendered(target)) return reveal(target)
  if (performance.now() > deadline) return false
  requestAnimationFrame(() => revealWhenReady(id, deadline))
  return null
}

function rendered(el) {
  return el.getClientRects().length > 0 || el.closest("details:not([open])") !== null
}

function reveal(target) {
  for (let d = target.closest("details"); d; d = d.parentElement.closest("details")) {
    d.open = true
  }

  const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
  target.scrollIntoView({behavior: reduce ? "auto" : "smooth", block: "start"})

  // A <section> is not focusable by default; -1 makes it a focus target without
  // adding it to the tab order. A later patch may drop the attribute, which is
  // harmless once focus has landed.
  if (!target.hasAttribute("tabindex")) target.setAttribute("tabindex", "-1")
  target.focus({preventScroll: true})

  if (!reduce) {
    target.classList.remove(PULSE_CLASS)
    void target.offsetWidth
    target.classList.add(PULSE_CLASS)
    setTimeout(() => target.classList.remove(PULSE_CLASS), PULSE_MS)
  }
  return true
}
