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
// `mountChallenge` takes its window and document as arguments so `node --test`
// (assets/test/challenge.test.mjs) can drive it without a browser.

const loaders = new Map()

// One <script> per URL per page, however many widgets ask. A failed load is
// forgotten so a later widget can try again.
export function loadScript(url, globalName, win = window, doc = document) {
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
    loadScript(data.scriptUrl, data.global, win, doc)
      .then((api) => {
        if (state.gone) return
        state.api = api
        state.widgetId = api.render(box, {
          sitekey: data.sitekey,
          action: data.action,
          // Our own hidden input carries the token; the provider's default one
          // would post a second copy under a name the server ignores.
          "response-field": false,
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
      })
      .catch(() => {
        if (!state.gone) fail()
      })
  }

  const stopWatching = whenVisible(el, draw, win)

  return {
    destroy() {
      state.gone = true
      stopWatching()
      if (state.api && state.widgetId != null) {
        try {
          state.api.remove(state.widgetId)
        } catch (_error) {
          // Already gone with its element; nothing to clean up.
        }
      }
    },
  }
}

export const Challenge = {
  mounted() {
    this.challenge = mountChallenge(this.el)
  },
  destroyed() {
    if (this.challenge) this.challenge.destroy()
  },
}
