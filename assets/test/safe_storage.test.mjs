// The storage guard app.js hands to LiveSocket (#2773), against fake windows.
// Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"

import {safeStorage, memoryStorage} from "../js/safe_storage.js"

function realStorage() {
  const s = memoryStorage()
  s.calls = []
  const {setItem, removeItem} = s
  s.setItem = (k, v) => (s.calls.push(["set", k]), setItem(k, v))
  s.removeItem = k => (s.calls.push(["remove", k]), removeItem(k))
  return s
}

const isShim = (storage, original) => {
  assert.notEqual(storage, original)
  assert.equal(typeof storage.getItem, "function")
  assert.equal(typeof storage.setItem, "function")
  assert.equal(typeof storage.removeItem, "function")
}

test("returns the browser's store when it works, and leaves no probe behind", () => {
  const local = realStorage()
  local.setItem("kiln:sidebar", "collapsed")
  const win = {localStorage: local}

  assert.equal(safeStorage("localStorage", win), local)
  assert.equal(local.getItem("kiln:sidebar"), "collapsed")
  assert.equal(local.getItem("kiln:storage-probe"), null)
  assert.deepEqual(local.calls.slice(1), [
    ["set", "kiln:storage-probe"],
    ["remove", "kiln:storage-probe"],
  ])
})

test("a getter that throws (Chrome, site data blocked) gives the in-memory store", () => {
  const win = {}
  Object.defineProperty(win, "sessionStorage", {
    get() {
      throw new Error("SecurityError: access is denied for this document")
    },
  })

  isShim(safeStorage("sessionStorage", win), undefined)
})

test("a null store (Firefox, dom.storage.enabled off) gives the in-memory store", () => {
  isShim(safeStorage("localStorage", {localStorage: null}), null)
})

test("a store whose setItem throws (full or read-only) gives the in-memory store", () => {
  const broken = realStorage()
  broken.setItem = () => {
    throw new Error("QuotaExceededError")
  }

  isShim(safeStorage("localStorage", {localStorage: broken}), broken)
})

test("no window at all gives the in-memory store", () => {
  isShim(safeStorage("localStorage", undefined), undefined)
})

test("the in-memory store answers like Web Storage", () => {
  const s = memoryStorage()

  assert.equal(s.getItem("phx:theme"), null)
  s.setItem("phx:theme", "dark")
  assert.equal(s.getItem("phx:theme"), "dark")
  s.setItem("n", 3)
  assert.equal(s.getItem("n"), "3")
  s.removeItem("phx:theme")
  assert.equal(s.getItem("phx:theme"), null)
})

test("each in-memory store is its own", () => {
  const a = memoryStorage()
  const b = memoryStorage()
  a.setItem("k", "v")
  assert.equal(b.getItem("k"), null)
})
