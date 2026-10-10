# Minimum system requirements

What a machine needs to run Kiln, to build the release image, and to develop
on it. Written against v1.1.0. The versions here restate
[`.tool-versions`](https://github.com/The-Verscienta/kiln_cms/blob/main/.tool-versions)
and the [`Dockerfile`](https://github.com/The-Verscienta/kiln_cms/blob/main/Dockerfile);
when they disagree, those files win and this page needs editing
(`mix kiln.toolchain.check` fails when the two of them drift from each other).

## Running the release image

The prebuilt image (`ghcr.io/the-verscienta/kiln_cms`, one per version tag)
carries the release and every native library it needs. A deployment adds
Postgres, a reverse proxy, and somewhere for media to live.

| | Minimum | Recommended | Notes |
|---|---|---|---|
| CPU | 1 shared vCPU | 2 vCPU | The BEAM uses every core it is given; one is enough for a small site. The Fly and Render specs use one |
| RAM | 512 MB | 1 GB | 512 MB runs a small site (the Render blueprint's `0.5c-512mb` plan); the Fly, Render and DigitalOcean specs use 1 GB. Image processing (libvips) and in-app backups are the spikes |
| Disk | Image plus media | A volume or object storage for media | Uploads live on the container's local disk unless `KILN_MEDIA_ROOT` points at a mounted volume or `S3_BUCKET` is set; a redeploy discards the local disk. The Render blueprint mounts 1 GB at `/app/media` |
| Postgres | 17 with the `vector` extension | 17, `pgvector/pgvector:pg17` | The only required service. Older majors are not tested. Extensions created on migrate: `citext`, `pg_trgm`, `unaccent`, `vector`; a server without `vector` available fails at `mix ash.setup` with "extension vector is not available" |
| Postgres pool | `POOL_SIZE=10` | Sized per [performance.md](performance.md) | The pool is shared by web requests and Oban workers, so a busy instance wants more |
| Reverse proxy | TLS termination, WebSocket pass-through | | LiveView and the API sockets need WebSockets forwarded; the proxy must set `x-forwarded-for` and `x-forwarded-proto`. See [deploy.md](deploy.md) |
| Outbound network | 443 | | Webhooks, oEmbed, the update feed, image imports and the CDN purge all go out over HTTPS through `KilnCMS.SafeFetch`. Port 25 outbound only for `MAIL_MODE=direct` (the built-in MTA); most clouds block it, see [direct-email-delivery.md](direct-email-delivery.md) |
| Database TLS | On by default | | `ssl: true`; set `DATABASE_CACERTFILE` to verify the server certificate |

**Native libraries in the runner.** These are installed in the image and are
what a from-source deployment has to provide itself:

| Library | Used for | If missing |
|---|---|---|
| libvips 8.x (`libvips42t64` on Debian trixie) | Every image derivative and transform | Uploads fail to derive; nothing else runs |
| `qpdf` | PDF metadata stripping on upload | A PDF that cannot be stripped is **refused** (a privacy control that silently does not apply is worse than none), see [media-pipeline.md](media-pipeline.md) |
| `postgresql-client-17` (`pg_dump`) | In-app backups | Backups unavailable. **Must match the server's major version**; see [backups.md](backups.md) |
| `ffmpeg` | A/V duration, poster frames, A/V metadata stripping | Optional and not in the image. Without it audio and video upload without enrichment, and `REQUIRE_AV_METADATA_STRIP` turns a missing strip into a refusal |
| `openssl`, `ca-certificates`, `locales` (`en_US.UTF-8`) | TLS, outbound HTTPS, the BEAM's string handling | Boot failures |

**Optional services.** None are required, and the dev and prod compose files
keep each behind a profile:

| Service | Profile | What it adds |
|---|---|---|
| S3-compatible object storage (MinIO in compose) | `s3` | Media that survives redeploys and serves from a CDN. Any S3 API works |
| Meilisearch v1.11 | `search` | An alternative search backend; Postgres full-text is the default and is what search is tuned on |
| Dragonfly / Redis | `cache` | Nothing today: Kiln's caches are in-process by decision (D2) and cross-node busts travel over native PubSub. Kept for parity only |

**Multi-node** needs no broker: PubSub is native, Oban is Postgres-backed,
and node discovery is `DNS_CLUSTER_QUERY`. It does need long node names
(`RELEASE_NODE=kiln_cms@<ip>`) and a shared media store; see
[deploy.md](deploy.md).

**The ML stack is not in the default image.** Semantic search and the
reranker need a `KILN_ML=1` build with Bumblebee, Nx and EXLA; that build is
larger; the plan does not yet size it, so budget RAM for the model separately.
A default build runs keyword search and reports `KilnCMS.Search.ML.available?/0`
as false.

## Presets

Three environment files under
[`deploy/presets/`](https://github.com/The-Verscienta/kiln_cms/tree/main/deploy/presets)
turn the runtime features on or off as a set. Each layers on `.env.prod`,
which keeps the required variables and the secrets; a preset holds neither.

| Preset | Image | What is on | Needs from the host |
|---|---|---|---|
| `minimal.env` | `kiln_cms:1.x` | Console, delivery, backups, media on a volume. Nothing calls out and no mail leaves | 512 MB, Postgres, a volume at `/app/media` |
| `publishing.env` | `kiln_cms:1.x` | Mail over SMTP, oEmbed cards, provenance signing, CDN purge hooks, error tracking | 1 GB, Postgres, an SMTP relay, outbound 443; optionally S3 and a CDN |
| `everything.env` | `kiln_cms:1.x-ml` | `publishing` plus Meilisearch, federation, experiments, the metrics listener, the LLM assistants and reranking | 2 GB, Postgres, SMTP, S3, Meilisearch, an LLM provider key |

The only thing an image decides is whether the ML stack is compiled in
(`KILN_ML`); every other optional subsystem is in every image and the preset
switches it. The `-ml` tag is [#1932](https://github.com/The-Verscienta/kiln_cms/issues/1932);
until it ships, `everything.env` runs on the lean image with reranking and
semantic search off.

```bash
docker compose -f docker-compose.prod.yml \
  --env-file .env.prod --env-file deploy/presets/publishing.env up -d
```

## Building the release image

A `docker build` on a laptop, a CI job, or a PaaS that builds from the
Dockerfile (Coolify, Render) all do the same thing.

| | Minimum | Recommended | Notes |
|---|---|---|---|
| RAM | 2 GB (marginal) | 4 GB | Peak is `mix deps.compile`, not the app: the Ash ecosystem compiles in one BEAM. The Dockerfile caps the build BEAM to two schedulers so a small host is not OOM-killed |
| Disk | 3 GB free | 6 GB | The builder stage pulls the dep tree and `node_modules`; the final image is a slim Debian trixie with the release only |
| Toolchain | Pulled by the Dockerfile | | `hexpm/elixir:1.19.5-erlang-27.3.4.15` on Debian bookworm as the builder; nothing to install on the host but Docker |
| Network | Hex, npm, GitHub, Debian and PostgreSQL apt mirrors | | A build behind a proxy needs `HEX_MIRROR` and npm config as usual |

## Developing on it

| | Requirement | Notes |
|---|---|---|
| Elixir / OTP | **1.19.5 on OTP 27.3.4.15**, exactly as `.tool-versions` says; 1.19.3+ and OTP 27+ is the floor | `config/dev.exs` uses a regex modifier Elixir 1.18 cannot parse. A newer OTP on a developer machine works; its dialyzer is stricter than CI's (OTP 27), so run `mix dialyzer` locally before a PR |
| Node.js | 22 (what CI uses); any current LTS | Only for building assets: the editor bundles TipTap from `assets/node_modules`. Not needed at runtime |
| Postgres | 17 with `vector`, via `docker compose up -d postgres` | The compose file runs `pgvector/pgvector:pg17`. Two test suites running at once against one server can exhaust Postgres's default 100 connections; raise `max_connections` or run them one at a time |
| Docker | Any recent Docker or compatible | For Postgres and the optional profiles; the app itself runs on the host |
| libvips | `brew install vips` / `apt install libvips-dev` | `vix` builds against it; image tests need it |
| Build tools | `build-essential` / Xcode command-line tools | `bcrypt_elixir`, `picosat_elixir`, `vix` and `y_ex` compile native code |
| Checkout path | **No spaces** | `picosat_elixir`'s Makefile splits absolute paths at a space; the error blames a missing gcc. `mix setup` refuses such a path up front |
| RAM | 4 GB | A full `mix compile` with tests and dialyzer; `KILN_ML=1` wants more |
| Disk | 1 GB for a lean dep tree; 2 GB with `KILN_ML=1` | `deps/exla` alone is most of the difference |

`mix setup` runs `deps.get`, `ash.setup` and `assets.setup`, and
`mix kiln.toolchain.check` confirms the installed Elixir and OTP match the
pins. A running instance reports its own build, commit and toolchain on
`/editor/system`.

## Browsers

The console is built on LiveView and Tailwind 4 and targets current
evergreen browsers; there is no stated floor older than that. The public site
a Kiln renders is plain HTML and works everywhere the theme does.
