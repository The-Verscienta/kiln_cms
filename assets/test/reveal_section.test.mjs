// The server-asked reveal (`/editor/backups?run=<id>` pushes `kiln:reveal`,
// #2875, #2933) against a fake window and document: the row is waited for,
// scrolled to and focused, and a `<details>` around it is opened.
// Run: `npm test` in assets/.
import {test, beforeEach, afterEach, mock} from "node:test"
import assert from "node:assert/strict"

import {initServerReveal} from "../js/reveal_section.js"

let frames
let elements
let now

beforeEach(() => {
  frames = []
  elements = {}
  now = 0
  mock.method(performance, "now", () => now)
  globalThis.requestAnimationFrame = (callback) => frames.push(callback)
  globalThis.document = {getElementById: (id) => elements[id] || null}
  globalThis.window = {matchMedia: () => ({matches: false})}
})

afterEach(() => {
  mock.restoreAll()
  mock.timers.reset()
  delete globalThis.requestAnimationFrame
  delete globalThis.document
  delete globalThis.window
})

// Runs the frames queued so far, `ms` apart; each may queue the next.
function runFrames(count, ms = 16) {
  for (let i = 0; i < count && frames.length > 0; i++) {
    now += ms
    const queued = frames
    frames = []
    for (const callback of queued) callback()
  }
}

// A `<details>` stand-in: `open` is what `rendered` and `reveal` read.
function fakeDetails(open = false) {
  return {tag: "details", open, parentElement: null}
}

// Just what `revealWhenReady` touches. `parent` is an enclosing `<details>`;
// a row inside a closed one has no client rects, as in a browser.
function fakeRow({parent = null, visible = true} = {}) {
  const classes = new Set()
  const attributes = {}
  return {
    calls: {scroll: [], focus: []},
    parentElement: parent,
    classes,
    attributes,
    offsetWidth: 0,
    getClientRects() {
      return visible ? [{}] : []
    },
    closest(selector) {
      for (let el = parent; el; el = el.parentElement) {
        if (el.tag !== "details") continue
        if (selector === "details") return el
        if (selector === "details:not([open])" && !el.open) return el
      }
      return null
    },
    hasAttribute: (name) => name in attributes,
    setAttribute: (name, value) => {
      attributes[name] = value
    },
    scrollIntoView(options) {
      this.calls.scroll.push(options)
    },
    focus(options) {
      this.calls.focus.push(options)
    },
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
    },
  }
}

// A window stand-in for `initServerReveal`: records the listener so a test
// can dispatch what LiveView would.
function fakeTarget() {
  const listeners = {}
  return {
    addEventListener: (name, listener) => {
      listeners[name] = listener
    },
    push: (detail) => listeners["phx:kiln:reveal"]({detail}),
  }
}

function serverReveal(detail) {
  const target = fakeTarget()
  initServerReveal(target)
  target.push(detail)
}

test("a row already on the page is scrolled to and focused at once", () => {
  const row = fakeRow()
  elements["backup-run-1"] = row

  serverReveal({id: "backup-run-1"})

  assert.deepEqual(row.calls.scroll, [{behavior: "smooth", block: "start"}])
  assert.deepEqual(row.calls.focus, [{preventScroll: true}])
  assert.equal(row.attributes.tabindex, "-1")
  assert.equal(frames.length, 0)
})

test("a row that keeps its own tabindex keeps it", () => {
  const row = fakeRow()
  row.attributes.tabindex = "0"
  elements["backup-run-1"] = row

  serverReveal({id: "backup-run-1"})

  assert.equal(row.attributes.tabindex, "0")
  assert.equal(row.calls.focus.length, 1)
})

test("a row that appears a few frames later is revealed then", () => {
  serverReveal({id: "backup-run-2"})
  runFrames(3)
  assert.equal(frames.length, 1, "still waiting")

  const row = fakeRow()
  elements["backup-run-2"] = row
  runFrames(1)

  assert.equal(row.calls.focus.length, 1)
  assert.equal(row.calls.scroll.length, 1)
  assert.equal(frames.length, 0)
})

test("a row in the document but not yet rendered is waited for", () => {
  const row = fakeRow({visible: false})
  elements["backup-run-3"] = row

  serverReveal({id: "backup-run-3"})
  assert.equal(row.calls.focus.length, 0)

  row.getClientRects = () => [{}]
  runFrames(1)

  assert.equal(row.calls.focus.length, 1)
})

test("a row that never appears is given up on after the wait", () => {
  serverReveal({id: "backup-run-missing"})

  // 3 s of 100 ms frames, and then some: the loop stops on its own.
  runFrames(40, 100)

  assert.equal(frames.length, 0)
  assert.ok(now <= 3200, `stopped at ${now} ms`)
})

for (const detail of [undefined, null, {}, {id: 42}, {id: null}, {id: ["backup-run-1"]}]) {
  test(`a push with no string id does nothing (${JSON.stringify(detail)})`, () => {
    const row = fakeRow()
    elements["backup-run-1"] = row
    let looked = false
    document.getElementById = () => {
      looked = true
      return row
    }

    serverReveal(detail)

    assert.equal(looked, false)
    assert.equal(row.calls.focus.length, 0)
    assert.equal(frames.length, 0)
  })
}

test("a closed <details> around the row is opened, and every one above it", () => {
  // `closest` includes the element itself, as in a browser; the page body
  // above the outer one is not a `<details>`.
  const outer = fakeDetails(false)
  const inner = fakeDetails(false)
  inner.parentElement = outer
  outer.parentElement = {closest: () => null}
  outer.closest = () => outer
  const row = fakeRow({parent: inner, visible: false})
  elements["backup-run-4"] = row

  serverReveal({id: "backup-run-4"})

  assert.equal(inner.open, true)
  assert.equal(outer.open, true)
  assert.equal(row.calls.focus.length, 1)
})

test("the row pulses, and the pulse is taken off again", () => {
  mock.timers.enable({apis: ["setTimeout"]})
  const row = fakeRow()
  elements["backup-run-5"] = row

  serverReveal({id: "backup-run-5"})
  assert.ok(row.classes.has("kiln-focus-pulse"))

  mock.timers.tick(1600)
  assert.ok(!row.classes.has("kiln-focus-pulse"))
})

test("with reduced motion: no smooth scroll and no pulse", () => {
  window.matchMedia = (query) => ({matches: query === "(prefers-reduced-motion: reduce)"})
  const row = fakeRow()
  elements["backup-run-6"] = row

  serverReveal({id: "backup-run-6"})

  assert.deepEqual(row.calls.scroll, [{behavior: "auto", block: "start"}])
  assert.deepEqual(row.calls.focus, [{preventScroll: true}])
  assert.equal(row.classes.size, 0)
})
