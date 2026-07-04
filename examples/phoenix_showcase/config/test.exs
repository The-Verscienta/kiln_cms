import Config

config :showcase, ShowcaseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4102],
  secret_key_base: "test-only-secret-test-only-secret-test-only-secret-test-only-secret",
  server: false

# Point at a closed port so the Kiln client's error paths are exercised
# deterministically (no live KilnCMS needed for the test suite).
config :showcase, Showcase.Kiln, base_url: "http://localhost:4999", locale: "en"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
