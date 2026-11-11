// The human-verification hook (#2249) against a fake window and document.
// Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"

import {
  mountChallenge,
  loadScript,
  mountAll,
  holdSubmitForToken,
  widgetSettings,
} from "../js/challenge.js"

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

// ── providers (#2249) ───────────────────────────────────────────────────────

// Timers a test fires by hand, with clearTimeout.
function manualTimers() {
  let next = 1
  const pending = new Map()
  return {
    setTimeout(fn) {
      const id = next++
      pending.set(id, fn)
      return id
    },
    clearTimeout(id) {
      pending.delete(id)
    },
    fireAll() {
      const fns = Array.from(pending.values())
      pending.clear()
      for (const fn of fns) fn()
    },
    pending,
  }
}

// reCAPTCHA's shape: render returns 0 for the first widget, and no remove.
function recaptchaApi() {
  const calls = {render: []}
  return {
    calls,
    render(box, options) {
      calls.render.push({box, options})
      return calls.render.length - 1
    },
    reset() {},
  }
}

const recaptchaData = (url) => ({
  scriptUrl: url,
  global: "grecaptcha",
  renderOptions: "{}",
  actionOption: "",
  onloadParam: "onload",
})

test("markup from before the provider attributes keeps Turnstile's behaviour", () => {
  assert.deepEqual(widgetSettings({}), {
    renderOptions: {"response-field": false},
    actionOption: "action",
    onloadParam: null,
  })

  assert.deepEqual(
    widgetSettings({renderOptions: "{\"theme\":\"dark\"}", actionOption: "", onloadParam: ""}),
    {renderOptions: {theme: "dark"}, actionOption: null, onloadParam: null}
  )

  assert.deepEqual(widgetSettings({renderOptions: "not json"}).renderOptions, {})
})

test("the provider's render options are passed, and the action only under its option", async () => {
  const api = fakeApi()
  const win = {p1: api}
  const {el} = fakeWidget({
    global: "p1",
    renderOptions: "{\"theme\":\"dark\",\"sitekey\":\"forged\"}",
    actionOption: "data-action",
    onloadParam: "",
  })

  mountChallenge(el, {win, doc: fakeDocument()})
  await tick()

  const {options} = api.calls.render[0]
  assert.equal(options.theme, "dark")
  assert.equal(options["data-action"], "sign_in")
  assert.equal(options.action, undefined)
  assert.equal(options.sitekey, "site-key", "ours win over the provider's")
  assert.equal(options["response-field"], undefined)
})

test("reCAPTCHA: waits for the onload callback, never for its stub global", async () => {
  const timers = manualTimers()
  const win = {...timers}
  const doc = fakeDocument()
  const url = "https://www.recaptcha.net/recaptcha/api.js?render=explicit&r=1"

  const first = fakeWidget(recaptchaData(url))
  const second = fakeWidget(recaptchaData(url))
  mountChallenge(first.el, {win, doc})

  assert.equal(doc.scripts.length, 1)
  assert.equal(
    doc.scripts[0].src,
    `${url}&onload=__kilnChallengeOnload_grecaptcha`,
    "the callback is named in the query"
  )

  // api.js defines a stub synchronously and fires its load event long before
  // render works.
  const api = recaptchaApi()
  win.grecaptcha = {ready() {}}
  doc.scripts[0].onload()
  mountChallenge(second.el, {win, doc})
  await tick()

  assert.equal(doc.scripts.length, 1, "one script for two widgets")
  assert.equal(api.calls.render.length, 0, "nothing drawn on the stub")

  win.grecaptcha = api
  win.__kilnChallengeOnload_grecaptcha()
  await tick()

  assert.equal(api.calls.render.length, 2, "both draw once it is ready")
  assert.equal(timers.pending.size, 0, "the readiness timer is cleared")
  const {options} = api.calls.render[0]
  assert.equal(options.action, undefined, "v2 takes no action")
  assert.equal(options["response-field"], undefined)
  assert.equal(options.sitekey, "site-key")

  options.callback("rc-token")
  assert.equal(first.parts["challenge-token"].value, "rc-token")
})

test("reCAPTCHA: widget id 0 is kept, and destroy never calls a missing remove", async () => {
  const win = {}
  const doc = fakeDocument()
  const url = "https://www.recaptcha.net/recaptcha/api.js?render=explicit&r=2"
  const api = recaptchaApi()
  api.resets = []
  api.reset = (id) => api.resets.push(id)
  const handlers = {}
  win.addEventListener = (type, fn) => (handlers[type] = fn)
  win.removeEventListener = (type) => delete handlers[type]

  const challenge = mountChallenge(fakeWidget(recaptchaData(url)).el, {win, doc})
  win.grecaptcha = api
  win.__kilnChallengeOnload_grecaptcha()
  await tick()

  handlers.pageshow({persisted: true})
  assert.deepEqual(api.resets, [0], "widget 0 is a widget")

  assert.doesNotThrow(() => challenge.destroy())
})

