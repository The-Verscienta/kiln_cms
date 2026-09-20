import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Error tracking (Sentry)
#
# Enabled — in any environment — only when SENTRY_DSN is set. With no DSN every
# Sentry capture is a no-op, so dev/test/CI stay offline. The logger handler that
# turns crashes into Sentry events is attached in KilnCMS.Application only when a
# DSN is present.
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: System.get_env("SENTRY_ENV") || to_string(config_env()),
    # Tag events with the running release version when available (set by the
    # release runtime), so regressions can be pinned to a deploy.
    release: System.get_env("RELEASE_VSN")
end

# ## Distributed tracing (OpenTelemetry)
#
# Enabled only when an OTLP collector endpoint is configured. Flips the flag
# KilnCMS.Application reads to attach the Phoenix/Ecto/Bandit/Oban
# instrumentation, and points the OTLP exporter at the collector. Honors the
# standard OTEL_* env vars (OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_PROTOCOL,
# OTEL_EXPORTER_OTLP_HEADERS) for the rest.
if otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :kiln_cms, :otel_enabled, true

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp,
    resource: %{service: %{name: System.get_env("OTEL_SERVICE_NAME") || "kiln_cms"}}

  config :opentelemetry_exporter,
    otlp_protocol:
      "OTEL_EXPORTER_OTLP_PROTOCOL" |> System.get_env("http_protobuf") |> String.to_atom(),
    otlp_endpoint: otlp_endpoint
end

# ## Metrics exporter (Prometheus, #1362)
#
# Off by default. KilnCMSWeb.Metrics starts a Peep reporter and a /metrics
# listener on its own port only when this is on. Each variable writes config
# only when the operator set a recognized value, so the compiled defaults in
# config/config.exs (off, 9568, loopback, no token) stand otherwise.
with {:ok, enabled?} <- Env.fetch("KILN_METRICS_ENABLED") do
  config :kiln_cms, KilnCMSWeb.Metrics, enabled: enabled?
end

# No upper-bound check beyond the shared reader's: a port above 65535 fails the
# listener at boot, loudly, which is the right outcome for an opt-in feature.
with {:ok, port} <- Env.positive_integer("KILN_METRICS_PORT") do
  config :kiln_cms, KilnCMSWeb.Metrics, port: port
end

# `loopback` for a sidecar agent; `all` for a scraper on a private network.
# A named choice rather than an address, so an unreadable value keeps loopback
# and warns instead of being guessed at. Mapped by hand, not with
# `String.to_existing_atom/1`: in a release this runs before the module that
# mentions `:loopback` is loaded.
with {:ok, bind} <- Env.one_of("KILN_METRICS_BIND", ~w(loopback all)) do
  config :kiln_cms, KilnCMSWeb.Metrics, bind: if(bind == "all", do: :all, else: :loopback)
end

# Blank is unset: `KILN_METRICS_TOKEN=` in a compose file must not turn into a
# required empty bearer token.
with token when is_binary(token) <- System.get_env("KILN_METRICS_TOKEN"),
     token = String.trim(token),
     true <- token != "" do
  config :kiln_cms, KilnCMSWeb.Metrics, token: token
end
