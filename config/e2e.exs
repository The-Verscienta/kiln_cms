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

# Background jobs DO run during E2E, cron does not (#1314). The media journey
# needs `KilnCMS.Media.VariantWorker`: an upload's `width`/`height` are
# measured there, not at ingest, and the library's focal-point editor is gated
# on `width` — under `testing: :manual` it never appeared and the journey could
# not be driven. `plugins: []` drops the Cron plugin (no scheduled-publish /
# purge / sweep triggers firing mid-journey) and the Pruner. The other queues
# processing is harmless here: outbound mail lands in Swoosh's local mailbox
# (config.exs), no webhook endpoints or embeddings are configured, and jobs
# that fail just retry in the background. `Config` deep-merges keyword lists,
# so there is no way to leave only `:media` running from this file without
# restating every queue.
config :kiln_cms, Oban, testing: :disabled, plugins: []

config :kiln_cms, token_signing_secret: "e2eTokenSigningSecretForBrowserTests0"

# Fast password hashing so seeding + sign-in aren't slow.
config :bcrypt_elixir, log_rounds: 1

# The whole browser suite drives one server from one address, and every spec
# signs in — so the per-IP `:auth` bucket counts the suite as a single client.
# At the real 20/min that is now seven sign-ins per window (#715 added a third
# charge per sign-in: the page GET, the submit, and the token-exchange GET the
# LiveView redirects to), which the suite already exceeds. Whether a run goes
# red is then down to where the fixed window happens to fall — a flake, not a
# signal. Raised here for the same reason `config/test.exs` raises it, and
# production is unaffected (unset).
config :kiln_cms, KilnCMSWeb.RateLimit, limits: %{auth: {1_000, :timer.minutes(1)}}

# Emails are stored locally (Swoosh.Adapters.Local from config.exs); disable the
# external API client so the app boots without hackney.
config :swoosh, :api_client, false

# The dev-only browser tooling — chiefly the Swoosh mailbox at /dev/mailbox —
# so a journey can observe what the server SENT, not just what it rendered:
# the comment `@mention` spec (#1314) reads the mailbox's JSON to prove the
# mentioned editor was actually notified. Compile-time (`Application.compile_env`
# in the router), same as dev; `KilnCMS.Application` refuses it in :prod only.
config :kiln_cms, dev_routes: true

# Quiet, non-reloading server.
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# The browser suite drives a real server, so a Req.Test stub (which resolves
# through the calling process) can't intercept the update check. Turn it off
# outright: an e2e run must not depend on api.github.com being reachable, and
# must not spend the instance's unauthenticated rate-limit budget.
config :kiln_cms, Kiln.Updates, enabled: false
