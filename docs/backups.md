# Backups & restore drills

KilnCMS keeps **two independent pieces of durable state**. A complete backup must
cover both, taken close enough together in time that they're consistent:

1. **The Postgres database** — all content, revisions, users, media *metadata*
   (`KilnCMS.Repo`, connected via `DATABASE_URL`). This is the source of truth
   for everything except the bytes of uploaded files.
2. **The media blobs** — the actual uploaded file bytes. *Where* these live
   depends on the storage adapter selected at runtime
   (`config/runtime.exs`, `KilnCMS.Storage`):
   - **S3-compatible object store** (`KilnCMS.Storage.S3`) when `S3_BUCKET` is
     set — AWS S3, Cloudflare R2, Backblaze B2, Wasabi, or MinIO. The bucket is
     the system of record for blobs.
   - **Local uploads volume** (`KilnCMS.Storage.Local`, the default) when
     `S3_BUCKET` is unset — blobs are written under `priv/uploads` in the
     release (`Application.app_dir(:kiln_cms, "priv/uploads")`) and served from
     `/uploads`. In Docker/Coolify this **must** be a mounted volume, otherwise
     uploads are lost on every redeploy.

> The database stores only the storage *key* for each blob, not the bytes. A DB
> restore without the matching media (and vice versa) yields broken images. Back
> up and restore the pair together.

This doc resolves issue **#57 — [Phase 9] Backup strategy (Postgres + media)**.

---

## What is *not* covered here (and why that's fine)

- **Meilisearch** (`MEILI_URL`, optional) and **pgvector embeddings** are
  *derived* indexes. Don't back them up; rebuild after a restore:
  `bin/kiln_cms eval 'KilnCMS.Release.something'`-style reindex, or
  `mix kiln.meili.reindex` (see `docs/meilisearch.md`). Treat them as a cache.
- **Dragonfly / cache** — ephemeral, never backed up.
- **Secrets** (`SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`, `DATABASE_URL`,
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, `MEILI_MASTER_KEY`) live in the
  Coolify environment, not in these backups. **Store them separately** in a
  password manager / secrets vault — a database dump is useless if you've lost
  the key that decrypts the session tokens and re-creates the env.

---

## Backup schedule (recommendation)

Tuned for a single-instance Coolify/Docker deployment. Adjust retention to your
RPO (how much data you can afford to lose) and storage budget.

| What | Frequency | Method | Retention |
|------|-----------|--------|-----------|
| Postgres full dump | **Nightly** (off-peak, e.g. 03:00 server time) | `pg_dump -Fc` | 7 daily + 4 weekly + 6 monthly |
| Media — S3 bucket | **Continuous** via bucket versioning **+ nightly** replication to a second bucket/region | bucket versioning + `aws s3 sync` / `mc mirror` | versioning lifecycle: 30 days; replica: indefinite |
| Media — local uploads volume | **Nightly**, right after the DB dump | `tar` snapshot | match the DB (7 daily + 4 weekly) |
| Off-site copy of dumps | **Nightly** | upload dump + media archive to a *different* provider/account | 30+ days |
| **Restore drill** | **Quarterly** (and after any backup-tooling change) | run the runbook below against staging | n/a |

Targets to write down for your deployment:

- **RPO** (max data loss): with nightly dumps + S3 versioning, ≤ 24 h for DB,
  near-zero for versioned media.
- **RTO** (max time to restore): aim for < 1 h; the drill validates this.

If 24 h of potential loss is too much, enable Postgres **WAL archiving / PITR**
(point-in-time recovery) via your managed-Postgres provider or
`pgBackRest`/`wal-g`. That's beyond the nightly-dump baseline and only worth the
operational weight if your RPO demands it.

---

## Backup commands (copy-paste)

All commands assume the standard env vars from `config/runtime.exs` are present.
Run the Postgres ones from any host that can reach the DB (a cron container, the
app container, or your laptop over a tunnel). `psql`/`pg_dump`/`pg_restore` must
match the **server major version (Postgres 17**, per `docker-compose.yml`).

`DATABASE_URL` is an `ecto://` URL. `pg_dump` wants a `postgres://` URL, so
normalise the scheme:

```sh
# DATABASE_URL=ecto://user:pass@host:5432/kiln_cms_prod
export PG_URL="$(printf '%s' "$DATABASE_URL" | sed 's#^ecto://#postgresql://#')"
```

### 1. Postgres — nightly dump

Use the **custom format** (`-Fc`): compressed, and restorable selectively with
`pg_restore`.

```sh
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="kiln_cms-${STAMP}.dump"

pg_dump -Fc --no-owner --no-privileges "$PG_URL" -f "$DUMP"

# Optional integrity check: list the archive's table of contents.
pg_restore --list "$DUMP" >/dev/null && echo "dump OK: $DUMP"
```

Running from inside the app container (no local `pg_dump` needed if the
`postgres` image is reachable):

```sh
# Dump the DB by exec-ing pg_dump inside the postgres container.
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" kiln_postgres \
  pg_dump -Fc --no-owner --no-privileges \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  > "kiln_cms-$(date -u +%Y%m%dT%H%M%SZ).dump"
```

