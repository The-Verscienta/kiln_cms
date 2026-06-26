# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_oban, pro?: false

config :kiln_cms, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10],
  repo: KilnCMS.Repo,
  plugins: [{Oban.Plugins.Cron, []}]

config :kiln_cms,
  ash_domains: [
    KilnCMS.Accounts,
    KilnCMS.CMS,
    KilnCMS.Analytics,
    KilnCMS.Firing,
    KilnCMS.History,
    KilnCMS.SearchIndex
  ],
  # Default "from" address for transactional email (auth confirmation/reset).
  # Override per environment in runtime.exs for production.
  email_from: {"KilnCMS", "noreply@kilncms.dev"}

# Media blob storage. Swap the adapter for S3/MinIO in production (configure
# the bucket/endpoint/credentials in runtime.exs).
config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.Local

# ExAws (used by KilnCMS.Storage.S3) routes HTTP through Req rather than hackney.
config :ex_aws,
  json_codec: Jason,
  http_client: KilnCMS.Storage.S3.ReqClient

# Public base URL of the delivery frontend — used to build sitemap/robots URLs
# and JSON-LD canonical URLs. Override in runtime.exs for production.
config :kiln_cms, :public_base_url, "http://localhost:4000"

# White-label branding tokens (see KilnCMS.Branding). Override at runtime via
# SITE_NAME / BRAND_LOGO_URL / BRAND_PRIMARY_COLOR in config/runtime.exs.
config :kiln_cms, :branding,
  site_name: "KilnCMS",
  logo_url: "/images/logo.svg"

# AI content assistant (see KilnCMS.AI). Defaults to the offline Echo provider;
# runtime.exs swaps in the Claude (Anthropic) provider when ANTHROPIC_API_KEY is
# set. Set `enabled: false` to hide the editor assist UI entirely.
config :kiln_cms, KilnCMS.AI, adapter: KilnCMS.AI.Echo, enabled: true

# Semantic search — pgvector storage + local Bumblebee embeddings. Disabled by
# default: with `semantic: false` the model/serving never start and content
# writes skip embedding work, so the lean install pays nothing. Flip `semantic`
# to true (and run `mix kiln.embed_all` once) to enable it. See
# docs/semantic-search-plan.md.
config :kiln_cms, KilnCMS.Search,
  semantic: false,
  embedder: KilnCMS.Search.Embedder.Bumblebee,
  model: "BAAI/bge-small-en-v1.5",
  dim: 384,
  # Optional reranking of `hybrid/3` results by a local cross-encoder. Off by
  # default — the model only loads when `rerank: true`, and even then only the
  # `hybrid(..., rerank: true)` calls use it.
  rerank: false,
  reranker: KilnCMS.Search.Reranker.Bumblebee,
  rerank_model: "BAAI/bge-reranker-base"

# Optional Meilisearch backend — typo-tolerant, faceted keyword search over
# published content (Project Plan Phase 6). Disabled by default: with
# `enabled: false` no content write or publish ever talks to Meilisearch, so the
# lean install pays nothing. Enable it (and point it at a running instance — the
# `search` Docker Compose profile starts one) here or, for production, in
# runtime.exs via MEILI_* env vars. Run `mix kiln.meili.reindex` once after
# enabling. See docs/meilisearch.md.
config :kiln_cms, KilnCMS.Search.Meilisearch,
  enabled: false,
  url: "http://localhost:7700",
  master_key: nil,
  index: "kiln_content"

# Register pgvector's Postgrex extension so `vector` columns encode/decode.
config :kiln_cms, KilnCMS.Repo, types: KilnCMS.PostgrexTypes

# EXLA backs Nx — only exercised when the embedding serving runs.
config :nx, default_backend: EXLA.Backend

# Organization name used as the JSON-LD publisher. Override in runtime.exs.
config :kiln_cms, :site_name, "KilnCMS"

# Content locales. Content is modelled per-locale (unique [slug, locale]); the
# delivery layer serves the requested locale with a fallback to the default.
# Non-default locales are served under a `/<locale>/…` URL prefix.
config :kiln_cms, :i18n, default_locale: "en", locales: ["en"]

# How many days soft-deleted (trashed) content is retained before the nightly
# AshOban `purge_trashed` trigger hard-deletes it.
config :kiln_cms, :trash, retention_days: 30

config :ash_graphql, authorize_update_destroy_with_error?: true

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :graphql,
        :json_api,
        :admin,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :graphql,
        :json_api,
        :admin,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

config :kiln_cms,
  namespace: KilnCMS,
  ecto_repos: [KilnCMS.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :kiln_cms, KilnCMSWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KilnCMSWeb.ErrorHTML, json: KilnCMSWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: KilnCMS.PubSub,
  live_view: [signing_salt: "LPPY3qp7"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kiln_cms, KilnCMS.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kiln_cms: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  kiln_cms: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
