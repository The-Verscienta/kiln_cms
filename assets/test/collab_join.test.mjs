// How a collab block waits on its channel join (#2772), against a fake
// phoenix.js channel and socket. Run: `npm test` in assets/.
//
// Before #2772 the wait settled only on a join "ok" or a lasting refusal, so
// a socket that never connected or a join that timed out left it pending and
// the rich-text block never mounted an editor.
import {test} from "node:test"
import assert from "node:assert/strict"

import {awaitJoin, JOIN_DEADLINE_MS} from "../js/collab_join.js"

// The slice of phoenix.js's Push the join uses: `receive(status, cb)` chains,
// and the test fires a status by hand. Every hook stays registered, the way
// phoenix.js keeps them for each rejoin.
function fakeChannel() {
  const hooks = {}
  const push = {
    receive(status, cb) {
      ;(hooks[status] ||= []).push(cb)
      return push
    },
  }
  return {
    joins: 0,
    join() {
      this.joins++
      return push
    },
    fire(status, payload) {
      ;(hooks[status] || []).forEach(cb => cb(payload))
    },
  }
}

function fakeSocket() {
  const callbacks = new Map()
  let ref = 0
  const on = kind => cb => {
    callbacks.set(++ref, {kind, cb})
    return ref
  }
  const fire = kind =>
    Array.from(callbacks.values())
      .filter(c => c.kind === kind)
      .forEach(c => c.cb(kind))
  return {
    onError: on("error"),
    onClose: on("close"),
    off(refs) {
      refs.forEach(r => callbacks.delete(r))
    },
    error: () => fire("error"),
    close: () => fire("close"),
    listeners() {
      return callbacks.size
    },
  }
}

// Timers the test advances itself, so the deadline needs no real waiting.
function fakeTimers() {
  const pending = new Map()
  let id = 0
  return {
    setTimeout(cb, ms) {
      pending.set(++id, {cb, ms})
      return id
    },
    clearTimeout(t) {
      pending.delete(t)
    },
    fireAll() {
      const due = Array.from(pending.values())
      pending.clear()
      due.forEach(({cb}) => cb())
    },
    pending() {
      return Array.from(pending.values())
    },
  }
}

// Whether `promise` has settled yet, without waiting on it.
async function settled(promise) {
  const marker = Symbol("pending")
  const winner = await Promise.race([promise, Promise.resolve(marker)])
  return winner !== marker
}

// The outcome, failing at once if there is none yet. Awaiting a promise that
// never settles (the pre-#2772 behavior) would hang the run, not fail it.
async function outcome(promise) {
  assert.equal(await settled(promise), true, "the join wait is still pending")
  return promise
}

const setup = () => {
  const chan = fakeChannel()
  const socket = fakeSocket()
  const timers = fakeTimers()
  const oks = []
  const joined = awaitJoin({
    chan,
    socket,
    timers,
    onOk: reply => {
      oks.push(reply)
      return {firstPeer: reply.peers === 1}
    },
  })
  return {chan, socket, timers, oks, joined}
}

test("a join that succeeds resolves with the room's first-peer flag", async () => {
  const {chan, socket, timers, oks, joined} = setup()
  chan.fire("ok", {state: "", peers: 2})

  assert.deepEqual(await outcome(joined), {firstPeer: false})
  assert.equal(oks.length, 1)
  assert.equal(chan.joins, 1)
  assert.equal(socket.listeners(), 0, "the socket error hook is dropped once settled")
  assert.deepEqual(timers.pending(), [], "the deadline is cleared once settled")
})

test("a join timeout mounts a solo editor instead of waiting forever", async () => {
  const {chan, joined} = setup()
  chan.fire("timeout")

  assert.deepEqual(await outcome(joined), {solo: "timeout"})
})

test("a refused socket connect mounts a solo editor", async () => {
  const {socket, joined} = setup()
  socket.error()

  assert.deepEqual(await outcome(joined), {solo: "socket error"})
  assert.equal(socket.listeners(), 0)
})

// phoenix.js cancels the join's timeout when the socket closes and waits for
// it to reopen, so a handshake that is only ever closed sends no timeout.
test("a socket closed before the join answers mounts a solo editor", async () => {
  const {socket, joined} = setup()
  socket.close()

  assert.deepEqual(await outcome(joined), {solo: "socket closed"})
  assert.equal(socket.listeners(), 0)
})

test("a lasting join refusal mounts a solo editor", async () => {
  for (const reason of ["collab disabled", "stale bundle", "unavailable", "not found"]) {
    const {chan, joined} = setup()
    chan.fire("error", {reason})
    assert.deepEqual(await outcome(joined), {solo: reason})
  }

  const {chan, joined} = setup()
  chan.fire("error")
  assert.deepEqual(await outcome(joined), {solo: "refused"})
})

test("an over-budget refusal waits for phoenix.js's retry to succeed", async () => {
  const {chan, joined} = setup()
  chan.fire("error", {reason: "over budget"})
  assert.equal(await settled(joined), false)

  chan.fire("ok", {state: "", peers: 1})
  assert.deepEqual(await outcome(joined), {firstPeer: true})
})

test("a join that never answers is capped by the deadline", async () => {
  const {chan, timers, joined} = setup()
  chan.fire("error", {reason: "over budget"})
  assert.deepEqual(
    timers.pending().map(t => t.ms),
    [JOIN_DEADLINE_MS]
  )
  assert.equal(await settled(joined), false)

  timers.fireAll()
  assert.deepEqual(await outcome(joined), {solo: "deadline"})
})

test("only the first outcome counts; later rejoins still resync the doc", async () => {
  const {chan, socket, oks, joined} = setup()
  chan.fire("ok", {state: "", peers: 1})
  socket.error()
  chan.fire("timeout")
  chan.fire("ok", {state: "", peers: 3})

  assert.deepEqual(await outcome(joined), {firstPeer: true})
  assert.equal(oks.length, 2, "a rejoin after a reconnect still applies the room's state")
})

test("a solo outcome is not overturned by a join that answers late", async () => {
  const {chan, oks, joined} = setup()
  chan.fire("timeout")
  chan.fire("ok", {state: "", peers: 1})

  assert.deepEqual(await outcome(joined), {solo: "timeout"})
  assert.equal(oks.length, 1)
})
