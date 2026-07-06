# projects/ — downstream project overlays

KilnCMS is a reusable core: nothing project-specific is committed here. A
deployment layers its own subproject onto this directory **at image-build
time** and activates it via config — the core repo never changes.

## The overlay contract

A subproject is a `projects/<name>/` directory (this path is in
`elixirc_paths` for every env — see `mix.exs`) containing:

- an **Ash domain** (e.g. `MyProject.Catalog`) whose resources are built on
  `KilnCMS.CMS.Content` with `domain: MyProject.Catalog` — admin CRUD,
  delivery APIs, search, webhooks and workers follow automatically once the
  domain is registered;
- a **`Kiln.Plugin`** module declaring the domain (verified by
  `mix kiln.plugins.doctor`), plus any blocks/nav/routes/children it adds;
- optionally mix tasks, importers, fixtures and tests.

Activation is config-only. `config/config.exs` ends by importing
`config/project.exs` **when present** (a clean core checkout has none — the
file is git-ignored here). The overlay ships one that registers everything:

```elixir
import Config

config :kiln_cms,
  ash_domains: [KilnCMS.Accounts, KilnCMS.CMS, ..., MyProject.Catalog],
  content_domains: [KilnCMS.CMS, MyProject.Catalog]

config :kiln_cms, :plugins, [MyProject.Plugin]
```

`:content_domains` is read at compile time by the GraphQL schema and the
JSON:API router, so registering a domain there exposes its types on every
delivery surface with no core edits.

## Building an overlaid image

The downstream repo pins this repo (submodule or fetched ref) and its
Dockerfile copies the core plus its overlay:

```dockerfile
COPY upstream/ ...                     # this repo, pinned
COPY projects  projects                # the subproject
COPY config/project.exs config/        # activation config
```

## Reference

The first real subproject — Verscienta Health (`Verscienta.Catalog`, six
content types, a two-pass Directus ETL importer) — lives in the
[verscienta-base](https://github.com/The-Verscienta/verscienta-base) repo
under `kiln/`, and was extracted from this repo where it originally landed
(#236).
