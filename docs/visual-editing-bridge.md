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
  data-kiln-preview-token="SFMyNTY…"  <!-- minted server-side for this document -->
  data-kiln-auto>                    <!-- enable edit mode on load -->
</script>
```

The bridge needs a credential only to see a **draft**: the live-preview socket
and `fetchPreview` both read, and without one they see published content only.
Give it a **preview token**. Don't give it an API key.

- **A preview token (recommended).** Your front-end *server* mints one for the
  document it is rendering with `POST /api/content/:type/:id/preview-token`
  (see [api.md → Preview tokens](api.md#preview-tokens)), using an editor's
  **`:read`** key that never leaves the server, and writes the token into the
  page. The browser then holds a credential that is **read-only**, opens **one
  document**, and expires in **15 minutes**. If it leaks, it exposes that one
  draft briefly and nothing else.
- **An API key (`data-kiln-api-key`), still accepted.** A `:read` key on an
  editor's account works (never a `:read_write` key: the bridge only reads).
  But it is a standing credential that sees **every** draft until someone
  revokes it, and in the browser anyone can read it from the page source. Use
  it only where no server can mint tokens, such as a static edit-mode build,
  and never in the public site.

When both are configured, the bridge sends only the token.

### Preview tokens and long edit sessions

A token lasts 15 minutes, and an editing session can last an afternoon.
Neither side extends the token: `PreviewToken` tokens are stateless and cannot
be renewed. The front end **re-mints** instead and hands the bridge the new
token. Both surfaces enforce the lifetime:

- the annotated read answers `404 invalid_preview` to an expired token, never
  a fall-back to the published page, so a lapsed token is noticed;
- the live socket re-verifies its token every 30 seconds (the #775 re-check)
  and **closes once the token has expired**. `bridge.js` reconnects on close
  with whatever token it holds by then. A leaked token therefore streams for
  at most 15 minutes plus one check interval, not for as long as a tab stays
  open.

Two refresh patterns, and most front ends use both:

1. **Re-mint per render.** Every server render of an edit-mode page mints a
   fresh token and writes it into `data-kiln-preview-token`. A front end that
   re-renders on each `onUpdate` (e.g. `router.refresh()` in Next.js) gets a
   new token each time an editor saves, which needs no extra code:

   ```js
   // app/[...slug]/page.tsx (server): runs on every draft-mode render
   // `kiln` is a @kiln-cms/client instance holding an editor's :read key, server-only
   const { token } = await kiln.mintPreview(doc.type, doc.id)
   // …render <script src=…/bridge.js data-kiln-preview-token={token} data-kiln-auto>
   ```

   Then hand the new token to the bridge after each refresh. Call
   `KilnBridge.setPreviewToken(t)` with the value from the new render, since
   the script tag is not re-executed.

2. **Re-mint on an interval.** An editor can leave a tab open without saving
   anything. For that case, have the page ask a small endpoint on your own
   server for a new token well inside the 15 minutes:

   ```js
   // Client side. /api/kiln-preview-token is YOUR route: it mints with the
   // server-held key and returns only {token}.
   setInterval(async () => {
     const r = await fetch(`/api/kiln-preview-token?type=post&id=${doc.id}`)
     if (r.ok) KilnBridge.setPreviewToken((await r.json()).token)
   }, 10 * 60 * 1000)   // 10 min, inside the 15-minute lifetime
   ```

   Gate that route on your own edit-mode session. It mints a draft credential
   for whoever calls it.

`setPreviewToken` does not interrupt an open socket. The socket keeps its old
token until the server closes it at that token's expiry, then reconnects with
the new one. A socket that is already down (refused, or backing off after
refusals) reconnects immediately. If refusals continue for about two and a
half minutes, the bridge stops retrying until it is given a new token or
`connect` is called again, so an abandoned tab does not retry forever.

### 2. Render the annotated preview in edit mode

In edit mode, fetch content from the annotated route instead of the public
artifact, so the stega addresses are present and drafts are visible:

```
GET /api/visual-editing/<type>/<slug>
x-kiln-preview-token: SFMyNTY…     # token for this document → its draft
Authorization: Bearer kiln_…        # (or) editor key → draft; neither → published
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
| `configure({host, previewToken, apiKey})` | Override script-tag config. |
| `setPreviewToken(token)` | Swap in a freshly minted token. The live socket reconnects with it (see [long edit sessions](#preview-tokens-and-long-edit-sessions)). |
| `enable()` / `disable()` | Turn the click-to-edit overlay on/off. |
| `onUpdate(cb)` | Register a callback fired on a live `update` push. |
| `connect(type, id)` | Open the live-preview socket for a document. The socket reconnects after the server closes it. |
| `disconnect()` | Close the live-preview socket and stop reconnecting. |
| `fetchPreview(type, slug, locale?)` | Fetch the annotated preview JSON with the token, or else the key. |
| `decode(text)` / `clean(text)` | Stega decode / strip (mirrors the server). |

## The protocol (for other clients)

- **Stega payload** (per encoded string): `{type, id, slug, field, block?}` —
  `block` is present for a block field, absent for a document scalar. Wire format
  is documented in `KilnCMS.VisualEditing.Stega`; `bridge.js` has a matching JS
  decoder (verified cross-language).
- **Annotated read:** `GET /api/visual-editing/:type/:slug` → the `:json`
  artifact shape plus the working copy's custom fields
  (`{id, type, title, slug, blocks, custom_fields}`) with editable strings
  stega-encoded. Plain-string custom-field values are encoded block-less
  (`{type, id, slug, field}`); values consumers parse — JSON-encoded structures,
  URLs — and non-strings are left untouched. `no-store`; draft visibility
  follows the caller's credential. A preview token (the `x-kiln-preview-token`
  header, or `?preview_token=` for a client that cannot set headers) reads its
  own document's working copy. The route's type and slug must be that
  document's, the host must be the token's site, and `?locale=`, if given,
  must be the document's. Any mismatch, and an expired or tampered token, gets
  `404` with code `invalid_preview`. A presented token is the only credential
  consulted. (The public fired artifact still omits `custom_fields`.)
- **Live push:** `WS /ws/bridge?type=&id=&preview_token=` (or `&api_key=`) →
  JSON frames `{event: "update", type, id, title, excerpt}`. Connect is refused
  when a token does not name this `type`/`id` on this host's site, or has
  expired, and when a key's actor (or an anonymous caller) can't read the
  document. The server closes the connection when its periodic re-check
  refuses, including when a token expires.
- **Deep-link:** `/editor/site/:type/:slug?focus=<block_id>` (in-context editor,
  block-level). Locale variants share a slug, so the bridge also passes
  `locale=` from the stega payload (#1104); absent locale falls back to the
  site default. The structured editor accepts the field-level twin:
  `/editor/content/:type/:id?focus=<field>` scrolls to, opens (if collapsed),
  pulses, and focuses that field's input — `<field>` is a custom field's `name`
  or a core field (`title`, `slug`, `excerpt`, `seo_title`, …). Unknown fields
  are ignored. Useful when a front end's content lives in custom fields rather
  than blocks, where the in-context editor has nothing to show.
- **Bridge click routing:** a payload with `block` opens the in-context editor
  (`/editor/site/:type/:slug?focus=<block_id>`); a block-less payload other than
  `title` opens the structured editor field-focused
  (`/editor/content/:type/:id?focus=<field>`). `title` stays on the in-context
  editor, which edits it inline natively.
- **postMessage:** when `bridge.js` runs inside a parent frame, a click posts
  `{source: "kiln-bridge", event: "edit", payload, url}` to `window.parent`
  instead of opening a tab — the hook a future Kiln "Presentation" console (a
  Kiln-hosted iframe of your site) will consume.

## Security

- **Drafts require a preview token or an API key; writes require a key.** A
  preview token reads one document's draft for 15 minutes. What a key *reads*
  follows its owner's role (an editor's `:read` key sees drafts), and only a
  `:read_write` key can write, through the write API (#330). An anonymous
  caller sees only published content.
- **Cross-origin is off by default.** The annotated read, the write API, and the
  live-preview socket are all gated by the shared **`CORS_ORIGINS`** allowlist
  (the socket via `check_origin`). Set it to your front end's origin(s).
- **Feature flag.** `VISUAL_EDITING_ENABLED=false` turns the whole surface off
  (`/api/visual-editing/...` 404s; the socket refuses).
- **Keep the editor key on a server.** Mint preview tokens with it there and
  give the browser the token. Load `bridge.js` only in the edit-mode build.

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

### Preview iframe sandbox (#1059)

The preview `<iframe>` always carries a `sandbox` attribute. Whether it also
gets `allow-same-origin` depends on whether `PRESENTATION_PREVIEW_URL` resolves
to the **same origin as the console**:

| Preview origin | `sandbox` | Cookies in the frame | Can reach console DOM |
|---|---|---|---|
| Same as `/editor/...` | `allow-scripts` | No (opaque origin) | No |
| Separate front-end host | `allow-scripts allow-same-origin` | Yes, for that host | No (SOP) |

Same-origin is the configuration `docs/deploy-write-visual-editing.md` walks
through when Kiln's own delivery *is* the front end. Without the restrictive
sandbox, delivery scripts (including code injection or stored XSS) would share
the console's origin and reach its DOM in the signed-in editor's browser.

**Cookie consequence:** a same-origin preview cannot show gated or member-only
content as the signed-in user — the frame is anonymous. Point
`PRESENTATION_PREVIEW_URL` at a separate front-end origin if authenticated
preview matters. The console shows a banner when it detects the same-origin case.

The click-to-edit bridge still works: opaque frames post with origin `"null"`,
and the `PresentationFrame` hook accepts that when it deliberately sandboxed
without `allow-same-origin`, using `event.source === contentWindow` as the
real guard.

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
  rendered as clickable body text). Custom fields are stega-annotated on the
  preview read, so a click on one lands the structured editor focused on that
  field — in-place editing of custom fields on the front end itself remains a
  follow-on.
- **Rich-text editing granularity** is block-level, not per-span (spans lack
  stable keys); the whole block opens in the editor.
