import Config

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
