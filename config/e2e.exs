import Config

# Dedicated environment for the Playwright browser E2E suite (see `e2e/`). It
# runs a real HTTP server with built assets against its own database, so the
# external browser driver can exercise the full LiveView editor journey.

# Its own database — kept separate from dev/test so the persistent E2E data
# (no SQL sandbox here; the browser hits the server out-of-process) never
# collides with `mix test` or local dev.
#
# The default name is partitioned PER CHECKOUT (#1353), the way
# MIX_TEST_PARTITION partitions the test database: this suite runs against
# persistent, never-reset-between-specs data, and one shared `kiln_cms_e2e`
# meant two worktrees' suites accumulated pollution into each other's runs.
# The suffix is the checkout directory's basename, so it is stable across
# runs of one checkout and different across worktrees. `POSTGRES_DB` still
# overrides outright (CI sets nothing and simply gets the partitioned
# default; `mix e2e.reset` drops and rebuilds whichever name is in effect).
e2e_db_suffix =
  File.cwd!()
  |> Path.basename()
  |> String.downcase()
  |> String.replace(~r/[^a-z0-9_]/, "_")
  # Postgres identifiers cap at 63 bytes; leave room for the prefix.
  |> String.slice(0, 40)

config :kiln_cms, KilnCMS.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "kiln_cms_e2e_#{e2e_db_suffix}"),
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

# Background jobs DO run during E2E (#1314). The media journey needs
# `KilnCMS.Media.VariantWorker`: an upload's `width`/`height` are measured
# there, not at ingest, and the library's focal-point editor is gated on
# `width` — under `testing: :manual` it never appeared and the journey could
# not be driven. The releases journey likewise ships and rolls back through
# `KilnCMS.CMS.Workers.ReleaseWorker`. Every queue runs: `Config` deep-merges
# keyword lists, so there is no way to leave only `:media` running from this
# file without restating every queue, and the rest is harmless here — outbound
# mail lands in Swoosh's local mailbox (config.exs), no webhook endpoints or
# embeddings are configured, and jobs that fail just retry in the background.
#
# The Oban Cron plugin from config.exs runs too — it cannot be dropped from
# here (`plugins: []` would deep-merge into the base list and change nothing,
# and AshOban refuses to boot without a Cron plugin because resources declare
# `scheduler_cron`). What it fires is bounded: AshOban's every-minute
# schedulers only act on rows whose `scheduled_at`/`unpublish_at`/release
# go-live is already due, which no journey creates, and the app-level daily
# and hourly sweeps are switched off below through the per-key knobs
# `KilnCMS.Application.oban_config/0` honours, so a run that straddles HH:20
# / HH:40 / HH:50 / 03:40 does not get a reaper, nonce sweep, occurrence sweep
# or governance checkpoint running against the rows a spec is asserting on.
config :kiln_cms, Oban, testing: :disabled

config :kiln_cms,
  governance_checkpoint_cron: false,
  link_check_cron: false,
  task_digest_cron: false,
  occurrence_sweep_cron: false,
  media_quarantine_reaper_cron: false,
  federation_nonce_sweep_cron: false,
  health_sweep_cron: false

# Same reasoning as config/test.exs: application boot is outside any journey,
# and with queues now running a boot-time backfill enqueue would execute
# during whatever spec happens to be first (and inside the `mix run seeds.exs`
# VM, which halts underneath it).
config :kiln_cms, :occurrence_backfill_on_boot, false

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

# The Swoosh mailbox at /dev/mailbox, so a journey can observe what the server
# SENT, not just what it rendered: the comment `@mention` spec (#1314) reads
# the mailbox's JSON to prove the mentioned editor was actually notified. Its
# own compile-time flag rather than `dev_routes` — that one also mounts
# AshAdmin's unauthenticated actor picker, LiveDashboard and the GraphQL
# playground, none of which a browser journey needs, and it stays dev-only (see
# README's hardening checklist). `KilnCMS.Application` refuses either flag in a
# :prod release.
config :kiln_cms, mailbox_preview: true

# Quiet, non-reloading server.
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# The browser suite drives a real server, so a Req.Test stub (which resolves
# through the calling process) can't intercept the update check. Turn it off
# outright: an e2e run must not depend on api.github.com being reachable, and
# must not spend the instance's unauthenticated rate-limit budget.
config :kiln_cms, Kiln.Updates, enabled: false
