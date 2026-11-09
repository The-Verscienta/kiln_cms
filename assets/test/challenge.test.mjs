// The human-verification hook (#2249) against a fake window and document.
// Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"

import {mountChallenge, loadScript} from "../js/challenge.js"

// Element stand-ins: just what the hook touches.
function fakeWidget(data) {
  const parts = {
    "challenge-token": {value: ""},
    "challenge-widget": {},
    "challenge-status": {textContent: ""},
    "challenge-fallback": {hidden: true},
  }
  return {
    parts,
    el: {
      dataset: {
        scriptUrl: "https://challenge.test/api.js?render=explicit",
        global: "fakeChallenge",
        sitekey: "site-key",
        action: "sign_in",
        loadingText: "Loading",
        solvedText: "Done",
        expiredText: "Expired",
        errorText: "Could not load",
        ...data,
      },
      querySelector: (selector) => parts[selector.match(/'([^']+)'/)[1]],
    },
  }
}

// A document whose <script> tags "load" when the test says so.
function fakeDocument() {
  const scripts = []
  return {
    scripts,
    createElement: () => ({}),
    head: {appendChild: (script) => scripts.push(script)},
  }
}

const tick = () => new Promise((resolve) => setImmediate(resolve))

function fakeApi() {
  const calls = {render: [], remove: []}
  return {
    calls,
    render(box, options) {
      calls.render.push({box, options})
      return "widget-1"
    },
    remove(id) {
      calls.remove.push(id)
    },
  }
}

test("loads the script once, draws the widget and fills the token", async () => {
  const win = {}
  const doc = fakeDocument()
  const api = fakeApi()
  const {el, parts} = fakeWidget({scriptUrl: "https://challenge.test/a.js", global: "g1"})

  mountChallenge(el, {win, doc})
  mountChallenge(fakeWidget({scriptUrl: "https://challenge.test/a.js", global: "g1"}).el, {win, doc})
  assert.equal(doc.scripts.length, 1, "one script for two widgets")
  assert.equal(doc.scripts[0].src, "https://challenge.test/a.js")

  win.g1 = api
  doc.scripts[0].onload()
  await tick()

  assert.equal(api.calls.render.length, 2)
  const {options} = api.calls.render[0]
  assert.equal(options.sitekey, "site-key")
  assert.equal(options.action, "sign_in")
  assert.equal(options["response-field"], false)

  options.callback("the-token")
  assert.equal(parts["challenge-token"].value, "the-token")
  assert.equal(parts["challenge-status"].textContent, "Done")

  options["expired-callback"]()
  assert.equal(parts["challenge-token"].value, "", "an expired token is cleared")
})

test("a script that cannot load shows the fallback and no token", async () => {
  const win = {}
  const doc = fakeDocument()
  const {el, parts} = fakeWidget({scriptUrl: "https://challenge.test/b.js", global: "g2"})

  mountChallenge(el, {win, doc})
  doc.scripts[0].onerror()
  await tick()

  assert.equal(parts["challenge-fallback"].hidden, false)
  assert.equal(parts["challenge-status"].textContent, "Could not load")
  assert.equal(parts["challenge-token"].value, "")

  // Forgotten, so a later widget tries again.
  mountChallenge(fakeWidget({scriptUrl: "https://challenge.test/b.js", global: "g2"}).el, {win, doc})
  assert.equal(doc.scripts.length, 2)
})

test("a widget error clears the token and shows the fallback", async () => {
  const api = fakeApi()
  const win = {g3: api}
  const {el, parts} = fakeWidget({global: "g3"})

  mountChallenge(el, {win, doc: fakeDocument()})
  await tick()

  const {options} = api.calls.render[0]
  options.callback("t")
  assert.equal(options["error-callback"](), true)
  assert.equal(parts["challenge-token"].value, "")
  assert.equal(parts["challenge-fallback"].hidden, false)
})

test("destroy removes the drawn widget, and a destroyed one never draws", async () => {
  const api = fakeApi()
  const win = {g4: api}

  const drawn = mountChallenge(fakeWidget({global: "g4"}).el, {win, doc: fakeDocument()})
  await tick()
  drawn.destroy()
  assert.deepEqual(api.calls.remove, ["widget-1"])

  const doc = fakeDocument()
  const pending = mountChallenge(
    fakeWidget({scriptUrl: "https://challenge.test/c.js", global: "g5"}).el,
    {win: {}, doc}
  )
  pending.destroy()
  doc.scripts[0].onload()
  await tick()
  assert.equal(api.calls.render.length, 1)
})

test("a hidden widget waits until it is visible", async () => {
  const api = fakeApi()
  let observed
  const win = {
    g6: api,
    IntersectionObserver: class {
      constructor(callback) {
        this.callback = callback
        observed = this
      }
      observe() {}
      disconnect() {
        this.disconnected = true
      }
    },
  }

  mountChallenge(fakeWidget({global: "g6"}).el, {win, doc: fakeDocument()})
  await tick()
  assert.equal(api.calls.render.length, 0, "nothing drawn while hidden")

  observed.callback([{isIntersecting: true}])
  await tick()
  assert.equal(api.calls.render.length, 1)
  assert.equal(observed.disconnected, true)
})

test("loadScript resolves at once when the global is already there", async () => {
  const api = fakeApi()
  assert.equal(await loadScript("https://x.test/a.js", "g7", {g7: api}, fakeDocument()), api)
})
