import Config

# Point the showcase at any KilnCMS instance without recompiling.
#
#   KILN_API_URL   base URL of the KilnCMS delivery API (default http://localhost:4000)
#   KILN_API_KEY   optional `kiln_…` API key — sent as a bearer token so the app
#                  can read beyond public content (mint one at /editor/api-keys)
#   KILN_LOCALE    default content locale to request (default "en")
# Skip in test so the suite keeps the closed-port base_url from config/test.exs
# (which exercises the client's error paths without a live KilnCMS).
if config_env() != :test do
  config :showcase, Showcase.Kiln,
    base_url: System.get_env("KILN_API_URL", "http://localhost:4000"),
    api_key: System.get_env("KILN_API_KEY"),
    locale: System.get_env("KILN_LOCALE", "en")
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing. Generate one with: mix phx.gen.secret"

  config :showcase, ShowcaseWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost", port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4002")
    ],
    secret_key_base: secret_key_base,
    server: true
end
