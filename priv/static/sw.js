// Service worker for the installable editor PWA (issues #65, #628).
//
// Deliberately minimal. Three jobs, and nothing else:
//
//   1. Exist, with a `fetch` handler — Chromium won't offer "Install" without
//      one, so this is the price of admission for an installable app.
//   2. Show a readable offline page instead of the browser's error page when a
//      navigation fails.
//   3. Show a notification when the review queue gains something, and focus the
//      already-open editor when it's tapped (#628).
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

// ── Push (#628) ─────────────────────────────────────────────────────────────
//
// The payload is JSON encrypted end-to-end by KilnCMS.Push.Encryption and
// carries NO draft content — a kind, a canned line, and a link to a filtered
// queue. See the KilnCMS.Push moduledoc for why.

self.addEventListener("push", (event) => {
  // `showNotification` is not optional. A browser that grants push permission
  // and then receives a push the worker does not surface will, after a couple
  // of times, show its own "This site has been updated in the background"
  // notification — or revoke the permission outright. So every branch here,
  // including a malformed payload, ends in one.
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch (_error) {
    // Not JSON. Fall through to the defaults rather than throwing, which would
    // leave the promise rejected and the notification unshown.
  }

  const title = data.title || "KilnCMS"
  const options = {
    body: data.body || "Something needs your attention.",
    // Same tag for every review request, so a reviewer who was away returns to
    // one notification saying something is waiting rather than to nine.
    tag: data.tag || "kiln-review",
    renotify: false,
    icon: "/images/app-icon-192.png",
    badge: "/images/app-icon-192.png",
    data: {url: data.url || "/editor"}
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const target = new URL(
    (event.notification.data && event.notification.data.url) || "/editor",
    self.location.origin
  )

  // Only ever navigate within our own origin: `data.url` arrives over the
  // network, and an absolute URL to somewhere else would turn a notification
  // into an open redirect out of the installed app.
  if (target.origin !== self.location.origin) return

  event.waitUntil(
    self.clients.matchAll({type: "window", includeUncontrolled: true}).then((clients) => {
      // Reuse a window that is already on the editor rather than opening a
      // second one — an installed PWA has exactly one, and `openWindow` in it
      // would replace the reviewer's place in whatever they were editing.
      for (const client of clients) {
        if (new URL(client.url).origin === self.location.origin && "focus" in client) {
          client.navigate(target.href).catch(() => {})
          return client.focus()
        }
      }

      return self.clients.openWindow(target.href)
    })
  )
})
