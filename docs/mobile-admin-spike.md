# Spike: Mobile admin (LiveView Native)

**Issue:** #65 ([Stretch] Mobile admin — LiveView Native).
**Status:** research spike / feasibility doc. **No shipped feature proposed.** This
is an exploration of a focused mobile review/approve app, plus the responsive-PWA
alternative.
**Scope note:** content *moderation/approvals on the go* — read queued content and
publish or return-to-draft. **Not** full block editing.

## TL;DR

- **Is a native mobile admin feasible on this stack? Yes, narrowly.** LiveView
  Native (`live_view_native` + the SwiftUI / Jetpack Compose client plugins) can
  drive native screens from the existing BEAM, reusing our Ash actions and
  policies. But it does **not** reuse our HEEx LiveViews — every native screen
  needs a **separate render template** in a platform-specific markup
  (`.swiftui.neex` / `.jetpack.neex`), so it's a parallel UI, not a free skin.
- **The review/approve flow is a perfect minimal fit.** It's a list + a detail +
  three buttons (`Approve`/`Return`/read). That maps cleanly onto the actions that
  already exist on `Page`/`Post`: `submit_for_review`, `return_to_draft`,
  `publish`, plus the `:read`/`:published` reads. No new domain code required for a
  prototype.
- **But LiveView Native is still young**, the dep footprint is non-trivial (Elixir
  lib + per-platform native client projects + Xcode/Android toolchains), and
  version/compat with our LiveView line needs verification. That's real spike risk.
- **Auth is already solved for native clients:** reuse the headless bearer-token
  sign-in from issue #37 (`POST /api/auth/sign_in` → JWT). The native client signs
  in once, stores the JWT in the platform keychain, and presents it when connecting.
- **Recommendation:** **defer the native build; do a timeboxed throwaway spike
  first**, and in the meantime **ship the responsive PWA** of the existing
  `/editor` LiveView (which already works in a mobile browser today) as the
  pragmatic "mobile admin." The PWA covers the on-the-go review use case at a tiny
  fraction of the cost. Pursue native only if there's a concrete demand the PWA
  can't meet (push notifications for the review queue, offline, app-store presence).

---

## 1. Goal

A focused mobile app for **reviewers/admins** to:

1. **See the review queue** — content in `in_review` (and optionally `draft`),
   newest first.
2. **Read the content** — title, state, body — enough to make a call. *Reading,
   not editing.*
3. **Act** — `Approve` (→ `publish`), `Return` (→ `return_to_draft`), and for
   editors `Submit` (→ `submit_for_review`). These are exactly the inline workflow
   buttons that already exist in `KilnCMSWeb.EditorLive`.

Explicitly **out of scope:** the block editor (`ContentEditorLive`), media
management, taxonomy, analytics, webhooks, bulk destructive actions. The mobile
surface is moderation, not authoring. Full block editing on a phone fights both the
form factor and LiveView Native's current maturity (see §3, §6).

## 2. What already exists (we're not starting from zero)

The entire backend for this flow is in place — the mobile app is purely a new
*client* over existing actions and policies.

