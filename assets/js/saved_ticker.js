// The save line of a screen that saves by itself (texttile's saved_ticker.js).
//
// A draft with no Save click owes the eye an answer, and a grey word that
// quietly rewrites itself is not one. So the line is loud for a moment and
// quiet the rest of the time: every save that LANDS turns it to the success
// colour and says "Saved"; a few seconds later it fades back to the clock
// stamp of that save. While the line to the server is down or has gone quiet
// (liveness.js), it says so instead, in the error colour, because "Last saved
// 14:32" over a dead socket would be the lie the old "Saving…" was.
//
// The words come from the host's data attributes, so the hook speaks the
// page's locale; the server-rendered text is the first paint and the no-JS
// fallback. States other than saved/pending keep their server words.

const FLASH_MS = 2600
const FRESH_S = 20

// What the line says at one moment, as a value: the sentence and the tooltip
// when one is owed, or `null` when the server's own words should stand.
// Pure, so the wording matrix can be read without a browser around it.
export function savedLine({at, now, state, offline, flash, wide, words}) {
  if (offline) return {text: words.offline, tone: "offline"}
  if (state !== "saved" && state !== "pending") return null
  if (!at) return null

  const d = new Date(at)
  const pad = n => String(n).padStart(2, "0")
  const clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`

  // The seconds are not in the words: they changed once a second in the
  // corner of the eye and said nothing anyone could act on. The exact second
  // is in the tooltip, for the one time it settles an argument.
  const title = words.tooltip.replace("%{time}", `${clock}:${pad(d.getSeconds())}`)
  const fresh = (now - at) / 1000 < FRESH_S

  if (flash) return {text: words.saved, title, tone: "fresh"}
  // A phone bar has room for the stamp, not for the sentence.
  if (!wide) return {text: fresh ? words.saved : words.narrow.replace("%{time}", clock), title}
  return {text: fresh ? words.justNow : words.stamp.replace("%{time}", clock), title}
}

export const SavedTicker = {
  mounted() {
    // The line arrives with the last save already on it; only a save that
    // happens while somebody is watching is worth a flash.
    this.at = Number(this.el.dataset.at || 0)
    this.timer = setInterval(() => this.paint(), 1000)
    this.paint()
  },
  updated() {
    this.paint()
  },
  destroyed() {
    clearInterval(this.timer)
    clearTimeout(this.fade)
  },

  words() {
    return this.el.querySelector("[data-words]") || this.el
  },

  // Down (LiveView's own classes on the main container) or quiet (liveness.js
  // on the root): either way nothing typed now is reaching the server.
  offline() {
    const main = document.querySelector("[data-phx-main]")
    return (
      document.documentElement.classList.contains("phx-late") ||
      (!!main &&
        (main.classList.contains("phx-client-error") || main.classList.contains("phx-server-error")))
    )
  },

  paint() {
    const now = Date.now()
    const d = this.el.dataset
    const at = Number(d.at || 0)

    if (at && at !== this.at) {
      this.at = at
      this.flash(FLASH_MS)
    }

    const line = savedLine({
      at,
      now,
      state: d.state,
      offline: this.offline(),
      flash: this.el.classList.contains("fresh"),
      wide: window.matchMedia("(min-width: 768px)").matches,
      words: {
        saved: d.wordSaved,
        justNow: d.wordJustNow,
        stamp: d.wordStamp,
        narrow: d.wordNarrow,
        tooltip: d.wordTooltip,
        offline: d.wordOffline,
      },
    })

    this.el.classList.toggle("offline", !!line && line.tone === "offline")
    if (!line) {
      this.el.removeAttribute("title")
      return
    }
    if (line.title) this.el.title = line.title
    else this.el.removeAttribute("title")
    const target = this.words()
    if (target.textContent !== line.text) target.textContent = line.text
  },

  // The class carries the whole loud state; taking it off and putting it back
  // in one frame restarts the animation when two saves follow each other.
  flash(ms) {
    this.el.classList.remove("fresh")
    void this.el.offsetWidth
    this.el.classList.add("fresh")
    clearTimeout(this.fade)
    this.fade = setTimeout(() => {
      this.el.classList.remove("fresh")
      this.paint()
    }, ms)
  },
}
