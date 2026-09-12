# Demo mode — a public instance that resets itself

A **demo instance** is a Kiln that anyone may sign in to, as a shared **editor**
account, and that returns to a known-good state on a schedule. It is how
`demo.kilncms.dev` lets visitors try the editor without an install.

Demo mode is **hard off by default**. It is enabled by one variable, and even
then it refuses to run against anything that doesn't look like a demo (see
[the guard rails](#guard-rails)). The reset drops every table in the database it
points at, so it has to be *unable* to run anywhere else, not merely configured
not to.

The code is `KilnCMS.Demo` (`lib/kiln_cms/demo.ex`) and its four helpers under
`lib/kiln_cms/demo/`.

## Set up a demo instance

A demo is its **own deployment**: its own app and its own Postgres (the
`pgvector/pgvector` image, like production), sharing nothing with production or
with the marketing site. Deploy it as described in [`deploy.md`](deploy.md),
with these differences.

1. **Name the database like a demo.** The name must contain `demo`, e.g.
   `kiln_demo`. This check has no override.
2. **Serve it at a demo host.** `PHX_HOST` must contain `demo`, e.g.
   `demo.kilncms.dev` (or be `localhost` while you try it locally).
3. **Give `BACKUP_DIR` a persistent volume** (default `/var/backups/kiln`).
   The golden snapshot lives there, and without a volume a redeploy loses it.
4. **Keep media somewhere that survives an upgrade.** The golden content's
   images must still exist after every image upgrade. The Local adapter writes
   inside the release (`/app/lib/kiln_cms-<version>/priv/uploads`), a path that
   changes with each version, so prefer object storage with **a bucket of the
   demo's own** — never production's (see [Media](#media)).
5. **Set the demo variables** (full rows in
   [`environment-variables.md`](environment-variables.md#demo-mode)):

   ```bash
   KILN_DEMO_RESET=confirm          # the sentinel — `true` does NOT enable it
   KILN_DEMO_RESET_CRON="0 * * * *" # optional; hourly is the default
   ```

   Leave the outbound integrations unset: no `MAIL_MODE`/`SMTP_*` (mail is inert
   anyway), no LLM provider keys, no `KILN_VAPID_*`, no Unsplash key. Visitors
   are strangers, and each of those spends your money or sends in your name.
6. **Boot it, sign in as the admin** ([first admin](deploy.md#first-admin--bootstrap)),
   create the shared account with role **editor**, and curate the demo
   content: pages, media, a few drafts worth editing.
7. **Capture the golden snapshot** from inside the running container:

   ```bash
   /app/bin/kiln_cms rpc 'KilnCMS.Demo.capture_golden!()'
   ```

8. **Run one reset by hand** to prove the round trip before the schedule does:

   ```bash
   /app/bin/kiln_cms rpc 'KilnCMS.Demo.reset!()'
   ```

9. Publish the shared account's email and password wherever visitors will find
   them (the marketing site). The console and the sign-in page show a strip
   naming the deployment `demo` and when it next resets.

## What a reset does

```
guard ─ read golden ─ render SQL ─ note current media keys
  │
  ▼
quiesce   gate mounts + collab, close documents, pause + drain Oban, evict sockets
  │
  ▼
restore   wipe + golden snapshot, ONE transaction — a failure changes nothing
  │
  ▼
reconnect the pool ─ evict again ─ flush caches ─ migrate ─ reap media ─ flush
  │
  ▼
resume    always, even after a failure
```

A reset that is refused, or that fails before the restore commits, leaves the
demo exactly as it was.

## Design decisions

### 1. Snapshot mechanism: a golden `pg_dump`, restored atomically

The alternative was an in-app truncate-and-reseed. It was rejected because the
demo's content is curated by hand in the editor (pages, media, drafts, and
their history), and a seed script would have to reproduce all of it and keep
pace with every schema change. A dump captures whatever the operator built,
with no code to maintain.

How the restore works (`KilnCMS.Demo.Restore`):

- **One transaction.** `pg_restore --file` renders the archive to SQL, and
  `psql --single-transaction` applies a wipe script and that SQL together. If the
  restore fails partway (corrupt archive, lock timeout, full disk), the wipe
  rolls back with it.
- **Restore, then migrate.** The wipe drops everything in `public`, including
  tables the snapshot has never heard of, so an old snapshot restores cleanly.
  `Ecto.Migrator` then brings it up to the running code's schema. This is why
  it is a wipe and not `pg_restore --clean`: `--clean` drops only the archive's
  own objects, which would leave every newer table in place, and the `migrate`
  would then fail creating a table that already exists.
- **Extensions are left alone.** Objects owned by an extension (`vector`,
  `pg_trgm`, `citext`) survive the wipe, and the archive's `EXTENSION` entries
  are skipped. `vector` isn't a trusted extension on every build, so
  re-creating it could need a superuser the demo's role doesn't have.
- **Inside the live node.** The Oban job runs in the serving node, so that node
  can quiesce its own sockets, documents, queues and caches around the restore.
  A separate process could not reach any of them.
- **Never restored:** the rows of `tokens` (so a captured session, the
  operator's own included, is never resurrected), `oban_jobs` and
  `oban_peers` (so jobs queued at capture time don't run against today's
  data).

### 2. Live state during a reset

The danger is not a request that fails while the restore runs. It is state
from *before* the restore being written *into* the restored database. Postgres
makes that easy: a write that blocked on the restore's locks lands in the new
table once they are released. So each holder of pre-reset state is stopped
first (`KilnCMS.Demo.LiveState`):

| Live state | What the reset does |
|---|---|
| **Collaborative documents** (`KilnCMS.Collab.DocServer`) | Closed before the restore. Their write-back lands in the database about to be replaced. None may open until the reset ends; the editor falls back to solo editing. |
| **LiveView sessions** | Every user's sockets are evicted just before the restore, and again after it. While the reset runs, a signed-in page refuses to mount and redirects to sign-in with *"The demo is being reset. Sign in again in a moment."* |
| **User sessions / tokens** | `tokens` restores empty, so every visitor signs in again after a reset. |
| **In-flight Oban jobs** | All queues are paused cluster-wide, and running jobs get 30 s to finish. A job still running after that is left alone and reported, because killing it mid-write is worse than a stale write the next reset removes. Queues resume afterwards. |
| **Delivery caches** | `KilnCMS.Cache.flush_delivery/0` (every node) runs after the restore and again after the migration, and the host→org cache is cleared. |
| **Pooled DB connections** | Recycled (`Ecto.Adapters.SQL.disconnect_all/2`), because their prepared statements and cached type OIDs refer to replaced tables. |
| **Rate limits** | Per-account sign-in throttles are forgotten. Everyone shares the demo account's failure budget, and anyone can spend it on purpose. Per-IP buckets are kept: they belong to the visitor, not the data, and expire on their own. |

### 3. Media

A restore rewinds the `media_items` rows but not the files they point at, and
that fails in two directions. Visitors' uploads leak, and worse, a visitor who
purges a golden image or rotates one (which regenerates and deletes its
variants) deletes files the golden snapshot still references.

So in demo mode `KilnCMS.Storage.delete/1` and `delete_private/1` don't delete.
They record the key in `deferred-deletes` beside the golden snapshot. The reset
then deletes:

    (keys the pre-reset database referenced ∪ deferred keys)
      − keys the restored golden database references

A file the golden snapshot references is never deleted. Storage is never
*listed*: only keys Kiln itself recorded are candidates, so a demo that
mistakenly shares a bucket deletes nothing another deployment wrote. The one
leftover is an upload that failed before any row or deferral recorded it, the
same residue production has.

### 4. Guard rails

`KilnCMS.Demo.Guard` re-checks at **every** reset, not once at boot:

- **The sentinel.** `KILN_DEMO_RESET=confirm`. `true` is refused like a typo (the
  `KILN_STAGING_SCRUB` convention) and reported in the boot-time config
  warnings.
- **The database name contains `demo`.** No override.
- **The served host (`PHX_HOST`) contains `demo`** or is `localhost`. A
  production node given a demo `DATABASE_URL` by copy-paste still refuses.
- **The tools connect where the app does.** `pg_restore`/`psql` use a URL, which
  `BACKUP_DATABASE_URL` can point anywhere, so that URL's host and database
  must match the Repo's.
- **The snapshot came from a demo database.** Its archive header names the
  database it was dumped from, and that name must contain `demo`. Restoring a
  production backup here would publish production's accounts, password hashes
  included.
- **The tools exist:** `pg_dump`, `pg_restore`, `psql` (the image ships
  `postgresql-client-17`).

A refusal cancels the scheduled job with the reason. A reset that tried and
failed errors the job, so alert on that.

### 5. Trigger

- **On a schedule:** `KILN_DEMO_RESET_CRON` (hourly by default; `false` keeps
  demo mode but only allows manual resets). `KilnCMS.Demo.ResetWorker` runs on
  its own `:demo` queue, with one worker, started only in demo mode.
- **By hand, on the running node** (the normal manual path):
  `/app/bin/kiln_cms rpc 'KilnCMS.Demo.reset!()'`.
- **By hand, with the app stopped** (first boot, or a pre-deploy command):
  `/app/bin/kiln_cms eval 'KilnCMS.Release.reset_demo()'`. This runs the same
  guards, but there is no live node to quiesce, so don't use it while the app
  is serving.

Visitors see when the next reset is due: the environment strip reads
**Environment: demo · resets in 23 minutes**, on the sign-in page too. A demo
is labelled `demo` unless `KILN_ENV_LABEL` says otherwise.

### 6. Outbound side effects

A public demo lets anyone trigger whatever a visitor can reach, so:

- **Mail is inert.** Demo mode replaces the mailer with `Swoosh.Adapters.Logger`
  whatever `MAIL_MODE` says, which logs the recipient and delivers nothing. That
  covers newsletters, form notifications, invitations and password resets.
- **Federation is off**, whatever `KILN_FEDERATION_ENABLED` says.
- **The operator's job:** webhooks, social posting, Web Push, outbound link
  checking and LLM features are all configured by an admin or through
  environment keys. Leave them out of the golden snapshot and the demo's
  environment. The shared account is an editor and can't configure them.

### 7. The shared account's credentials

Every visitor signs in as the same account, so a visitor who changed its
password, or turned on two-factor with an authenticator only they hold, would
lock everyone else out until the next reset. While demo mode is on, a
**non-admin** can't change how an account signs in:

| Refused | Action |
|---|---|
| Change the password | `User.change_password` |
| Turn on two-factor | `User.setup_totp`, `User.confirm_totp` |
| Turn it off, or mint new recovery codes | `User.disable_totp`, `User.regenerate_totp_recovery_codes` |
| Add or remove a passkey | `Passkey.register`, `Passkey.destroy` |

Each refusal is `KilnCMS.Accounts.Errors.DemoAccountLocked` (forbidden-class):
*"this is a shared demo account — its password and sign-in methods can't be
changed"*. It is a validation on each action
(`KilnCMS.Accounts.Validations.NotDemoSharedAccount`), not a check in the
settings page, so it holds for every caller, including the WebAuthn ceremony,
which writes the passkey with `authorize?: false`. The settings page hides
those forms and shows the same sentence in their place.

- **Admins are exempt.** The operator curates the demo as an admin, and can
  still repair the shared account from the console, their own account
  included.
- **A call with no actor passes.** That is a system call (`rpc`, `eval`), made
  by whoever operates the node.

Some things were already out of the shared account's reach, demo or not:

- **Its email.** No action lets an account change its own email.
- **API keys.** Minting, listing and revoking them is admin-only.
- **A password reset by email.** Mail is inert on a demo, so the reset link
  never reaches anyone.

## Refreshing the golden snapshot

Edit the content on the demo (sign in as the admin, right after a reset), then
capture again. The previous snapshot is replaced only once the new one has
verified:

```bash
/app/bin/kiln_cms rpc 'KilnCMS.Demo.capture_golden!()'
```

Upgrading Kiln does **not** require a new snapshot, because every reset migrates
it forward. Recapture when you want the demo content itself to change.

## Known limits

- **The shared account is shared.** What would lock other visitors out is
  refused ([its credentials are fixed](#7-the-shared-accounts-credentials)),
  but the rest of what it can change about itself is anyone's until the next
  reset: its display name (the byline on content it publishes) and its
  notification preferences (inert, since mail is).
- **A reset takes the editor away for a few seconds.** Requests during the
  restore may fail. Visitors land on sign-in afterwards.
- **One node.** The drain and the deferred-delete log are node-local. The other
  steps reach every connected node, but a demo is expected to be one container.
- **`public` schema only.** Kiln keeps everything there. An object in another
  schema makes the restore fail, and roll back.

## Cross-references

- [`environment-variables.md`](environment-variables.md#demo-mode):
  `KILN_DEMO_RESET`, `KILN_DEMO_RESET_CRON`, `KILN_DEMO_GOLDEN_PATH`.
- [`staging-environments.md`](staging-environments.md): the other destructive,
  guarded operation, whose conventions this follows.
- [`backups.md`](backups.md): `BACKUP_DIR`, the client tools, and their version
  pin.
