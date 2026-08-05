# Multi-stage build for a KilnCMS OTP release.
# Includes libvips in the runtime image for on-the-fly image processing.

# These restate `.tool-versions`, which is the source of truth — Docker cannot
# read a file to default an ARG, so this is the one place the versions have to
# be duplicated. `mix kiln.toolchain.check` (in `precommit` and CI) fails when
# they drift from it or from mix.exs's `elixir:` requirement. Change versions in
# `.tool-versions` first, then mirror them here.
#
# The previous 1.18.4 could not satisfy mix.exs's `~> 1.19` (raised in #573,
# which missed this file). Note where that surfaces — `mix deps.get` and
# `mix deps.compile` do *not* check the requirement, only compiling this project
# does. So the build ran the whole expensive dep compile and then died at
# `mix compile` below, which is both the slowest way to find out and late enough
# to look like a compile error rather than a version mismatch.
#
# OTP tracks CI's major (27) rather than the newest available: the release image
# should run the toolchain the test suite and dialyzer actually ran against.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=27.3.4.15
ARG DEBIAN_VERSION=bookworm-20260713-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ---- Build stage ----
FROM ${BUILDER_IMAGE} AS builder

# build-essential/git for native deps, libvips for image processing, and
# nodejs/npm to install the JS deps (TipTap) that esbuild bundles into app.js.
RUN apt-get update -y \
  && apt-get install -y build-essential git libvips-dev nodejs npm \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
# Cap the BEAM to 2 schedulers *for the build only* (inline, so it never reaches
# the runtime image). Compiling the full dep set cold — the Ash ecosystem plus
# the Nx/Axon/Bumblebee ML stack — is the peak-RAM moment of the build, and the
# small build host OOM-kills `mix deps.compile` (exit 255, no error). Fewer
# schedulers = fewer modules compiled at once = lower peak RAM.
#
# The scheduler cap alone wasn't enough: `mix deps.compile` uses one long-lived
# BEAM and keeps every compiled dep loaded so later deps can use their macros.
# The ML stack (nx/axon/tokenizers/bumblebee) compiles early but stays resident,
# so by the time the Ash/Phoenix web stack compiles at the end, the whole world
# is co-resident and RAM peaks — which is where the OOM hit (after ash_phoenix).
#
# Split the compile: build the ML/Nx stack in its own RUN (a separate BEAM that
# frees that memory when it exits), then compile the rest. Nothing in the
# Ash/Phoenix stack has a compile-time dependency on the ML stack, so the second
# (heavy) pass never reloads it — the peak-RAM final compile is much lighter.
# Any ML dep not named here still compiles in the second pass; it just costs a
# bit of the benefit, so this list is safe to keep loosely in sync.
#
# `mix deps.compile <list>` only compiles exactly the apps named — it does
# NOT transitively pull in an unlisted compile-time dependency the way a bare
# `mix deps.compile` would. Two ML deps have such a dependency and must be
# listed explicitly even though they're not in the curated set above:
#   - rustler_precompiled: tokenizers/native.ex does `use RustlerPrecompiled`.
#   - unzip: bumblebee/conversion/pytorch_loader.ex pattern-matches
#     `%Unzip.Entry{}`, which needs the struct's definition at compile time.
# (Verified against bumblebee's source: `Unzip.Entry` is its only external
# struct usage; other unlisted deps like jason/progress_bar/castore are only
# called as plain functions, which just warn under this scheme — see the
# Jason warnings on `safetensors` below — not hard-fail.)
RUN ERL_FLAGS="+S 2:2" mix deps.compile \
  complex nx nx_image nx_signal polaris axon safetensors unpickler \
  rustler_precompiled unzip tokenizers bumblebee
RUN ERL_FLAGS="+S 2:2" mix deps.compile

COPY priv priv
COPY lib lib
# `projects/` is a compiled source path (see mix.exs elixirc_paths) — project
# subprojects layered on the core. Without this COPY the release builds green
# and boots, then 500s on the first request that touches a project domain.
COPY projects projects
COPY assets assets

# Activate a project overlay at build time (docker build --build-arg
# PROJECT=<name>): the subproject's project.exs becomes config/project.exs
# (compile-time domain/plugin registration — must precede `mix compile`), and
# its priv/ (migrations, resource snapshots) merges into the core priv/ so
# boot-time migrate and ash.codegen see the overlay schema. Empty (the
# default) leaves the core project-agnostic, exactly as before.
ARG PROJECT=""
RUN if [ -n "$PROJECT" ]; then \
  test -f "projects/$PROJECT/project.exs" \
  || { echo "unknown project overlay: $PROJECT"; exit 1; }; \
  cp "projects/$PROJECT/project.exs" config/project.exs; \
  if [ -d "projects/$PROJECT/priv" ]; then cp -R "projects/$PROJECT/priv/." priv/; fi; \
  fi

# Install JS dependencies (TipTap, etc.) before bundling.
RUN npm --prefix assets ci

# Compile first so Phoenix generates the colocated JS/CSS manifest
# (_build/$MIX_ENV/phoenix-colocated/...) that assets/css/app.css and
# assets/js/app.js import; otherwise tailwind/esbuild can't resolve it.
# Same 2-scheduler cap for the app compile (Ash resources are also memory-heavy).
RUN ERL_FLAGS="+S 2:2" mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel

# Package application source so Sentry can show code context around stack frames
# in error reports (config :sentry, enable_source_code_context: true). Must run
# after `lib` is present and before the release is assembled.
RUN mix sentry.package_source_code

RUN mix release

