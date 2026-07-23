# Visual-editing bridge (external front ends)

Kiln can give an **external** headless front end (Next, Astro, SvelteKit, a
mobile web view — anything rendering from Kiln's read APIs) a Sanity
Presentation-style **in-context editing** overlay: hover a rendered value, click,
and land in the Kiln editor focused on exactly that field. This is issue
[#355](https://github.com/The-Verscienta/kiln_cms/issues/355); it builds on the
write-capable headless API ([#330](https://github.com/The-Verscienta/kiln_cms/issues/330)).

> **The structural caveat (read this first).** Kiln does **not** render your
> external front end, so it cannot know which DOM element maps to which field on
> its own. Your front end must **opt in**: load `bridge.js` and render the
> *annotated preview* in edit mode. This is inherent to headless — every CMS
> (Sanity stega, Storyblok bridge, Tina) has the same requirement. For Kiln's
> **own** LiveView site, in-context editing needs no bridge — it ships natively
> ([#354](https://github.com/The-Verscienta/kiln_cms/issues/354), `/editor/site/:type/:slug`).

## How it fits together

```
   external front end                         Kiln
 ┌─────────────────────┐   annotated read   ┌──────────────────────────┐
 │ renders JSON +       │ ◀───────────────── │ GET /api/visual-editing/ │
 │ bridge.js overlay    │  (stega-encoded)   │   :type/:slug            │
 │                      │                    │                          │
 │ click → deep-link ───┼──────────────────▶ │ /editor/site/:type/:slug │
 │                      │                    │   ?focus=<block_id>      │
 │ writes ──────────────┼──────────────────▶ │ PATCH /api/json/:type/:id│  (#330)
 │ onUpdate ◀───────────┼──────────────────  │ WS /ws/bridge (live push)│
 └─────────────────────┘                     └──────────────────────────┘
```

Four moving parts, all first-party:

1. **Addressing metadata.** The fired `:json` artifact carries each block's
   stable `_id` and the document `id` (always on — non-sensitive, also handy as
   React keys). The **annotated** preview additionally **stega-encodes** each
   editable string with its full address `{type, id, slug, field, block}` — an
   invisible run of Unicode Tag characters appended to the value. The visible
   text is unchanged; the invisible tail rides into your DOM, so the overlay can
   recover the field at the point of a click with no markup from you.
2. **`bridge.js`** — a dependency-free overlay you embed. It decodes the stega
   (or reads explicit `data-kiln-*` attributes), outlines editable regions, and
   on click deep-links to the Kiln editor. Served at `/bridge.js`.
3. **The deep-link round-trip.** A click opens `/editor/site/:type/:slug?focus=<block_id>`;
   the Kiln editor scrolls to and focuses that block. Edits write through the
   #330 API and re-fire.
4. **Live push (optional).** `bridge.js` can open `wss://…/ws/bridge` to receive
   `update` frames when an editor changes the content, and fire your `onUpdate`
   callback so the page re-fetches and re-renders.

## Integrating your front end

### 1. Load the bridge (edit mode only)

Only load it for editors previewing the site — never in production for end
users. A typical gate: a `?kilnPreview=1` query param or a preview cookie.

```html
<script
  src="https://cms.example.com/bridge.js"
  data-kiln-host="https://cms.example.com"
  data-kiln-api-key="kiln_…"    <!-- an editor/admin :read_write key -->
  data-kiln-auto>              <!-- enable edit mode on load -->
</script>
```

`data-kiln-api-key` is optional and only used for the live-preview socket and
`fetchPreview`. It is an editor credential — inject it **only** into the
edit-mode build, never the public site.

### 2. Render the annotated preview in edit mode

In edit mode, fetch content from the annotated route instead of the public
artifact, so the stega addresses are present and drafts are visible:

```
GET /api/visual-editing/<type>/<slug>
Authorization: Bearer kiln_…        # editor key → draft; anonymous → published
```

Render its strings as-is (the stega is invisible). That's all — hovering now
outlines editable regions, and clicking opens the editor.

The `bridge.js` helper does the fetch for you:

```js
const doc = await window.KilnBridge.fetchPreview("post", "hello-world")
// render doc.title, doc.blocks, … exactly as your public renderer does
```

### 3. (Optional) live updates

```js
window.KilnBridge
  .onUpdate(() => rerenderFromKiln())   // e.g. router.refresh() in Next.js
  .connect("post", doc.id)              // watch this document
```

### 4. (Optional) explicit annotations instead of stega

If you'd rather not rely on invisible characters (e.g. for images or wrapper
elements, where there's no text to encode), annotate elements yourself from the
`_id`s in the JSON:

```html
<img src="…"
     data-kiln-type="post" data-kiln-id="<doc id>" data-kiln-slug="hello-world"
     data-kiln-field="url" data-kiln-block="<block _id>">
```

`bridge.js` reads `data-kiln-*` in preference to stega.

## The `window.KilnBridge` API

| Method | What it does |
|--------|--------------|
| `configure({host, apiKey})` | Override script-tag config. |
| `enable()` / `disable()` | Turn the click-to-edit overlay on/off. |
| `onUpdate(cb)` | Register a callback fired on a live `update` push. |
| `connect(type, id)` | Open the live-preview socket for a document. |
| `fetchPreview(type, slug)` | Fetch the annotated preview JSON (uses the key). |
| `decode(text)` / `clean(text)` | Stega decode / strip (mirrors the server). |

## The protocol (for other clients)

- **Stega payload** (per encoded string): `{type, id, slug, field, block?}` —
  `block` is present for a block field, absent for a document scalar. Wire format
  is documented in `KilnCMS.VisualEditing.Stega`; `bridge.js` has a matching JS
  decoder (verified cross-language).
- **Annotated read:** `GET /api/visual-editing/:type/:slug` → the `:json`
  artifact shape (`{id, type, title, slug, blocks}`) with editable strings
  stega-encoded. `no-store`; draft visibility follows the caller's actor.
- **Live push:** `WS /ws/bridge?type=&id=&api_key=` → JSON frames
  `{event: "update", type, id, title, excerpt}`. Connect refuses if the actor
  can't read the document.
- **Deep-link:** `/editor/site/:type/:slug?focus=<block_id>` (in-context editor,
  block-level). The structured editor accepts the field-level twin:
  `/editor/content/:type/:id?focus=<field>` scrolls to, opens (if collapsed),
  pulses, and focuses that field's input — `<field>` is a custom field's `name`
  or a core field (`title`, `slug`, `excerpt`, `seo_title`, …). Unknown fields
  are ignored. Useful when a front end's content lives in custom fields rather
  than blocks, where the in-context editor has nothing to show.
- **postMessage:** when `bridge.js` runs inside a parent frame, a click posts
  `{source: "kiln-bridge", event: "edit", payload, url}` to `window.parent`
  instead of opening a tab — the hook a future Kiln "Presentation" console (a
  Kiln-hosted iframe of your site) will consume.

## Security

- **Writes and drafts require an API key.** The annotated read and the write API
  (#330) share the `:read_write` API-key model and the resource policies — a
  read-only key or anonymous caller sees only published content and cannot write.
- **Cross-origin is off by default.** The annotated read, the write API, and the
  live-preview socket are all gated by the shared **`CORS_ORIGINS`** allowlist
  (the socket via `check_origin`). Set it to your front end's origin(s).
- **Feature flag.** `VISUAL_EDITING_ENABLED=false` turns the whole surface off
  (`/api/visual-editing/...` 404s; the socket refuses).
- **Never ship the editor key to the public site.** Load `bridge.js` and the key
  only in the edit-mode build.

> **Deploying this?** See [deploy-write-visual-editing.md](deploy-write-visual-editing.md)
> — the operator checklist (audit `:read_write` keys; set `CORS_ORIGINS` +
> `PRESENTATION_PREVIEW_URL`; no migration/POOL_SIZE change).

## The Presentation console (side-by-side editing)

Beyond the deep-link, Kiln ships a **Presentation console** at
`/editor/presentation/:type/:slug` (editor/admin) — your front end framed on the
left, an inline field editor on the right, Sanity Presentation-style.

Point Kiln at your front end with a URL template (the origin is derived from it
for `postMessage` validation):

```
PRESENTATION_PREVIEW_URL="https://front.example.com{path}?kilnPreview=1"
```

Placeholders: `{path}` (the locale-prefixed public path, e.g. `/blog/hello`),
`{type}`, `{slug}`, `{locale}`. A bare base URL gets `{path}` appended. Your
front end serves that URL with `bridge.js` in edit mode (the `?kilnPreview=1`
flag is yours to gate on).

The loop: click a region in the framed site → `bridge.js` `postMessage`s the
field up to the console (origin-validated) → the console opens that block's
field in the right pane → edit (same contenteditable hooks as in-context
editing) → **Save** writes through Ash (`:update`, policies + PaperTrail native)
→ the console broadcasts on the preview topic, so `bridge.js` (over `/ws/bridge`)
re-fetches and the frame updates. No deep-link tab needed.

The console edits the inline block fields (heading / quote / rich-text, same as
#354) **and** the document **title** (click the rendered title). Rich-text is
fully clickable — every word carries its block's address (see below). Other
fields (SEO, custom fields) offer an "Open the full editor" link.

## What's covered

- **Rich-text is stega-encoded per span**, so a click anywhere in a rich-text
  region resolves to its block. (The edit round-trip still opens the whole
  rich-text block — Portable Text spans have no stable key.)
- **Live push works for every content type**, compiled (page/post) and the
  dynamic entry tier alike — the bridge socket subscribes to the same
  `content_preview:<type>:<id>` topic the editor broadcasts on, keyed by the
  public type name.
- **Console scalar editing** covers `title` today.

## Limitations & follow-ons

- **Console scalar editing** is `title` only; `excerpt` works when the front end
  annotates it, and SEO/custom fields route to the full editor (they aren't
  rendered as clickable body text).
- **Rich-text editing granularity** is block-level, not per-span (spans lack
  stable keys); the whole block opens in the editor.
