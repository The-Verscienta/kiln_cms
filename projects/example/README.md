# projects/example — the "Acme" showcase subproject

The in-tree worked example of building on kiln_cms — what a company
evaluating the platform activates to see its capabilities, not a real
deployment. Deliberately subject-matter-agnostic: "Acme" is a fictional
generic company, and every content type here is something virtually any
company has an analogue for (products, staff, customer quotes, FAQs,
events), so the demo showcases the platform rather than one vertical's
content model.

Unlike the Verscienta overlay (which lives in the downstream
[verscienta-base](https://github.com/The-Verscienta/verscienta-base) repo under
`kiln/`), this subproject is committed here under `projects/` — `projects/` is
in `elixirc_paths` and the stock `Dockerfile` ships it — but it follows the
same contract (`projects/README.md`): **the catalog is dormant unless a
deployment activates it**. The core's config never registers
`Example.Catalog`, no core migration creates its tables
(`Kiln.CoreAgnosticTest` enforces both), and the core's own image and CI build
exactly as if this directory were empty.

## What this demonstrates

| Feature | Where |
| --- | --- |
| Compiled content types, block editor, versioning, workflow, search — the baseline every type gets free | `catalog/*.ex` |
| `schema_org_type` opt-in (Product/Person/Review/FAQPage/Event JSON-LD, instead of the macro's default `"Article"`) | every type in `catalog/*.ex`, plus the `event` dynamic type |
| Multi-segment `alias_pattern` + `seo_title_pattern` driven by a custom field | `catalog/product.ex` |
| Admin-defined **custom fields** (D4) — no resource code, no migration | `example_field_definitions.exs` |
| Plugin-contributed **block type** (D18) | `blocks/stat.ex`, wired via `plugin.ex` |
| Plugin-contributed **composite field type** (D18), used as Product's `price` | `field_types/money.ex` |
| Admin-defined **dynamic content type** (D17) — zero Elixir code | `example_dynamic_types.exs` (the `event` type) |
| Events: `datetime_range`/`recurrence` field types → ICS feed + Event JSON-LD | `example_dynamic_types.exs`, seeded entries in `example_import.exs` |
| Multi-locale content (same slug, two locales) | one FAQ, seeded in `example_import.exs` |
| Audience-gating (`:member`-only) and passphrase-locking (`ContentPassword`) | two seeded Products in `example_import.exs` |
| Cross-type related content (`ContentLink`) | Testimonials → Products, `example_import.exs` |
| Forms, embedded via the core `form` block | the "request a demo" form, `example_import.exs` |
| Automation rule, webhook subscription, A/B experiment, content release | `example_demo_config.exs` |

## Layout

| Path | Purpose |
| --- | --- |
| `catalog.ex`, `catalog/` | `Example.Catalog` domain + the four compiled content-type resources (each `use KilnCMS.CMS.Content, domain: Example.Catalog`). Originally generated with `mix kiln.gen.content` (kiln_cms#439). |
| `plugin.ex` | `Example.Plugin` (D18) — declares the domain, block, and field type for `mix kiln.plugins.doctor`. |
| `blocks/stat.ex`, `field_types/money.ex` | The plugin's contributed extension-point examples — see the table above. |
| `project.exs` | Activation config. Copy to `config/project.exs` to register the domain/plugin (see below). |
| `priv/repo/migrations/` | The catalog's Ash migrations: the eight tables (four types + their `_versions`) and the hand-written search-vector migration. Overlaid onto the core's `priv/repo/migrations/` at deploy build time. |
| `priv/resource_snapshots/repo/` | The matching `ash.codegen` snapshots — kept here so the core ships zero example schema. Overlay next to the migrations. |
| `priv/repo/example_field_definitions.exs` | Custom-field definitions for the four compiled types plus two on core `post`. Idempotent; run first. |
| `priv/repo/example_dynamic_types.exs` | Creates the `event` dynamic type and its field definitions (D17, no Elixir module). Run second. |
| `priv/repo/example_import.exs` | Self-contained synthetic seed data — no external export file needed. Run third. |
| `priv/repo/example_demo_config.exs` | Seeds the platform-level features (automation, webhooks, experiments, releases) that aren't resource code. Run last. |

## Activating (dev or a deploy)

Activation is config-only. The core's `config/config.exs` imports
`config/project.exs` when present (git-ignored in the core repo):

```bash
cp projects/example/project.exs config/project.exs
mix ecto.migrate --migrations-path priv/repo/migrations \
                 --migrations-path projects/example/priv/repo/migrations
```

A deployment image does the same at build time via the core Dockerfile's
`PROJECT` build arg — activation and the priv merge in one flag:

```bash
docker build --build-arg PROJECT=example .
```

Equivalent manual COPY steps, for a custom Dockerfile:

```dockerfile
COPY projects/example/project.exs config/project.exs
# Additive: distinct filenames, nothing in core priv/ is clobbered.
COPY projects/example/priv/repo/migrations/ priv/repo/migrations/
COPY projects/example/priv/resource_snapshots/repo/ priv/resource_snapshots/repo/
```

With the migrations overlaid into `priv/repo/migrations/`, the release's
boot-time `bin/migrate` picks them up unchanged, and `mix ash.codegen` in the
assembled tree sees resources and snapshots agree.

## Seeding the demo

One-time, after activation, against a seeded admin (`ADMIN_EMAIL`, default
`admin@kiln.test`), in this order:

```bash
mix run projects/example/priv/repo/example_field_definitions.exs
mix run projects/example/priv/repo/example_dynamic_types.exs
mix run projects/example/priv/repo/example_import.exs
mix run projects/example/priv/repo/example_demo_config.exs
```

All four are idempotent and safe to re-run. Unlike the overlay's original
Sanity-derived import, `example_import.exs` needs no external export file —
it generates its own fictional "Acme" sample data directly, so the demo runs
out of the box.
