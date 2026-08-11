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
// v2: the offline page became per-org (#629). The bump is what makes an already
// installed worker drop its precached copy of the old unbranded page — without
// it the URL is unchanged, so the existing cache entry would just keep serving.
const CACHE = `${CACHE_PREFIX}v2`
// Served by KilnCMSWeb.OfflineController, not from `priv/static`. Precached by
// the SAME URL it is served from, so the copy in the cache is the one this
// origin's org would have rendered — the worker is per-origin, and subdomain
// tenancy makes the origin the org.
const OFFLINE_URL = "/offline.html"

// How stale a precached offline page may get before a successful navigation
// refreshes it in the background. Cache Storage ignores `Cache-Control`
// entirely and `install` only re-runs when the bytes of THIS file change — so
// without a refresh, a site that rebrands after a device installed the app
// would show that device the old name and colour forever. Which is the bug
// #629 exists to fix, just frozen per-device instead of per-build.
const OFFLINE_MAX_AGE_MS = 24 * 60 * 60 * 1000

// Never rejects. `/offline.html` used to be a `priv/static` file, which could
// not fail; it is now a router route behind a rate limiter and a branding
// lookup, so it CAN 429 or 5xx. A rejected `cache.add` inside `waitUntil`
// fails the whole installation — no fetch handler, no install prompt, and no
// web push (#628) — over a fallback page that is by definition optional. So the
// failure is swallowed and retried on the first successful navigation instead.
async function cacheOffline() {
  try {
    const cache = await caches.open(CACHE)
    // `cache: "reload"` so a stale HTTP-cached copy can't be what we precache.
    await cache.add(new Request(OFFLINE_URL, {cache: "reload"}))
  } catch (_error) {
    // Nothing to do here: `refreshOffline` will try again later.
  }
}

// Re-fetch the offline page if the cached copy is older than OFFLINE_MAX_AGE_MS,
// or missing because the install-time attempt failed.
async function refreshOffline() {
  const cache = await caches.open(CACHE)
  const cached = await cache.match(OFFLINE_URL)

  if (cached) {
    const date = Date.parse(cached.headers.get("date") || "")
    if (Number.isFinite(date) && Date.now() - date < OFFLINE_MAX_AGE_MS) return
  }

  await cacheOffline()
}

self.addEventListener("install", (event) => {
  event.waitUntil(cacheOffline().then(() => self.skipWaiting()))
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
    fetch(request)
      .then((response) => {
        // The network is up, so this is the moment to top up the fallback: it
        // is the only hook that runs without `sw.js` itself changing. Off the
        // response path via `waitUntil`, and a no-op unless the copy is stale.
        event.waitUntil(refreshOffline())
        return response
      })
      .catch(async () => {
        // Scoped to our own cache: a bare `caches.match` searches every cache
        // on the origin and would happily serve someone else's `/offline.html`.
        const offline = await caches.open(CACHE).then((cache) => cache.match(OFFLINE_URL))

        // The precache can be missing if storage was evicted, or if the
        // install-time fetch failed and no navigation has succeeded since.
        // Better a terse response than a broken promise, which surfaces as a
        // generic network error.
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
    // One tag PER EVENT KIND, not one overall. Coalescing repeated review
    // requests is the point — a reviewer who was away returns to one
    // notification rather than nine. Coalescing *different* events is a bug:
    // with `renotify: false`, a "Changes requested" would silently overwrite an
    // undismissed "Review requested" with no sound and no re-alert, and the
    // reviewer would never learn the second thing happened.
    tag: data.tag || "kiln",
    renotify: false,
    // Per-org app icon when the payload carries one (#1146 / #629). The worker
    // is static and has no tenant, so branding arrives on the encrypted JSON
    // rather than from a request. Badge stays stock: Android renders it
    // monochrome, and a full-colour ≥512 square is the wrong asset for that.
    icon: data.icon || "/images/app-icon-192.png",
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
      // Focus a window that is already ours rather than opening a second one —
      // an installed PWA has exactly one.
      //
      // Focus, and *only* focus: `client.navigate()` is a full-page navigation
      // of that very window, which would tear down an editor the reviewer had
      // unsaved work in — the opposite of what reusing the window is for. It
      // also rejects for a client this worker does not control, which
      // `includeUncontrolled` deliberately admits. So the reviewer lands in the
      // app and taps through from there; only when there is no window at all do
      // we open one at the target.
      for (const client of clients) {
        if (new URL(client.url).origin === self.location.origin && "focus" in client) {
          return client.focus()
        }
      }

      return self.clients.openWindow(target.href)
    })
  )
})
