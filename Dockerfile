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
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Install JS dependencies (TipTap, etc.) before bundling.
RUN npm --prefix assets ci

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

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

CMD ["/app/bin/server"]
