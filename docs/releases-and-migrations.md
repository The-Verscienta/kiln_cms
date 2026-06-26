# Releases & database migrations — Project Plan Phase 9

How KilnCMS database migrations are **generated** in development and **applied**
in a production OTP release that ships *without Mix installed*. This is the
Phase 9 "Database migrations in release" work (issue #55).

The short version:

- **Develop:** `mix ash.codegen <name>` generates a migration *and* updates the
  resource snapshots. Commit both together.
- **Deploy:** run `bin/migrate` (a thin wrapper over
  `bin/kiln_cms eval "KilnCMS.Release.migrate"`) as a pre-deploy / release step,
  then start the server with `bin/server`.

See [`docs/deployment-coolify.md`](deployment-coolify.md) for the full Coolify
service/deploy setup that this document plugs into.

## Where migrations live

KilnCMS persists its Ash resources with AshPostgres on top of Ecto, so the
on-disk artifacts are the usual Ecto migrations plus Ash's resource snapshots:

| Path | What it is | Committed? |
|------|------------|-----------|
| `priv/repo/migrations/*.exs` | Generated Ecto migrations (`up`/`down`). | Yes |
| `priv/resource_snapshots/repo/**/*.json` | Per-table snapshots of each resource's data layer. Ash diffs the *current* resources against these snapshots to decide what a new migration should contain. | Yes |
| `priv/resource_snapshots/repo/extensions.json` | Installed Postgres extensions (e.g. `ash-functions`, `citext`, `vector`) tracked the same way. | Yes |

> [!IMPORTANT]
> A migration and its snapshot changes are **one logical unit**. Always commit
> the new file(s) under `priv/repo/migrations/` *together with* the matching
> changes under `priv/resource_snapshots/`. If the snapshots drift out of sync
> with the migrations, the next `mix ash.codegen` will try to "re-create" or
> "fix up" schema that already exists, producing a spurious migration.

## Generating migrations (development)

Edit your Ash resources, then ask Ash to diff them against the snapshots and
emit a migration. The Ash-native task is preferred because it keeps the
snapshots in lock-step:

```bash
# Preferred: name the change; updates migrations AND resource snapshots.
mix ash.codegen add_author_to_content
```

`mix ash.codegen` is the high-level codegen entry point across all Ash
extensions; for the AshPostgres data layer it calls through to the migration
generator. You can invoke the generator directly if you only want the Postgres
migrations regenerated:

```bash
mix ash_postgres.generate_migrations add_author_to_content
```

Useful variants while iterating:

```bash
# See what *would* be generated without writing files.
mix ash.codegen --dry-run

# Generate without prompting for a name (named "auto_generated_<timestamp>").
mix ash.codegen --check   # CI-friendly: fails if resources & snapshots disagree
```

To create the local database and apply everything in one shot during setup, the
repo ships a `mix setup` alias that runs `ash.setup` (create + migrate + Ash
extension setup) among other steps — see the `aliases/0` in
[`mix.exs`](../mix.exs):

```bash
mix setup        # deps.get, ash.setup, assets, seeds
# or just the DB part:
mix ash.setup    # create + migrate + install extensions
mix ash.migrate  # apply pending migrations to an existing DB
```

Review the generated `*.exs` migration by hand before committing — Ash gets the
schema right, but data backfills, index concurrency, and destructive changes
usually want human attention.

## Applying migrations in a release (production)

The production image is a `mix release` (see [`Dockerfile`](../Dockerfile)). It
contains the compiled application and the ERTS, but **no Mix and no source
tasks** — so `mix ecto.migrate` is not available at runtime. Instead the release
exposes a plain Elixir module that drives `Ecto.Migrator` directly.

### The release module

[`lib/kiln_cms/release.ex`](../lib/kiln_cms/release.ex) defines
`KilnCMS.Release.migrate/0`, which iterates the repos in the application's
`:ecto_repos` config and runs every pending migration:

```elixir
def migrate do
  load_app()

  for repo <- repos() do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
  end
end
```

`load_app/0` starts `:ssl` (many managed Postgres providers require TLS) and
loads the `:kiln_cms` application so its config — including the
`DATABASE_URL`-derived repo config in [`config/runtime.exs`](../config/runtime.exs)
— is available. It does **not** start the full supervision tree (so the web
endpoint never boots just to migrate).

### The `bin/migrate` overlay

The release overlay [`rel/overlays/bin/migrate`](../rel/overlays/bin/migrate) is
the operator-facing entry point. It is copied into the release `bin/` directory
and simply `eval`s the module above:

```sh
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
exec ./kiln_cms eval KilnCMS.Release.migrate
```

So inside a running container these are equivalent:

```bash
/app/bin/migrate
# is exactly:
/app/bin/kiln_cms eval "KilnCMS.Release.migrate"
```

`eval` boots a throwaway node, runs the function with the application *loaded*
(config applied) but *not started*, then exits — ideal for one-shot DB tasks.

### Coolify

In Coolify, run the migration as a **pre-deployment command** (or an
on-demand command on the running service) so it executes against the same image
and environment as the app:

```bash
# Pre-deploy command (runs before the new container takes traffic):
/app/bin/migrate
```

If you prefer to exec into an already-running container instead:

```bash
docker exec -it <kiln_cms_container> /app/bin/migrate
```

The container already has `DATABASE_URL`, `SECRET_KEY_BASE`, and
`TOKEN_SIGNING_SECRET` in its environment (required by `config/runtime.exs`), so
no extra wiring is needed. See [`docs/deployment-coolify.md`](deployment-coolify.md)
for where these are configured.

### Fly.io

Fly runs a dedicated migration step via `release_command` in `fly.toml`, which
Fly executes in a temporary VM built from the release image *before* the new
version is rolled out:

```toml
# fly.toml
[deploy]
  release_command = "/app/bin/migrate"
```

If the `release_command` exits non-zero the deploy is aborted and the previous
version keeps serving — which is exactly the safety property you want from a
migration step.

## Recommended deploy ordering

> **Run `bin/migrate` as a pre-deploy / release step, then start the server with
> `bin/server`.** Do not migrate from inside the application boot.

There are two common ways to apply migrations on deploy:

1. **Dedicated release task (recommended).** A separate step
   (`bin/migrate` → Coolify pre-deploy command, Fly `release_command`) runs the
   migrations *once*, to completion, before any new app container starts taking
   traffic. The web image then starts cleanly with `bin/server`
   ([`rel/overlays/bin/server`](../rel/overlays/bin/server)), which just sets
   `PHX_SERVER=true` and runs `./kiln_cms start`:

   ```sh
   #!/bin/sh
   set -eu
   cd -P -- "$(dirname -- "$0")"
   PHX_SERVER=true exec ./kiln_cms start
   ```

   Benefits: migrations run exactly once regardless of replica count; a failed
   migration aborts the deploy instead of crash-looping the app; the web node's
   boot path stays free of DB-schema side effects.

2. **Migrate-on-boot.** Call `KilnCMS.Release.migrate/0` from the application
   start sequence so each container migrates as it comes up. Simpler to wire,
   but with multiple replicas several nodes race to migrate the same database,
   boot is coupled to schema changes, and a bad migration turns into a restart
   loop rather than a clean failed-deploy. Avoid this for KilnCMS.

The KilnCMS image is built for option 1: `CMD ["/app/bin/server"]` starts only
the web server, and `bin/migrate` is provided as the separate schema step.

A typical deploy is therefore:

```text
build image  →  bin/migrate (release/pre-deploy step)  →  bin/server (CMD)
```

## Rolling back

`KilnCMS.Release.rollback/2` rolls a single repo back **to** a target migration
version (every migration after that version is reverted via its `down/0`):

```elixir
def rollback(repo, version) do
  load_app()
  {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
end
```

Because it takes arguments, call it with `eval` and pass the repo module plus
the target version (the numeric timestamp prefix of a migration filename):

```bash
# Roll the primary repo back to (and including) version 20260622013203:
/app/bin/kiln_cms eval "KilnCMS.Release.rollback(KilnCMS.Repo, 20260622013203)"
```

Notes:

- The `version` is the timestamp prefix of a file in `priv/repo/migrations/`
  (e.g. `20260622013203_add_scheduled_at.exs` → `20260622013203`). Migrations
  *after* that version are rolled back; the named version itself is kept.
- A rollback is only as good as the migration's `down/0`. Review generated
  `down` steps before relying on them, and never count on rollback to recover
  data dropped by a destructive `up`.
- There is no `bin/rollback` overlay — rollback is a deliberate, manual
  operation run through `eval`.

## Verifying in the Docker production image

The acceptance criterion for issue #55 is that the documented migration command
works inside the Docker production image. Verify it end-to-end against a throwaway
Postgres:

```bash
# 1. Build the production image (multi-stage release build).
docker build -t kiln_cms:verify .

# 2. Start a throwaway Postgres for the test.
docker run -d --name kiln-pg \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=kiln_cms_prod \
  -p 5432:5432 postgres:16

# 3. Run the release migration task against it.
#    (Note: bin/migrate does NOT need PHX_SERVER or the endpoint secrets,
#    but runtime.exs still requires SECRET_KEY_BASE / TOKEN_SIGNING_SECRET.)
docker run --rm --link kiln-pg:db \
  -e DATABASE_URL="ecto://postgres:postgres@db/kiln_cms_prod" \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e TOKEN_SIGNING_SECRET="$(openssl rand -base64 32)" \
  kiln_cms:verify /app/bin/migrate
```

Confirm the schema was created:

```bash
# 4. List the tables Ash/AshPostgres created.
docker exec -it kiln-pg \
  psql -U postgres -d kiln_cms_prod -c "\dt"
# Expect: pages, posts, media_items, categories, content_links,
#         content_views, users, oban_jobs, schema_migrations, … etc.

# 5. Confirm every migration is recorded.
docker exec -it kiln-pg \
  psql -U postgres -d kiln_cms_prod -c "SELECT version FROM schema_migrations ORDER BY version;"
```

Then start the server against the now-migrated database and check it boots and
serves health traffic:

```bash
# 6. Start the web server (same CMD the image uses by default).
docker run --rm --link kiln-pg:db -p 4000:4000 \
  -e DATABASE_URL="ecto://postgres:postgres@db/kiln_cms_prod" \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e TOKEN_SIGNING_SECRET="$(openssl rand -base64 32)" \
  -e PHX_HOST="localhost" \
  kiln_cms:verify   # CMD defaults to /app/bin/server

# In another terminal, the endpoint should respond:
curl -i http://localhost:4000/
```

The image's `HEALTHCHECK` uses `bin/kiln_cms rpc "1 + 1"`, which proves the node
is up and accepting distributed RPC — you can reproduce it directly:

```bash
docker exec -it <kiln_cms_container> /app/bin/kiln_cms rpc "1 + 1"
# => 2
```

Re-running `bin/migrate` after a successful run is safe and idempotent: with no
pending migrations it is a no-op. Clean up the test resources with
`docker rm -f kiln-pg` when finished.

## Checklist

- [ ] Resources changed → `mix ash.codegen <name>` (or
      `mix ash_postgres.generate_migrations <name>`).
- [ ] Reviewed the generated migration's `up`/`down`.
- [ ] Committed `priv/repo/migrations/*` **and** `priv/resource_snapshots/*`
      together.
- [ ] Deploy applies them via `bin/migrate` as a pre-deploy / `release_command`
      step **before** `bin/server` starts.
- [ ] `mix ash.codegen --check` is clean (no undiffed resource changes).
