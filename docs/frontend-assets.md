# Frontend asset strategy

How KilnCMS acquires, builds, and serves its editor/admin frontend
dependencies (TipTap, SortableJS, topbar, heroicons) and how the media/image
pipeline is wired. This is the audit and the decision record requested in
Phase 0.

**TL;DR — everything is bundled and self-hosted; nothing is loaded from a CDN
at runtime.** Two acquisition channels feed one esbuild bundle:

| Dependency | Channel | Pinned at | Why |
| --- | --- | --- | --- |
| TipTap (`@tiptap/core`, `@tiptap/pm`, `@tiptap/starter-kit`) | **npm** → bundled by esbuild | `assets/package.json` + `assets/package-lock.json` | Multi-module package with a real transitive tree; semver + a committed lockfile matter |
| SortableJS `1.15.6` | **vendored** single file | `assets/vendor/sortable.js` | One stable UMD file; not worth an npm transitive tree |
| topbar | **vendored** single file | `assets/vendor/topbar.js` | phx.new default; one tiny file |
| heroicons `v2.2.0` | **mix dep** + Tailwind plugin | `mix.exs` (`:heroicons`) + `@plugin "../vendor/heroicons"` | SVGs consumed as `hero-*` classes at build time |

## Build pipeline

Two Mix-managed runners produce exactly two artifacts:

- **esbuild** (`0.25.4`, via the `:esbuild` hex package) bundles
  `assets/js/app.js` → `priv/static/assets/js/app.js`. Config:
  [`config/config.exs:170`](../config/config.exs). The `--alias:@=.` flag lets
  app.js import npm packages (e.g. `@tiptap/core`) resolved through
  `NODE_PATH`/`assets/node_modules`.
- **tailwind** (`4.3.0`, via the `:tailwind` hex package) compiles
  `assets/css/app.css` → `priv/static/assets/css/app.css`. Config:
  [`config/config.exs:180`](../config/config.exs).

Mix aliases tie it together ([`mix.exs:152`](../mix.exs)):

- `mix assets.setup` — installs the tailwind/esbuild binaries (`--if-missing`)
  and runs `npm install` in `assets/`.
- `mix assets.build` — `tailwind kiln_cms` + `esbuild kiln_cms`.
- `mix assets.deploy` — the same with `--minify`, then `phx.digest` for
  cache-busting fingerprints. This is what the [`Dockerfile`](../Dockerfile)
  release build runs.

`node_modules` is gitignored; `assets/package-lock.json` is committed. After
pulling JS dep changes, run `npm install` in `assets/` (or `mix setup`). Node.js
is therefore a build-time requirement — see [`AGENTS.md`](../AGENTS.md).

## Serving model: one JS bundle, one CSS bundle, no CDN

The root layout links only the two digested bundles, both with
`phx-track-static` so LiveView reloads the page when a fingerprint changes:
[`lib/kiln_cms_web/components/layouts/root.html.heex:22`](../lib/kiln_cms_web/components/layouts/root.html.heex).

CDN delivery was considered and **rejected**:

- **CSP.** The app serves a per-request nonce (`csp_nonce`) and avoids
  third-party script origins. Self-hosted bundles keep the policy tight; a CDN
  would require widening `script-src`/`style-src` to external hosts.
- **Reproducible/offline builds.** Releases build the exact pinned versions
  from the lockfile with no network fetch at runtime — no risk of a CDN
  serving a different minor or going down.
- **Cache-busting.** `phx.digest` fingerprints + `phx-track-static` give
  correct long-cache + reload-on-change behavior that an external `<script
  src>` can't participate in.

This matches the project rule in [`AGENTS.md`](../AGENTS.md): *"only the app.js
and app.css bundles are supported … you must import vendor deps into app.js and
app.css to use them … never reference an external vendor'd script `src` or link
`href` in the layouts."*

## Editor dependencies in use

[`assets/js/app.js`](../assets/js/app.js) wires them into LiveView hooks:

- **TipTap** (`Editor` + `StarterKit`) powers the `RichText` hook for rich-text
  blocks; the editor's HTML is mirrored into a hidden input so it saves through
  the normal form submit.
- **SortableJS** powers the `Sortable` hook for drag-and-drop block reordering,
  pushing a `reorder` event with the new `data-sort-id` order.
- **topbar** shows the live-navigation progress bar.
- **heroicons** are compiled into `hero-*` utility classes via the Tailwind
  plugin in [`assets/css/app.css`](../assets/css/app.css).

## Media / image pipeline (already wired — no gap)

The issue asked to confirm remaining gaps for Image/Mogrify and ex_aws. Both are
complete; **`:image` (libvips/Vix) is used, not Mogrify (ImageMagick)**:

- **Processing.** [`KilnCMS.ImageProcessor`](../lib/kiln_cms/image_processor.ex)
  uses `:image` (`~> 0.69`, started as an `extra_application` in
  [`mix.exs`](../mix.exs)) to validate uploads and generate responsive variants
  (`thumb: 400`, `medium: 1024`) via libvips. It degrades gracefully for
  non-raster inputs.
- **Storage.** [`KilnCMS.Storage`](../lib/kiln_cms/storage.ex) is a swappable
  adapter behaviour: `Storage.Local` (default) and `Storage.S3`. The S3 adapter
  uses `ex_aws` + `ex_aws_s3` + `sweet_xml`, routing HTTP through `Req` rather
  than hackney ([`KilnCMS.Storage.S3.ReqClient`](../lib/kiln_cms/storage/s3/req_client.ex)).
  Opt in at runtime by setting `S3_BUCKET` ([`config/runtime.exs:81`](../config/runtime.exs));
  works with AWS S3, Cloudflare R2, Backblaze B2, Wasabi, and MinIO via
  `S3_ENDPOINT_HOST`.

No Mogrify dependency is needed or planned — libvips covers the processing
requirement with better performance and no external `convert` binary.

## Adding a new frontend dependency

Pick a channel:

1. **npm path** (multi-module library, has its own deps, want semver +
   lockfile): `npm install <pkg> --prefix assets`, commit the updated
   `package.json` **and** `package-lock.json`, then `import` it in `app.js`
   using its package name.
2. **Vendor path** (single self-contained UMD/ESM file, stable): drop the file
   in `assets/vendor/` and `import "../vendor/<name>"` in `app.js` (or
   `@plugin`/`@source` in `app.css`). Note the upstream version in a header
   comment so it can be refreshed deliberately.

Either way the dependency ends up inside the single esbuild bundle — never a
runtime CDN reference.
