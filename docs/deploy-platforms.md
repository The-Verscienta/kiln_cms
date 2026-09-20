# One-click deploy platforms

Kiln publishes a container image on every release
(`ghcr.io/the-verscienta/kiln_cms:<version>`), so a hosting platform can run it
without building anything. This page covers four platforms that can do that,
and the templates in the repository for each:

| Platform | File | How to start | Postgres + pgvector | Media storage |
|----------|------|--------------|---------------------|---------------|
| [Render](#render) | [`render.yaml`](https://github.com/The-Verscienta/kiln_cms/blob/main/render.yaml) | Deploy button | Render Postgres 17, works as-is | 1 GB disk |
| [Railway](#railway) | none (Railway keeps templates in its dashboard) | Recipe below | pgvector template (Postgres 18) | Volume |
| [Fly](#fly) | [`fly.toml`](https://github.com/The-Verscienta/kiln_cms/blob/main/fly.toml) | `fly launch` | Managed Postgres 17, enable `vector` once | Volume |
| [DigitalOcean](#digitalocean) | [`.do/app.yaml`](https://github.com/The-Verscienta/kiln_cms/blob/main/.do/app.yaml) | `doctl apps create` | Managed cluster 17, enable `vector` once | Spaces (S3) |

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/The-Verscienta/kiln_cms)

For a server you run yourself (a VPS, Coolify, Kubernetes), use
[deploy.md](deploy.md) instead. Everything there still applies here; this page
covers only what is different on a platform.

> **Status.** The templates follow each platform's documentation as of
> September 2026. Before this page calls a platform verified, someone has to
> deploy it end to end: fresh deploy, `/setup`, publish a page, view it,
> restart, and check the page and its images are still there. Until then,
> treat the steps below as a well-researched first attempt, and report what
> differs on [#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529).

## What every template does

- **Runs a pinned image tag**, never `latest`. Upgrading means changing that
  tag on purpose (see [Upgrading](#upgrading)).
- **Sets `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET`.** Where the platform can
  generate a long enough value it does; otherwise you paste one from
  `openssl rand -base64 64 | tr -d '\n'`. Phoenix needs at least 64 bytes for
  `SECRET_KEY_BASE`.
- **Leaves `PHX_HOST` to the platform.** When `PHX_HOST` is unset, Kiln uses
  the platform's own hostname: `RENDER_EXTERNAL_HOSTNAME`,
  `RAILWAY_PUBLIC_DOMAIN`, or `<FLY_APP_NAME>.fly.dev`. The DigitalOcean spec
  binds `PHX_HOST` to `${APP_DOMAIN}`. When you add a custom domain, set
  `PHX_HOST` to it. It always wins.
- **Keeps media outside the image.** A platform's container filesystem is
  wiped on every restart, so the templates either mount a volume at
  `/app/media` with `KILN_MEDIA_ROOT=/app/media`, or use object storage. See
  [Media storage](#media-storage).
- **Health-checks `/up`**, which answers 200 once the database is reachable.
  `/up` and `/live` answer over plain HTTP, because the platform probes the
  container directly; every other path still redirects to HTTPS.
- **Creates the first admin at `/setup`.** Open
  `https://<your-host>/setup` once the deploy is live. The wizard only exists
  while there is no admin.

## Render

Click the button above, or create a Blueprint from the repository in Render's
dashboard. It creates:

- a web service running the image, on the `0.5c-512mb` plan (512 MB);
- a Postgres 17 database on the `0.1c-256mb` plan, reachable only from
  Render's private network;
- a 1 GB disk at `/app/media` for uploaded media.

You are asked for one value, **`SECRET_KEY_BASE`**. Render's generated values
are 44 characters, too short for Phoenix, so paste one from
`openssl rand -base64 64 | tr -d '\n'`. `TOKEN_SIGNING_SECRET` is generated.

Things to know:

- **No free tier for this Blueprint.** Disks need a paid web plan, and free
  Render Postgres is deleted after 30 days.
- **A disk limits the service to one instance** and turns off zero-downtime
  deploys: each deploy stops the old instance before starting the new one.
  For more than one instance, move media to object storage (`S3_BUCKET`) and
  remove the disk.
- **Image-backed services never redeploy on their own.** Upgrades are a tag
  change; see [Upgrading](#upgrading).

## Railway

Railway keeps templates in its dashboard rather than in a repository file, so
this is the recipe for building one. Once someone publishes it, a
Deploy on Railway button for it can go in the README.

1. **Database.** Add Railway's pgvector template. It runs Postgres 18 and
   creates the `vector` extension for you. Kiln's CI tests Postgres 17, so
   Postgres 18 is not yet verified. The plain Railway Postgres template has
   no pgvector and will fail the first migration.
2. **App service.** Add a service from the Docker image
   `ghcr.io/the-verscienta/kiln_cms:0.10.0` with these variables:

   | Variable | Value |
   |----------|-------|
   | `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` (use your database service's name) |
   | `SECRET_KEY_BASE` | `${{secret(64, "abcdef0123456789")}}` |
   | `TOKEN_SIGNING_SECRET` | `${{secret(64, "abcdef0123456789")}}` |
   | `KILN_MEDIA_ROOT` | `/app/media` |

   Railway sets `PORT`, and Kiln listens on it.
3. **Volume.** Attach a volume to the app service, mounted at `/app/media`.
4. **Networking.** Generate a public domain. Kiln reads it from
   `RAILWAY_PUBLIC_DOMAIN`.
5. **Health check.** Set the path to `/up`. Railway only checks during a
   deploy, and sends `Host: healthcheck.railway.app`. Kiln answers that probe
   normally, including with `TENANT_STRICT_HOST` on, because health probes
   are exempt from host checks.

A volume limits the service to one replica and causes a short outage on each
redeploy. Railway's free plan caps a volume at 0.5 GB.

## Fly

Fly has no deploy button. With [`flyctl`](https://fly.io/docs/flyctl/install/)
installed:

```bash
fly launch --from https://github.com/The-Verscienta/kiln_cms --copy-config --no-deploy
```

`fly launch` asks for an app name and region and writes them into your copy of
`fly.toml`. Then create the database:

```bash
fly mpg create --pg-major-version 17
```

Open the cluster's **Extensions** page in the Fly dashboard and enable
`vector`, then attach it, which sets `DATABASE_URL`:

```bash
fly mpg attach <cluster-id>
```

Set the secrets:

```bash
fly secrets set SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" TOKEN_SIGNING_SECRET="$(openssl rand -base64 64 | tr -d '\n')"
```

Deploy. The first deploy creates the `kiln_media` volume from `fly.toml`:

```bash
fly deploy
```

Things to know:

- **Managed Postgres is the main cost.** Its smallest plan is about $38 a
  month, with no free tier. The app machine (1 GB) is a few dollars a month.
- **`DATABASE_URL` goes through PgBouncer.** It runs in session mode by
  default, which Kiln needs: migrations take an advisory lock, and the job
  queue uses `LISTEN`. Don't switch the pooler to transaction mode.
- **The machine stays running** (`auto_stop_machines = "off"`). Scheduled
  publishing, webhooks and email run in the background job queue, and a
  stopped machine does not run it.
- **A volume belongs to one machine.** Keep the app at one machine, or move
  media to object storage (`fly storage create`, then the `S3_*` variables in
  [environment-variables.md](environment-variables.md)) before scaling out.

## DigitalOcean

App Platform's Deploy button builds from a git branch and offers only a dev
database. Neither fits: building from `main` ships unreleased code, and a dev
database's user can't create the `vector` extension, since pgvector is not a
trusted extension. So the spec is deployed with
[`doctl`](https://docs.digitalocean.com/reference/doctl/) instead:

1. **Database.** Create a managed Postgres 17 cluster named `kiln-db` with a
   database named `kiln`. Connect as `doadmin` and run
   `CREATE EXTENSION vector;` in that database once.
2. **Media.** App Platform has no persistent disk, so media goes to Spaces.
   Create a bucket and an access key.
3. **Secrets.** Copy [`.do/app.yaml`](https://github.com/The-Verscienta/kiln_cms/blob/main/.do/app.yaml)
   and replace every `CHANGE_ME`: the two secrets
   (`openssl rand -base64 64 | tr -d '\n'`), the bucket name, its public URL,
   and the key pair. Change `S3_ENDPOINT_HOST` and `region` if you are not in
   New York.
4. **Deploy:**

   ```bash
   doctl apps create --spec .do/app.yaml
   ```

The spec sets `S3_ACL=public_read`, because Spaces objects are private unless
uploaded public. The smallest App Platform size (512 MB) may be enough for a
small site; the spec uses 1 GB.

## Media storage

Without configuration, the Local storage adapter writes under the release's
own `priv/uploads`, which in the image is
`/app/lib/kiln_cms-<version>/priv/uploads`. That path changes with every
version, and a platform wipes it on every restart. There are two ways to keep
media:

- **A volume at `KILN_MEDIA_ROOT`.** Setting `KILN_MEDIA_ROOT=/app/media`
  moves Local storage there: public files to `/app/media/public` (served at
  `/uploads`), private ones to `/app/media/private` (never served). Mount the
  platform's volume at `/app/media`. The in-app backup archives that directory
  too, so you don't need to set `MEDIA_DIR` separately.
- **Object storage.** Set `S3_BUCKET` and the rest of the `S3_*` variables
  (see [environment-variables.md](environment-variables.md)).
  `KILN_MEDIA_ROOT` is ignored then. This is the choice for more than one
  instance, and the only one on DigitalOcean.

**Volume ownership.** The image runs as `nobody` (uid 65534). The image's own
`/app/media` belongs to `nobody`, but a platform volume mounted over it may
belong to `root`, and then every upload fails. Kiln checks this at boot, and
if it can't write there it logs *"Media storage directory … is not
writable"*. If you see that, either make the volume writable by uid 65534 or
switch to object storage. Whether each platform's volumes need this is one of
the things the verification drill will confirm.

## Client addresses and rate limiting

Kiln's per-IP rate limits (sign-in brute-force protection included) need the
real client address. Behind a proxy, Kiln takes it from `X-Forwarded-For`, but
only when the proxy's address is listed in `TRUSTED_PROXIES`.

None of these four platforms documents the address range its proxy connects
from, so the templates leave `TRUSTED_PROXIES` unset. Guessing a range risks
trusting addresses that aren't the proxy. As a result, every request appears
to come from the platform's proxy, and each rate limit becomes one shared
bucket for all visitors. Kiln logs a warning about this on the first proxied
request. DigitalOcean also puts its own ingress address in `X-Forwarded-For`,
so even a correct `TRUSTED_PROXIES` wouldn't help there.

Fly (`Fly-Client-IP`) and DigitalOcean (`do-connecting-ip`) send the client's
address in a header of their own. Reading it is tracked in
[#1548](https://github.com/The-Verscienta/kiln_cms/issues/1548). Until then,
these deployments get per-deployment, not per-visitor, rate limiting.

## Upgrading

Each template pins an image tag. To upgrade:

1. Read the new release's `### Upgrading` section in
   [CHANGELOG.md](https://github.com/The-Verscienta/kiln_cms/blob/main/CHANGELOG.md).
2. Change the tag: `image.url` in `render.yaml` (then sync the Blueprint),
   the image in Railway's service settings, `[build] image` in `fly.toml`
   (then `fly deploy`), or `tag` in `.do/app.yaml` (then
   `doctl apps update <app-id> --spec .do/app.yaml`).

Migrations run on boot, as on any deployment.

## Backups

The platform's database backups cover the database. Two things they don't
cover:

- **`SECRET_KEY_BASE`.** Encrypted columns (DKIM keys and other secrets) can't
  be read without the same value, so keep it wherever you keep the database
  backups. See [backups.md](backups.md#what-must-be-backed-up).
- **Media on a volume.** The in-app backup (Backups in the console) archives
  `KILN_MEDIA_ROOT`, but it writes the archive to `BACKUP_DIR` on the
  container's own disk, which the platform wipes, unless
  `BACKUP_RCLONE_REMOTE` copies it off-site. Set that, or snapshot the volume
  with the platform's tools.
