# Runtime / marketplace extensibility — decision & marketplace design

**Status:** decision (amends nothing — it *ratifies* the stance D18/D4 already
took) plus a design for the "marketplace" future those decisions deferred.
**Issue:** [#333](https://github.com/The-Verscienta/kiln_cms/issues/333).
**Relies on:** `Kiln.Plugin` (D18, `docs/plugin-system-plan.md`), dynamic
content types (D17, `docs/dynamic-content-types-plan.md`), `Kiln.FieldType`,
declarative editorial automation (#342).

## TL;DR

> **Kiln does not hot-load arbitrary plugin *code* at runtime, by design.**
> A plugin is compile-time OTP code activated by one config line (D18). The
> "marketplace" is a catalog of **vetted, git/hex-distributed, compile-time
> plugins** — installers, not a code-execution sandbox — plus the parts of a
> live instance that are *already* extensible without code: dynamic content
> types (D17), the `Kiln.FieldType` registry, and declarative automation
> rules (#342). A genuine runtime-code story (out-of-process plugins, a WASM
> runtime) is a separate, dedicated, security-reviewed effort, deferred until
> a proven demand justifies it.

## 1. The decision: no runtime hot-loading of arbitrary code

The issue itself flags the instinct — "Hot-loading arbitrary OTP code is a big
security/stability surface." That instinct is correct and load-bearing.

### Why the BEAM makes this the wrong target

OTP genuinely supports hot code loading, so it is tempting to reach for it. The
problem is not *whether* code can be loaded — it is *what confines it once
loaded*:

- **There is no in-process sandbox on the BEAM.** Hot-loaded code runs in the
  *same node*, in the *same VM*, with the *same privileges* as core. A loaded
  module can call `System.cmd/2`, read or `:sys.get_state/1` any process,
  open the database with full credentials, spawn unlimited processes, or crash
  the scheduler. There is no capability boundary — no seccomp, no namespace,
  no per-module permission — that a plugin could be confined to. Erlang's
  distribution security model assumes *mutually trusting* nodes; it is not an
  isolation primitive.
- **Untrusted third-party code therefore means full compromise.** The moment
  arbitrary code from a marketplace runs in-node, every guarantee above it is
  void: an attacker's "star-rating widget" can exfiltrate secrets or tamper
  with published artifacts.
- **It contradicts what Kiln sells.** Kiln's differentiators — immutable
  published artifacts, supervision-tree reliability, content provenance
  (#4/#5) — all assume the node is *trusted*. Other CMS marketplaces
  (Strapi/Craft/Directus) run on Node/PHP VMs that *also* lack strong
  in-process isolation; they accept that risk because their trust story is
  weaker to begin with. Adopting their model would trade away exactly the
  property Kiln is built to offer.

Compile-time inclusion, by contrast, puts every line of a plugin through the
same review, `mix kiln.plugins.doctor`, CI gate, and release build as core
code. Trust is established *before* the code is in the node, which is the only
point at which the BEAM lets you establish it.

### What a genuine runtime-code story would require

This is not an incremental feature flag away — each option below is a major
architecture project with its own threat model, and all are explicitly
deferred until proven demand justifies the investment:

- **Out-of-process plugins.** Run untrusted extension code as a separate OS
  process (or container) behind an RPC/port boundary, with an explicit,
  narrow protocol (think Language Server Protocol, or `erlang:open_port/2`
  with a byte contract). The OS enforces the isolation the BEAM cannot.
- **Separate, restricted BEAM nodes.** Give plugins their own node with a
  constrained distribution channel and no shared ETS/Mnesia; the core node
  brokers every capability. Distribution hardening and a capability broker are
  the hard parts.
- **A WASM runtime (e.g. [Wasmex](https://hex.pm/packages/wasmex)).** Compile
  plugin logic to WebAssembly and run it in a sandbox with an explicit host
  ABI — memory-isolated, syscall-free by default, capabilities granted one at
  a time. The most promising path for *true* third-party code, but it forces a
  narrow value-passing ABI (no sharing Ash structs/PIDs), a defined extension-
  point surface, and resource metering. A dedicated effort, not a bolt-on.

None of these is required for the marketplace below, which delivers the
practical value of "extend my instance" without opening any of these fronts.

## 2. The marketplace: vetted compile-time plugins + data-driven runtime config

The realization behind this design: **most of what a "live marketplace"
delivers elsewhere, Kiln can offer as data or as vetted installers — with no
runtime code loading at all.**

### 2a. Catalog of vetted, distributable plugins

A "marketplace plugin" is an ordinary `Kiln.Plugin` (D18) packaged as a **hex
package or a git dependency**. Installing one is the flow that already exists:

1. **Add the dependency** — `{:kiln_ratings, "~> 1.0"}` in `mix.exs` (hex) or a
   `git:`/`path:` dep for a private or in-repo plugin.
2. **Register it** — one line: `config :kiln_cms, :plugins, [Ratings.Plugin]`
   (plus its domains in `:ash_domains`/`:content_domains` if it ships content
   types — Ash's own mix tasks read those keys directly).
3. **Verify** — `mix kiln.plugins.doctor` (already gates precommit) asserts the
   contract holds: domains registered, no block/field-type/queue name
   collisions, well-formed routes.
4. **Discover what's installed** — `mix kiln.plugins.list` prints every
   installed plugin with its catalog metadata and contribution surface.

The `mix kiln.gen.plugin <Name>` scaffold already produces a
distribution-shaped skeleton; a marketplace plugin is that skeleton, filled in,
published to hex or a git host.

### 2b. Catalog metadata (the "registry")

The registry is **cheap, declarative data carried by the plugin itself** — no
central service required for v1. Each plugin optionally declares:

| Field | Callback | Purpose |
|---|---|---|
| Name | `name/0` | Machine name (already required) |
| Version | `version/0` | Display/version pin (defaults to `nil`) |
| Summary | `summary/0` | One-line catalog description |
| Homepage | `homepage/0` | Hexdocs / repo URL — **where screenshots, changelog and docs live** |

`Kiln.Plugins.manifests/0` collects these plus each plugin's *contribution
counts* (domains, blocks, field types, nav items, admin routes, queues,
children) into plain maps — the data a catalog UI or `mix kiln.plugins.list`
renders. Screenshots and long-form docs deliberately live in the plugin's own
hex package / README, **not** in the running node: the node carries a pointer
(`homepage/0`), not a media library.

**The curated index** — "which plugins are vetted" — is a governance artifact,
not a code feature: a docs table (or, later, a hosted static index) listing
approved packages with their hex/git coordinates and homepage. Vetting is a
human review that a package is safe to compile in, exactly the bar core code
clears. This keeps the security property intact: nothing is "installed" until a
maintainer adds the dep and re-releases.

### 2c. What's already runtime-configurable without code

For the "extend a live instance *without a rebuild*" cases, Kiln already ships
the safe, data-driven answers — this is the real moat, because it delivers the
agility of a live marketplace while staying compile-time-safe:

- **Dynamic content types (D17).** Admins define a new content type and its
  fields from the UI, backed by the generic `Entry` resource — strings
  end-to-end, no runtime atoms or modules. This is the Directus/Strapi "create
  a collection live" capability *without* code loading.
- **Custom field types (`Kiln.FieldType`).** Plugin-contributed field types are
  compile-time code, but admins *select and configure* them per field at
  runtime in the fields admin (`/editor/fields`).
- **Declarative editorial automation (#342).** "When X, do Y" rules are Oban-
  backed **data**, authored in the admin UI — the safe substitute for the
  "run this script on publish" hooks that other marketplaces sell.

A plugin author reaches for compile-time code only for genuinely new *behavior*
(a new block renderer, a new integration worker); everything schema- or
rule-shaped is data an operator changes without a deploy.

## 3. Scope for this change

- **Decision documented** (this file) and cross-linked from
  `docs/plugin-system-plan.md` §5.
- **Lightweight registry**, implemented here:
  - optional `version/0` / `summary/0` / `homepage/0` metadata on the
    `Kiln.Plugin` contract (defaults keep every existing plugin valid);
  - `Kiln.Plugins.manifests/0` — the plain-data registry view;
  - `mix kiln.plugins.list` — local discovery of installed plugins.
- **Explicitly out of scope, by design:** runtime loading of arbitrary plugin
  code; a hosted marketplace service; screenshot/media hosting in-node.
- **Deferred to a future dedicated effort:** any true third-party runtime-code
  sandbox (WASM / out-of-process), per §1.

Issue #333 stays **open** as the tracking issue for that future effort.
