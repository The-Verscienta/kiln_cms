// Yjs over a Phoenix Channel — the client half of the collaborative-editing
// CRDT prototype (KilnCMS.Collab.Crdt; see docs/collaborative-editing-spike.md).
//
// One shared Y.Doc + one channel per document topic, no matter how many
// rich-text blocks are on the page — each block binds to its own XmlFragment
// of that doc (TipTap Collaboration's `field`). Local Yjs updates push to the
// channel; remote ones apply back tagged with a "remote" origin so they aren't
// echoed. The join reply carries the authoritative doc state plus the peer
// count — `peers === 1` means "you're first", which is the (race-tolerant
// enough for a prototype) signal to seed fragments from the stored HTML.
//
// The server budgets every frame this file sends, per account
// (KilnCMSWeb.SocketEventBudget, #1305), and closes the connection when the
// account is over it. Three things here exist for that:
//   * awareness pushes are coalesced (AWARENESS_PUSH_MS), so a mouse-drag
//     selection — which re-announces the caret on every selection change —
//     cannot emit at the browser's event rate; the ceiling is sized against
//     what this file emits, so this IS the ceiling's input;
//   * every successful join pushes back the local ops the server's state is
//     missing, so a frame the server refused (or one in flight when it closed
//     the connection) is recovered on the rejoin rather than lost;
//   * an "over budget" join refusal is transient — the account's budget frees
//     within the window and phoenix.js keeps retrying — so it must NOT resolve
//     `whenReady` as the first peer: seeding from the stored HTML and then
//     merging the room's real state on the retry that succeeds duplicates the
//     document.
import {Socket} from "phoenix"
import * as Y from "yjs"
import {
  Awareness,
  applyAwarenessUpdate,
  encodeAwarenessUpdate,
} from "y-protocols/awareness"

// Re-exported for debugging/verification consoles (a second in-page client
// can build its own Y.Doc + awareness against the same channel protocol).
export {Y, Awareness, applyAwarenessUpdate, encodeAwarenessUpdate}

const REMOTE_ORIGIN = "kiln-collab-remote"

// The editor's ProseMirror node-set version, bumped whenever the schema grows
// (2 = tables, #475). Sent on join so the server can refuse peers running an
// older bundle: y-prosemirror DELETES nodes its schema doesn't know from the
// shared doc, so one stale tab would silently destroy every peer's tables.
// A refused join falls back to solo editing below — safe, just not live.
export const SCHEMA_VSN = 2

// Awareness (caret/selection/name) pushes are coalesced to one frame per this
// many ms — the latest local state wins, so nothing is lost by waiting — which
// bounds what a drag-select can emit at ~10 frames/s instead of the browser's
// event rate. Removals (`setLocalState(null)` on release) flush immediately so
// remote carets still disappear at once.
const AWARENESS_PUSH_MS = 100

// A join refusal that clears on its own (the account's frame budget, #1305):
// phoenix.js retries the join on a backoff, and the "ok" that eventually
// arrives resolves `whenReady` — so this one must not resolve it as an error.
const TRANSIENT_JOIN_ERRORS = new Set(["over budget"])

let socket = null
const docs = {} // topic -> {doc, chan, whenReady, refs}

const toBase64 = bytes => {
  let bin = ""
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin)
}

const fromBase64 = b64 => Uint8Array.from(atob(b64), c => c.charCodeAt(0))

const collabSocket = token => {
  if (!socket) {
    socket = new Socket("/ws/collab", {params: {token}})
    socket.connect()
  }
  return socket
}

