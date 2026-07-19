# Deploying the write API + visual-editing features

Deploy checklist for the headless-write / visual-editing arc: **write-capable
headless APIs (#330)** and the **visual-editing bridge + Presentation console
(#355)**. Shipped across PRs #385, #388, #390, #391.

Production is a **manual Coolify _Redeploy_** on the VPS. A Redeploy rebuilds the
image (`mix assets.deploy` at build time) and runs pending migrations at
container start. The mechanical steps are automatic — **verify, don't hand-run.**

> **Read §4 before deploying.** This set has **no migration and no *required*
> env var**, but it does two things that go live the moment you deploy: it
> **reverses D7** (the headless surface is no longer read-only — `:read_write`
> API keys can now write over REST/GraphQL, not just `/mcp`), and it adds a new
> public WebSocket. Neither is dangerous, but both deserve a conscious look.

## What changed (deploy-relevant)

| Area | Schema | Assets | New env/config | New Oban queue |
| --- | --- | --- | --- | --- |
| #330 write API (JSON:API + GraphQL) | none | none | none (reuses API keys + `CORS_ORIGINS`) | none |
| #355 bridge / annotated read / `bridge.js` | none | **`bridge.js`** static + JS hooks | `VISUAL_EDITING_ENABLED` (default on), `CORS_ORIGINS` | none |
| #355 Presentation console | none | JS hook (`PresentationFrame`), CSS pulse | `PRESENTATION_PREVIEW_URL` (unset ⇒ setup hint) | none |
| #355 `/ws/bridge` live push | none | none | none |

Key points:

- **No migrations.** Body writes ride the existing `blocks` column via a public
  `block_tree` argument; nothing schema-changed. (The `org_id` column you may see
  on content is multi-tenancy #336 — a *different* deploy, not this one.)
- **Assets rebuild is required** for the `FocusBlock` / `PresentationFrame` JS
  hooks and the `.kiln-focus-pulse` CSS — handled automatically by
  `mix assets.deploy` in the image build. `priv/static/bridge.js` is a
  hand-written static file (allow-listed in `KilnCMSWeb.static_paths/0`) and
  ships in the image too. Deploying a *prebuilt* image without a rebuild would
  omit the hooks (the write API still works; the in-app console/deep-link focus
  wouldn't).
- **No new *required* env vars.** `VISUAL_EDITING_ENABLED` defaults **on**;
  `CORS_ORIGINS` and `PRESENTATION_PREVIEW_URL` are only needed to *use* the
  bridge cross-origin (§4).
- **POOL_SIZE: no change.** No new Oban queue. The one new firing path — a
  `published`-guarded re-fire on in-place `:update` of live content — enqueues to
  the **existing `:firing` queue**, so worker concurrency is unchanged.

## 1. Pre-deploy

- [ ] Deploy `main` at/after the `#391` squash merge (`fdabc52` or later) — that
      commit contains the whole arc (#385/#388/#390/#391).
- [ ] **Audit existing `:read_write` API keys** (`/editor/api-keys`). Before this
      deploy they could only write via `/mcp`; after it they can also write over
      JSON:API (`POST`/`PATCH`/`DELETE`) and GraphQL mutations — *as their owning
      user, under the same policies* (read-only key or anonymous still can't
      write; publish stays admin-only; hard delete is never exposed to any key).
      Revoke any `:read_write` key you don't recognize. Nothing changes for
      `:read` keys.
- [ ] Decide whether you actually want the bridge reachable cross-origin
      (§4). If not, you can deploy as-is — the write API is same-origin-safe and
      the bridge surfaces simply won't be reachable from another origin until you
      set `CORS_ORIGINS`.

## 2. Deploy

- [ ] In Coolify, **Redeploy** the app (full image rebuild).
- [ ] Watch the **build** logs for `mix assets.deploy` and `mix release`
      succeeding.

## 3. Post-deploy verification

- [ ] **App healthy** — `GET /up` returns `200`; no migration to run (boot should
      log "Already up").
- [ ] **`bridge.js` served** — `GET /bridge.js` returns `200` with a JS
      content-type (it references `KilnBridge`).
- [ ] **Write API reachable, still gated** — with an editor `:read_write` key:

      ```bash
      curl -s -X POST https://<host>/api/json/posts \
        -H 'accept: application/vnd.api+json' \
        -H 'content-type: application/vnd.api+json' \
        -H "authorization: Bearer $KILN_RW_KEY" \
        -d '{"data":{"type":"post","attributes":{"title":"deploy smoke","slug":"deploy-smoke"}}}'
      ```

      expects `201` (a draft). The **same call with a `:read` key must `403`.**
      Then clean up the draft in the editor.
- [ ] **Presentation console** — as an **admin**, open
      `/editor/presentation/post/<some-slug>`. Without `PRESENTATION_PREVIEW_URL`
      set it shows the "No preview URL configured" hint (expected); with it set
      (§4) it frames the front end.
- [ ] **WebSocket passthrough** — the new `/ws/bridge` socket rides the same
      Cowboy/Bandit WS upgrade path your proxy already allows for `/live`,
      `/ws/gql`, `/ws/collab`. No proxy change is expected; if those work,
      `/ws/bridge` works. (It refuses connections unless `VISUAL_EDITING_ENABLED`
      and the origin/API-key check pass — a 4xx/immediate-close on a bad request
      is correct.)

## 4. Optional — enable cross-origin visual editing

The write API, the annotated preview read (`/api/visual-editing/:type/:slug`),
and the `/ws/bridge` socket are all **cross-origin gated by `CORS_ORIGINS`**
(prod default: `[]` = deny all cross-origin). An external front end can't use any
of them until you allow its origin.

- [ ] Set **`CORS_ORIGINS`** to your front end's origin(s), comma-separated
      (e.g. `https://app.example.com`). This one allowlist governs cross-origin
      reads, the write API, and the bridge WebSocket (`check_origin`). It is
      **not** `CHECK_ORIGINS` — that's for extra hostnames of *this* app; the
      bridge is a genuinely different origin.
- [ ] Set **`PRESENTATION_PREVIEW_URL`** to where your front end serves content —
      a template with `{path}`/`{type}`/`{slug}`/`{locale}` placeholders (a bare
      base URL gets `{path}` appended), e.g.
      `https://app.example.com{path}?kilnPreview=1`. Unset ⇒ the console shows a
      setup hint. The front-end origin is derived from this for `postMessage`
      validation.
- [ ] On the **front end** (its responsibility, not Kiln's): load
      `https://<kiln-host>/bridge.js` in an **edit-mode build only**, and inject
      the editor's `kiln_…` API key there — **never** in the public build. The
      key grants draft reads + writes; treat it like any editor credential. See
      `docs/visual-editing-bridge.md`.
- [ ] Verify end to end: from the front end's edit-mode build, hover a rendered
      value → it outlines → click → you land in the Kiln editor (or the
      Presentation console's side pane) on that field; save; the frame refreshes.

### Turning it off

- [ ] Set **`VISUAL_EDITING_ENABLED=false`** to disable the *whole* visual-editing
      surface (the annotated read `404`s, `/ws/bridge` refuses) without a
      redeploy-to-old-image. The plain write API (#330) stays available — it has
      no separate flag; to lock writes back down, mint only `:read` keys and keep
      `CORS_ORIGINS` empty.

## 5. Fired-artifact note (optional, no action required)

The `:json` fired artifact now carries the document `id` and each block's `_id`
(the visual-editing addressing anchors). **Already-published** artifacts don't
have them until the content is next re-fired (re-published, or an in-place edit
of live content). Delivery falls back to a live render on a cache miss, and the
annotated preview always renders live, so **nothing breaks** — a headless
consumer that wants `_id` on the *public* artifact for existing content can
force it by re-publishing, or by re-firing published content in bulk
(`bin/kiln_cms eval 'KilnCMS.Firing.…'` per your firing tooling). Purely
additive; low priority.

## 6. Rollback

- [ ] Redeploy the previous image tag. **No schema to reverse.** The extra
      `id`/`_id` keys in any artifacts fired under the new code are additive and
      ignored by the old renderers. The write routes/mutations simply disappear
      with the old image; existing `:read_write` keys revert to MCP-only writes.

---

**Bottom line:** a plain Redeploy of `main` ships the write API and the
visual-editing surfaces with **no migration, no POOL_SIZE change, no required
secret**. Two conscious calls before you deploy: (1) the headless surface is now
**writable** by `:read_write` keys — audit them (§1); (2) the bridge is inert
cross-origin until you set **`CORS_ORIGINS`** (+ `PRESENTATION_PREVIEW_URL`) —
§4. Everything else is verify-boot.
