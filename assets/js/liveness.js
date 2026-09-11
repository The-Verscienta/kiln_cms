// THE LINE THAT LOOKS FINE (texttile's connection.js, the watch half).
//
// The worst case wears no mark at all. A WebSocket that is cut without a
// goodbye — a laptop that went to sleep, a network that dropped it, a proxy
// that let it go — stays open in the browser. Nothing on the screen changes:
// the view still wears phx-connected, and every keystroke's push goes into a
// line whose other end is gone. Phoenix asks every 30 s, and a browser slows
// a background tab's clock to about once a minute, so its question can be
// minutes away; until it comes back, whatever is typed is thrown away in
// silence. In an editor that saves by itself, that is data loss.
//
// So the page asks for itself while it is in front, and counts how long the
// server has been quiet. Silence is the one symptom every cause shares, so
// it is the one thing worth watching. A quiet line gets `phx-late` on the
// root (the save line reads it — saved_ticker.js) and is taken down and built
// again through Phoenix's own machinery, which shows the usual reconnect
// flash and, on rejoin, gives every rich-text host its `reconnected()`.
//
// A line that was put down on purpose is left alone: Phoenix marks that
// close as clean, and a page disconnected deliberately has nothing to repair.

// A browser test may shorten these through `window.__lineTiming` before the
// page scripts run. The silence is only read once a tick, so `quiet` has to
// stay well above `tick` or a page would call itself quiet between answers.
const clock = {
  tick: 1000,
  ask: 4000,
  quiet: 8000,
  revive: 10_000,
  late: 5000,
  ...(globalThis.window?.__lineTiming || {}),
}

// What the page knows about its line, and what follows from it. On its own so
// the rule can be read without a browser: `connected` and `clean` come from
// the socket, `joined` from the main view's channel, `live` from the class
// LiveView writes on the container, `silent` is how long the server has said
// nothing. The mark comes at once for a line that has gone quiet, because the
// silence was already counted; for everything else it waits (`late`), since
// no page is live in its first moment and a warning there would be a lie.
export function readTheLine({connected, clean, joined, live, inFront, silent}) {
  const quiet = connected && !clean && inFront && silent > clock.quiet
  const standing = connected && live && joined
  return {mark: quiet ? "now" : standing ? "never" : "soon", revive: quiet}
}

export function watchLiveness(liveSocket) {
  const root = document.documentElement
  const socket = () => liveSocket && liveSocket.socket
  const main = () => document.querySelector("[data-phx-main]")
  const inFront = () => document.visibilityState === "visible"

  let heard = Date.now()
  let asked = 0
  let waiting = false
  let revivedAt = 0
  let lateTimer = null

  // A joined view is the only one that can answer a push.
  const joined = () => {
    const view = liveSocket.main
    return !view || !view.channel || view.channel.state === "joined"
  }

  function forgetTheAsk() {
    heard = Date.now()
    asked = 0
    waiting = false
  }

  // One question at a time: an unanswered one keeps its listener on the
  // socket, so asking again over a dead line would pile them up.
  function ask() {
    if (!inFront() || waiting || Date.now() - asked < clock.ask) return
    asked = Date.now()
    waiting = true
    socket().ping(() => {
      waiting = false
      heard = Date.now()
    })
  }

  // Down and up again through Phoenix's own machinery, so a rebuild that
  // fails leaves its reconnect running. `disconnect` marks the close as clean,
  // which would stop that, and this close was anything but. The question that
  // was out goes down with the line it was asked on.
  function revive() {
    if (Date.now() - revivedAt < clock.revive) return
    revivedAt = Date.now()
    forgetTheAsk()
    const line = socket()
    liveSocket.disconnect(() => {
      line.closeWasClean = false
      liveSocket.connect()
    })
  }

  function say(mark) {
    if (mark === "now") {
      clearTimeout(lateTimer)
      lateTimer = null
      root.classList.add("phx-late")
    } else if (mark === "never") {
      clearTimeout(lateTimer)
      lateTimer = null
      root.classList.remove("phx-late")
    } else if (lateTimer === null) {
      lateTimer = setTimeout(() => root.classList.add("phx-late"), clock.late)
    }
  }

  function watchTheLine() {
    const line = socket()
    if (!line || !main()) {
      say("never")
      return
    }

    // A line that is down is not a quiet line: LiveView says that one itself
    // and is already building it again.
    if (!line.isConnected() || line.closeWasClean) forgetTheAsk()
    else ask()

    const read = readTheLine({
      connected: line.isConnected(),
      clean: line.closeWasClean,
      joined: joined(),
      live: main().classList.contains("phx-connected"),
      inFront: inFront(),
      silent: Date.now() - heard,
    })

    say(read.mark)
    if (read.revive) revive()
  }

  // Coming back to a tab that was away: its clock was slowed while it sat
  // there, so the silence it brings says nothing about the line. The question
  // goes out now, and the answer decides.
  function backInFront() {
    if (inFront()) forgetTheAsk()
    watchTheLine()
  }

  // The views of the line before. A page put into the browser's back-forward
  // cache loses its socket after Phoenix has written that close off as
  // deliberate, so the close reaches no channel: a view that still claims to
  // be joined on a line that was only just built is remembering a line that
  // is gone, and every push on it comes back as "unmatched topic". `phx_error`
  // is the word Phoenix uses itself for a channel whose connection is gone,
  // and it makes the view rejoin.
  function dropTheViewsOfTheOldLine() {
    const line = socket()
    if (!line) return
    line.channels
      .filter(channel => channel.state === "joined")
      .forEach(channel => channel.trigger("phx_error"))
  }

  if (socket()) {
    socket().onMessage(() => {
      heard = Date.now()
    })
    socket().onOpen(forgetTheAsk)
    socket().onOpen(dropTheViewsOfTheOldLine)
  }

  setInterval(watchTheLine, clock.tick)
  addEventListener("visibilitychange", backInFront)
  addEventListener("focus", backInFront)
  watchTheLine()
}
