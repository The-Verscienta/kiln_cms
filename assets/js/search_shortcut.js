// ⌘K / Ctrl-K opens the editor search palette from anywhere (no-op if already
// there). Skipped while typing in an input so it doesn't hijack the field.
// Prefer the hidden `navigate` link rendered in the app layout so connected
// LiveViews jump there without a full page reload (#139); fall back to a normal
// load when the link isn't present (e.g. public pages).
//
// Shared by app.js and public.js (#2402): a signed-out content page loads only
// the latter, and the shortcut still takes an editor reading the site to the
// console's search.
//
// Takes its window as an argument so `node --test`
// (assets/test/search_shortcut.test.mjs) can drive it without a browser.

export const SEARCH_PATH = "/editor/search"

export function onSearchShortcut(e, win = window) {
  if (!(e.metaKey || e.ctrlKey) || (e.key || "").toLowerCase() !== "k") return
  const tag = (e.target.tagName || "").toLowerCase()
  if (tag === "input" || tag === "textarea" || e.target.isContentEditable) return
  if (win.location.pathname === SEARCH_PATH) return
  e.preventDefault()
  const link = win.document.getElementById("cmdk-search-link")
  if (link) {
    link.click()
  } else {
    win.location.href = SEARCH_PATH
  }
}

export function initSearchShortcut(win = window) {
  win.addEventListener("keydown", e => onSearchShortcut(e, win))
}
