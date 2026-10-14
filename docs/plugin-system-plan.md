# Plugin system — design & phased plan

**Status:** **shipped** — decision **D18**, proposed below, was accepted and
built. The contract is `Kiln.Plugin`, the registry is `Kiln.Plugins`, plugin
routes mount through `KilnCMSWeb.PluginRouter`, and `mix kiln.gen.plugin` /
`mix kiln.plugins.list` / `mix kiln.plugins.doctor` are the operator surface.
This document is the design record; see
[Runtime extensibility](plugin-extensibility.md) for the marketplace question
that remains deferred.
**Goal:** the WordPress-moat pillar — a package drops into a KilnCMS install,
registers **one config line**, and contributes block types, content types,
admin panels, workers and background queues, with the core none the wiser.
The project plan has promised this from the start (Architecture →
Extensibility: *"Plugin / Module System: plug-and-play custom modules via
Elixir behaviours"*; Risks: the first downstream project *"as the first
plugin/consumer, not a coupling"*).

## 1. What exploration found: the system half-exists

The downstream host-project integration (`projects/` overlays) **is** a
working plugin mechanism — just unnamed and undocumented:

| Contribution | Mechanism today | Plugin-ready? |
|---|---|---|
| Content types + code interfaces | `:content_domains`/`:ash_domains` config + `__kiln_content_type__` marker discovery | ✅ one config line |
| Admin CRUD (AshAdmin), webhook events, Oban workers/triggers, public delivery routes, editor | derived from domains/registry at runtime | ✅ automatic |
| Storage / search embedder / reranker / mailer | behaviour + config adapter pattern | ✅ |
| Mix tasks | compiled from `projects/` | ✅ |
| **Block types** | `use Kiln.Block` modules ARE auto-discovered (`KilnCMS.Blocks.modules/0`), **but** `BlockUnion`'s union `types:` list, `TypedBlocks`' module/type-atom maps are hardcoded to the 7 core blocks | ❌ the headline gap |
| **Admin nav** | hardcoded `nav_links/1` in the layout | ❌ |
| **Supervision children / Oban queues** | hardcoded in `application.ex` / config | ❌ |
| **Admin routes** (plugin LiveViews) | hardcoded router scopes | ❌ |
| Custom field types | `Kiln.FieldType` registry (`KilnCMS.CMS.FieldTypes`) | ✅ shipped (was deferred) |

So this plan is **not a new subsystem**: it's (a) a small contract that names
the existing pattern, (b) four seam closures, (c) the scaffold + docs, and
(d) proving it by retrofitting a downstream project as the first real plugin —
exactly what the project plan called for.

## 2. Decision D18 — the plugin contract

> **D18. Plugins are compile-time OTP code registered by one config entry.**
> A plugin is a module (`use Kiln.Plugin`) shipped as a Mix dependency
> (Hex, git or path) or as a `projects/` directory, declared in
> `config :kiln_cms, :plugins, [...]`.
> It contributes through **explicit callbacks** — blocks, nav items,
> supervision children, Oban queues, admin routes — while domains keep the
> existing config registration (`:ash_domains`/`:content_domains`), because
> Ash's own mix tasks read those keys directly. Everything stays
> compile-time (D4's stance): no dynamic module loading; the "marketplace"
> future is installers, not runtime code.

> **Amended twice (#1909).** D18 as first written allowed "a hex dep", which
> could not compile: Mix builds a dependency before the project that uses
> it, with only the dependency's own deps loaded, so `use Kiln.Plugin` (a
> macro) failed with `module Kiln.Plugin is not loaded and could not be
> found`, and a plugin can't depend on `kiln_cms` (not on Hex, and the root
> project in the overlay layout, so a cycle). The first amendment said
> `projects/` only.
>
> The second extracted the compile-time contract into its own package,
> [`kiln_plugin`](https://github.com/The-Verscienta/kiln_cms/blob/main/sdk/kiln_plugin/README.md): `Kiln.Plugin`, `Kiln.Block`
> and `Kiln.Block.*`, `Kiln.FieldType`, `Kiln.Tokens`,
> `Kiln.Forms.SpamCheck`, `Kiln.ImageBackend` and `Kiln.Advisory` (with its
> `Finding`, `Context` and `Body` structs), under the same names. The
> core depends on it as a `path:` dependency (`override: true`), so overlays
> see no change, and a plugin that depends on it can be a Hex, git or path
> dependency. What such a plugin can contribute is bounded by what it can
> build from that package alone: blocks, field types (without colocated
> hooks), spam checks, advisory checks, image backends, nav items, children
> and queues. Content types (`KilnCMS.CMS.Content`), domains and LiveViews on
> `KilnCMSWeb` still need the core, so those plugins stay `projects/`
> overlays. A dependency plugin is still added to the core's `mix.exs`, which
> edits the pin; an overlay-level hook for that is open in #1967.
>
> The SDK versions separately from the core (`kiln_plugin-vX.Y.Z` tags). It
> is under the same 1.x contract (minors add; a major only with a core
> major), and because the core overrides it, Mix doesn't check a plugin's
> requirement on it: `mix kiln.plugins.doctor` does.

```elixir
defmodule MyApp.Plugin do
  use Kiln.Plugin

  @impl true
  def name, do: "my_app"

  # Documented + verified against :ash_domains/:content_domains by
  # `mix kiln.plugins.doctor` (they can't be auto-merged: Ash mix tasks read
  # those config keys before any plugin code could run).
  def domains, do: [MyApp.Catalog]

  def blocks, do: [MyApp.Blocks.PriceTable]

  def nav_items, do: [%{label: "Import", path: "/editor/my-app", role: :admin}]

  def admin_routes, do: [{"/editor/my-app", MyApp.ImportLive, :index}]

  def children, do: [MyApp.SyncWorker]

  def oban_queues, do: [imports: 2]
end
```

`use Kiln.Plugin` provides empty defaults for every callback (all optional)
and the behaviour. `Kiln.Plugins` (core registry) reads
`Application.compile_env(:kiln_cms, :plugins, [])` — compile-time, because
the block union and the router need the list during compilation.

## 3. The four seam closures

1. **Blocks (the headline).** `BlockUnion`'s `types:` becomes
   `KilnCMS.Blocks.union_types()` evaluated at compile time: the 7 core
   blocks ++ every plugin's `blocks/0`, keyed by each module's `Kiln.Block`
   name. `TypedBlocks`' `@block_modules` / `@type_atoms` switch to the same
   source; the editor palette and serializer dispatch are already
   registry-driven. (Compile-order is safe: a `projects/` plugin compiles
   in the same pass and the compiler tracks the references; a dependency
   plugin compiles first, and `Kiln.Plugins.__mix_recompile__?/0` recompiles
   the registries when one changes, since Mix tracks no compile-time edge
   into a dependency, #1909.)
2. **Admin nav.** `nav_links/1` appends `Kiln.Plugins.nav_items()` (runtime
   read), each gated by its declared role.
3. **Supervision + queues.** `application.ex` appends
   `Kiln.Plugins.children()` and merges `Kiln.Plugins.oban_queues()` into
   the Oban config it already builds (queues merge at boot — no config-file
   coupling; plugin queue names must not collide with core queues, checked
   by the doctor).
4. **Admin routes.** A `Kiln.Plugins.Router.plugin_admin_routes/0` macro in
   the router's admin live_session expands each plugin's `admin_routes/0`
   (path, LiveView, action) at compile time. v1 scope: admin-gated routes
   only — public plugin routes can serve content types through the existing
   generic delivery already.

## 4. Verification & tooling

- **`mix kiln.plugins.doctor`** — asserts every declared domain is present in
  `:ash_domains`/`:content_domains`, no block-name or queue-name collisions,
  nav/route paths well-formed. Run in precommit? (cheap — yes.)
- **`mix kiln.gen.plugin <Name>`** — Igniter scaffold: plugin module +
  domain + a sample block + config registration, mirroring what
  `kiln.gen.content` does for types.
- **A test-fixture plugin** (`test/support/fixture_plugin/…`, registered in
  config/test.exs) exercises every seam in ExUnit: its block round-trips
  through `BlockUnion` storage and renders in the palette/firing, its nav
  item and admin route appear for admins, its child boots, its queue merges.

## 5. Deliberately deferred

- **Custom field types** — ~~needs a coercion-behaviour registry in
  `ApplyCustomFields`~~ **shipped (2026-07-03)**: `Kiln.FieldType`
  (`name`/`label`/`cast`/`input_type`/`input_attrs` with `use` defaults),
  a `field_types/0` plugin callback, the compile-baked
  `KilnCMS.CMS.FieldTypes` registry, dispatch in `ApplyCustomFields`,
  runtime `KnownFieldType` validation (replacing the `one_of` constraint),
  editor + fields-admin rendering, doctor contract/collision checks, and
  `mix kiln.gen.plugin --field <name>`.
- **Marketplace/discovery** — the plan marks it "future"; a dependency on a
  plugin built on `kiln_plugin`, or vendoring a plugin's repo into
  `projects/` when it needs the core, is the v1 distribution story (#1909). Scoped in
  `docs/plugin-extensibility.md` (decision #333): **no runtime hot-loading of
  arbitrary code** (the BEAM has no in-process sandbox); the marketplace is
  vetted, compile-time, git-distributed plugins carrying cheap catalog
  metadata (`version`/`summary`/`homepage` on the contract,
  `Kiln.Plugins.manifests/0`, `mix kiln.plugins.list`), plus the already-safe
  data-driven runtime config (D17 dynamic types, `Kiln.FieldType`, #342 rules).
  A true third-party runtime-code sandbox (WASM / out-of-process) is a future
  dedicated effort. The hosted catalog itself — submissions, verification,
  per-version compatibility — is designed in
  `docs/plugin-registry-plan.md` (#1447).
- **Public plugin routes** — content types already get public delivery;
  arbitrary public routes invite router-conflict complexity for no proven
  need.

## 6. Phases

1. **Contract + registry.** ✅ **Done.** `Kiln.Plugin` (behaviour + `use`
   defaults), `Kiln.Plugins` (compile-env registry),
   `mix kiln.plugins.doctor` (domain registration, block/queue collisions,
   path shape).
2. **Seam closures + fixture plugin.** ✅ **Done.** `BlockUnion` and
   `TypedBlocks` derive from `KilnCMS.Blocks.union_types/0` (core + plugin,
   compile-time; the runtime `modules/0` scan also merges plugin blocks,
   which also covers dependency plugins on `kiln_plugin`, #1909); nav appends role-gated plugin items;
   `application.ex` appends plugin children and merges plugin Oban queues at
   boot; `KilnCMSWeb.PluginRouter.plugin_admin_routes/0` expands plugin
   panels inside the admin live_session (`alias: false` — plugin modules are
   fully qualified). All proven by the test-suite fixture plugin: its
   callout block round-trips storage and renders escaped HTML, appears in
   the editor palette, its nav item is role-gated, its panel mounts
   admin-only, its Agent child runs.
3. **Downstream retrofit + scaffold.** ✅ **Done.** The first downstream
   project's plugin module (overlaid into `projects/<name>`; `Example.Plugin`
   in `projects/example` is the in-repo equivalent) makes the plan's "first
   plugin/consumer" literal —
   domains declared on the contract, doctor-verified against the host
   config. `mix kiln.gen.plugin <Name> [--block <name>]` scaffolds a plugin
   (contract module with stubbed callbacks + optional working sample block +
   config registration); its generated sources are compile-tested against
   the real contract in the suite. `mix kiln.plugins.doctor` joined the
   precommit pipeline. Plugin story documented in
   `docs/extending-content.md` §5. Contract polish: `X.Plugin` default-names
   itself after `X`, not the convention suffix.
