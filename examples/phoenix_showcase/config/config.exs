import Config

config :showcase,
  generators: [timestamp_type: :utc_datetime]

config :showcase, ShowcaseWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ShowcaseWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Showcase.PubSub,
  live_view: [signing_salt: "kiln-showcase"]

# Bundle the LiveView client. NODE_PATH points esbuild at the Elixir deps so
# `import ... from "phoenix"` / "phoenix_live_view" resolve without npm.
config :esbuild,
  version: "0.23.0",
  showcase: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :phoenix, :json_library, Jason

# Where this app points for the KilnCMS delivery API. Overridable at runtime via
# KILN_API_URL / KILN_API_KEY / KILN_LOCALE (see config/runtime.exs).
config :showcase, Showcase.Kiln,
  base_url: "http://localhost:4000",
  locale: "en"

import_config "#{config_env()}.exs"
