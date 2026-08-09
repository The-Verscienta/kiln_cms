# Spike: mobile admin (LiveView Native)

**Issue:** [#65](https://github.com/The-Verscienta/kiln_cms/issues/65) — *[Stretch] Mobile admin (LiveView Native)*.
**Scope:** content moderation on the go — read the review queue and approve or
return. **Not** block editing on a phone.
**Date pinned:** 2026-07-31. Every version claim below was checked against
hex.pm and the resolver on that date; re-check before acting on it.

## TL;DR

**LiveView Native cannot be adopted by this codebase today.** Not "risky" —
blocked, by dependency resolution:

| | LiveView Native 0.4.0-rc.1 requires | KilnCMS runs |
|---|---|---|
| `phoenix` | `~> 1.7.0` | **1.8.8** |
| `phoenix_live_view` | `~> 1.0.2` | **1.2.7** |

Adopting LVN means downgrading two major framework lines under the whole
application. That is not a trade worth making for a two-screen approvals app.

Three further facts compound it:

- **There is no Android client.** `live_view_native_jetpack` does not exist on
  hex — the package 404s. The SwiftUI client is the only released one, so
  "mobile admin" via LVN means *iOS only*, indefinitely.
- **The newest release is a release candidate from March 2025**, and no package
  in the LVN family has published since 2025-03-05 — roughly seventeen months of
  silence as of this writing. There is no `0.4.0` final.
- **The rest of the work is a parallel UI anyway.** LVN reuses the LiveView
  process model and our Ash actions, but *not* our HEEx. Every native screen is
  hand-authored SwiftUI markup.

**What shipped instead, in this PR:** the `/editor` review queue is now an
**installable PWA** — a web app manifest, app icons, an offline fallback, and
`display: standalone` so it launches chromeless from the home screen. It reaches
the actual goal (approve content from a phone) on both platforms, with no native
toolchain, no app review, and no second front end. See [§5](#5-what-shipped-the-pwa).

**Revisit LVN when** it publishes a stable release supporting Phoenix 1.8+ and
LiveView 1.2+, *and* there is a concrete need the PWA cannot meet (native push
for the review queue, offline authoring, app-store presence).

---

## 1. The flow this is about

A reviewer with a phone wants to:

1. **See what's waiting** — content in `in_review`, newest first.
2. **Read enough to judge it** — title, state, body. Reading, not editing.
3. **Act** — Approve (→ `publish`), Return (→ `return_to_draft`); and for
   editors, Submit (→ `submit_for_review`).

Explicitly out of scope: the block editor, media, taxonomy, analytics, bulk
destructive actions. Full block editing on a phone fights both the form factor
and (see below) LVN's maturity.

## 2. The backend already exists

Nothing in the domain needs building. Both the PWA and any future native client
are pure *clients* over actions that ship today.

| Capability | Where |
|---|---|
| `draft → in_review → published` state machine | `KilnCMS.CMS.Content`, `state_machine` block |
| `submit_for_review` / `return_to_draft` / `publish` | `KilnCMS.CMS.Content`, `actions` block |
| Tier gating (editors submit, admins approve/return) | `KilnCMS.CMS.Checks.OrgAdmin` on the `:publish` and `:return_to_draft` policies |
| The list + buttons UI, on the web | `KilnCMSWeb.EditorLive` |
| Per-type dispatch (`Page`, `Post`, dynamic types) | `KilnCMS.CMS.ContentTypes` — `transition/4`, `list!/2`, `get_record!/3` |
| Headless bearer sign-in (JWT) | `KilnCMSWeb.ApiAuthController`, `POST /api/auth/sign_in` (#37); a 2FA account finishes at `POST /api/auth/sign_in/verify` (#726) |
| Bearer verification without a `conn` | `KilnCMSWeb.BearerAuth` — `token_from_params/1`, `user_from_token/1` |
| Tenant-from-host on a raw socket | `lib/kiln_cms_web/graphql_socket.ex` |

`publish` does considerably more than flip a column — it stamps `published_at`,
records a PaperTrail published version, fires artifacts, notifies webhooks, and
sends the workflow email. **Any client must call the action, never write state
directly.**

### 2.1 Three things the June 2026 draft of this spike got wrong

This document was first drafted before epic #336 (multi-tenancy) and #419
(per-org tiers) landed. Those changed the answers:

1. **Roles are no longer global.** The policies read
   `KilnCMS.CMS.Checks.OrgAdmin`, which resolves through
   `KilnCMS.Accounts.Scoping.effective_tier/2` — a user's *membership tier on the
   request's org* — not `actor_attribute_equals(:role, :admin)`. `EditorLive`
   correspondingly gates its buttons on `@tier`, not `@actor.role`.

2. **`POST /api/auth/sign_in` returns the wrong thing for UI shaping.**
   `ApiAuthController` returns `user.role` — the *global* role. For a user with
   memberships across orgs that is not their effective tier anywhere in
   particular. A native client that hid or showed Approve based on it would show
   the button to someone the server will refuse. This is a real gap for any
   headless review client; filed as
   [#627](https://github.com/The-Verscienta/kiln_cms/issues/627).

3. **The tenant comes from the host, not the token.** `KilnCMSWeb.Plugs.SetTenant`
   resolves the org from `conn.host`. A native app therefore has to dial *that
   org's* subdomain or custom domain; a single hardcoded endpoint would silently
   serve the default org. See [§4](#4-what-a-native-client-would-actually-need).

## 3. Evaluating LiveView Native

### 3.1 What it would and wouldn't reuse

**Reuses:** the LiveView process model, `handle_event/3`, assigns, PubSub — and
our Ash actions and policies. A native Approve tap becomes
`ContentTypes.transition(kind, "publish", record, actor: actor, tenant: org)`,
exactly as the web does, so authorization, webhooks, PaperTrail and email all
come along unchanged.

**Does not reuse:** our HEEx. LVN renders platform markup (`VStack`, `List`,
`Text`, `Button`) from `.swiftui.neex` templates. `EditorLive` cannot be
"pointed at mobile" — you write a parallel native render of the same assigns.
For two screens that is small; for the editor it would be a second front end.

So LVN saves the *business logic and state* half and none of the *UI* half.

### 3.2 The blocking evidence

Resolved against the real registry on 2026-07-31:

```
$ mix deps.get   # phoenix ~> 1.8.8, phoenix_live_view ~> 1.2.0, live_view_native ~> 0.4.0-rc.1
Because "your app" depends on "live_view_native ~> 0.4.0-rc.1" which depends on
"phoenix_live_view ~> 1.0.2", "phoenix_live_view ~> 1.0.2" is required.
So, because "your app" depends on "phoenix_live_view ~> 1.2.0", version solving failed.
** (Mix) Hex dependency resolution failed
```

Resolving the LVN family *alone*, with no constraints from this app, shows the
ceiling it pins everything to:

```
live_view_native 0.4.0-rc.1
live_view_native_stylesheet 0.4.0-rc.1
live_view_native_swiftui 0.4.0-rc.1
phoenix 1.7.24
phoenix_live_view 1.0.18
```

There is no combination that admits Phoenix 1.8 or LiveView 1.2.

### 3.3 Project health

| Package | Newest | Published |
|---|---|---|
| `live_view_native` | 0.4.0-rc.1 | 2025-03-04 |
| `live_view_native_swiftui` | 0.4.0-rc.1 | 2025-03-04 |
| `live_view_native_stylesheet` | 0.4.0-rc.1 | 2025-03-04 |
| `live_view_native_live_form` | 0.4.0-rc.1 | 2025-03-04 |
| `live_view_native_jetpack` | **does not exist** | — |

The whole family stopped at one release candidate on the same day and has not
moved since. The last *stable* release is `0.3.1` (2024-10), which requires
`phoenix_live_view ~> 0.20.10` — further away still.

This isn't a knock on the idea; LVN is a DockYard-backed project that has been
through real architectural work. It is a statement about what adopting it would
mean *right now*: pinning a production CMS to a stale release candidate of an
unreleased line, on one platform, at the cost of two framework downgrades.

## 4. What a native client would actually need

Recorded so a future attempt doesn't rediscover it. Three items; the first two
are smaller than the June draft assumed, because the pieces landed in the
meantime for GraphQL.

1. **Bearer auth on the LiveView socket.** The web flow authenticates the socket
   from the session cookie; a native client has a JWT. The endpoint declares:

   ```elixir
   socket "/live", Phoenix.LiveView.Socket,
     websocket: [connect_info: [session: @session_options]],
     longpoll: [connect_info: [session: @session_options]]
   ```

   No bearer path. But the verification primitive already exists and is
   `conn`-free: `KilnCMSWeb.BearerAuth.token_from_params/1` +
   `user_from_token/1`, which `KilnCMSWeb.GraphqlSocket` uses today. The June
   draft listed this as the unverified risk; it is now a solved problem with an
   in-tree precedent.

2. **Tenant on the socket.** `/live` has no `connect_info: [:uri]`, so a raw
   native connection has no host to resolve an org from and would fall through
   to the default org — a silent cross-site bug under multi-tenancy, not an
   error. `GraphqlSocket` and `BridgeSocket` both already carry `:uri` for
   exactly this reason and are the pattern to copy.

3. ~~**A `return_to_draft` endpoint.**~~ **Done** —
   [#626](https://github.com/The-Verscienta/kiln_cms/issues/626). Half of the
   approve/return pair used to be LiveView-only, so a native or headless review
   client could approve but could not send anything back to its author.
   `PATCH /:id/return-to-draft` now exists on both the compiled types and
   `/api/json/entries`, and GraphQL exposes `returnPostToDraft` /
   `returnPageToDraft` / `returnEntryToDraft`. It is admin-gated, like `publish`.

Item 3 also matters for the non-LVN route: if a native app is ever genuinely
wanted, the cheaper path is a plain SwiftUI/Compose app over the existing
JSON:API (`/api/json`) with the #37 bearer token — no LVN, no framework
downgrade, no coupling to a stalled dependency. That trades LVN's free
server-side state for full control of the client. Given LVN's current state,
it is the more likely shape of any future native work.

## 5. What shipped: the PWA

Delivered with this document, because it reaches the goal the issue names:

- **`KilnCMSWeb.ManifestController`** serves `/manifest.webmanifest?locale=…`
  **per org and per locale** (#630)
  — `name`, `short_name` and `theme_color` come from `KilnCMS.Branding.for_org/1`,
  so a white-labelled site installs under its own name and colour (#48). A
  static file could not do this.
- **`start_url` is `/editor?status=in_review`** — the review queue, not a
  generic dashboard. `scope` stays `/` so a sign-in redirect stays inside the
  installed window. A stable `id` (`/editor`) keeps existing installs valid if
  the landing filter ever changes — and it stays stable across locales too, since
  a mismatched id makes a browser discard the whole manifest update rather than
  rename the app.
- **App icons** at 192/512 plus a separate maskable 512 and an iOS
  `apple-touch-icon`, all derived from the ember mark.
- **`priv/static/sw.js`** — a deliberately minimal service worker. It exists
  because Chromium will not offer "Install" without a `fetch` handler, and it
  serves `offline.html` when a *GET navigation* fails. It caches **no**
  application HTML and no API responses: every editor page is per-user and
  per-org and mostly unpublished drafts, so a cache there would be a
  cross-account leak on a shared device and a stale-content bug on every deploy.
- **Advertised only where authoring is authorised.** The manifest link is
  emitted from the root layout on `assigns[:pwa]`, which the
  `:live_editor_required` / `:live_admin_required` on_mount hooks set — so a
  public reader is never offered the admin app, and `app.js` keys service worker
  registration off that same link.

### 5.1 What the PWA does not do

Honest limits. Each is filed, so closing #65 doesn't bury them:

- ~~**No push notifications for the review queue.**~~ **Done** —
  [#628](https://github.com/The-Verscienta/kiln_cms/issues/628). A reviewer can
  turn notifications on per device in `/editor/settings`, and a submission for
  review reaches their home screen. Off unless the deployment sets a VAPID pair
  (`mix kiln.vapid.gen`, then `KILN_VAPID_*`), and the payload never carries
  draft content — see `KilnCMS.Push`. iOS still needs 16.4+ *and* the app added
  to the home screen; the toggle hides itself where the browser cannot honour it.
- **No offline reading or queued approvals.** By design — see the caching note
  above. Offline authoring is a substantially larger design problem than a cache
  entry, and is not filed as a follow-up because it is not obviously wanted.
- **Install icons and the offline page are stock KilnCMS on every org**, even a
  white-labelled one: the manifest cannot honestly declare `sizes` for a logo of
  unknown dimensions, and the offline page is a static file with no org context
  — [#629](https://github.com/The-Verscienta/kiln_cms/issues/629).
- ~~**The manifest is not localized**~~ **Done** —
  [#630](https://github.com/The-Verscienta/kiln_cms/issues/630). The link now
  carries `?locale=`, so `name`, `description` and the shortcut labels are
  translated. `short_name` is not (a brand name is a proper noun), and Android
  labels the home-screen icon from `short_name` — so what this reaches is the
  install dialog, app list, splash screen and shortcut menu, not the icon label.
- **iOS gives no install prompt.** Safari requires the user to pick "Add to Home
  Screen" manually; there is no `beforeinstallprompt` equivalent.
- **The iOS status bar stays opaque.** `apple-mobile-web-app-status-bar-style:
  black-translucent` would give the full-bleed look, but it lets the status bar
  overlay the page — which needs `viewport-fit=cover` and
  `env(safe-area-inset-*)` padding through the editor chrome, or the header
  renders under the notch. Deliberately deferred to that work.

## 6. Recommendation

1. **Now — use the PWA.** It is in this PR. It covers review-and-approve from a
   phone on both platforms.
2. **Do not start an LVN prototype.** It cannot compile against this
   application's Phoenix and LiveView versions, and there is no Android client
   to prototype toward.
3. **Re-evaluate on a signal, not a schedule.** Specifically: a stable
   `live_view_native` release declaring `phoenix ~> 1.8` and
   `phoenix_live_view ~> 1.2`, plus a released Jetpack client. Until both exist,
   this stays closed.
4. **If a native app becomes a hard requirement before then**, build it over the
   JSON:API with the #37 bearer token rather than LVN. The `return_to_draft`
   endpoint that used to block this has landed
   ([§4](#4-what-a-native-client-would-actually-need), item 3).

## Sources

- [LiveView Native](https://native.live/) — DockYard
- [`liveview-native/live_view_native`](https://github.com/liveview-native/live_view_native)
- [`liveview-native/liveview-client-swiftui`](https://github.com/liveview-native/liveview-client-swiftui)
- Package versions and requirements: [hex.pm API](https://hex.pm/api/packages/live_view_native), read 2026-07-31
- [Web app manifest (MDN)](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Manifest)
- [Installability criteria (MDN)](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable)
- Issue #37 — headless bearer sign-in; `KilnCMSWeb.ApiAuthController`
- Epic #336 — multi-tenancy; `KilnCMSWeb.Plugs.SetTenant`, `KilnCMSWeb.Tenant`
- Issue #419 — per-org capability tiers; `KilnCMS.Accounts.Scoping.effective_tier/2`