// Acquire the shared doc for `topic` (creating + joining on first use).
// Returns {doc, whenReady, release}: `whenReady` resolves to {firstPeer}
// once the server state has been applied; `release` drops this user of the
// doc and leaves the channel when nobody on the page needs it anymore.
export function acquireDoc(topic, token) {
  if (!docs[topic]) {
    const doc = new Y.Doc()
    const chan = collabSocket(token).channel(topic, {vsn: SCHEMA_VSN})

    const pushLocal = (update, origin) => {
      if (origin === REMOTE_ORIGIN) return
      chan.push("update", {update: toBase64(update)})
    }
    doc.on("update", pushLocal)
    chan.on("update", ({update}) => Y.applyUpdate(doc, fromBase64(update), REMOTE_ORIGIN))

    // Presence carets/names (the Yjs awareness protocol) ride the same
    // channel. Awareness handles liveness itself — local state re-broadcasts
    // periodically and stale peers expire — we only relay the updates,
    // coalesced (see AWARENESS_PUSH_MS).
    const awareness = new Awareness(doc)

    const pendingAwareness = new Set()
    let awarenessTimer = null
    const flushAwareness = () => {
      awarenessTimer = null
      if (pendingAwareness.size === 0) return
      const changed = Array.from(pendingAwareness)
      pendingAwareness.clear()
      chan.push("awareness", {update: toBase64(encodeAwarenessUpdate(awareness, changed))})
    }

    const pushAwareness = ({added, updated, removed}, origin) => {
      if (origin === REMOTE_ORIGIN) return
      added.concat(updated, removed).forEach(id => pendingAwareness.add(id))
      if (removed.length > 0) {
        if (awarenessTimer) clearTimeout(awarenessTimer)
        flushAwareness()
      } else if (!awarenessTimer) {
        awarenessTimer = setTimeout(flushAwareness, AWARENESS_PUSH_MS)
      }
    }
    awareness.on("update", pushAwareness)

    chan.on("awareness", ({update}) =>
      applyAwarenessUpdate(awareness, fromBase64(update), REMOTE_ORIGIN)
    )

    // The document was published while this room was open (#1061). The server
    // took the converged prose into that write, so nothing typed so far is
    // lost — but from here on nobody persists this doc: client autosave stops
    // on a non-draft, and the server checkpoint is refused by `:autosave`'s
    // draft-only filter. Continuing to type would silently diverge, so say so
    // rather than let the editor keep writing into a doc that is going nowhere.
    chan.on("published", () => {
      window.dispatchEvent(
        new CustomEvent("kiln:collab-published", {detail: {topic}})
      )
    })

    // A newcomer asks the room for current awareness states (otherwise
    // existing carets only appear on their next periodic refresh).
    chan.on("awareness_request", () => {
      const state = awareness.getLocalState()
      if (!state) return
      chan.push("awareness", {
        update: toBase64(encodeAwarenessUpdate(awareness, [doc.clientID])),
      })
    })

    const whenReady = new Promise(resolve => {
      chan
        .join()
        // Fires on every join that succeeds, the first and each rejoin after a
        // reconnect (phoenix.js keeps the join push's hooks).
        .receive("ok", ({state, peers}) => {
          const remote = fromBase64(state)
          Y.applyUpdate(doc, remote, REMOTE_ORIGIN)
          // Sync step 2: whatever this doc has that the room's state doesn't
          // — the update the server refused, the ones in flight when it closed
          // the connection, anything typed while disconnected — goes back now.
          // Empty (two bytes) on a fresh doc and after a clean handshake.
          const missing = Y.encodeStateAsUpdate(doc, Y.encodeStateVectorFromUpdate(remote))
          if (missing.length > 2) chan.push("update", {update: toBase64(missing)})
          if (peers > 1) chan.push("awareness_request", {})
          resolve({firstPeer: peers === 1})
        })
        // Join refused (flag off / stale token / stale-bundle schema vsn):
        // behave like a lone editor — autosave still works, collab doesn't.
        // A TRANSIENT refusal is left pending: the retry that succeeds
        // resolves it, and seeding now would duplicate the room's content.
        .receive("error", ({reason} = {}) => {
          if (TRANSIENT_JOIN_ERRORS.has(reason)) return
          resolve({firstPeer: true})
        })
    })

    docs[topic] = {doc, chan, awareness, whenReady, refs: 0, pushLocal, pushAwareness}
  }

  const entry = docs[topic]
  entry.refs++

  return {
    doc: entry.doc,
    awareness: entry.awareness,
    whenReady: entry.whenReady,
    release() {
      if (--entry.refs > 0) return
      // Announce the departure so remote carets disappear immediately (a
      // removal flushes the coalesced awareness push synchronously).
      entry.awareness.setLocalState(null)
      entry.awareness.off("update", entry.pushAwareness)
      entry.awareness.destroy()
      entry.doc.off("update", entry.pushLocal)
      entry.chan.leave()
      entry.doc.destroy()
      delete docs[topic]
    },
  }
}
