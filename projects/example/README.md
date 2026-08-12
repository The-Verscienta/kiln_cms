# projects/example — the holistic-acupuncture site's subproject

The content catalog backing the holistic-acupuncture site's migration off
Sanity: four content types on `KilnCMS.CMS.Content` — **Condition**,
**TeamMember**, **Testimonial**, **Faq** — registered on the
`Example.Catalog` Ash domain, plus the one-time Sanity import scripts.

Unlike the Verscienta overlay (which lives in the downstream
[verscienta-base](https://github.com/The-Verscienta/verscienta-base) repo under
`kiln/`), this subproject is committed here under `projects/` — `projects/` is
in `elixirc_paths` and the stock `Dockerfile` ships it — but it follows the
same contract (`projects/README.md`): **the catalog is dormant unless a
deployment activates it**. The core's config never registers
`Example.Catalog`, no core migration creates its tables
(`Kiln.CoreAgnosticTest` enforces both), and the core's own image and CI build
exactly as if this directory were empty.

## Layout

| Path | Purpose |
| --- | --- |
| `catalog.ex`, `catalog/` | `Example.Catalog` domain + the four content-type resources (each `use KilnCMS.CMS.Content, domain: Example.Catalog`). Originally generated with `mix kiln.gen.content` (kiln_cms#439). |
| `plugin.ex` | `Example.Plugin` (D18) — declares the domain for `mix kiln.plugins.doctor`. |
| `project.exs` | Activation config. Copy to `config/project.exs` to register the domain/plugin (see below). |
| `priv/repo/migrations/` | The catalog's Ash migrations: the eight tables (four types + their `_versions`) and the hand-written search-vector migration. Overlaid onto the core's `priv/repo/migrations/` at deploy build time. |
| `priv/resource_snapshots/repo/` | The matching `ash.codegen` snapshots — kept here so the core ships zero example schema. Overlay next to the migrations. |
| `priv/repo/example_field_definitions.exs` | 27 custom-field definitions (24 across the four types + 3 on core `post` for the migrated blog). Idempotent; run before the import. |
| `priv/repo/example_import.exs` | The Sanity content import (kiln_cms#441). Loads the export produced by the Astro repo's `scripts/export-to-kiln.js`. Idempotent by natural key. |

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

## The Sanity migration

One-time, after activation, against a seeded admin (`ADMIN_EMAIL`, default
`admin@kiln.test`):

```bash
mix run projects/example/priv/repo/example_field_definitions.exs
mix run projects/example/priv/repo/example_import.exs path/to/kiln-export.json
```

Both are idempotent and safe to re-run; the field-definitions script is the
source of truth for the custom fields (condition category/symptoms,
team-member credentials, testimonial ratings, FAQ categories, post bylines).
The import publishes each record and then restores its original Sanity
`published_at` with a direct `Repo` update.