### 2. Media — S3 / MinIO bucket

**Enable bucket versioning first** (one-time) so an overwrite or delete is
recoverable, then replicate to a second bucket for off-site safety.

With the AWS CLI (works against any S3-compatible store via `--endpoint-url`):

```sh
# Credentials come from the same AWS_* env vars the app uses.
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

# For R2/B2/Wasabi/MinIO, pass the custom endpoint (mirrors S3_ENDPOINT_* in runtime.exs):
#   --endpoint-url "${S3_ENDPOINT_SCHEME:-https://}${S3_ENDPOINT_HOST}:${S3_ENDPOINT_PORT:-443}"

aws s3 sync "s3://${S3_BUCKET}" "s3://${S3_BUCKET}-backup" \
  --endpoint-url "https://${S3_ENDPOINT_HOST}" \
  --delete
```

With MinIO's `mc` (e.g. when the live store is MinIO):

```sh
# Register the source and destination aliases once.
mc alias set kilnsrc  "http://${S3_ENDPOINT_HOST}:${S3_ENDPOINT_PORT:-9000}" \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc alias set kilndst  "https://offsite.example.com" "$OFFSITE_KEY" "$OFFSITE_SECRET"

# Mirror (incremental, removes objects deleted at the source with --remove).
mc mirror --overwrite --remove "kilnsrc/${S3_BUCKET}" "kilndst/${S3_BUCKET}-backup"
```

### 3. Media — local uploads volume (no object store)

When `S3_BUCKET` is unset, blobs live on the mounted uploads volume. Snapshot it
with `tar`. The path inside the container is the release's `priv/uploads`
(typically `/app/lib/kiln_cms-<vsn>/priv/uploads`); the simplest approach is to
back up the **named Docker volume** instead of guessing the in-container path.

```sh
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# Back up the named volume that is mounted into the app container.
# Replace `kiln_uploads` with your actual volume name (docker volume ls).
docker run --rm \
  -v kiln_uploads:/data:ro \
  -v "$(pwd)":/backup \
  debian:bookworm-slim \
  tar czf "/backup/kiln_uploads-${STAMP}.tar.gz" -C /data .
```

Or, if you have a host path bind-mounted for uploads:

```sh
tar czf "kiln_uploads-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" -C /srv/kiln/uploads .
```

### 4. Off-site copy

Whichever media path you use, push the **DB dump** (and the uploads tarball, if
local) to a *different* account/provider so a single compromised credential or
region can't take out both primary data and backups:

```sh
aws s3 cp "$DUMP" "s3://offsite-kiln-backups/db/" \
  --endpoint-url "https://offsite.example.com"
# and, for local media:
aws s3 cp kiln_uploads-*.tar.gz "s3://offsite-kiln-backups/media/" \
  --endpoint-url "https://offsite.example.com"
```

---

## Encryption at rest

- **Object store**: enable server-side encryption on the bucket (SSE-S3 /
  SSE-KMS on AWS; encryption-at-rest is on by default for R2/B2/Wasabi). For the
  off-site copy, prefer a bucket with its own KMS key you control.
- **DB dumps & uploads tarballs**: encrypt *before* they leave the host so plain
  bytes never sit on backup storage. Age or GPG, with the recipient key stored
  in your secrets vault (never alongside the backups):

  ```sh
  # age (recommended — simple, modern):
  age -r "$AGE_PUBLIC_KEY" -o "${DUMP}.age" "$DUMP" && rm "$DUMP"

  # or GPG:
  gpg --encrypt --recipient ops@example.com "$DUMP"
  ```

- **Postgres volume**: the `postgres_data` volume should sit on an
  encrypted-at-rest disk (most cloud block storage is by default).
- **Key custody**: store the age/GPG private key and the Coolify env secrets in
  a password manager or vault. A restore needs *both* the backup and these keys.

---

## Restore drill runbook

Run this **quarterly** and after any change to backup tooling. **Always restore
into a throwaway staging database and a staging bucket/volume — never the live
system** during a drill.

### Prerequisites

- The most recent encrypted DB dump and (if local media) uploads tarball.
- The age/GPG key to decrypt them.
- A staging Postgres reachable at `STAGING_PG_URL` and an empty staging
  bucket/volume.
- `pg_restore` matching the dump's server version (Postgres 17).

### Steps

1. **Decrypt the dump.**

   ```sh
   age -d -i ~/.kiln-backup-key.txt -o restore.dump kiln_cms-<stamp>.dump.age
   pg_restore --list restore.dump >/dev/null && echo "archive readable"
   ```

2. **Create a clean staging database.**

   ```sh
   export STAGING_PG_URL="postgresql://user:pass@staging-host:5432/kiln_restore_test"
   psql "${STAGING_PG_URL%/*}/postgres" -c 'DROP DATABASE IF EXISTS kiln_restore_test;'
   psql "${STAGING_PG_URL%/*}/postgres" -c 'CREATE DATABASE kiln_restore_test;'
   ```

