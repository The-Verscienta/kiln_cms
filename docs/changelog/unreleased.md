# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

<a id="plugin-sdk-docker"></a>

- **A Dockerfile that runs `mix deps.get` before copying the whole core must
  first `COPY sdk/kiln_plugin sdk/kiln_plugin`; the core's own Dockerfile does.**
  The plugin SDK is a `path:` dependency of the core now (see the next
  entry), so `mix deps.get` reads its `mix.exs`. A build that copies the
  pinned core in one step, as `projects/README.md` shows, needs nothing. One
  modelled on the core's Dockerfile, which copies `mix.exs` and `mix.lock`
  alone to cache the dependency layer, fails at `deps.get` until it copies
  `sdk/kiln_plugin` too. `sdk/fixtures/` is a test-only dependency, which a
  prod `deps.get` doesn't read.
  ([#1909](https://github.com/The-Verscienta/kiln_cms/issues/1909))

<a id="chunked-embeddings-migration"></a>

- **A new, empty table — `document_chunk_embeddings` — arrives by migration;
  nothing writes to it until `chunk_long_documents` is turned on.** The
  migration only adds: the table, its HNSW index and a lookup index. Turning
  the knob on (`SEARCH_CHUNK_LONG_DOCUMENTS=true`, or `chunk_long_documents:
  true` in `config :kiln_cms, KilnCMS.Search`) embeds long records as they are
  next saved; run `mix kiln.embed_all` to backfill the rest, which costs about
  twice a full re-embed for a corpus of long records. Chunks are charged to the
  `"search_embedding"` budget as unattended work, 300 chunks an hour per org
  at the defaults, so a large backfill takes several hours unless
  `embedding_per_org_limit` is raised for it. See the next entry under Added.
  ([#1940](https://github.com/The-Verscienta/kiln_cms/issues/1940))

<a id="plugin-sdk"></a>

- **Plugins can ship as Hex, git or `path:` dependencies: the plugin contract
  moved, under the same module names, into its own package, `kiln_plugin`.**
  A plugin's entry module does `use Kiln.Plugin`, a macro, and Mix compiles a
  dependency before the project that uses it, so with the contract inside the
  core a plugin added as a dependency failed with "module Kiln.Plugin is not
  loaded". `Kiln.Plugin`, `Kiln.Block` and `Kiln.Block.*`, `Kiln.FieldType`,
  `Kiln.Tokens`, `Kiln.Forms.SpamCheck` (with its `Context`) and
  `Kiln.ImageBackend` now live in `sdk/kiln_plugin`, which the core takes as a
  `path:` dependency with `override: true`; the modules are unchanged, so
  overlays compile as before. A plugin that depends on `{:kiln_plugin,
  "~> 1.0"}` can contribute blocks, field types (without a colocated client
  hook), spam checks, image backends, nav items, children and queues. Content
  types, domains, advisory checks and LiveViews on `KilnCMSWeb` need the core,
  so those plugins stay `projects/` overlays. Adding a dependency plugin still
  means a line in the core's `mix.exs`. Because the core overrides the
  package, Mix no longer checks a plugin's requirement on it, so
  `mix kiln.plugins.doctor` does. `Kiln.Plugins` gains a
  `__mix_recompile__?/0` over its plugins' compiled modules, so an edit to a
  dependency plugin reaches the registries the core bakes at compile time
  without `--force`. CI builds and tests the package on its own, compiles a
  fixture plugin against only the package, and runs the suite with that
  fixture installed as a dependency. The package is versioned and tagged on
  its own (`kiln_plugin-v1.0.0`) and published to Hex from
  `release-clients.yml`; until that first publish, links into its docs from
  the core's reference 404.
  ([#1909](https://github.com/The-Verscienta/kiln_cms/issues/1909))

<a id="image-backends"></a>

- **A plugin can contribute an image backend (`Kiln.ImageBackend`) — an
  external service such as Cloudflare Images that takes new image uploads and
  renders their variants and transforms from URLs.** A new plugin callback,
  `image_backends/0`, and an operator setting,
  `config :kiln_cms, :image_backend, Module`, which selects one; installing a
  plugin changes nothing until it is selected and reports itself configured.
  A new image upload bound for the operator's store goes to the backend when
  it accepts it — after metadata stripping, and never an image whose strip
  failed. Documents, video, audio and a site's own bucket (#1559) are
  untouched. The row records the backend's name in the new nullable
  `media_items.image_backend` column, and `KilnCMS.Storage` resolves it, so
  downloads, rotation, deletion and every other operation on that item reach
  the backend that holds it, whichever is selected later. The variant worker
  records the backend's URLs for the same labels, sizes and types the encoder
  would have written (`ImageProcessor.plan/4`), so the `variants` map reads
  the same to every client; `/media/:id/t/…` redirects to the backend after
  Kiln's own signing, allowlist and policy checks. A backend that can't render
  falls back to Kiln's encoder. The selected backend's delivery origin joins
  `img-src`. `mix kiln.plugins.doctor` checks the contract and the name, and
  System → Plugins says whether a backend is receiving uploads.
  `mix kiln.media.adopt_image_backend` hands the backend the rows imported by
  URL whose images it already holds (`key_for_url/1`), through a new
  system-only `adopt_into_image_backend` action on media items. The Cloudflare
  Images plugin itself ships separately.
  ([#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955))

<a id="chunked-embeddings"></a>

- **Semantic search can see past the first 512 tokens of a long record:
  `chunk_long_documents` embeds the rest of its text in overlapping chunks.**
  A record's vector covers the first window of its `search_text`, which the
  model truncates at 512 tokens, and since #1585 searchable custom fields make
  prose-heavy records run well past it. A record with no blocks had nothing
  else to be found by, and the relevance floor judged it by a vector that
  never saw the passage the query matched. With the knob on (off by default),
  the embedding job also splits the text past the window into windows of the
  serving's length, `chunk_overlap` tokens apart (64), at most
  `chunk_max_per_document` (8) per record, each prefixed with the title. They
  are stored in their own table rather than as synthetic rows in
  `block_embeddings`, whose consumers read every row as a block. Hybrid
  search's block leg then reaches a record through its nearest chunk as well
  as its nearest block, so it is reported as `block` and the floor judges it
  by `min(document, block, chunk, tag)`. Boundaries are counted in words at
  0.6 words a token — the lean build has no tokenizer, and the estimate errs
  towards overlap, never towards a gap. A re-embed replaces a record's chunks
  in one transaction and reuses unchanged ones; a lock or a hard purge deletes
  them. Each chunk that reaches the model costs one unit of the
  `"search_embedding"` budget, charged as unattended work so it stops at
  `embedding_unattended_share` and leaves editors their reserve; a spent window
  snoozes the job until it rolls over. Off, nothing is written and no stored
  vector changes. See
  `docs/semantic-search-plan.md`, "Long documents".
  ([#1940](https://github.com/The-Verscienta/kiln_cms/issues/1940))

<a id="prosemirror-view-paste-xss"></a>

- **prosemirror-view 1.42.6 for GHSA-c8x8-7fp4-3x9w: pasting HTML into the
  rich-text editor can no longer run script.** The advisory (HIGH) is an XSS
  in prosemirror-view's paste handling, which the TipTap editor bundled into
  `app.js` uses. A non-breaking `npm audit fix` in `assets/` also takes
  markdown-it 14.3.2 and linkify-it 5.0.2 (GHSA-253c-mchw-3w2r, quadratic
  parsing with `linkify: true`) and TipTap 2.27.3. TipTap's own
  `mergeAttributes()` advisory (GHSA-cp6q-959q-f8rh, MODERATE) is fixed only
  in TipTap 3 and stays open until the editor moves to v3. Outside the shipped
  bundle, `clients/js` moves to vitest 5 (critical and high advisories in its
  test-only tinypool, vite and esbuild) and `examples/astro-blog` to Astro 7;
  both report no advisories now.

<a id="tiptap-3"></a>

- **The rich-text editor moves to TipTap 3 for GHSA-cp6q-959q-f8rh, and keeps
  underlines it used to drop; a co-editing tab still on the old bundle edits
  solo until it reloads.** The advisory (MODERATE) is in TipTap's
  `mergeAttributes()`: an attribute object with an own `__proto__` key turns
  into inherited DOM attributes, a path to script in the editor. It is fixed
  only in TipTap 3. StarterKit 3 bundles Link, Underline, ListKeymap and
  TrailingNode. Kiln keeps its own `safeHref`-gated Link and turns
  StarterKit's off, and turns TrailingNode off so a closing table or code
  block does not save an empty paragraph after it. Underline stays on: the
  server already stored and rendered underline marks, but the old editor had
  no such mark and stripped one from API-authored prose the next time the
  block was edited. Ctrl/⌘U now applies it. The shared Yjs schema gains that
  mark, so the collab schema version goes from 2 to 3, and a tab open across
  the deploy is refused from the room ("stale bundle") instead of stripping
  its peers' underlines. It keeps editing solo with autosave. Under the hood:
  `@tiptap/extension-collaboration-cursor` becomes `-caret`, the table
  row/cell/header packages fold into `@tiptap/extension-table`,
  `y-prosemirror` gives way to `@tiptap/y-tiptap`, and `setContent` takes an
  options object (v3 emits an update by default, so the reconnect reload now
  passes `emitUpdate: false` explicitly).

<a id="toolbar-keeps-editor-focus"></a>

- **Clicking a rich-text block's toolbar button keeps the caret in the text, so
  the first letters typed straight after Bold are no longer lost.** The block
  editor's toolbar let the browser move focus to the button on mousedown. The
  button's `chain().focus()` hands focus back to the editor only on the next
  animation frame, so keystrokes in that gap went to the button: click Bold,
  type "heavy" at once, and the block held a bold "avy". Each click also blurred
  the editor, which released the block's field lock and took it again. The
  toolbar now cancels mousedown, as the page editor's floating toolbar already
  did. The language select still opens.

<a id="collab-e2e"></a>

- **The browser suite now drives live co-editing: two peers type into one
  rich-text block and each sees the other's words and caret.** No spec
  exercised the CRDT path before (`mountCollab` in `assets/js/rich_text.js`,
  `assets/js/collab.js`): `:collab_prototype` was unset in `config/e2e.exs`,
  so every block mounted solo. During the TipTap 3 move (#1957) that hid a
  constructor throw that stopped every peer from syncing while all 33 editor
  specs passed. `e2e/tests/collab.spec.js` signs in as the admin and the
  editor in two contexts. A types, B sees it; A clicks away to release the
  field lock, B types, A sees it. It asserts B's remote caret renders in A's
  editor with a color and B's initials, that joining doubles no text, and
  that neither page throws. Reverting the #1957 guard fails it, and so does a
  joiner that seeds before the room's state arrives (`"AlphaAlphaAlpha"`).
  The flag stays off for the rest of the suite, as production pins it, so
  the other editor specs keep driving the solo editor and its reconnect
  re-send. The spec switches it on and back through a new e2e-only route,
  `POST /dev/e2e-collab` (`KilnCMSWeb.Plugs.E2ECollab`). The route is mounted
  beside `/dev/e2e-identity` in the compile-gated dev-tools scope, which
  `KilnCMS.Application` refuses in `:prod`.
