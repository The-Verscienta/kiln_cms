// The human-verification hook (#2249) against a fake window and document.
// Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"

import {mountChallenge, loadScript, mountAll, holdSubmitForToken} from "../js/challenge.js"

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

// ── public forms (#2249) ────────────────────────────────────────────────────

// A form element that records listeners and re-submits.
function fakeForm() {
  const listeners = []
  const form = {
    dataset: {},
    submitted: [],
    addEventListener: (type, fn) => listeners.push({type, fn}),
    requestSubmit(submitter) {
      form.submitted.push(submitter)
      // A real requestSubmit fires the submit event again.
      return fire(form)
    },
  }
  form.listeners = listeners
  return form
}

function fire(form, submitter) {
  const event = {
    submitter,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  for (const {type, fn} of form.listeners) if (type === "submit") fn(event)
  return event
}

function formWidget(form, data = {}) {
  const widget = fakeWidget({waitingText: "Finishing", ...data})
  widget.el.closest = (selector) => (selector === "form" ? form : null)
  return widget
}

// Timers the test runs by hand.
function fakeTimers() {
  const queue = []
  return {
    setTimeout: (fn) => queue.push(fn),
    run() {
      while (queue.length) queue.shift()()
    },
    queue,
  }
}

test("mountAll mounts each public-form widget once", async () => {
  const api = fakeApi()
  const win = {g8: api}
  const form = fakeForm()
  const {el} = formWidget(form, {global: "g8"})
  el.dataset.kilnChallenge = ""
  const root = {querySelectorAll: () => [el]}

  assert.equal(mountAll(root, {win, doc: fakeDocument()}).length, 1)
  assert.equal(el.dataset.kilnChallengeMounted, "true")
  assert.equal(mountAll(root, {win, doc: fakeDocument()}).length, 0, "already mounted")

  await tick()
  assert.equal(api.calls.render.length, 1)
  assert.equal(api.calls.render[0].options.action, "sign_in")
  assert.equal(form.listeners.length, 1, "one submit guard")
})

test("a submit with a token goes straight through", () => {
  const form = fakeForm()
  const {el, parts} = formWidget(form)
  parts["challenge-token"].value = "tok"
  holdSubmitForToken(el, {win: fakeTimers()})

  assert.equal(fire(form).defaultPrevented, false)
})

test("a submit without a token waits for one, then submits once", () => {
  const timers = fakeTimers()
  const form = fakeForm()
  const {el, parts} = formWidget(form)
  holdSubmitForToken(el, {win: timers, waitMs: 60_000})

  const button = {name: "send"}
  assert.equal(fire(form, button).defaultPrevented, true)
  assert.equal(parts["challenge-status"].textContent, "Finishing")
  assert.equal(form.submitted.length, 0)

  parts["challenge-token"].value = "late-token"
  timers.run()

  assert.deepEqual(form.submitted, [button])
  assert.equal(form.dataset.kilnChallengeSubmitting, undefined, "flag cleared after the re-fire")
})

test("a later submit without a token waits again (Back, or a blocked re-request)", () => {
  const timers = fakeTimers()
  const form = fakeForm()
  const {el, parts} = formWidget(form)
  holdSubmitForToken(el, {win: timers, waitMs: 60_000})

  fire(form)
  parts["challenge-token"].value = "tok"
  timers.run()
  assert.equal(form.submitted.length, 1)

  parts["challenge-token"].value = ""
  assert.equal(fire(form).defaultPrevented, true, "held again")
  assert.equal(timers.queue.length, 1)
})

test("the re-fired submit passes the guard, so it can never wait on itself", () => {
  const timers = fakeTimers()
  const form = fakeForm()
  const {el} = formWidget(form)
  holdSubmitForToken(el, {win: timers, waitMs: 0})

  assert.equal(fire(form).defaultPrevented, true)
  timers.run()

  // Submitted once, and the re-fired event was not held again.
  assert.equal(form.submitted.length, 1)
  assert.equal(timers.queue.length, 0)
})

test("past the wait it submits anyway, without a token", () => {
  const timers = fakeTimers()
  const form = fakeForm()
  const {el, parts} = formWidget(form)
  holdSubmitForToken(el, {win: timers, waitMs: 0})

  fire(form)
  timers.run()

  assert.equal(form.submitted.length, 1)
  assert.equal(parts["challenge-token"].value, "")
})

test("a widget that already failed does not hold the submit", () => {
  const form = fakeForm()
  const {el, parts} = formWidget(form)
  parts["challenge-fallback"].hidden = false
  holdSubmitForToken(el, {win: fakeTimers()})

  assert.equal(fire(form).defaultPrevented, false)
})

test("a form whose submit cannot be re-requested falls back to submit()", () => {
  const timers = fakeTimers()
  const form = fakeForm()
  form.requestSubmit = undefined
  form.submit = () => form.submitted.push("submit()")
  const {el} = formWidget(form)
  holdSubmitForToken(el, {win: timers, waitMs: 0})

  fire(form)
  timers.run()
  assert.deepEqual(form.submitted, ["submit()"])
})

test("a second click while waiting does not submit twice", () => {
  const timers = fakeTimers()
  const form = fakeForm()
  const {el, parts} = formWidget(form)
  holdSubmitForToken(el, {win: timers, waitMs: 60_000})

  assert.equal(fire(form).defaultPrevented, true)
  assert.equal(fire(form).defaultPrevented, true)
  assert.equal(timers.queue.length, 1, "one wait")

  parts["challenge-token"].value = "tok"
  timers.run()
  assert.equal(form.submitted.length, 1)
})

test("a page restored from the back/forward cache drops its spent token", async () => {
  const api = fakeApi()
  api.resets = []
  api.reset = (id) => api.resets.push(id)
  const handlers = {}
  const win = {
    g9: api,
    addEventListener: (type, fn) => (handlers[type] = fn),
    removeEventListener: (type) => delete handlers[type],
  }
  const {el, parts} = fakeWidget({global: "g9"})
  const challenge = mountChallenge(el, {win, doc: fakeDocument()})
  await tick()

  parts["challenge-token"].value = "spent"
  handlers.pageshow({persisted: false})
  assert.equal(parts["challenge-token"].value, "spent", "an ordinary load keeps it")

  handlers.pageshow({persisted: true})
  assert.equal(parts["challenge-token"].value, "")
  assert.equal(api.resets.length, 1)

  challenge.destroy()
  assert.equal(handlers.pageshow, undefined)
})
