// Human verification on the sign-in and registration forms (#2249).
//
// `KilnCMSWeb.ChallengeComponents.challenge_widget/1` renders a container with
// everything this needs as data- attributes — never an inline script — and the
// `Challenge` hook below:
//
//  * loads the provider's script once per page (explicit rendering), and only
//    when the widget is actually visible: the three auth forms share one page
//    and two of them are hidden, so a hidden form's widget must not load a
//    third-party script nobody can see;
//  * draws the widget and writes its token into the hidden input the form
//    submits (`user[challenge_token]`);
//  * clears the token when it expires, and shows the fallback line (another
//    way in) when the script cannot load or the widget errors.
//
// A spent token is a new widget: the server bumps the element's id after every
// submit, so LiveView replaces it — `destroyed()` removes the old widget and
// `mounted()` draws a fresh one.
//
// Public forms (#2249) are dead renders — a delivered page, `/forms/:slug`,
// the embed iframe, a refused re-render — so there is no hook to mount them.
// Their widget is marked `data-kiln-challenge` instead, and `mountAll` mounts
// every one in a document once: app.js calls it on the site's own pages, and
// the embed (which does not load app.js) loads `challenge_static.js`, which
// does nothing else. It also makes the form wait briefly for a token rather
// than posting without one (`holdSubmitForToken`).
//
// The provider is the operator's choice (`Kiln.Challenge.Provider`): the markup
// names its script, its global, extra render options, the render option the
// action goes under (if any) and, for a script that must say when it is ready
// (reCAPTCHA), the query parameter naming a callback. Markup rendered before
// those attributes existed gets Turnstile's behaviour, which is all it could
// have been drawn for.
//
// `mountChallenge` takes its window and document as arguments so `node --test`
// (assets/test/challenge.test.mjs) can drive it without a browser.

const loaders = new Map()

// How long a script that reports readiness through a callback gets to call
// it once loaded. Past this the widget shows its fallback line.
export const READY_TIMEOUT_MS = 10000

// One <script> per URL per page, however many widgets ask. A failed load is
// forgotten so a later widget can try again.
//
// With `onloadParam`, the script is ready only when it calls the callback the
// parameter names: reCAPTCHA defines a stub `grecaptcha` synchronously, long
// before `render` works, so neither the global's presence nor the `load`
// event says anything. A readiness timeout is remembered, not forgotten: the
// script did load, and injecting it again would only run it twice.
export function loadScript(
  url,
  globalName,
  win = window,
  doc = document,
  {onloadParam = null, timeoutMs = READY_TIMEOUT_MS} = {},
) {
  if (onloadParam) return loadWithCallback(url, globalName, onloadParam, timeoutMs, win, doc)
  if (win[globalName]) return Promise.resolve(win[globalName])
  if (!loaders.has(url)) {
    const loading = new Promise((resolve, reject) => {
      const script = doc.createElement("script")
      script.src = url
      script.async = true
      script.onload = () =>
        win[globalName] ? resolve(win[globalName]) : reject(new Error("challenge global missing"))
      script.onerror = () => {
        loaders.delete(url)
        reject(new Error("challenge script failed to load"))
      }
      doc.head.appendChild(script)
    })
    loaders.set(url, loading)
  }
  return loaders.get(url)
}

// Widgets that gave up on a script past its readiness timeout, per URL, to
// be drawn after all if it becomes ready late.
const lateReady = new Map()

// Calls `fn(api)` if the script at `url` becomes ready after its readiness
// timeout. Returns a function that stops waiting.
export function onLateReady(url, fn) {
  if (!lateReady.has(url)) lateReady.set(url, new Set())
  lateReady.get(url).add(fn)
  return () => {
    const waiting = lateReady.get(url)
    if (waiting) waiting.delete(fn)
  }
}

class ReadinessTimeout extends Error {}

