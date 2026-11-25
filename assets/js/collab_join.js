// How a collab block waits for its channel join (#2772). Kept apart from
// collab.js, which imports phoenix.js and Yjs, so the decision can be tested
// with a fake channel and socket under `node --test`.
//
// `awaitJoin` resolves exactly once, to one of:
//   * {firstPeer}      the join succeeded and `onOk` applied the room's state;
//   * {solo: reason}   it did not, and the block must mount a plain
//                      single-user editor instead of waiting on the room.
//
// It used to settle only on a join "ok" or a refusal, so a socket that never
// connected (a token past its max_age after a deploy, a proxy that drops
// WebSockets) or a join that timed out left the promise pending, and the
// rich-text block never mounted at all. Now each of those falls back:
//   * the join push timed out;
//   * the socket reported an error or closed (connect refused or dropped)
//     before the join succeeded;
//   * the join was refused for good (flag off, stale bundle, unavailable...);
//   * nothing settled within `deadlineMs`, the cap on a transient refusal
//     such as "over budget", which phoenix.js keeps retrying.
//
// `onOk` keeps running on every later "ok" (phoenix.js keeps the join push's
// hooks for each rejoin), so a joined doc still resyncs after a reconnect.
// After a solo outcome the caller leaves the channel, so no late "ok" can
// bind a document the block is no longer editing through.

// A join refusal that clears on its own (the account's frame budget, #1305):
// phoenix.js retries the join on a backoff, and the "ok" that eventually
// arrives resolves the join, so it waits for that (up to the deadline).
export const TRANSIENT_JOIN_ERRORS = new Set(["over budget"])

// The longest a block waits for the room before mounting on its own. Longer
// than phoenix.js's default 10 s push timeout, so a slow join that does
// answer still gets the collaborative editor.
export const JOIN_DEADLINE_MS = 15000

export function awaitJoin({chan, socket, onOk, deadlineMs = JOIN_DEADLINE_MS, timers = globalThis}) {
  return new Promise(resolve => {
    let settled = false
    let refs = []
    let deadline = null

    const settle = outcome => {
      if (settled) return
      settled = true
      if (deadline) timers.clearTimeout(deadline)
      socket.off(refs)
      resolve(outcome)
    }

    // A close with no error event (a handshake the server or a proxy closes)
    // makes phoenix.js cancel the join's timeout and wait for the socket to
    // reopen, so the close has to end the wait itself.
    refs = [
      socket.onError(() => settle({solo: "socket error"})),
      socket.onClose(() => settle({solo: "socket closed"})),
    ]
    deadline = timers.setTimeout(() => settle({solo: "deadline"}), deadlineMs)

    chan
      .join()
      .receive("ok", reply => {
        // Only the first "ok" decides how the block mounts; later ones are
        // rejoins of a doc that is already bound and only need its state.
        // After a solo outcome the channel has been left, so none arrive.
        const result = onOk(reply)
        settle(result)
      })
      .receive("error", ({reason} = {}) => {
        if (TRANSIENT_JOIN_ERRORS.has(reason)) return
        settle({solo: reason || "refused"})
      })
      .receive("timeout", () => settle({solo: "timeout"}))
  })
}