# Assert the API routers actually ship. `mix release` embeds only modules
# recorded in the compile manifest; a beam present on disk without a manifest
# entry is pruned as an orphan, and the embedded-mode release then boots fine
# until the first /api/json or /gql request raises UndefinedFunctionError.
# Build-time probes can't catch this (they run with lazy code loading), so
# check what actually ships: the assembled release's .app :modules list.
RUN elixir -e ' \
  app = \
    Path.wildcard("_build/prod/rel/kiln_cms/lib/kiln_cms-*/ebin/kiln_cms.app") \
    |> List.first() || raise("release .app not found"); \
  {:ok, [{:application, :kiln_cms, props}]} = :file.consult(String.to_charlist(app)); \
  mods = Keyword.get(props, :modules, []); \
  for m <- [KilnCMSWeb.AshJsonApiRouter, KilnCMSWeb.GraphqlSchema], m not in mods do \
    raise("#{inspect(m)} missing from release .app :modules — the release would 500 on its API surface") \
  end; \
  IO.puts("release wiring verified: API routers present in .app :modules")'

# ---- Runtime stage ----
FROM ${RUNNER_IMAGE}

# curl is here for the HEALTHCHECK below — it probes the HTTP endpoint, which
# is the only thing that proves this container is actually serving (#647).
# postgresql-client ships `pg_dump`/`pg_restore` for in-app backups (#484).
# Without it the "Backup now" button has nothing to call and
# `KilnCMS.Backups.availability/0` reports `:no_pg_dump` — the console says so
# rather than failing at the point of use.
#
# The MAJOR VERSION MUST MATCH THE SERVER. `pg_dump` refuses to run against a
# newer server ("aborting because of server version mismatch"), so this pin
# tracks the Postgres this deployment targets — bump both together. Debian's
# own `postgresql-client` metapackage would float to whatever the base image's
# suite carries, which is precisely how this breaks silently on a base-image
# bump; `postgresql-client-17` is explicit. See docs/backups.md.
# Base packages FIRST, including curl/ca-certificates/gnupg — the pgdg step
# below needs all three, and a `-slim` Debian ships none of them. (An earlier
# revision fetched the signing key with curl three lines before installing
# curl; CI doesn't build this image, so nothing would have caught it.)
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     libstdc++6 openssl libncurses5 locales ca-certificates libvips42 curl gnupg \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# `set -o pipefail` so a truncated download can't produce an empty keyring
# that rides through to apt-get update. HTTPS for the repo as well as the key:
# apt verifies the signature either way, but cleartext leaks which packages
# this host installs and permits a downgrade to an older signed Release.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
     | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
     > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update -y \
  && apt-get install -y --no-install-recommends postgresql-client-17 \
  && apt-get purge -y gnupg && apt-get autoremove -y \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*
SHELL ["/bin/sh", "-c"]

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/kiln_cms ./

# Build stamp — how a running instance knows which Kiln it is (Kiln.Version).
# Both are optional: an image built without them still boots, it just can't
# report a SHA or build date on the admin update page. The release version
# itself comes from mix.exs and is already compiled in.
#
#   docker build --build-arg GIT_SHA="$(git rev-parse HEAD)" \
#                --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" .
ARG GIT_SHA=""
ARG BUILD_DATE=""
ENV KILN_GIT_SHA=${GIT_SHA}
ENV KILN_BUILD_DATE=${BUILD_DATE}

LABEL org.opencontainers.image.title="KilnCMS" \
      org.opencontainers.image.source="https://github.com/The-Verscienta/kiln_cms" \
      org.opencontainers.image.revision=${GIT_SHA} \
      org.opencontainers.image.created=${BUILD_DATE}

USER nobody

# Healthcheck asserts the container is SERVING HTTP, not merely that the BEAM is
# alive. `rpc 1 + 1` only proved the node was up, so a container booted with
# PHX_SERVER unset — running migrations, answering rpc, serving zero HTTP —
# reported healthy forever, to Docker, to Coolify, and to anything reading the
# container status (#647; the runtime.exs PHX_SERVER note describes the same
# hole). `/up` (KilnCMSWeb.HealthController :show) returns 200 only when the
# endpoint is listening AND the database is reachable; with the endpoint down
# the connection is refused. `curl -f` turns both a non-2xx and a refused
# connection into a non-zero exit — the unhealthy signal. Shell form so
# ${PORT} (default 4000, matching runtime.exs) is expanded.
#
# Probing 127.0.0.1 over http depends on config/prod.exs's `force_ssl` EXCLUDING
# host "127.0.0.1" — without that exclude, `Plug.SSL` answers a 301 to https,
# and `curl -f` treats a 3xx as success, so the check would pass without ever
# confirming /up's 200. Keep the two in sync.
#
# start-period is generous: migrations run in the boot CMD before HTTP is up,
# and a cold boot of the Ash + Nx/Axon/Bumblebee stack is not fast. Failures
# during this window don't count toward --retries, so a longer period only
# delays the first "healthy", it never causes a premature unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT:-4000}/up" || exit 1

# Run pending migrations (KilnCMS.Release.migrate — see rel/overlays/bin/migrate)
# before starting the server. Coolify's pre-deployment command hook only runs
# inside an already-running container, so it's a no-op on a fresh deploy target
# or after any build failure — this makes migrations run unconditionally on
# every boot instead. Ecto.Migrator takes a DB advisory lock, so this stays
# safe if this ever scales beyond a single replica.
CMD ["/bin/sh", "-c", "/app/bin/migrate && /app/bin/server"]
