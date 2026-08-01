// Service worker for the installable editor PWA (issue #65).
//
// Deliberately minimal. Two jobs, and nothing else:
//
//   1. Exist, with a `fetch` handler — Chromium won't offer "Install" without
//      one, so this is the price of admission for an installable app.
//   2. Show a readable offline page instead of the browser's error page when a
//      navigation fails.
//
// It caches NO application HTML and NO API responses, on purpose. Every editor
// page is per-user and per-org (epic #336) and most of it is unpublished draft
// content; a cache here would be a cross-account leak on a shared device and a
// stale-content bug on every deploy. LiveView also holds its own state over the
// websocket, which a cached shell would desynchronise. Offline *authoring* is a
// much larger design problem than a cache entry — see docs/mobile-admin-spike.md.
//
// Registered only from editor/admin pages (assets/js/app.js), so a public
// reader never gets a service worker.

const CACHE_PREFIX = "kiln-offline-"
const CACHE = `${CACHE_PREFIX}v1`
const OFFLINE_URL = "/offline.html"

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      // `cache: "reload"` so a stale HTTP-cached copy can't be what we precache.
      .then((cache) => cache.add(new Request(OFFLINE_URL, {cache: "reload"})))
      .then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      // Only OUR older versions. A blanket "delete everything that isn't mine"
      // would silently wipe any cache a later feature opens on this origin.
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key.startsWith(CACHE_PREFIX) && key !== CACHE)
            .map((key) => caches.delete(key))
        )
      )
      .then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", (event) => {
  const request = event.request

  // Only GET page navigations. Returning without calling `respondWith` leaves
  // the request entirely to the browser, which is what we want for assets, the
  // LiveView websocket, and every non-GET (intercepting a failed POST would
  // swallow the form submission behind an offline page).
  if (request.method !== "GET" || request.mode !== "navigate") return

  event.respondWith(
    fetch(request).catch(async () => {
      // Scoped to our own cache: a bare `caches.match` searches every cache on
      // the origin and would happily serve someone else's `/offline.html`.
      const offline = await caches.open(CACHE).then((cache) => cache.match(OFFLINE_URL))

      // The precache can be missing if storage was evicted. Better a terse
      // response than a broken promise, which surfaces as a generic network error.
      return (
        offline ||
        new Response("Offline.", {
          status: 503,
          headers: {"Content-Type": "text/plain; charset=utf-8"}
        })
      )
    })
  )
})