function loadWithCallback(url, globalName, onloadParam, timeoutMs, win, doc) {
  if (!loaders.has(url)) {
    const loading = new Promise((resolve, reject) => {
      const callback = `__kilnChallengeOnload_${globalName}`
      let settled = false
      let timer = null
      const settle = (fn, value) => {
        if (settled) return
        settled = true
        if (timer != null && typeof win.clearTimeout === "function") win.clearTimeout(timer)
        fn(value)
      }

      win[callback] = () => {
        const api = win[globalName]
        if (!settled) {
          if (api) settle(resolve, api)
          else settle(reject, new Error("challenge global missing"))
          return
        }
        // Ready after all, past the timeout: later widgets use it at once,
        // and the ones that gave up draw now.
        if (!api) return
        loaders.set(url, Promise.resolve(api))
        const waiting = lateReady.get(url)
        lateReady.delete(url)
        if (waiting) for (const fn of waiting) fn(api)
      }

      const script = doc.createElement("script")
      const separator = url.includes("?") ? "&" : "?"
      script.src = `${url}${separator}${encodeURIComponent(onloadParam)}=${callback}`
      script.async = true
      script.onload = () => {
        if (!settled && typeof win.setTimeout === "function") {
          timer = win.setTimeout(
            () => settle(reject, new ReadinessTimeout("challenge script never became ready")),
            timeoutMs,
          )
        }
      }
      script.onerror = () => {
        if (settled) return
        loaders.delete(url)
        settle(reject, new Error("challenge script failed to load"))
      }
      doc.head.appendChild(script)
    })
    loaders.set(url, loading)
  }
  return loaders.get(url)
}

// What the markup says about the provider, or Turnstile's behaviour for
// markup rendered before the attributes existed (no `data-render-options`).
export function widgetSettings(data) {
  if (data.renderOptions === undefined) {
    return {
      renderOptions: {"response-field": false},
      actionOption: "action",
      onloadParam: null,
    }
  }
  let renderOptions = {}
  try {
    const parsed = JSON.parse(data.renderOptions || "{}")
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) renderOptions = parsed
  } catch (_error) {
    // Unreadable options draw the widget with none rather than not at all.
  }
  return {
    renderOptions,
    actionOption: data.actionOption || null,
    onloadParam: data.onloadParam || null,
  }
}

// Calls `onVisible` once the element is rendered visible. Without
// IntersectionObserver (old browsers, tests) it assumes it is.
export function whenVisible(el, onVisible, win = window) {
  if (typeof win.IntersectionObserver !== "function") {
    onVisible()
    return () => {}
  }
  const observer = new win.IntersectionObserver((entries) => {
    if (entries.some((entry) => entry.isIntersecting)) {
      observer.disconnect()
      onVisible()
    }
  })
  observer.observe(el)
  return () => observer.disconnect()
}

export function mountChallenge(el, {win = window, doc = document} = {}) {
  const data = el.dataset
  const input = el.querySelector("[data-role='challenge-token']")
  const box = el.querySelector("[data-role='challenge-widget']")
  const status = el.querySelector("[data-role='challenge-status']")
  const fallback = el.querySelector("[data-role='challenge-fallback']")

  const state = {api: null, widgetId: null, gone: false}
  const settings = widgetSettings(data)

  const say = (text) => {
    if (status) status.textContent = text || ""
  }
  const setToken = (token) => {
    if (input) input.value = token || ""
  }
  const fail = () => {
    setToken("")
    say(data.errorText)
    if (fallback) fallback.hidden = false
  }

  const draw = () => {
    if (state.gone) return
    say(data.loadingText)
    loadScript(data.scriptUrl, data.global, win, doc, {
      onloadParam: settings.onloadParam,
    })
      .then(render)
      .catch((error) => {
        if (state.gone) return
        fail()
        if (error instanceof ReadinessTimeout) {
          state.stopLate = onLateReady(data.scriptUrl, (api) => {
            if (state.gone) return
            if (fallback) fallback.hidden = true
            render(api)
          })
        }
      })
  }

  // Draws the widget with a ready API: once loaded, or late, past a readiness
  // timeout, when the hidden fallback line gives way to it.
  const render = (api) => {
    if (state.gone) return
    state.api = api
    // The provider's own options first; ours last, so none can be
    // replaced by them (the server refuses such options anyway).
    const options = {...settings.renderOptions}
    if (settings.actionOption) options[settings.actionOption] = data.action
    // A widget id can be 0 (reCAPTCHA's first), so it is compared to null.
    state.widgetId = api.render(box, {
      ...options,
      sitekey: data.sitekey,
      callback: (token) => {
        setToken(token)
        say(data.solvedText)
      },
      "expired-callback": () => {
        setToken("")
        say(data.expiredText)
      },
      "error-callback": () => {
        fail()
        // Handled: the provider must not also retry or throw.
        return true
      },
    })
    say("")
  }

  const stopWatching = whenVisible(el, draw, win)

  // A page restored from the back/forward cache still holds the token it was
  // submitted with, which the provider will refuse as spent: drop it and ask
  // the widget for a new one.
  const onPageShow = (event) => {
    if (!event || !event.persisted) return
    setToken("")
    say("")
    if (state.api && state.widgetId != null && typeof state.api.reset === "function") {
      try {
        state.api.reset(state.widgetId)
      } catch (_error) {
        // The widget is gone; the next submit waits and then goes without.
      }
    }
  }
  if (typeof win.addEventListener === "function") win.addEventListener("pageshow", onPageShow)

  return {
    destroy() {
      state.gone = true
      if (typeof win.removeEventListener === "function") {
        win.removeEventListener("pageshow", onPageShow)
      }
      stopWatching()
      if (state.stopLate) state.stopLate()
      // reCAPTCHA has no `remove`: its widget goes with its element, and the
      // script keeps its own record of it until the page unloads.
      if (state.api && state.widgetId != null && typeof state.api.remove === "function") {
        try {
          state.api.remove(state.widgetId)
        } catch (_error) {
          // Already gone with its element; nothing to clean up.
        }
      }
    },
  }
}

