# Contributing to KilnCMS

Thanks for contributing! This guide covers the development workflow and the
conventions that keep the codebase consistent. For the project vision and
architecture see [`KilnCMS_Project_Plan.md`](KilnCMS_Project_Plan.md); for the
authoritative, always-in-context coding rules see [`AGENTS.md`](https://github.com/The-Verscienta/kiln_cms/blob/main/AGENTS.md)
(which also links the per-package Ash/Phoenix usage rules).

By participating you agree to the
[Code of Conduct](https://github.com/The-Verscienta/kiln_cms/blob/main/.github/CODE_OF_CONDUCT.md).
Found a security problem? **Don't open an issue** — follow the
[security policy](https://github.com/The-Verscienta/kiln_cms/blob/main/.github/SECURITY.md)
and report it privately.

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

In dev, AshAdmin uses your signed-in user as its actor automatically, so admin
actions run under real RBAC policies — sign in as the editor and you'll only see
what an editor is allowed to do. You can still impersonate a specific record by
picking an actor from the AshAdmin toolbar (that choice overrides the default).
This wiring lives in `KilnCMSWeb.AshAdmin.ActorPlug` and is enabled only when
`dev_routes` is on (`config :ash_admin, :actor_plug, ...` in `config/dev.exs`).

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

Commit the generated migration **and** snapshot together with the resource
change. Don't hand-edit files under `priv/repo/migrations/` or
`priv/resource_snapshots/` — they're generated and checked.

CI runs `mix ash.codegen --check`, which fails the build if the committed
migrations/snapshots don't match the resources (i.e. you edited a resource but
forgot to run `mix ash.codegen`). Run the same check locally before pushing:

```bash
mix ash.codegen --check   # exits non-zero when codegen is pending
```

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
`credo --strict`, `sobelow` (security scan), `deps.audit` (dependency CVE scan,
see below), `kiln.plugins.doctor`, and the test suite. CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) additionally runs
`mix ash.codegen --check` (migration/snapshot drift, see above),
`mix dialyzer` (the first local run builds a PLT and is slow; it's cached
afterwards), and a **gettext catalog gate** — `mix gettext.extract --merge`
must leave `priv/gettext` unchanged. That gate is CI-only and is not part of
`mix precommit`, so run it yourself before pushing any change to a file
containing `gettext(...)`; drifting line references alone will fail CI:

```bash
mix gettext.extract --merge && git diff --exit-code -- priv/gettext
```

### Documentation

CI builds the docs with `mix docs --warnings-as-errors` in its own job. Like the
gettext gate this is CI-only, so run it yourself if you renamed a file under
`docs/`, changed a link between guides, or wrote a moduledoc that references
another module or function:

```bash
mix docs --warnings-as-errors
```

It fails on dead cross-references — a `docs/` file listed in `extras` that no
longer exists, a `` `Module.fun/2` `` that was renamed or changed arity. Adding
a new guide means adding it to both `extras` and `groups_for_extras` in
`mix.exs`; an unlisted guide is silently invisible in the generated sidebar.

### Dependency audit

`mix deps.audit` ([mix_audit](https://github.com/mirego/mix_audit)) checks
`mix.lock` against the Elixir security advisory database. It runs in
`mix precommit` and as its own CI job (`Dependency audit`).

Because the advisory database moves independently of this repo, **this gate can
fail on a PR that touched no dependencies** — that means a new advisory landed
against something already locked, not that your change broke anything. It has
its own job precisely so that failure doesn't bury the lint/test results of an
unrelated change. Remediate by upgrading the affected dependency; if no fixed
version exists, document the accepted risk and use mix_audit's ignore options
rather than dropping the check.

The job fetches the advisory database explicitly before running the audit.
mix_audit clones it at run time and ignores the exit status of its own git
commands, so a failed fetch would otherwise leave it with zero advisories and a
green "No vulnerabilities found" — a pass that verified nothing.

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
