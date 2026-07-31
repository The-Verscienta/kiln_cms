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

## Staying up to date

Updating Kiln means moving the pin to a newer upstream release, rebuilding, and
redeploying. Run it **from inside the pinned Kiln checkout** — whichever path
your layout uses (`kiln/upstream`, `upstream/`, …), submodule or fetched ref:

```bash
cd <your kiln checkout>
mix kiln.update --check     # what's new, new migrations, upgrade notes
mix kiln.update             # move the pin to the newest release
```

It refuses to run anywhere else: it identifies the repo to move from the
directory it runs in, so from the project repo it would read *your* tags,
migrations and changelog as Kiln's. It targets tagged releases, refuses to move
a dirty or locally-patched pin, and refuses a major jump (which by this repo's
versioning means *your subproject needs code changes*) without `--allow-major`.
It never runs migrations or deploys — it prints those steps, in the order you
run them.

A deployed instance also reports its version and whether it's behind at
`/editor/system`, and prints the same command. The image cannot know where your
pin lives; set `KILN_PIN_PATH` (e.g. `kiln/upstream`) if you want that page to
show the matching `cd` too.

Full release and upgrade process: [`docs/releasing.md`](../docs/releasing.md).

## Reference

The first real subproject — Verscienta Health (`Verscienta.Catalog`, six
content types, a two-pass Directus ETL importer) — lives in the
[verscienta-base](https://github.com/The-Verscienta/verscienta-base) repo
under `kiln/`, and was extracted from this repo where it originally landed
(#236).

One subproject is committed in-tree: `acupuncture/` (`Acupuncture.Catalog`,
the holistic-acupuncture site's four content types + Sanity import — see its
README). It follows the same contract: the domain compiles but stays
**dormant** — core config never registers it, its migrations and snapshots
live under `acupuncture/priv/` (not the core `priv/`), and
`Kiln.CoreAgnosticTest` enforces that no unregistered project's schema leaks
into a core build. Activation is still deploy-side via `config/project.exs`.
