// The connection notices: "We can't find the internet" (#client-error) and
// "Something went wrong!" (#server-error), from `Layouts.flash_group/1`.
//
// LiveView marks the main view `phx-client-error` while the line is down and
// `phx-server-error` while the line is up but the view cannot be opened. Both
// also happen for a moment on a perfectly healthy page: the first connection
// can take a beat, and a line that drops comes back on its own. LiveView's own
// `phx-disconnected` waits half a second before it speaks, which is too short
// for either, so testers saw both notices flash on a page that worked (#1821).
//
// So a notice comes up only once the view has been in trouble for `grace` ms
// without a break, and only the one for the trouble it is in now (#1784): a
// line that comes back and then fails to rejoin is one outage that changes its
// name, not two. The moment the view is connected again, both go.
//
// Each notice carries a "Try again" button. A line that is down is built again
// at once, rather than at the end of Phoenix's back-off; a page the server
// could not open is reloaded, since a new connection would be refused the same
// way.

// A browser test may shorten this through `window.__lineTiming.notice` before
// the page scripts run, like the liveness clock (liveness.js).
const GRACE_MS = 2500

const NOTICES = {client: "client-error", server: "server-error"}

// Which trouble the view is in, read from the classes LiveView keeps current
// on the container: "server", "client", or null for none.
export function troubleOf(main) {
  if (!main) return null
  if (main.classList.contains("phx-server-error")) return "server"
  if (main.classList.contains("phx-client-error")) return "client"
  return null
}

// What to show, given the trouble now and how long the view has been in some
// trouble without a break. On its own so the rule reads without a browser.
export function noticeFor(trouble, troubledMs, grace = GRACE_MS) {
  return trouble && troubledMs >= grace ? trouble : null
}

export function watchConnectionNotices(liveSocket) {
  const grace = (globalThis.window?.__lineTiming || {}).notice ?? GRACE_MS
  const main = () => document.querySelector("[data-phx-main]")

  // When the current unbroken stretch of trouble began, or null when there is
  // none.
  let troubleSince = null
  let timer = null

  function show(kind) {
    for (const [name, id] of Object.entries(NOTICES)) {
      const el = document.getElementById(id)
      if (el) el.hidden = name !== kind
    }
  }

  function check() {
    const trouble = troubleOf(main())

    if (!trouble) {
      troubleSince = null
      clearTimeout(timer)
      timer = null
      show(null)
      return
    }

    const now = Date.now()
    if (troubleSince === null) troubleSince = now
    const kind = noticeFor(trouble, now - troubleSince, grace)
    show(kind)

    if (!kind && timer === null) {
      timer = setTimeout(() => {
        timer = null
        check()
      }, grace - (now - troubleSince))
    }
  }

  function retry(button) {
    const kind = troubleOf(main())
    if (kind === "server") {
      window.location.reload()
      return
    }
    if (kind !== "client" || !liveSocket) return
    // Down and straight up again, the way the liveness watchdog rebuilds a
    // quiet line: `disconnect` cancels the back-off wait and `connect` tries
    // now. `disconnect` also marks the close as deliberate, which would stop
    // Phoenix reconnecting if this try fails too, so that mark comes off.
    button.disabled = true
    const line = liveSocket.socket
    liveSocket.disconnect(() => {
      line.closeWasClean = false
      liveSocket.connect()
      setTimeout(() => (button.disabled = false), 1000)
    })
  }

  document.addEventListener("click", e => {
    const button = e.target instanceof Element && e.target.closest("[data-connection-retry]")
    if (button) {
      e.preventDefault()
      retry(button)
    }
  })

  // The container's class is the signal; a live navigation swaps the
  // container itself, so the whole tree is watched, and a burst of changes is
  // read once.
  let queued = false
  new MutationObserver(() => {
    if (queued) return
    queued = true
    queueMicrotask(() => {
      queued = false
      check()
    })
  }).observe(document.body, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["class"],
  })

  check()
}
