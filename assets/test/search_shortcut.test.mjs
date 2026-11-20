// The ⌘K / Ctrl-K shortcut (#139, shared with public.js by #2402) against a
// fake window. Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"

import {onSearchShortcut, initSearchShortcut, SEARCH_PATH} from "../js/search_shortcut.js"

function fakeWindow({pathname = "/blog", link = null} = {}) {
  const listeners = []
  return {
    location: {pathname, href: pathname},
    document: {getElementById: id => (id === "cmdk-search-link" ? link : null)},
    addEventListener: (type, fn) => listeners.push([type, fn]),
    listeners,
  }
}

function keydown({key = "k", metaKey = false, ctrlKey = true, target = {tagName: "BODY"}} = {}) {
  return {
    key,
    metaKey,
    ctrlKey,
    target,
    prevented: false,
    preventDefault() {
      this.prevented = true
    },
  }
}

test("with no in-page link it loads the search page", () => {
  const win = fakeWindow()
  const e = keydown()
  onSearchShortcut(e, win)
  assert.equal(win.location.href, SEARCH_PATH)
  assert.ok(e.prevented)
})

test("with the in-page link it clicks it instead", () => {
  let clicked = 0
  const win = fakeWindow({link: {click: () => clicked++}})
  onSearchShortcut(keydown({metaKey: true, ctrlKey: false, key: "K"}), win)
  assert.equal(clicked, 1)
  assert.equal(win.location.href, "/blog")
})

test("typing in a field, a plain k, or already on the page does nothing", () => {
  for (const [e, win] of [
    [keydown({target: {tagName: "INPUT"}}), fakeWindow()],
    [keydown({target: {tagName: "TEXTAREA"}}), fakeWindow()],
    [keydown({target: {tagName: "DIV", isContentEditable: true}}), fakeWindow()],
    [keydown({ctrlKey: false}), fakeWindow()],
    [keydown(), fakeWindow({pathname: SEARCH_PATH})],
  ]) {
    const before = win.location.href
    onSearchShortcut(e, win)
    assert.equal(win.location.href, before)
    assert.equal(e.prevented, false)
  }
})

test("initSearchShortcut listens for keydown on the window", () => {
  const win = fakeWindow()
  initSearchShortcut(win)
  assert.deepEqual(
    win.listeners.map(([type]) => type),
    ["keydown"],
  )
  win.listeners[0][1](keydown())
  assert.equal(win.location.href, SEARCH_PATH)
})
