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
    const chan = collabSocket(token).channel(topic, {})

    const pushLocal = (update, origin) => {
      if (origin === REMOTE_ORIGIN) return
      chan.push("update", {update: toBase64(update)})
    }
    doc.on("update", pushLocal)
    chan.on("update", ({update}) => Y.applyUpdate(doc, fromBase64(update), REMOTE_ORIGIN))

    // Presence carets/names (the Yjs awareness protocol) ride the same
    // channel. Awareness handles liveness itself — local state re-broadcasts
    // periodically and stale peers expire — we only relay the updates.
    const awareness = new Awareness(doc)

    const pushAwareness = ({added, updated, removed}, origin) => {
      if (origin === REMOTE_ORIGIN) return
      const changed = added.concat(updated, removed)
      chan.push("awareness", {update: toBase64(encodeAwarenessUpdate(awareness, changed))})
    }
    awareness.on("update", pushAwareness)

    chan.on("awareness", ({update}) =>
      applyAwarenessUpdate(awareness, fromBase64(update), REMOTE_ORIGIN)
    )

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
        .receive("ok", ({state, peers}) => {
          Y.applyUpdate(doc, fromBase64(state), REMOTE_ORIGIN)
          if (peers > 1) chan.push("awareness_request", {})
          resolve({firstPeer: peers === 1})
        })
        // Join refused (flag off / stale token): behave like a lone editor.
        .receive("error", () => resolve({firstPeer: true}))
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
      // Announce the departure so remote carets disappear immediately.
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
