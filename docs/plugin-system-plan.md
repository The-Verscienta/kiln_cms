# Plugin system — design & phased plan

**Status:** design (decision **D18** proposed below).
**Goal:** the WordPress-moat pillar — a package drops into a KilnCMS install,
registers **one config line**, and contributes block types, content types,
admin panels, workers and background queues, with the core none the wiser.
The project plan has promised this from the start (Architecture →
Extensibility: *"Plugin / Module System: plug-and-play custom modules via
Elixir behaviours"*; Risks: *"Verscienta Health as the first plugin/consumer,
not a coupling"*).

## 1. What exploration found: the system half-exists

The Verscienta host-project integration **is** a working plugin mechanism —
just unnamed and undocumented:

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
(d) proving it by retrofitting Verscienta as the first real plugin — exactly
what the project plan called for.

## 2. Decision D18 — the plugin contract

> **D18. Plugins are compile-time OTP code registered by one config entry.**
> A plugin is a module (`use Kiln.Plugin`) shipped as a hex dep or a
> `projects/` directory, declared in `config :kiln_cms, :plugins, [...]`.
> It contributes through **explicit callbacks** — blocks, nav items,
> supervision children, Oban queues, admin routes — while domains keep the
> existing config registration (`:ash_domains`/`:content_domains`), because
> Ash's own mix tasks read those keys directly. Everything stays
> compile-time (D4's stance): no dynamic module loading; the "marketplace"
> future is installers, not runtime code.

```elixir
defmodule Verscienta.Plugin do
  use Kiln.Plugin

  @impl true
  def name, do: "verscienta"

  # Documented + verified against :ash_domains/:content_domains by
  # `mix kiln.plugins.doctor` (they can't be auto-merged: Ash mix tasks read
  # those config keys before any plugin code could run).
  def domains, do: [Verscienta.Catalog]

  def blocks, do: [Verscienta.Blocks.DosageTable]

  def nav_items, do: [%{label: "Import", path: "/editor/verscienta", role: :admin}]

  def admin_routes, do: [{"/editor/verscienta", Verscienta.ImportLive, :index}]

  def children, do: [Verscienta.SyncWorker]

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
   registry-driven. (Compile-order is safe: the compiler tracks the
   module references; plugins compile in the same pass from `projects/` or
   as deps, which compile first.)
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
- **Marketplace/discovery** — the plan marks it "future"; installers +
  hexdocs are the v1 distribution story. Scoped in
  `docs/plugin-extensibility.md` (decision #333): **no runtime hot-loading of
  arbitrary code** (the BEAM has no in-process sandbox); the marketplace is
  vetted, compile-time, git/hex-distributed plugins carrying cheap catalog
  metadata (`version`/`summary`/`homepage` on the contract,
  `Kiln.Plugins.manifests/0`, `mix kiln.plugins.list`), plus the already-safe
  data-driven runtime config (D17 dynamic types, `Kiln.FieldType`, #342 rules).
  A true third-party runtime-code sandbox (WASM / out-of-process) is a future
  dedicated effort.
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
   compile-time; the runtime `modules/0` scan also merges plugin blocks so
   hex-dep plugins aren't missed); nav appends role-gated plugin items;
   `application.ex` appends plugin children and merges plugin Oban queues at
   boot; `KilnCMSWeb.PluginRouter.plugin_admin_routes/0` expands plugin
   panels inside the admin live_session (`alias: false` — plugin modules are
   fully qualified). All proven by the test-suite fixture plugin: its
   callout block round-trips storage and renders escaped HTML, appears in
   the editor palette, its nav item is role-gated, its panel mounts
   admin-only, its Agent child runs.
3. **Verscienta retrofit + scaffold.** ✅ **Done.** `Verscienta.Plugin`
   (projects/verscienta) makes the plan's "first plugin/consumer" literal —
   domains declared on the contract, doctor-verified against the host
   config. `mix kiln.gen.plugin <Name> [--block <name>]` scaffolds a plugin
   (contract module with stubbed callbacks + optional working sample block +
   config registration); its generated sources are compile-tested against
   the real contract in the suite. `mix kiln.plugins.doctor` joined the
   precommit pipeline. Plugin story documented in
   `docs/extending-content.md` §5. Contract polish: `X.Plugin` default-names
   itself after `X`, not the convention suffix.
