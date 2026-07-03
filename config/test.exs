import Config
config :kiln_cms, Oban, testing: :manual

# Register the Verscienta project's catalog domain for the test suite only.
# `config/config.exs` deliberately keeps `Verscienta.Catalog` out of
# `ash_domains`/`content_domains` everywhere else, so a clean core build/boot
# never references a project-specific module (see the comment there). But
# `Verscienta.Catalog` IS compiled here (`projects/` is in `elixirc_paths` for
# every env — see mix.exs), and `test/verscienta/importer_test.exs` exercises
# its import pipeline (Catalog.Herb/Formula) directly, so the test suite needs
# it registered to pass. This override is test-only: prod stays exactly as
# decided (dormant), so there's no boot-crash risk from this change.
config :kiln_cms,
  ash_domains: [
    KilnCMS.Accounts,
    KilnCMS.CMS,
    KilnCMS.Analytics,
    KilnCMS.Firing,
    KilnCMS.History,
    KilnCMS.SearchIndex,
    KilnCMS.Mail,
    Verscienta.Catalog
  ],
  content_domains: [KilnCMS.CMS, Verscienta.Catalog]

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

# Route the Verscienta Directus migration client through a Req.Test stub so its
# pagination/auth is exercised offline.
config :kiln_cms, Verscienta.Source.Directus,
  req_options: [plug: {Req.Test, Verscienta.Source.Directus}]

# S3 storage adapter: dummy credentials + route ExAws HTTP through a Req.Test
# stub, so the adapter is exercised end-to-end (signing included) with no live S3.
config :ex_aws, access_key_id: "test", secret_access_key: "test", region: "us-east-1"

config :kiln_cms, KilnCMS.Storage.S3,
  bucket: "kiln-test",
  public_base_url: "https://cdn.test/kiln-test",
  req_options: [plug: {Req.Test, KilnCMS.Storage.S3}]

# Extra locales so the locale-aware delivery tests have something to switch to.
config :kiln_cms, :i18n, default_locale: "en", locales: ["en", "fr", "es"]

config :kiln_cms, token_signing_secret: "DxVOH7q7LauTIqk0KY8Mj2auM6QzdpHw"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# In tests, prevent async Task-based analytics recording (view counts, search queries)
# which can produce noisy "owner exited" DB connection errors under Ecto sandbox
# when the task outlives the test process. Tests that assert on the side-effects
# call the record functions synchronously instead.
config :kiln_cms, :analytics_enabled, false

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
config :kiln_cms, :plugins, [KilnCMS.FixturePlugin, Verscienta.Plugin]