| Capability | Status | Where |
|---|---|---|
| Workflow state machine `draft → in_review → published` | ✅ | `KilnCMS.CMS.Content` `state_machine` block |
| `submit_for_review` / `return_to_draft` / `publish` actions | ✅ | `KilnCMS.CMS.Content` `actions` block |
| Role gating (editor submits, admin approves/returns) | ✅ | `Content` `policies`; `publish`/`return_to_draft` are admin-only |
| The exact list+button UI, on the web | ✅ | `KilnCMSWeb.EditorLive` (web; HEEx) |
| Per-type dispatch (`Page`, `Post`, generated types) | ✅ | `KilnCMS.CMS.ContentTypes` (`transition/list!/get_record!`) |
| Headless bearer-token sign-in (JWT) | ✅ | `KilnCMSWeb.ApiAuthController`, `POST /api/auth/sign_in` (#37) |
| Headless reads (JSON:API) incl. `:read`/`:published`/`:search` | ✅ | `AshJsonApiRouter`, `/api/json` |
| LiveView Native client | ❌ | does not exist |
| Native render templates | ❌ | does not exist |

**Key facts pinned from the code:**

- The policies enforce the role split: `policy action([:publish, :publish_scheduled])`
  and `policy action(:return_to_draft)` are `authorize_if actor_attribute_equals(:role, :admin)`.
  Editors can `submit_for_review` (it's an `:update`-type action gated to `:editor`).
  The mobile UI must mirror this — show `Approve`/`Return` only to admins, `Submit`
  only to editors on drafts — exactly as `EditorLive.render/1` does with
  `@actor.role` checks.
- The state-machine transitions are: `submit_for_review` (`draft → in_review`),
  `return_to_draft` (`in_review → draft`), `publish` (`[:draft, :in_review] → :published`),
  `unpublish` (`published → draft`), `archive` (`[…] → :archived`).
- `publish` does more than flip state — it stamps `published_at`, records a
  PaperTrail published version, fires artifacts, notifies webhooks, and sends the
  workflow email. The native client must call the **action**, never write state
  directly, so all of that runs.

## 3. Evaluating LiveView Native

LiveView Native (LVN) lets a LiveView render to a **native** client (SwiftUI on
iOS, Jetpack Compose on Android) instead of HTML, over the same Phoenix LiveView
socket and the same server-side event loop. The appeal here is obvious: our review
logic is already a LiveView (`EditorLive`), and the BEAM already holds the actions
and policies.

### 3.1 How it actually reuses our stack

- **Reuses:** the LiveView *process model*, `handle_event/3`, assigns, PubSub, and
  — most importantly — our **Ash actions and policies**. A native "Approve" tap
  becomes a `handle_event("publish", …)` that calls
  `ContentTypes.transition(kind, "publish", record, actor: actor)`, same as the web.
  All authorization, webhooks, PaperTrail, and emails come along for free.
- **Does NOT reuse:** our HEEx templates. This is the central caveat. LVN renders
  **native templates**, not HTML. A LiveView that supports native gets a separate
  render path per platform — a `.swiftui.neex` (and/or `.jetpack.neex`) template
  using SwiftUI element names (`VStack`, `List`, `Text`, `Button`), **not** the
  `<div>`/Tailwind markup in `EditorLive.render/1`. So `EditorLive` cannot be
  "pointed at mobile" as-is; we write a **parallel native render** of the same
  assigns (or, cleaner, a dedicated `EditorLive.Native` co-located module).
- **Practical consequence:** LVN saves us on *business logic and state* (large) but
  **not on UI** (we re-author every screen in native markup). For a 2-screen review
  app that's a small UI surface; for the full editor it would be a second front-end.

### 3.2 Maturity

- LVN has been through significant churn (the 0.x line, then a substantial rewrite
  around the `0.3+`/`0.4` "Core" architecture with `live_view_native` plus separate
  `live_view_native_swiftui` / `live_view_native_jetpack` client plugins and a
  `live_view_native_stylesheet` for styling). APIs and the template format have
  moved between minor versions. **Treat exact versions and the LiveView/LVN
  compatibility matrix as unverified until pinned during the spike** — this is the
  #1 thing the spike must de-risk.
- It is an actively developed, DockYard-backed project, but it is **not** at the
  maturity/stability of core LiveView. Expect rough edges, sparse docs for less
  common widgets, and breaking changes between releases.
- The "write once in HEEx, render native for free" story is **not** the reality —
  native templates are mandatory (see §3.1).

### 3.3 Dependency & toolchain footprint

- **Elixir side:** add `live_view_native`, a client plugin
  (`live_view_native_swiftui` and/or `live_view_native_jetpack`), and
  `live_view_native_stylesheet`. Plus LVN's format/template plugins. Non-trivial
  but contained to `mix.exs` + some config.
- **Native side (the real cost):** a **SwiftUI Xcode project** (macOS + Xcode +
  Apple Developer account for device/TestFlight) and/or a **Jetpack Compose Android
  Studio project**. These are full native app projects living alongside the Elixir
  repo. CI, signing, and store distribution are their own efforts.
- **Operational:** the native app connects to the same Phoenix endpoint over the
  LiveView socket. We must confirm the socket/auth path works for native clients
  (see §5) and that CSP / origin checks don't block it.

### 3.4 Version/compat caveats (must verify in the spike)

- LVN minor version ↔ our `phoenix_live_view` version compatibility.
- LVN client-plugin version ↔ LVN core version ↔ Xcode/SwiftUI and
  AGP/Compose versions.
- Whether the current LVN release supports the LiveView features we lean on (flash,
  navigation, form submit semantics) on both platforms equally — Android (Jetpack)
  support has historically trailed iOS (SwiftUI).

## 4. Prototype plan

A throwaway, iOS-first (SwiftUI) prototype. Three screens, all read/approve.

### 4.1 Screens

1. **Review queue** (`ReviewLive`, native list)
   - Lists content in `in_review` (with a toggle for `draft`), newest first.
   - Data: `ContentTypes.all/0` → per type `ContentTypes.list!(type, actor: actor)`,
     filtered to `state == :in_review` — mirrors `EditorLive.load_items/1` +
     `visible_items/3`, minus the search/select machinery.
   - Each row: title, type badge, state badge, tap → detail.

2. **Content detail** (`ReviewLive` detail / `ContentDetailLive`)
   - Read-only render: title, state, author, and the body. For a first cut, render
     the **fired/delivered** representation (what readers see) via
     `KilnCMS.Firing.Engine` or the public `/api/...` artifact, rather than the raw
     editable `blocks` tree — simplest faithful read, and avoids re-implementing the
     block renderer natively.
   - Action bar at the bottom: `Approve`, `Return` (admins), `Submit` (editors,
     drafts only).

3. **Approve / Return actions** (events, not a screen)
   - `Approve` → `handle_event("publish", …)` → `ContentTypes.transition(kind, "publish", record, actor)`.
   - `Return` → `handle_event("return", …)` → `…transition(kind, "return", record, actor)`
     (→ `return_to_draft`).
   - `Submit` → `…transition(kind, "submit", record, actor)` (→ `submit_for_review`).
   - On success: pop back to the queue and reload; on `{:error, _}` (policy/stale)
     show a flash. This is exactly `EditorLive.transition/3`'s shape.

### 4.2 Existing Ash actions used

| UI affordance | Verb (via `ContentTypes.transition/4`) | Ash action | Who | Notes |
|---|---|---|---|---|
| Approve | `"publish"` | `:publish` | admin | stamps `published_at`, PaperTrail version, artifacts, webhook, email |
| Return | `"return"` | `:return_to_draft` | admin | `in_review → draft`, sends "returned" email |
| Submit | `"submit"` | `:submit_for_review` | editor | `draft → in_review`, sends "submitted" email |
| Read queue | — | `:read` (filter `state == :in_review`) | editor/admin | policy already scopes visibility |
| Read body | — | firing/delivery read | editor/admin | render the published/fired view |

No new domain actions are needed — the prototype is a pure client over what
`KilnCMS.CMS.Content` already exposes. The actor is the JWT-resolved user, so the
same policies that protect the web editor protect the mobile app automatically.

### 4.3 Minimal `Native` LiveView module sketch

> ⚠️ **Prototype / illustrative only — NOT real code, NOT in the repo.** Element
> names, callbacks, and the LVN API surface must be checked against the pinned LVN
> version during the spike. This is a shape, not a contract.

```elixir
# lib/kiln_cms_web/live/review_live.ex  (PROTOTYPE — does not exist yet)
defmodule KilnCMSWeb.ReviewLive do
  use KilnCMSWeb, :live_view
  use KilnCMSWeb, :native   # PROTOTYPE: LVN render integration (name TBD by LVN version)

  alias KilnCMS.CMS.ContentTypes

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user           # JWT-resolved user (see §5)
    {:ok, assign(socket, actor: actor, items: queue(actor))}
  end

  # Content awaiting review, newest first — the EditorLive.load_items/1 shape,
  # filtered to in_review.
  defp queue(actor) do
    ContentTypes.all()
    |> Enum.flat_map(fn ct ->
      ct.type |> ContentTypes.list!(actor: actor) |> Enum.map(&{ct.type, &1})
    end)
    |> Enum.filter(fn {_kind, r} -> r.state == :in_review end)
    |> Enum.sort_by(fn {_k, r} -> r.updated_at end, {:desc, DateTime})
  end

  @impl true
  def handle_event("publish", %{"kind" => kind, "id" => id}, socket),
    do: {:noreply, transition(socket, kind, id, "publish")}

  def handle_event("return", %{"kind" => kind, "id" => id}, socket),
    do: {:noreply, transition(socket, kind, id, "return")}

  defp transition(socket, kind, id, verb) do
    actor = socket.assigns.actor
    record = ContentTypes.get_record!(kind, id, actor: actor)

    case ContentTypes.transition(kind, verb, record, actor: actor) do
      {:ok, _} -> assign(socket, :items, queue(actor))  # + flash
      {:error, _} -> socket  # + "not allowed right now" flash (policy/stale)
    end
  end

  # Native render — SwiftUI markup, NOT HEEx. Lives in a `.swiftui.neex`
  # template or a `render/1` in a co-located Native module, depending on LVN's
  # conventions for the pinned version.
  #
  #   <List>
  #     <%= for {kind, r} <- @items do %>
  #       <Section>
  #         <Text><%= r.title %></Text>
  #         <Text><%= r.state %></Text>
  #         <%= if @actor.role == :admin do %>
  #           <Button phx-click="publish" phx-value-kind={kind} phx-value-id={r.id}>
  #             Approve
  #           </Button>
  #           <Button phx-click="return" phx-value-kind={kind} phx-value-id={r.id}>
  #             Return
  #           </Button>
  #         <% end %>
  #       </Section>
  #     <% end %>
  #   </List>
end
```

The point this sketch makes: **the Elixir/event/Ash half is essentially the web
`EditorLive` minus search/select/bulk**, and the genuinely new work is the **native
template** and the **native client project**, not the server logic.

## 5. Auth strategy for native clients

**Reuse the headless bearer-token sign-in from issue #37 — do not invent a new
mechanism.**

- The native app shows a sign-in form, then `POST /api/auth/sign_in` with
  `{"email", "password"}` (`KilnCMSWeb.ApiAuthController`). On success it gets back
  `{"token": "<jwt>", "user": {id, email, role}}`.
- Store the JWT in the **platform secure store** (iOS Keychain / Android Keystore),
  not plain prefs.
- Present the JWT when establishing the LiveView socket connection (as a connect
  param / `Authorization: Bearer` on the socket handshake). The server resolves it
  to a `User` the same way the JSON:API pipeline does (`load_from_bearer` →
  `set_actor`), so the LiveView's `current_user`/actor is the real RBAC user and
  **all `Content` policies apply unchanged**.
- The `role` returned by sign-in lets the client pre-shape the UI (hide
  `Approve`/`Return` from non-admins), but the **server policy is the real
  boundary** — a forged client still can't `publish` without `role: :admin`.

Caveats to confirm in the spike: the LiveView socket on native must accept and
verify the bearer token at connect time (the web flow uses the session cookie, not
a bearer — this connect-param path is the new bit), and token lifetime/refresh UX
(re-sign-in on expiry for the prototype; refresh tokens later).

## 6. Risks, effort, recommendation

### 6.1 Risks

- **LVN maturity & version churn (top risk).** Template format and APIs have moved
  between minors; the LiveView↔LVN compat matrix must be verified before committing.
  Mitigation: timeboxed throwaway spike (§7).
- **Parallel UI, not a free skin.** Every native screen is hand-authored native
  markup. Cheap for 2 screens; expensive if scope creeps toward the editor.
- **Two front-ends to maintain.** Native review UI drifts from the web editor unless
  deliberately kept minimal.
- **Toolchain & distribution.** Xcode/Android Studio, signing, Apple Developer
  account, TestFlight/Play Console, app review. This is ongoing overhead the web/PWA
  path doesn't have.
- **Android (Jetpack) lag.** Compose support has historically trailed SwiftUI;
  iOS-first is realistic, Android may be a second phase.
- **Socket auth path is new.** Bearer-on-socket-connect for native isn't exercised
  by the current web flow; needs validation.
- **Block rendering on native.** Rendering the raw `blocks` tree natively is real
  work — mitigated by rendering the fired/delivered view for read-only detail.

### 6.2 Rough effort

| Item | Effort |
|---|---|
| Throwaway spike: LVN wired, one native list screen, sign-in via #37 JWT, one `publish` round-trips on a simulator | **S–M** (timeboxed, days) |
| iOS prototype: queue + detail + approve/return, read-only body via fired view | **M** |
| Productionized iOS app: polish, error/empty/loading states, token refresh, TestFlight | **L** |
| Android (Jetpack) parity | **+M–L** |
| **Alternative — responsive PWA of `/editor`** | **S** (CSS/responsive pass + web-app manifest + service worker) |

### 6.3 Recommendation

**Defer the native build. Do the throwaway spike first, and ship the PWA now.**

1. **Now (cheap, high-value): responsive PWA of the existing LiveView.** `/editor`
   (`EditorLive`) already runs in a mobile browser and already has the review/approve
   buttons. A responsive pass (the layout already uses `sm:` breakpoints) plus a web
   app manifest + a minimal service worker gives an installable "mobile admin" that
   covers the on-the-go review use case with **no native toolchain, no second
   front-end, no app review** — and it works on both platforms immediately. This is
   the pragmatic answer to "mobile admin" for the foreseeable term.
2. **Timeboxed throwaway LVN spike** (only if there's appetite): wire
   `live_view_native` + `live_view_native_swiftui`, pin the LVN↔LiveView versions,
   build the **review queue** native list, sign in via the #37 JWT, and prove **one
   `publish` round-trips** from a SwiftUI simulator through the real Ash action and
   policy. Success criteria: versions pin cleanly; bearer-on-socket auth resolves the
   actor; the policy correctly blocks a non-admin `publish`. Explicitly record LVN
   API gaps and breaking-change risk.
3. **Only if the spike passes *and* there's a concrete need the PWA can't meet**
   (native push for the review queue, offline, app-store presence) — productize the
   iOS prototype behind that justification, Android as a later phase.

The native path is feasible and the review/approve flow is an ideal minimal fit for
it, but it buys app-store presence and native affordances at a meaningful, ongoing
cost. The **PWA delivers the actual goal — review/approve on the go — far sooner and
cheaper**, and the LVN spike can be run independently to inform a later decision
without blocking anything.

## Sources

- [LiveView Native](https://native.live/) — DockYard
- [`liveview-native/live_view_native`](https://github.com/liveview-native/live_view_native)
- [`liveview-native/liveview-client-swiftui`](https://github.com/liveview-native/liveview-client-swiftui)
- [`liveview-native/liveview-client-jetpack`](https://github.com/liveview-native/liveview-client-jetpack)
- [`liveview-native/live_view_native_stylesheet`](https://github.com/liveview-native/live_view_native_stylesheet)
- Issue #37 — headless bearer-token sign-in (`KilnCMSWeb.ApiAuthController`, `POST /api/auth/sign_in`)
- `KilnCMS.CMS.Content` — workflow state machine + `submit_for_review`/`return_to_draft`/`publish` actions and policies
- `KilnCMSWeb.EditorLive` — the existing web review/approve UI this mirrors
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view) — socket/event model reused by LVN
- [PWA — Progressive Web Apps (MDN)](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps) — the responsive alternative
