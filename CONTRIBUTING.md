# Contributing to KilnCMS

Thanks for contributing! This guide covers the development workflow and the
conventions that keep the codebase consistent. For the project vision and
architecture see [`KilnCMS_Project_Plan.md`](KilnCMS_Project_Plan.md); for the
authoritative, always-in-context coding rules see [`AGENTS.md`](AGENTS.md)
(which also links the per-package Ash/Phoenix usage rules).

## Getting set up

See the **Getting started** section of the [README](README.md) for the full
setup (`docker compose up -d postgres`, then `mix setup`). A few environment
notes that bite people:

- **`mix` must be on your `PATH`** (Homebrew installs to `/opt/homebrew/bin`).
- **The repo must live at a space-free, non-iCloud path.** Native deps
  (`bcrypt_elixir`, libvips) build via `make`, which fails on spaced/iCloud
  paths.
- **Keep the `igniter` dependency** — removing it triggers an Elixir 1.20.1
  compiler crash locally.
- **Node.js is required for assets** — the editor bundles JS deps (TipTap) that
  esbuild pulls from `assets/node_modules`. `mix setup` runs `npm install` for
  you; otherwise run `npm install` in `assets/`. `assets/node_modules` is
  gitignored; `assets/package-lock.json` is committed.

`mix setup` seeds a demo admin (`admin@kiln.test` / `kilnadmin123`) and editor
(`editor@kiln.test` / `kilneditor123`); override with the `ADMIN_*` / `EDITOR_*`
env vars. Sign in at `/sign-in`, or use AshAdmin at `/admin` (dev only).

## Development workflow

### Modeling is done in Ash — never hand-write migrations

KilnCMS models its domain with Ash resources. To change the schema:

1. Edit the resource (e.g. `lib/kiln_cms/cms/page.ex`).
2. Generate the migration **and** resource snapshot:
   ```bash
   mix ash.codegen <descriptive_name>
   ```
3. Apply it:
   ```bash
   mix ash.migrate
   ```

Don't hand-edit files under `priv/repo/migrations/` or
`priv/resource_snapshots/` — they're generated and checked.

### Every action gets a domain code interface

Call into resources through the domain code interfaces (`CMS.create_page!`,
`CMS.list_pages!`, `Accounts.get_user_by_email`, …) — **not** raw
`Ash.create!/read!` — in app code, seeds, and tests. When you add an action,
add a matching `define :name, action: :name` on the domain. Ash also generates
`can_*?/2` helpers (e.g. `CMS.can_publish_page?(actor, page)`) — use them for
authorization-driven UI.

### Authorization is mandatory

Every domain/content resource uses `Ash.Policy.Authorizer`. The role model
(`User.role` → `:admin` / `:editor` / `:viewer`):

- **published** content is world-readable (headless delivery); **unpublished**
  is editor-only,
- create/update + workflow transitions require **editor** (or admin),
- hard deletes are **admin-only**, admins bypass.

A new resource without policies is a bug. Pass the current user as `actor:` to
code-interface calls so policies can evaluate.

## Quality gate

Run this before every PR — it's the same gate CI enforces:

```bash
mix precommit
```

It runs: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
`credo --strict`, `sobelow` (security scan), and the test suite. CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) additionally runs
`mix dialyzer` (the first local run builds a PLT and is slow; it's cached
afterwards).

### Testing

- Use `KilnCMS.DataCase` for data-layer tests (SQL sandbox).
- Test domain behaviour **through the code interfaces**; test authorization
  with the generated `can_*?` helpers or `Ash.can?`.
- Use globally unique values for identity fields
  (`"...-#{System.unique_integer([:positive])}@example.com"`) to avoid
  concurrent-test deadlocks.
- Seed fixtures with `Ash.Seed.seed!` when you want to bypass the very
  policies/actions under test.

### Browser E2E (Playwright)

LiveView tests cover server-side events; the browser E2E suite (in `e2e/`)
drives a real headless Chromium through the editor — TipTap rich text,
SortableJS drag-reorder, and the create → edit → publish → view-live journey.
It runs in a dedicated `MIX_ENV=e2e` against its own `kiln_cms_e2e` database
(no SQL sandbox — the browser hits the server out-of-process).

```bash
cd e2e
npm install
npx playwright install chromium   # bundled browser; no system Chrome needed
npx playwright test               # boots the server itself, then runs the suite
```

Playwright's `webServer` runs `mix e2e.setup` (build assets + create/migrate/seed
the e2e DB) and then serves with `PHX_SERVER=true PORT=4002 mix phx.server`. To
run against a server you started yourself, set `E2E_NO_WEBSERVER=1`. CI runs this
suite as a separate `e2e` job (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## Commits & pull requests

- Branch off `main`; keep commits focused with a clear imperative subject line.
- Ensure `mix precommit` passes and update
  [`KilnCMS_Project_Plan.md`](KilnCMS_Project_Plan.md)'s TODO checklist when you
  complete a planned item.
- Open a PR against `main`; CI must be green before merge.