test("reCAPTCHA: a readiness timeout shows the fallback and never loads the script again", async () => {
  const timers = manualTimers()
  const win = {...timers}
  const doc = fakeDocument()
  const url = "https://www.recaptcha.net/recaptcha/api.js?render=explicit&r=3"
  const {el, parts} = fakeWidget(recaptchaData(url))

  mountChallenge(el, {win, doc})
  doc.scripts[0].onload()
  timers.fireAll()
  await tick()

  assert.equal(parts["challenge-fallback"].hidden, false)
  assert.equal(parts["challenge-status"].textContent, "Could not load")

  const later = fakeWidget(recaptchaData(url))
  mountChallenge(later.el, {win, doc})
  await tick()
  assert.equal(doc.scripts.length, 1, "the loaded script is not injected twice")
  assert.equal(later.parts["challenge-fallback"].hidden, false)
})

test("reCAPTCHA: a script that fails to load can be tried again", async () => {
  const doc = fakeDocument()
  const url = "https://www.recaptcha.net/recaptcha/api.js?render=explicit&r=4"
  const win = {}

  const pending = loadScript(url, "grecaptcha", win, doc, {onloadParam: "onload"})
  doc.scripts[0].onerror()
  await assert.rejects(pending)

  loadScript(url, "grecaptcha", win, doc, {onloadParam: "onload"}).catch(() => {})
  assert.equal(doc.scripts.length, 2)
})

test("an interactive widget asks once instead of waiting, then lets the submit go", () => {
  const timers = fakeTimers()
  const form = fakeForm()
  const {el, parts} = formWidget(form, {
    interactive: "true",
    completeFirstText: "Complete the check above, then send again.",
  })
  holdSubmitForToken(el, {win: timers, waitMs: 60_000})

  assert.equal(fire(form).defaultPrevented, true)
  assert.equal(parts["challenge-status"].textContent, "Complete the check above, then send again.")
  assert.equal(timers.queue.length, 0, "no 8-second wait")

  assert.equal(fire(form).defaultPrevented, false, "the second submit goes, to be held")
})

test("an interactive widget with a token submits at once", () => {
  const form = fakeForm()
  const {el, parts} = formWidget(form, {interactive: "true"})
  parts["challenge-token"].value = "tok"
  holdSubmitForToken(el, {win: fakeTimers()})

  assert.equal(fire(form).defaultPrevented, false)
})

test("reCAPTCHA: ready after the timeout after all, the failed widgets draw and later ones load nothing", async () => {
  const timers = manualTimers()
  const win = {...timers}
  const doc = fakeDocument()
  const url = "https://www.recaptcha.net/recaptcha/api.js?render=explicit&r=5"
  const first = fakeWidget(recaptchaData(url))

  mountChallenge(first.el, {win, doc})
  doc.scripts[0].onload()
  timers.fireAll()
  await tick()
  assert.equal(first.parts["challenge-fallback"].hidden, false, "gave up at the timeout")

  const api = recaptchaApi()
  win.grecaptcha = api
  win.__kilnChallengeOnload_grecaptcha()
  await tick()

  assert.equal(api.calls.render.length, 1, "the widget that gave up draws")
  assert.equal(first.parts["challenge-fallback"].hidden, true)
  assert.equal(first.parts["challenge-status"].textContent, "", "the error is cleared")

  const later = fakeWidget(recaptchaData(url))
  mountChallenge(later.el, {win, doc})
  await tick()
  assert.equal(doc.scripts.length, 1, "no second script")
  assert.equal(api.calls.render.length, 2, "a later widget draws at once")
  assert.equal(later.parts["challenge-fallback"].hidden, true)
})

test("a widget destroyed after the timeout does not draw when the script is late", async () => {
  const timers = manualTimers()
  const win = {...timers}
  const doc = fakeDocument()
  const url = "https://www.recaptcha.net/recaptcha/api.js?render=explicit&r=6"

  const gone = mountChallenge(fakeWidget(recaptchaData(url)).el, {win, doc})
  doc.scripts[0].onload()
  timers.fireAll()
  await tick()
  gone.destroy()

  const api = recaptchaApi()
  win.grecaptcha = api
  win.__kilnChallengeOnload_grecaptcha()
  await tick()
  assert.equal(api.calls.render.length, 0)
})
