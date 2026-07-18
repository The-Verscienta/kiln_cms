# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_oban, pro?: false

# The build-time Mix environment, baked into the release so runtime code can
# refuse unsafe combinations (e.g. dev_routes enabled in a :prod release — see
# KilnCMS.Application). Compile-time only; never overridden at runtime.
config :kiln_cms, :compile_env, config_env()

config :kiln_cms, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  # Split by workload so a bulk publish / embedding backfill can't starve mail,
  # webhooks, or the cron-driven triggers. The every-minute scheduled
  # publish/unpublish (embargo) triggers get their own :scheduling queue so a
  # busy :default (bulk work, daily purge/sweep) can't leave them queued past
  # their one-minute cadence. Total worker concurrency here is ~34 — size
  # POOL_SIZE accordingly in production (see config/runtime.exs and
  # docs/performance.md).
  # Newsletter fan-out/delivery gets its own :newsletter queue so a large blast
  # can't starve transactional :mail (total worker concurrency is now ~37 — size
  # POOL_SIZE accordingly).
  queues: [
    firing: 5,
    search: 5,
    mail: 3,
    newsletter: 3,
    media: 3,
    webhooks: 3,
    scheduling: 5,
    default: 10
  ],
  repo: KilnCMS.Repo,
  plugins: [
    {Oban.Plugins.Cron, []},
    # Delete finished jobs after 7 days. Without this, `oban_jobs` grows
    # without bound AND retains job args indefinitely — and mail jobs carry
    # rendered email bodies containing live auth-token URLs (magic links,
    # password resets). Those tokens expire in hours, well inside this window,
    # so pruning bounds both the table size and how long token/PII data sits
    # in the database (and in backups).
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

config :kiln_cms,
  ash_domains: [
    KilnCMS.Accounts,
    KilnCMS.CMS,
    KilnCMS.Analytics,
    KilnCMS.Firing,
    KilnCMS.History,
    KilnCMS.SearchIndex,
    KilnCMS.Mail,
    KilnCMS.Newsletter
    # The core stays project-agnostic. A downstream project registers its own
    # content domain (e.g. `Verscienta.Catalog`) by appending to this list in its
    # OWN config — it must NOT be listed here, since it isn't compiled into the
    # reusable core. Ash and AshOban iterate `ash_domains` at compile and boot, so
    # a nonexistent module here crashes the release ("not a Spark DSL module").
  ],
  # Domains scanned by `KilnCMS.CMS.ContentTypes` for content types. Core types
  # (page/post) live on KilnCMS.CMS; each downstream project adds its catalog
  # domain in its own config (same reason as ash_domains above — keep it out of
  # the core default so a clean build/boot doesn't reference a missing module).
  content_domains: [KilnCMS.CMS],
  # Tools served by the `/mcp` endpoint (docs/mcp.md). Read at compile time by
  # `KilnCMSWeb.Router`; every name must match a `tools` block on a configured
  # Ash domain (the core set lives on `KilnCMS.CMS`). Like `ash_domains`, a
  # downstream project's config REPLACES this list — restate the core tools and
  # append your own (defined in a `tools` block on your content domain).
  # Publishing/destroying tools are deliberately absent: an LLM authors drafts
  # and submits them for review; a human approves.
  mcp_tools: [
    :read_pages,
    :read_posts,
    :read_entries,
    :read_type_definitions,
    :read_field_definitions,
    :read_tags,
    :read_categories,
    :create_page,
    :update_page,
    :submit_page_for_review,
    :create_post,
    :update_post,
    :submit_post_for_review,
    :create_entry,
    :update_entry,
    :submit_entry_for_review,
    :create_tag,
    :create_category
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

# Nx's backend is set per-env: EXLA.Backend in dev/test (where the :exla dep is
# available — see config/dev.exs + test.exs), Nx.BinaryBackend (Nx's default)
# elsewhere. EXLA is excluded from the prod build because its from-source XLA NIF
# is too heavy for the build host; semantic search is disabled by default there.

# Organization name used as the JSON-LD publisher. Override in runtime.exs.
config :kiln_cms, :site_name, "KilnCMS"

# GraphQL schema introspection. Enabled by default for local/dev tooling;
# disabled in production (config/prod.exs) so the public /gql endpoint doesn't
# expose a full schema map for reconnaissance.
config :kiln_cms, :graphql_introspection, true

# Open self-registration. `true` (default) lets anyone create a `:viewer`
# account via `/register`; set to `false` for an invite-only / internal CMS,
# which hides the registration route and rejects the registration action.
config :kiln_cms, :registration_enabled, true

# Content locales. Content is modelled per-locale (unique [slug, locale]); the
# delivery layer serves the requested locale with a fallback to the default.
# Non-default locales are served under a `/<locale>/…` URL prefix.
config :kiln_cms, :i18n, default_locale: "en", locales: ["en"]

# Consumer-facing access tiers ("audiences"). Independent of the editorial RBAC
# role (`:admin`/`:editor`/`:viewer`, which gates *authoring*): an audience
# gates which signed-in end-users may *read* a published record. `:public` is
# always implied (world-readable) and must stay first. Content carries one
# `audience`; a user carries the set of `audiences` they belong to, and may read
# a gated record only if its audience is in that set (editors/admins see all).
# Override per-deployment, e.g. `[:public, :professional, :patient]`.
config :kiln_cms, :audiences, [:public, :member]

# How many days soft-deleted (trashed) content is retained before the nightly
# AshOban `purge_trashed` trigger hard-deletes it.
config :kiln_cms, :trash, retention_days: 30

# How many days recorded editor search queries (KilnCMS.Analytics.SearchQuery)
# are retained before the nightly AshOban `purge_expired` trigger deletes them.
# Rows carry no actor/IP, but the query text can contain PII or confidential
# titles, so it isn't kept indefinitely. See docs/data-flows.md (#213, #220).
config :kiln_cms, :search_analytics, retention_days: 90

config :ash_graphql, authorize_update_destroy_with_error?: true

# GraphQL subscriptions (real-time headless): the DSL is opt-in while beta.
# Fields are declared per content resource (see KilnCMS.CMS.Content).
config :ash_graphql, :subscriptions, true

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

# Cryptographically signed / provenance-verified content (#340). When enabled,
# each fired :web/:json/:json_ld artifact gets a C2PA-*style* detached manifest:
# a signed SHA-256 hash bound to a claim (signer identity, AI-generation
# disclosure, origin, version, timestamp), verifiable via /api/provenance/*.
# **Off by default** — no manifest is produced and the verify endpoints 404, so
# the lean install pays nothing. See docs/provenance.md.
#
# `signing_key` reuses KilnCMS.Keys (the DKIM signing infra): `:dkim` shares the
# mail signing key, or point at a dedicated content-signing key with
# `{:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}` / `{:file, %{"path" => …}}`
# (PKCS#1 RSA PEM, like DKIM). Configure the key source in runtime.exs for prod.
config :kiln_cms, KilnCMS.Provenance,
  enabled: false,
  # Human-readable signer identity; defaults to :site_name when unset.
  signer: nil,
  # Origin URL recorded in the claim; defaults to :public_base_url when unset.
  origin: nil,
  # Default AI disclosure when a document doesn't set custom_fields["ai_disclosure"]:
  # :human | :ai_assisted | :ai_generated.
  ai_disclosure: :human,
  signing_key: {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kiln_cms: [
    # --format=esm + --splitting: dynamic import() (the lazily loaded TipTap
    # editor) becomes a separate content-hashed chunk instead of shipping in
    # app.js to every public visitor. Root layout loads app.js type="module".
    args:
      ~w(js/app.js --bundle --splitting --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
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

# Error tracking (Sentry). The DSN is only set in config/runtime.exs from the
# SENTRY_DSN env var, so with no DSN every capture is a no-op — dev, test, and
# precommit never reach out to Sentry. Transport uses the default Finch client
# (Finch is already in the tree via Req), so no extra HTTP client is pulled in.
# Oban job failures are captured automatically; request context is attached by
# `Sentry.PlugContext` in the endpoint. Source context is packaged into the
# release by `mix sentry.package_source_code` (see Dockerfile).
config :sentry,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  # Drop expected retry noise: transient mail-delivery failures are raised so
  # Oban retries (greylisting, a blip), and reporting each attempt of each
  # recipient buries real issues. The systemic relay-outage case is surfaced
  # once, aggregated, by KilnCMS.Mail.RelayAlert. See KilnCMS.SentryFilter.
  before_send: {KilnCMS.SentryFilter, :before_send},
  integrations: [oban: [capture_errors: true]]

# OpenTelemetry. Spans are dropped (`traces_exporter: :none`) and the
# instrumentation is never attached unless OTEL_EXPORTER_OTLP_ENDPOINT is set at
# runtime (config/runtime.exs flips `:otel_enabled` and the exporter on). This
# keeps dev/test/precommit free of tracing overhead and exporter connection
# noise. Instrumentation is wired up in KilnCMS.Application.setup_observability/0;
# see docs/observability.md.
config :kiln_cms, :otel_enabled, false

config :opentelemetry, traces_exporter: :none

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Downstream project overlay. A deployment that layers a `projects/<name>/`
# subproject onto this repo (see projects/README.md) drops a `config/project.exs`
# next to this file to register its domains and plugin. Imported after the env
# config so the overlay can build on (and override) it. The reusable core never
# ships this file — the conditional makes a clean checkout a no-op.
if File.exists?(Path.join(__DIR__, "project.exs")), do: import_config("project.exs")
