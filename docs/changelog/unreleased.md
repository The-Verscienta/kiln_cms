# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

<a id="project-deps-docker"></a>

- **A Dockerfile that runs `mix deps.get` before copying the whole core must
  also copy `config/project_deps_hook.exs`, which `mix.exs` now requires.**
  `mix.exs` requires it, the way it requires `config/ml_flag.exs`, to read an
  overlay's dependency list, so without it every `mix` command in that layer
  fails to load the project. An overlay with a `config/project_deps.exs`
  copies that file and `config/project.lock` into the same layer too, or
  `deps.get` never sees its plugins. The core's own Dockerfile copies all
  three, the overlay's two only when the build context has them.
  ([#1967](https://github.com/The-Verscienta/kiln_cms/issues/1967))

<a id="project-deps"></a>

- **An overlay installs dependency plugins through a git-ignored
  `config/project_deps.exs`, locked in `config/project.lock`, so the core's
  `mix.exs` and `mix.lock` never change.** Installing a plugin shipped as a
  dependency used to mean a line in the core's `mix.exs` and a changed
  `mix.lock`, which made the pin look patched, so `mix kiln.update` refused
  it. `config/project_deps.exs` is the dependency counterpart of
  `config/project.exs`: a list of dependency tuples that `mix.exs` appends to
  its own. While it exists Mix locks into `config/project.lock`, seeded from
  `mix.lock` so the core's dependencies stay at the release's versions; both
  files are git-ignored in the core and committed in the overlay. An entry
  may not set `override: true`. `mix kiln.update` re-seeds the lock after
  moving the pin (the release's entries for every core dependency, the
  overlay's own carried over), and `mix kiln.plugins.doctor` fails a core
  dependency that moved in it, notes a plugin installed there but not
  registered, and names where each plugin came from. CI installs a fixture
  plugin this way and fails unless `mix.lock` and `git status` are unchanged.
  ([#1967](https://github.com/The-Verscienta/kiln_cms/issues/1967))

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

<a id="block-embedding-prefixes-upgrade"></a>

- **Changing `document_prefix` (as an e5 model swap does) now needs block
  vectors re-embedded too: `mix kiln.embed_all --blocks`, or a firing sweep
  (`mix kiln.refire_all`), as well as documents and tags.** Block vectors are written
  only by firing (`KilnCMS.Search.BlockIndexer`), and `mix kiln.embed_all`
  re-embeds document vectors and tag names, not blocks. A block's `content_hash` now includes `document_prefix` when it is
  set, so the sweep re-embeds every block under the new prefix and skips
  nothing as unchanged. On a release, run
  `bin/kiln_cms rpc "KilnCMS.Firing.Sweep.run()"`. Changing only
  `query_prefix` needs no re-embed, because queries are embedded when they
  are asked. With the default empty prefixes (bge-small), the inputs and
  hashes are what they were, so upgrading re-embeds nothing.
  ([#1939](https://github.com/The-Verscienta/kiln_cms/issues/1939))

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

<a id="plugin-sdk-advisories"></a>

- **Advisory checks can ship in a dependency plugin, and `mix kiln.gen.plugin
  --dep` scaffolds one.** `Kiln.Advisory` and its `Finding`, `Context` and
  `Body` structs moved into `kiln_plugin` (1.1.0), under the same names, so a check
  that matches `%Kiln.Advisory.Context{}` compiles without the core. The
  block walk that fills a `Body` matches the core's block types, so it stays
  in the core as `Kiln.Advisory.Walk` (`compute/1`, `from_typed/1`,
  `from_indexed/1`); the same functions on `Body` still work, deprecated.
  `mix kiln.gen.plugin <Name> --dep` writes a standalone Mix project that
  depends only on `kiln_plugin` to `../<name>` (or `--path`), with
  `--block`/`--field` samples, its own config, formatter and a test, and
  changes nothing in the core checkout. The fixture dependency plugin gains an
  advisory check the suite runs against a core-built context.
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

<a id="image-backend-status"></a>

- **System → Image backend shows the selected backend's state, whether its
  service answers, and how much of the site's library it holds.** A new
  platform-admin page, `/editor/system/image-backend`, linked from System →
  Plugins. It says which backend is selected and whether it is receiving
  uploads, missing its settings or not an installed backend at all. It asks
  the service whether it answers, through a new optional callback,
  `Kiln.ImageBackend.check/0` (kiln_plugin, Unreleased), which may report
  what it found, and shows the reason when it doesn't. It counts the site's
  rows the backend holds, the imported links it would adopt and those it
  doesn't recognise (`KilnCMS.Media.Adoption.census/2`), and prints the
  adoption command when there is something to adopt. Like System, it
  reports and doesn't act.
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
  by `min(document, block, chunk, tag)`. That includes a `:keyword_any` hit
  the floor judges (#1936, `semantic_floor_legs`) that no semantic leg
  returned: the lookup that measures it reads its chunks too, so a match in a
  late passage is judged by the chunk that holds it. Boundaries are counted in words at
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

<a id="search-floor-legs"></a>

- **Hybrid search's relevance floor can judge the any-term (OR) keyword leg's
  hits too, and the floor is a runtime setting.** On a production corpus of
  long prose, `keyword_any` was how most junk queries came back non-empty: a
  several-word query shares one ordinary word with dozens of documents, the
  relaxation admits every one, and the floor judged only hits the semantic
  legs alone returned. A new `KilnCMS.Search` key, `semantic_floor_legs`,
  names the legs whose hits the floor judges — a hit is floored only when
  every leg that returned it is listed. The default, `[:semantic, :block,
  :tag]`, is the v1.1.0 rule unchanged; `:keyword_any` and `:fuzzy` may be
  added; `:keyword`, `:title` and `:alias` vouch for a hit and raise if
  listed. A judged lexical hit is measured by the nearest distance it has —
  the semantic leg's reading, else its document's and nearest block's, read
  for it — and kept when it has no vector at all. Judge `:keyword_any` with
  chunked document vectors (#1940), or accept that a late-passage match in a
  long document is judged by a vector that never saw it. The preregistered
  IDF-coverage variant ships opt-in for measurement: `keyword_any_idf_coverage:
  x` keeps a judged `keyword_any` hit beyond the floor when its matched query
  lexemes carry at least `x` of the query's IDF mass (per content type and
  locale, over published documents, smoothed BM25 IDF; the definition is on
  `KilnCMS.Search.keyword_any_idf_coverage/0`). Three variables override the
  compiled values at boot — `SEARCH_SEMANTIC_MAX_DISTANCE` (`0.0` legal, the
  model-swap setting), `SEARCH_SEMANTIC_FLOOR_LEGS` and
  `SEARCH_KEYWORD_ANY_IDF_COVERAGE` — so a retune or a model-swap window is a
  restart rather than a deploy each way. `KilnCMS.Config.Env` gains the two
  readers they need, `float_in/4` and `list_of/3`; an unusable value keeps
  the compiled one and warns through Logger and Sentry.
  ([#1936](https://github.com/The-Verscienta/kiln_cms/issues/1936))

<a id="embed-all-blocks"></a>

- **`mix kiln.embed_all --blocks` re-embeds the block index too, so a model,
  pooling or `document_prefix` change reaches every block vector.**
  `embed_all` re-embedded document and tag vectors only. Blocks are indexed on
  fire, and the indexer skips a block whose `content_hash` is unchanged. That
  hash covers what a block says, not the space it was embedded in, so after an
  embedding-space change neither a publish nor a re-fire sweep
  (`mix kiln.refire_all`) re-embedded a single block, and the block leg went
  on comparing old-space block vectors with new-space queries. `--blocks`
  enqueues one `BlockEmbeddingWorker` per published document, every org, with
  `"force" => true`. `BlockIndexer.reindex/2` then ignores the stored hashes.
  The jobs run on the `:search` queue and re-fire nothing else. Without the
  flag the task behaves as before. Drafts have no block rows, so they are not
  enqueued.
  ([#1939](https://github.com/The-Verscienta/kiln_cms/issues/1939))

<a id="vector-scan-knob"></a>

- **Search measurement runs can scan vectors at `ef_search` 200 or exactly
  (`KILN_HNSW_EF_SEARCH`, `KILN_VECTOR_SEARCH_EXACT`, `--ef-search`, `--exact`),
  and the search eval reports name the scan mode they ran under.** Every semantic leg
  used pgvector's default `hnsw.ef_search` of 40, which is approximate: it can
  miss a row nearer than the ones it returns. The pre-registered measurements
  for #1936, #1937 and an embedder decision (verscienta-base#894) are taken on
  a replica and must exclude that noise, and nothing could set it.
  `KilnCMS.Search.VectorScan` adds one `SET` to each repo connection:
  `hnsw.ef_search = N` (1–1000), or, for exact search,
  `enable_indexscan = off`. HNSW serves a query only through an ordered index
  scan, so turning those off keeps vector queries off the index, while btree
  indexes stay usable through bitmap scans. It is still connection-wide: no
  query gets an ordered btree walk, so exact mode is for measurement replicas,
  not traffic. Unset sends exactly the one `SET` as before. An unusable value,
  or both at once, refuses to boot instead of keeping the default and warning,
  because falling back to 40 is the contamination being excluded. The task
  flags override the env vars for a local run. Both reports print the mode
  read back from the database connection (`scan` in `--json`) and warn below
  ef_search 200; a flag that didn't reach the pool is refused. A `--url` run
  says the scan mode is the server's, and refuses the flags.
  ([#1969](https://github.com/The-Verscienta/kiln_cms/issues/1969))

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

<a id="ask-union-rerank"></a>

- **`/api/ask` can rerank its merged candidates once instead of each content
  type's, blend the reranker's order with the fused one, and hold a source
  the question names at its fused rank; all off by default.** With reranking
  on, each content type's candidates used to be reranked inside their own
  `hybrid/3` call: one padded reranker batch per non-empty section, and no
  way to blend with the fused order, because the cross-type fused rank is not
  visible inside a section. `KilnCMS.Ask`'s new `rerank_scope: :union`
  (`ASK_RERANK_SCOPE=union`) retrieves unreranked, merges the sections by
  fused score, and reranks the top `rerank_union` (default 30) in one call
  through `KilnCMS.Search.rerank_records/3`. `rerank_mode`
  (`ASK_RERANK_MODE`; defaults to `KilnCMS.Search`'s) replaces or blends.
  `rerank_pin: true` (`ASK_RERANK_PIN`) is the named-entity pin #1937
  preregistered: a source whose legs include `title` or `alias` keeps its
  fused position, and the rest fill the gaps in reranked order. If the union
  call fails, the union keeps its fused order and scores, so the scope no
  longer mixes RRF scores with 0–1 reranker scores the way a per-section
  failure can. The default stays `rerank_scope: :section` with `:replace`,
  today's behaviour, until a held-out measurement says otherwise.
  docs/rag.md, "Measuring each variant", maps each preregistered variant
  (F, R1–R4, R4 + pin) to its config for `mix kiln.search.eval --ask`.
  ([#1937](https://github.com/The-Verscienta/kiln_cms/issues/1937))

<a id="rerank-shape-and-mode"></a>

- **The reranker's compiled shape (`rerank_batch_size`,
  `rerank_sequence_length`) and how it meets the fused order (`rerank_mode`,
  `SEARCH_RERANK_MODE`) are configurable; the defaults are unchanged.**
  `RerankerServing` compiled a literal 8 × 512, and every call padded to it:
  0.8–1.05 s a batch for `bge-reranker-base` under EXLA on a laptop CPU. The
  shape now follows `KilnCMS.Search` config, mirroring the embedder's
  `batch_size`/`sequence_length`, with a list of lengths compiling one bucket
  each. `rerank_mode: {:rrf, k}` (`SEARCH_RERANK_MODE=rrf` or `rrf:<k>`)
  orders by `1/(k + fused rank) + 1/(k + rerank rank)` instead of the
  reranker's order outright, with ties going to fused order. Replacing
  outright cut question-form MRR from 0.672 to 0.388 on the golden set,
  because the cross-encoder prefers a record that answers a question to the
  one it names. A blended hit's `score` is its blend: comparable within the
  list that was reranked, which for a per-section rerank means within a
  section. docs/rag.md also gains a licence note on the MS MARCO-trained
  MiniLM cross-encoders.
  ([#1938](https://github.com/The-Verscienta/kiln_cms/issues/1938))

<a id="rerank-search-text"></a>

- **The reranker reads a record's title and its `search_text`, not its title
  and excerpt, so a record with no excerpt is no longer judged on its title
  alone.** A content type whose substance lives in searchable custom fields
  has no excerpt, so the cross-encoder scored "Huang Lian" at logit −8.1 for
  "intensely bitter and cold" on its title alone, and +4.7 with its text. On
  the golden set behind #1938, title + excerpt cut r@10 from the fused 0.851
  to 0.667, while title + `search_text` held 0.808. The text falls back to
  the `passage` calc, then the excerpt, and is capped at eight characters per
  token of the compiled window. `hybrid/3` widens a caller's `:select` to
  these fields when it reranks, so `GET /api/search`'s narrow read no longer
  starves the model.
  ([#1938](https://github.com/The-Verscienta/kiln_cms/issues/1938))

<a id="block-embedding-prefixes"></a>

- **Block vectors and the block search query now get `document_prefix` and
  `query_prefix`, so an asymmetric model such as multilingual-e5 embeds the
  block leg to spec.** Documents and tags already went through
  `Search.embed_document/1`, but `BlockIndexer` embedded each block with the
  raw `Search.embed/1`, and `BlockEmbedding`'s `:nearest` action embedded its
  query the same way. Under e5 (`"query: "` / `"passage: "`) the block leg of
  `hybrid/3` compared unprefixed block vectors with the prefixed query vector
  it shares with the document leg, which moved the block distances the
  relevance floor reads. Blocks now embed as `document_prefix` + the ancestor
  context line + the block text, on both the stored path and the
  compute-on-demand `block_vectors/1`, and `:nearest` uses
  `Search.embed_query/1`. `KilnCMS.Search.VectorCache`'s key gains `pooling`,
  since CLS and mean pooling give different vectors for one string; the cache
  is in memory, so the new key shape costs one cold cache after a deploy.
  `VectorCache.raw_cached?/1` is removed: no unprefixed path is left, and its
  two callers ask `cached?/1`.
  ([#1939](https://github.com/The-Verscienta/kiln_cms/issues/1939))
