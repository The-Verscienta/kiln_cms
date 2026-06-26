import Config

# Dedicated environment for the Playwright browser E2E suite (see `e2e/`). It
# runs a real HTTP server with built assets against its own database, so the
# external browser driver can exercise the full LiveView editor journey.

# Its own database — kept separate from dev/test so the persistent E2E data
# (no SQL sandbox here; the browser hits the server out-of-process) never
# collides with `mix test` or local dev.
config :kiln_cms, KilnCMS.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "kiln_cms_e2e"),
  pool_size: 10

# Endpoint serving the compiled assets. Serving is turned on at runtime by
# `PHX_SERVER=true mix phx.server` (config/runtime.exs), which also sets the
# port from `PORT` (default 4000) — the Playwright harness passes `PORT=4002`.
config :kiln_cms, KilnCMSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  secret_key_base: "e2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2eE2e0123456789",
  check_origin: false,
  code_reloader: false,
  debug_errors: false

# Background jobs don't run during E2E — no cron firing the scheduled-publish /
# purge triggers, no Bumblebee embedding, no outbound webhook/email delivery.
# Publish/workflow actions are synchronous, so the editor journey needs none of
# it. (Mirrors the test env.)
config :kiln_cms, Oban, testing: :manual

config :kiln_cms, token_signing_secret: "e2eTokenSigningSecretForBrowserTests0"

# Fast password hashing so seeding + sign-in aren't slow.
config :bcrypt_elixir, log_rounds: 1

# Emails are stored locally (Swoosh.Adapters.Local from config.exs); disable the
# external API client so the app boots without hackney.
config :swoosh, :api_client, false

# Quiet, non-reloading server.
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
