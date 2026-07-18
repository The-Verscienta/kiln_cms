import Config
config :kiln_cms, Oban, testing: :manual

# Keep DNS checks and the port-25 preflight off the network in tests; explicit
# `dns:`/`tcp:` opts in DnsCheck tests still override these.
config :kiln_cms, KilnCMS.Mail.DnsCheck,
  dns: KilnCMS.Test.StubDNS,
  tcp: KilnCMS.Test.StubTCP

# Run best-effort analytics writes (page-view + search-query recording) inline
# rather than in a detached supervised task, so the upsert stays on the test's
# ExUnit SQL sandbox connection — avoids a connection leaking past the owning
# test and racing assertions. See ContentController / SearchPaletteLive.
config :kiln_cms, :async_analytics, false
# Never cache the dynamic-type registry in tests: the cache is one global
# Cachex key while test sandboxes are per-test, so a cached registry would
# leak one async test's TypeDefinitions into another's requests.
config :kiln_cms, KilnCMS.CMS.ContentTypes, cache_registry?: false
# Route outbound webhook HTTP through a Req.Test stub in tests.
config :kiln_cms, KilnCMS.Webhooks, req_options: [plug: {Req.Test, KilnCMS.Webhooks}]

# Webhook URL validation: skip DNS resolution for Req.Test stub hosts.
config :kiln_cms, KilnCMS.Webhooks.SafeUrl, require_https: false, resolve_dns: false

# S3 storage adapter: dummy credentials + route ExAws HTTP through a Req.Test
# stub, so the adapter is exercised end-to-end (signing included) with no live S3.
config :ex_aws, access_key_id: "test", secret_access_key: "test", region: "us-east-1"

config :kiln_cms, KilnCMS.Storage.S3,
  bucket: "kiln-test",
  public_base_url: "https://cdn.test/kiln-test",
  req_options: [plug: {Req.Test, KilnCMS.Storage.S3}]

# Extra locales so the locale-aware delivery tests have something to switch to.
config :kiln_cms, :i18n, default_locale: "en", locales: ["en", "fr", "es"]

# Resolve GraphQL subscriptions synchronously in the publishing (test) process
# so reads stay on the test's sandbox connection.
config :kiln_cms, start_subscription_batcher: false

config :kiln_cms, token_signing_secret: "DxVOH7q7LauTIqk0KY8Mj2auM6QzdpHw"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# In tests, prevent async Task-based analytics recording (view counts, search queries)
# which can produce noisy "owner exited" DB connection errors under Ecto sandbox
# when the task outlives the test process. Tests that assert on the side-effects
# call the record functions synchronously instead.
config :kiln_cms, :analytics_enabled, false

# Raise the rate-limit buckets the broad controller suites hammer, per IP. All
# test requests come from 127.0.0.1, so a fast full-suite run can pack more than
# the production `:api` limit (120/min) of `/api/*` calls into one window and
# 429 unrelated tests (flaky on fast machines, and it started failing CI as the
# `/api` test volume grew). Only the buckets no test asserts on are raised — the
# `:auth`/`:preview`/`:form`/`:docs` limits `KilnCMSWeb.Plugs.RateLimitTest`
# exercises are left at their real values. Production is unaffected (unset).
config :kiln_cms, KilnCMSWeb.RateLimit,
  limits: %{
    api: {1_000_000, :timer.minutes(1)},
    delivery: {1_000_000, :timer.minutes(1)},
    gql: {1_000_000, :timer.minutes(1)},
    probe: {1_000_000, :timer.minutes(1)}
  }

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :kiln_cms, KilnCMS.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "kiln_cms_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kiln_cms, KilnCMSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "zXEJCKb9XY9OLFWheUXYzIb7uNd/polpymYt9sZ63H8kZSs9i/Bl7UAqiM2uGbHF",
  server: false

# In test we don't send emails
config :kiln_cms, KilnCMS.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Use the EXLA (XLA) backend for Nx in tests — the :exla dep is only available in
# dev/test. Prod/e2e fall back to Nx.BinaryBackend (see config/config.exs).
config :nx, default_backend: EXLA.Backend

# Exercise the collab CRDT channel in tests (joins refuse when off).
config :kiln_cms, :collab_prototype, true
# Collab doc persistence + checkpoint materialization are exercised by their
# own (sync) test suites; off by default so DocServers spawned by async
# channel/editor tests never touch the sandboxed database from an unowned
# process.
config :kiln_cms, KilnCMS.Collab.Crdt, persist?: false, materialize?: false

# The test-suite plugin (D18): exercises every plugin seam — block union
# membership, admin nav/route, supervision child, Oban queue merge.
config :kiln_cms, :plugins, [KilnCMS.FixturePlugin]

# A fixed CORS allowlist so the CORS tests can assert both the allowed and
# denied paths deterministically (prod default is `[]` / same-origin only).
config :kiln_cms, :cors_origins, ["https://frontend.test"]