// How long a submit waits for the widget to produce a token. A visitor who
// clicks before the invisible check finishes would otherwise post without one
// and be held for review; past this the form goes anyway, which is still fine.
export const SUBMIT_WAIT_MS = 8000
const SUBMIT_POLL_MS = 100

// Mounts every public-form widget under `root` that is not mounted yet.
// Idempotent: a widget is marked when mounted, so calling this twice (app.js
// and an embed script on one page, or a test) draws nothing twice.
export function mountAll(root = document, {win = window, doc = document} = {}) {
  const mounted = []
  for (const el of Array.from(root.querySelectorAll("[data-kiln-challenge]"))) {
    if (el.dataset.kilnChallengeMounted === "true") continue
    el.dataset.kilnChallengeMounted = "true"
    mounted.push(mountChallenge(el, {win, doc}))
    holdSubmitForToken(el, {win})
  }
  return mounted
}

// Mount on DOMContentLoaded, or now if that has passed.
export function mountAllWhenReady({win = window, doc = document} = {}) {
  const run = () => mountAll(doc, {win, doc})
  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", run, {once: true})
  else run()
}

// A submit with no token yet waits up to `SUBMIT_WAIT_MS` for one, then
// submits again either way. The re-fired submit is let through by a flag on
// the form, so it can never wait on itself. A widget that has already failed
// (its fallback line showing) does not wait at all.
//
// An interactive widget (a checkbox the visitor has to tick) will not finish
// on its own, so waiting would only stall the click. The first submit without
// a token is stopped with a line asking for the check; a second goes as it
// is, and is held for review like any other submission without a token.
export function holdSubmitForToken(el, {win = window, waitMs = SUBMIT_WAIT_MS} = {}) {
  const form = el.closest && el.closest("form")
  if (!form) return
  const input = el.querySelector("[data-role='challenge-token']")
  const status = el.querySelector("[data-role='challenge-status']")
  const fallback = el.querySelector("[data-role='challenge-fallback']")
  const interactive = el.dataset.interactive === "true"
  let waiting = false
  let asked = false

  form.addEventListener("submit", (event) => {
    if (form.dataset.kilnChallengeSubmitting === "true") return
    if (!input || input.value) return
    if (fallback && !fallback.hidden) return

    if (interactive) {
      if (asked) return
      asked = true
      event.preventDefault()
      if (status && el.dataset.completeFirstText) status.textContent = el.dataset.completeFirstText
      return
    }

    event.preventDefault()
    // A second click while waiting joins the wait rather than starting
    // another, which would submit the form twice.
    if (waiting) return
    waiting = true
    if (status && el.dataset.waitingText) status.textContent = el.dataset.waitingText

    const submitter = event.submitter
    const deadline = Date.now() + waitMs
    // The flag only has to outlive the one synchronous re-fired submit event.
    // Cleared afterwards, so a later submit (the page restored by Back, or a
    // re-request that constraint validation blocked) waits for a fresh token
    // again rather than going straight through.
    const resubmit = () => {
      form.dataset.kilnChallengeSubmitting = "true"
      try {
        if (typeof form.requestSubmit === "function") form.requestSubmit(submitter || undefined)
        else form.submit()
      } finally {
        delete form.dataset.kilnChallengeSubmitting
        waiting = false
      }
    }
    const poll = () => {
      if (input.value || Date.now() >= deadline || (fallback && !fallback.hidden)) resubmit()
      else win.setTimeout(poll, SUBMIT_POLL_MS)
    }
    win.setTimeout(poll, SUBMIT_POLL_MS)
  })
}

export const Challenge = {
  mounted() {
    this.challenge = mountChallenge(this.el)
  },
  destroyed() {
    if (this.challenge) this.challenge.destroy()
  },
}
