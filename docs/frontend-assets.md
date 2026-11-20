# Frontend asset strategy

How KilnCMS acquires, builds, and serves its editor/admin frontend
dependencies (TipTap, SortableJS, topbar, heroicons) and how the media/image
pipeline is wired. This is the audit and the decision record requested in
Phase 0.

**TL;DR — everything is bundled and self-hosted; nothing is loaded from a CDN
at runtime.** Two acquisition channels feed the esbuild bundles: `app.js`
for the console and every LiveView, and the much smaller `public.js` for
signed-out content pages (see [Which script a page loads](#which-script-a-page-loads)).

| Dependency | Channel | Pinned at | Why |
| --- | --- | --- | --- |
| TipTap (`@tiptap/core`, `@tiptap/pm`, `@tiptap/starter-kit`) | **npm** → bundled by esbuild | `assets/package.json` + `assets/package-lock.json` | Multi-module package with a real transitive tree; semver + a committed lockfile matter |
| SortableJS `1.15.6` | **vendored** single file | `assets/vendor/sortable.js` | One stable UMD file; not worth an npm transitive tree |
| topbar | **vendored** single file | `assets/vendor/topbar.js` | phx.new default; one tiny file |
| heroicons `v2.2.0` | **mix dep** + Tailwind plugin | `mix.exs` (`:heroicons`) + `@plugin "../vendor/heroicons"` | SVGs consumed as `hero-*` classes at build time |

## Build pipeline

Two Mix-managed runners, esbuild with three profiles and tailwind, produce
four artifacts:

- **esbuild** (`0.25.4`, via the `:esbuild` hex package) bundles
  `assets/js/app.js` → `priv/static/assets/js/app.js`. Config: the
  `config :esbuild, kiln_cms:` block in [`config/config.exs`](../config/config.exs). The `--alias:@=.` flag lets
  app.js import npm packages (e.g. `@tiptap/core`) resolved through
  `NODE_PATH`/`assets/node_modules`.
- **esbuild**, a second profile, `kiln_challenge_embed` (#2249), bundles
  `assets/js/challenge_static.js` → `priv/static/assets/js/challenge_static.js`
  with no splitting. Only the embedded form iframe (`/forms/:slug/embed`)
  loads it, to mount a human-verification widget; the embed never loads
  `app.js`. Config: the `config :esbuild, kiln_challenge_embed:` block in
  [`config/config.exs`](../config/config.exs).
- **esbuild**, a third profile, `kiln_public` (#2402), bundles
  `assets/js/public.js` → `priv/static/assets/js/public.js`, one file with no
  splitting. Signed-out content pages load it instead of `app.js`. Config: the
  `config :esbuild, kiln_public:` block in
  [`config/config.exs`](../config/config.exs). In dev it has its own watcher
  (`public_bundle` in `config/dev.exs`).
- **tailwind** (`4.3.3`, via the `:tailwind` hex package) compiles
  `assets/css/app.css` → `priv/static/assets/css/app.css`. Config: the
  `config :tailwind, kiln_cms:` block in [`config/config.exs`](../config/config.exs).

Mix aliases tie it together (the `aliases/0` list in [`mix.exs`](../mix.exs)):

- `mix assets.setup` — installs the tailwind/esbuild binaries (`--if-missing`)
  and runs `npm install` in `assets/`.
- `mix assets.build` — `tailwind kiln_cms` + `esbuild kiln_cms` +
  `esbuild kiln_challenge_embed` + `esbuild kiln_public`. A custom build or
  overlay `Dockerfile` that runs the esbuild profiles itself must run all
  three.
- `mix assets.deploy` — the same four with `--minify`, then `phx.digest`
  for cache-busting fingerprints. This is what the [`Dockerfile`](https://github.com/The-Verscienta/kiln_cms/blob/main/Dockerfile)
  release build runs. A custom asset build or overlay `Dockerfile` that does
  not run `mix assets.deploy` must also run these before `phx.digest`:
  - `mix esbuild kiln_challenge_embed --minify`. Without
    `challenge_static.js`, an embedded form that asks for a
    human-verification check has no widget, so every submission from it is
    held in Spam.
  - `mix esbuild kiln_public --minify`. Without `public.js`, signed-out
    pages load `app.js` instead: they keep working, without the saving.
    Outside dev, whether `public.js` exists is checked once per VM, so a
    `public.js` added to a running release is only picked up after a
    restart.
- `mix kiln.assets.budget` — builds the bundles minified into `_build` and
  fails when `public.js` outgrows its budget or a bundle imports what it must
  not. See [Check the public script budget](#check-the-public-script-budget).

`node_modules` is gitignored; `assets/package-lock.json` is committed. After
pulling JS dep changes, run `npm install` in `assets/` (or `mix setup`). Node.js
is therefore a build-time requirement — see [`AGENTS.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/AGENTS.md).

## Serving model: one script per page, one CSS bundle, no CDN

The root layout links one digested script and the stylesheet, both with
`phx-track-static` so LiveView reloads the page when a fingerprint changes:
[`lib/kiln_cms_web/components/layouts/root.html.heex`](../lib/kiln_cms_web/components/layouts/root.html.heex).
The script is `app.js` or `public.js`, never both; see
[Which script a page loads](#which-script-a-page-loads). The one other
script, `challenge_static.js`, is loaded only by the embedded form iframe,
which does not use the root layout, and only when the form asks for a
human-verification check.

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

This matches the project rule in [`AGENTS.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/AGENTS.md): *"only the app.js,
public.js (signed-out content pages) and app.css bundles are supported … you
must import the vendor deps into app.js and app.css to use them … never
reference an external vendor'd script `src` or link `href` in the layouts."*

### Which script a page loads

`app.js` carries LiveView, the Phoenix socket, the console's hooks, Sortable
and topbar: about 258 KB minified, 81 KB gzipped, in three requests. A
signed-out visitor reading a page uses none of it. `public.js` carries only
what those pages use (the human-verification mount for public forms, the
`data-method`/`data-confirm` helpers from `phoenix_html`, and the ⌘K / Ctrl-K
shortcut to the console's search): about 6.4 KB minified, 2.5 KB gzipped, in
one request.

`KilnCMSWeb.Layouts.js_bundle_path/1` picks the script. A page gets
`public.js` only when all of these hold:

- **Its controller opted in** by plugging `KilnCMSWeb.Plugs.PublicJsBundle`,
  which sets `conn.assigns.js_bundle` to `:public`. Three do:
  `ContentController` (delivered pages and posts, the blog and event
  indexes, `/search`, the passphrase lock page, the delivery 404, and the
  stock home page `/` falls through to), `FormController` (a form's own page
  `/forms/<slug>`, its thank-you page and its refused re-render), and
  `NewsletterController` (the confirm and unsubscribe pages). The plug goes
  on a controller, never in a router pipeline: the `:delivery` scope also
  serves `MembershipLive` and plugin LiveViews, and a LiveView rendered from
  a controller inherits the conn's assigns.
- **No LiveView is rendering** (`:live_module` is unset), a second guard on
  that same leak.
- **The flash is empty.** `Layouts.flash_group/1` closes through a LiveView
  JS command and a hook, which only `app.js` provides. The stock home page
  just after signing out is the usual case: it keeps `app.js`.
- **`public.js` was built.** If `priv/static/assets/js/public.js` is missing
  (a custom asset build that skipped `kiln_public`), every page keeps
  `app.js`, which mounts the same form widgets, instead of a script that
  404s. Outside dev the check runs once per VM and is cached in
  `:persistent_term`; under the code reloader it looks at the disk on every
  request.

Everything else loads `app.js`: the console, every LiveView (sign-in,
registration, account, membership, previews, plugin pages), and plain pages
that need it, such as `/sign-in/verify`.

To move another controller's pages onto `public.js`, first check that its
templates need nothing from `app.js` (no `phx-*` binding, hook, JS command,
`Layouts.flash_group/1`, or page script `app.js` wires up), then add
`plug KilnCMSWeb.Plugs.PublicJsBundle` to it.

Code-injection snippets (see [Code injection](code-injection.md)) on a page
that loads `public.js` run without `app.js` beside them, so a snippet that
reaches for `window.liveSocket` or another `app.js` global finds nothing.
That was never a supported use.

### Check the public script budget

`mix kiln.assets.budget` keeps `public.js` small. One `import` in the wrong
file would put all of LiveView back on every delivered page, and no page
would look different, so a check is the only thing that notices.

1. Install the esbuild binary if this checkout lacks it:

   ```sh
   mix esbuild.install --if-missing
   ```

2. Check `public.js` alone. This needs only `deps/` and the esbuild binary,
   not npm, and it is what CI's `build` job runs:

   ```sh
   mix kiln.assets.budget --only public
   ```

   It prints a table and exits 0 when the bundle is within budget:

   ```text
   bundle     files  min (B)  gzip (B)  budget (min / gzip)
   public.js      1    6,433     2,505       12,000 / 5,000
   ```

3. To check `app.js` as well, install the npm packages
   (`npm install --prefix assets`) and run the task with no option. It
   compiles the project first, for the colocated hooks:

   ```sh
   mix kiln.assets.budget
   ```

   ```text
   bundle     files  min (B)  gzip (B)  budget (min / gzip)
   public.js      1    6,433     2,505       12,000 / 5,000
   app.js         3  257,699    80,732        reported only
   ```

The task builds into `_build/asset_budget/<profile>/`, never `priv/static`,
so a running dev server's assets and digests are left alone. It measures
each bundle's static load set: the entry file and every chunk it reaches
through an `import` statement. Chunks reached only through `import()`, such
as the editor's TipTap and Yjs chunks, are left out.

What each bundle is held to:

| Bundle | Size budget | Must not carry | Must carry |
| --- | --- | --- | --- |
| `public.js` | 12,000 B minified, 5,000 B gzipped | LiveView, Phoenix (the socket), the colocated console hooks, Sortable, topbar, the rich-text editor, TipTap, Yjs | `js/challenge.js` |
| `app.js` | none: sizes are reported only | TipTap, Yjs or the rich-text editor outside `import()` | — |

What can go wrong:

- **`public.js: carries <input>, which it must not (...)`**: something
  `public.js` imports pulls in LiveView or console code. Find the import
  chain and move the shared piece into a module that does not import it.
- **`public.js: no longer carries js/challenge.js, which it must`**: the
  form widget's mount dropped out, so every challenge-enabled form on a
  delivered page would go unprotected. Restore the import in
  `assets/js/public.js`.
- **`public.js: 12,345 B minified, over its 12,000 B budget`** (or
  `gzipped`): the bundle grew. If the growth is needed, raise the budget in
  `lib/mix/tasks/kiln.assets.budget.ex` in the same change and say why.
- **`app.js: carries ...@tiptap...`**: a static `import` brought an editor
  dependency into every console page's first load. Load it through
  `import()` instead.
- **esbuild is not installed.** The message goes on to name
  `mix esbuild.install --if-missing`: run step 1.
- **`esbuild kiln_cms exited 1:`** followed by unresolved-import errors:
  `assets/node_modules` is missing. Run `npm install --prefix assets`, or use
  `--only public`.
- **`--only takes public or app, not "..."`**: a typo in the option.

Each problem is printed on its own line, and the task ends with
"N asset budget problem(s)." and a pointer back to this page.

## Editor dependencies in use

[`assets/js/app.js`](../assets/js/app.js) wires them into LiveView hooks:

- **TipTap** (`Editor` + `StarterKit`, plus `@tiptap/extension-link` and the
  `@tiptap/extension-table*` set — StarterKit v2 carries neither) powers the
  `RichText` hook for rich-text blocks; the editor's HTML is mirrored into a
  hidden input so it saves through the normal form submit.
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
  Opt in at runtime by setting `S3_BUCKET` ([`config/runtime/prod/storage.exs`](../config/runtime/prod/storage.exs));
  works with AWS S3, Cloudflare R2, Backblaze B2, Wasabi, and MinIO via
  `S3_ENDPOINT_HOST`.

No Mogrify dependency is needed or planned — libvips covers the processing
requirement with better performance and no external `convert` binary.

## Adding a new frontend dependency

First pick the bundle. Almost everything goes in `app.js`: anything the
console, the editor or a LiveView uses. Only something a signed-out content
page needs goes in `public.js`, and then it must work on a dead render (no
hooks, no `phx-*` bindings, no JS commands) and must not import LiveView,
the Phoenix socket or console code. Run `mix kiln.assets.budget --only
public` after the change. If both bundles need it, put it in its own module
under `assets/js/` and import that from each, as `search_shortcut.js` does.

Then pick a channel:

1. **npm path** (multi-module library, has its own deps, want semver +
   lockfile): `npm install <pkg> --prefix assets`, commit the updated
   `package.json` **and** `package-lock.json`, then `import` it in `app.js`
   using its package name (or in `public.js`, under the rules above).
2. **Vendor path** (single self-contained UMD/ESM file, stable): drop the file
   in `assets/vendor/` and `import "../vendor/<name>"` in `app.js` (or
   `@plugin`/`@source` in `app.css`). Note the upstream version in a header
   comment so it can be refreshed deliberately.

Either way the dependency ends up inside an esbuild bundle, never a runtime
CDN reference.
