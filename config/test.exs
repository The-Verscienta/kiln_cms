import Config
config :kiln_cms, Oban, testing: :manual
# Route outbound webhook HTTP through a Req.Test stub in tests.
config :kiln_cms, KilnCMS.Webhooks, req_options: [plug: {Req.Test, KilnCMS.Webhooks}]

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