3. **Restore the dump.** `pgvector` needs its extension; `--no-owner` avoids
   role mismatches between prod and staging.

   ```sh
   psql "$STAGING_PG_URL" -c 'CREATE EXTENSION IF NOT EXISTS vector;'
   pg_restore --no-owner --no-privileges --jobs=4 \
     -d "$STAGING_PG_URL" restore.dump
   ```

4. **Verify row counts** against what you expect from production. Spot-check the
   core content tables and compare to the live DB (read-only) numbers.

   ```sh
   psql "$STAGING_PG_URL" -At -c "
     SELECT 'pages',         count(*) FROM pages
     UNION ALL SELECT 'posts',        count(*) FROM posts
     UNION ALL SELECT 'media',        count(*) FROM media
     UNION ALL SELECT 'users',        count(*) FROM users;"
   ```

   > Table names follow your generated content types (`mix kiln.gen.content`);
   > adjust the list to your schema. Confirm the latest revision/`updated_at`
   > timestamp is within one backup window of "now".

5. **Run migrations** so the restored schema matches the current release (the
   dump is from whatever version was live when it was taken):

   ```sh
   DATABASE_URL="$STAGING_PG_URL" bin/kiln_cms eval KilnCMS.Release.migrate
   # or, equivalently, the bundled wrapper:
   DATABASE_URL="$STAGING_PG_URL" bin/migrate
   ```

6. **Restore / re-point media.**
   - **S3**: copy the backup bucket into a staging bucket, then run the staging
     app with `S3_BUCKET=<staging-bucket>` and a matching
     `S3_PUBLIC_BASE_URL`. No app change needed — the keys in the DB resolve
     against whatever bucket is configured.

     ```sh
     aws s3 sync "s3://${S3_BUCKET}-backup" "s3://${S3_BUCKET}-staging" \
       --endpoint-url "https://${S3_ENDPOINT_HOST}"
     ```

   - **Local volume**: unpack the tarball into the staging uploads volume.

     ```sh
     docker run --rm -v kiln_uploads_staging:/data -v "$(pwd)":/backup \
       debian:bookworm-slim \
       tar xzf /backup/kiln_uploads-<stamp>.tar.gz -C /data
     ```

7. **Boot staging and smoke-test.** Start the release
   (`PHX_SERVER=true bin/kiln_cms start`, or `bin/server`) against the staging
   DB and media, then:
   - Load the homepage and a content list — no 500s.
   - Open a page/post that has an image — the image **renders** (proves DB key →
     media bytes wiring).
   - Sign in (validates `TOKEN_SIGNING_SECRET`/`SECRET_KEY_BASE` are the staging
     values, not the prod ones).
   - Rebuild derived indexes if you use them (Meilisearch / embeddings) and
     confirm search returns results.

8. **Record the result.** Note the date, dump timestamp, measured **RTO**, row
   counts, and any deviation. File anything broken as an issue.

9. **Tear down** the staging DB, bucket, and volume.

### Drill checklist

- [ ] Dump decrypts and `pg_restore --list` reads it.
- [ ] Clean staging DB created.
- [ ] `pg_restore` completes with no errors.
- [ ] Row counts match expectations for core tables.
- [ ] `KilnCMS.Release.migrate` (`bin/migrate`) runs clean.
- [ ] Media restored to staging bucket/volume.
- [ ] App boots; homepage + content list render.
- [ ] An image-bearing page renders its image.
- [ ] Sign-in works.
- [ ] Derived indexes (Meili/embeddings) rebuilt and searching.
- [ ] RTO measured and within target.
- [ ] Result logged; staging torn down.

---

## Scheduling the backups (options — pick one)

Don't over-engineer this. Any of these is fine; choose what fits your ops.

1. **Coolify scheduled task (recommended for Coolify deploys).** Coolify can run
   a command in a service container on a cron expression. Point it at a small
   `backup.sh` that runs the `pg_dump` + media sync + encrypt + off-site upload
   from steps 1–4, e.g. schedule `0 3 * * *` (nightly 03:00). Secrets come from
   the service's existing env, so no extra credential plumbing.

2. **Dedicated cron sidecar container.** Add a tiny image (postgres-client +
   awscli/`mc` + `age`) to the compose/Coolify stack that runs `crond` with the
   same `backup.sh`. Keep it on the same network as `kiln_postgres` so it can
   reach the DB. Good when you want backups decoupled from the app's lifecycle.

3. **Host cron.** If you control the host, a plain `crontab` entry invoking
   `docker exec`/`docker run` (as in the commands above) is the least moving
   parts. Fine for single-server setups.

4. **Oban (in-app).** KilnCMS already runs Oban/AshOban. You *can* schedule a
   cron job that shells out to `pg_dump`, but it's generally **not recommended**:
   it couples backups to app health (a crashed app stops backing itself up) and
   puts DB credentials and large dump I/O inside the web process. Prefer an
   out-of-band scheduler (options 1–3). Oban *is* a good fit for triggering the
   lightweight bits — e.g. kicking off a derived-index rebuild after a restore,
   or emitting a "backup succeeded/failed" notification.

Whatever you choose: **alert on failure** (non-zero exit, or no fresh object in
the backup bucket for > 26 h) and **verify by drill** — an untested backup is a
hypothesis, not a backup.
