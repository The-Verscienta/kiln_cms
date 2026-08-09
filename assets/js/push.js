// Web Push opt-in for the editor PWA (#628).
//
// Drives the toggle on /editor/settings. Everything here is a no-op on a
// browser without the APIs — iOS below 16.4, a PWA that was never installed,
// Firefox with push disabled — because the toggle is a capability, not a
// setting, and a control that errors when clicked is worse than one that never
// appeared. The LiveView renders it only when the server has VAPID keys; this
// hides it again when the browser cannot honour it.
//
// The subscription is pushed to the LiveView with `pushEvent` rather than
// POSTed to a controller: the LiveView already knows the actor and the org, so
// a controller would mean a route, a CSRF token and a second authorization
// path for no gain.

import {b64uToBuf, bufToB64u} from "./passkeys"

const supported = () =>
  "serviceWorker" in navigator && "PushManager" in window && "Notification" in window

// `navigator.serviceWorker.ready` resolves only once an active worker controls
// the scope — and it NEVER rejects. app.js registers behind a `.catch(() => {})`,
// so on a browser that refuses registration (Firefox private browsing, storage
// disabled) awaiting it hangs forever: the reviewer grants the OS notification
// permission and then nothing happens, with the toggle stuck off and no error.
// Race it against a deadline so that dead end becomes a message.
const READY_TIMEOUT_MS = 5000

function registration() {
  return Promise.race([
    navigator.serviceWorker.ready,
    new Promise((_resolve, reject) =>
      setTimeout(() => reject(new Error("service worker not ready")), READY_TIMEOUT_MS)
    )
  ])
}

// `getKey` returns null when a key is unavailable, and an empty string passes
// every server-side `is_binary/1` guard — the row stores, the UI says
// notifications are on, and the first delivery prunes it silently.
function requireKey(subscription, name, fromJson) {
  const encoded = fromJson || (subscription.getKey(name) && bufToB64u(subscription.getKey(name)))
  if (!encoded) throw new Error(`push subscription has no ${name}`)
  return encoded
}

// A coarse family so the settings list can say "the phone" from "the laptop".
// Deliberately not the full user-agent string: it is rendered back into the
// page, it is a fingerprinting surface, and nobody reading the list wants it.
function deviceLabel() {
  const ua = navigator.userAgent || ""
  const platform =
    /iPhone|iPad|iPod/.test(ua) ? "iOS"
    : /Android/.test(ua) ? "Android"
    : /Macintosh/.test(ua) ? "Mac"
    : /Windows/.test(ua) ? "Windows"
    : /Linux/.test(ua) ? "Linux"
    : "Browser"
  const browser =
    /Edg\//.test(ua) ? "Edge"
    : /OPR\//.test(ua) ? "Opera"
    : /Chrome\//.test(ua) ? "Chrome"
    : /Firefox\//.test(ua) ? "Firefox"
    : /Safari\//.test(ua) ? "Safari"
    : null
  return browser ? `${platform} · ${browser}` : platform
}

export const PushToggle = {
  mounted() {
    this.applicationServerKey = this.el.dataset.vapidKey

    if (!supported() || !this.applicationServerKey) {
      // Tell the server so it can explain *why* rather than showing a toggle
      // that silently does nothing.
      this.pushEvent("push_unsupported", {})
      return
    }

    this.el.addEventListener("click", event => {
      event.preventDefault()
      this.el.dataset.enabled === "true" ? this.disable() : this.enable()
    })

    this.syncState()
  },

  // Reconcile the browser's actual subscription with what the server thinks.
  // They drift: a reviewer can revoke permission in browser settings, or clear
  // site data, and neither tells the server.
  async syncState() {
    try {
      const subscription = await this.current()
      this.pushEvent("push_state", {
        subscribed: !!subscription,
        permission: Notification.permission
      })
    } catch (_error) {
      // No usable service worker: the capability is not there, so say so
      // rather than leaving an enabled control that goes nowhere.
      this.pushEvent("push_unsupported", {})
    }
  },

  async current() {
    const ready = await registration()
    return ready.pushManager.getSubscription()
  },

  async enable() {
    // Must be inside the click handler's task: a permission prompt not tied to
    // a user gesture is what browsers penalise, and what the issue calls a dark
    // pattern. Nothing here runs on page load.
    const permission = await Notification.requestPermission()

    if (permission !== "granted") {
      this.pushEvent("push_denied", {permission})
      return
    }

    try {
      const ready = await registration()
      const subscription = await ready.pushManager.subscribe({
        // Required by every browser for a payload-bearing push, and true: every
        // push this app sends results in a visible notification.
        userVisibleOnly: true,
        applicationServerKey: new Uint8Array(b64uToBuf(this.applicationServerKey))
      })

      const keys = subscription.toJSON().keys || {}

      this.pushEvent("push_subscribed", {
        endpoint: subscription.endpoint,
        p256dh: requireKey(subscription, "p256dh", keys.p256dh),
        auth: requireKey(subscription, "auth", keys.auth),
        label: deviceLabel()
      })
    } catch (_error) {
      // Subscribe rejects for reasons the reviewer cannot act on individually
      // (a push service unreachable, a key the browser will not accept). One
      // honest failure message beats five.
      this.pushEvent("push_failed", {})
    }
  },

  async disable() {
    const subscription = await this.current()
    if (!subscription) return this.pushEvent("push_state", {subscribed: false})

    const endpoint = subscription.endpoint

    // Unsubscribe locally FIRST. If the server call is what failed, the browser
    // is still subscribed and the row still exists, so the state is consistent
    // and a retry works. The other order can leave a device receiving
    // notifications for a subscription the server has forgotten and can no
    // longer prune.
    await subscription.unsubscribe().catch(() => {})
    this.pushEvent("push_unsubscribed", {endpoint})
  }
}
