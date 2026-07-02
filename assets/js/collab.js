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

// Re-exported for debugging/verification consoles (a second in-page client
// can build its own Y.Doc against the same channel protocol).
export {Y}

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

    const whenReady = new Promise(resolve => {
      chan
        .join()
        .receive("ok", ({state, peers}) => {
          Y.applyUpdate(doc, fromBase64(state), REMOTE_ORIGIN)
          resolve({firstPeer: peers === 1})
        })
        // Join refused (flag off / stale token): behave like a lone editor.
        .receive("error", () => resolve({firstPeer: true}))
    })

    docs[topic] = {doc, chan, whenReady, refs: 0, pushLocal}
  }

  const entry = docs[topic]
  entry.refs++

  return {
    doc: entry.doc,
    whenReady: entry.whenReady,
    release() {
      if (--entry.refs > 0) return
      entry.doc.off("update", entry.pushLocal)
      entry.chan.leave()
      entry.doc.destroy()
      delete docs[topic]
    },
  }
}
