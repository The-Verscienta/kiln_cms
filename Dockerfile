# Multi-stage build for a KilnCMS OTP release.
# Includes libvips in the runtime image for on-the-fly image processing.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250520-slim

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

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates libvips42 \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/kiln_cms ./

USER nobody

# Healthcheck hits the Phoenix endpoint.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/app/bin/kiln_cms", "rpc", "1 + 1"]

# Run pending migrations (KilnCMS.Release.migrate — see rel/overlays/bin/migrate)
# before starting the server. Coolify's pre-deployment command hook only runs
# inside an already-running container, so it's a no-op on a fresh deploy target
# or after any build failure — this makes migrations run unconditionally on
# every boot instead. Ecto.Migrator takes a DB advisory lock, so this stays
# safe if this ever scales beyond a single replica.
CMD ["/bin/sh", "-c", "/app/bin/migrate && /app/bin/server"]
