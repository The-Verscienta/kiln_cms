// Web Storage that is there even when the browser blocks it (#2773).
//
// With site data blocked, Chrome's `window.localStorage` getter throws a
// SecurityError; with `dom.storage.enabled` off, Firefox's is `null`; a full or
// read-only store throws on `setItem`. LiveSocket's constructor reads both
// stores (and calls `sessionStorage.getItem`), so any of those stopped the
// whole of app.js: no LiveView, no hooks, no console chrome.
//
// `safeStorage(name)` probes the store once, with a set/remove round trip, and
// returns it when that works. Otherwise it returns an in-memory store with the
// same three methods, which lasts for the page view: enough for LiveView and
// for the console's sidebar and nav-section toggles, which then simply do not
// persist. The root layout's inline theme script runs before this bundle and
// carries its own guard.

const PROBE_KEY = "kiln:storage-probe"

export function memoryStorage() {
  const items = new Map()
  return {
    getItem: key => (items.has(String(key)) ? items.get(String(key)) : null),
    setItem: (key, value) => {
      items.set(String(key), String(value))
    },
    removeItem: key => {
      items.delete(String(key))
    },
  }
}

export function safeStorage(name, win = globalThis.window) {
  try {
    const storage = win[name]
    if (storage) {
      storage.setItem(PROBE_KEY, "1")
      storage.removeItem(PROBE_KEY)
      return storage
    }
  } catch (_) {
    // Blocked, or unwritable: fall through to the in-memory store.
  }
  return memoryStorage()
}
