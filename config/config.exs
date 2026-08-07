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
  # can't starve transactional :mail.
  # Inbound payment webhooks get :billing so a provider redelivery backfill can't
  # starve anything else, and so an entitlement grant is never queued behind a
  # newsletter blast (total worker concurrency is now ~40 — size POOL_SIZE
  # accordingly).
  queues: [
    firing: 5,
    search: 5,
    mail: 3,
    newsletter: 3,
    billing: 3,
    media: 3,
    webhooks: 3,
    scheduling: 5,
    # Outbound link checking (#474). Deliberately the narrowest queue: every job
    # is a request to somebody else's server, paced per domain by
    # KilnCMS.Links.Throttle, and a wide queue would just produce more jobs
    # snoozing on the same buckets.
    link_check: 3,
    # In-app backups (#484). Concurrency ONE: two simultaneous `pg_dump`s of
    # the same database is never what anyone wanted, and the panel's whole
    # premise is that there is a most-recent backup. Its own queue so a dump
    # that runs for minutes can't leave a publish or a password-reset email
    # queued behind it.
    backups: 1,
    default: 10
  ],
  repo: KilnCMS.Repo,
  plugins: [
    # The crontab is assembled in KilnCMS.Application.oban_config/0 rather than
    # written here, so a runtime override (KILN_GOVERNANCE_CHECKPOINT_CRON) sets
    # a plain `:kiln_cms` key instead of reaching into this nested keyword list.
    # `Config` DEEP-MERGES keyword lists, so overriding one entry of a plugin
    # tuple from runtime.exs is a footgun with a history here (#608).
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
    KilnCMS.Newsletter,
    KilnCMS.Automation,
    KilnCMS.Billing
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
    :read_tag_groups,
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

# In-app backups (#484). Defaults mirror `scripts/backup.sh`'s, so the cron
# path and the app path land in the same directory with the same retention
# without an operator stating either twice. `media_dir` stays nil on an S3
# deployment: the bucket is backed up provider-side, and tarring the wrong
# directory produces something that looks like a media backup and restores
# nothing. Overridden from the environment in runtime.exs.
config :kiln_cms, KilnCMS.Backups,
  enabled: true,
  dir: "/var/backups/kiln",
  media_dir: nil,
  keep_days: 14,
  stale_after_hours: 36

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

# AI-assisted SEO drafting (#60). The deterministic analysis and score in the
# editor are ALWAYS on and need none of this — the block below gates the
# optional "propose a title/description/keywords" step only, and is off by
# default: with `generator: nil` no module is called and no content leaves the
# deployment. The intended production setup is an on-prem endpoint
# (`model: "ollama:llama3.1"`); a hosted provider works too, and is announced at
# boot and in the editor. API keys are resolved by `req_llm` from its own
# environment, never read or stored by Kiln. See docs/seo.md.
# Timezone database (#480). Elixir ships none, so `DateTime.shift_zone/2` and
# anything wall-clock returns `{:error, :utc_only_time_zone_database}` without
# it. Set globally rather than per-call: a caller that forgets does not get a
# subtly-UTC answer, it gets an error.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Editorial advisory checks (#476, #495, #377) — the non-blocking advice panels
# in the content editor. Order here is display order. Plugins append their own
# via the `advisories/0` callback on `Kiln.Plugin`; a check that raises is
# dropped and logged rather than taking the editor down. See `Kiln.Advisory`.
#
# Three namespaces: `Kiln.Advisory.Checks.*` are feature-neutral (an
# accessibility panel wants them verbatim), `KilnCMS.Seo.Checks.*` are
# search-specific, `KilnCMS.Compliance.Checks.*` are claim checks. Which panel
# each one appears in is the check's own `lenses/0`, not this list — see
# `Kiln.Advisory`.
config :kiln_cms, Kiln.Advisory,
  checks: [
    KilnCMS.Seo.Checks.Meta,
    KilnCMS.Seo.Checks.Keyphrase,
    KilnCMS.Seo.Checks.Readability,
    Kiln.Advisory.Checks.Headings,
    Kiln.Advisory.Checks.ImageAlt,
    Kiln.Advisory.Checks.InternalLinks,
    Kiln.Advisory.Checks.LinkText,
    Kiln.Advisory.Checks.AllCaps,
    KilnCMS.Compliance.Checks.Claims,
    KilnCMS.Compliance.Checks.Disclaimer
  ]

# Editorial claim checking (#377) — the compliance panel. Registered above but
# inert until `enabled: true`: both checks return `:n_a` while it is off, so an
# install that never asked for this pays a map lookup and shows no panel.
#
# `require_at_publish` is the separate, harder switch — it turns an
# `:error`-severity match into a refused publish
# (`KilnCMS.CMS.Validations.ComplianceClaims`) rather than advice.
#
# The shipped rule pack is deliberately narrow, and is meant to be extended per
# publication. See `KilnCMS.Compliance` for why bare curative vocabulary
# ("cures", "heals") is NOT in it.
config :kiln_cms, KilnCMS.Compliance,
  enabled: false,
  require_at_publish: false,
  disclaimer: nil,
  rules: :default

# Form submission spam scoring (#477) — post-storage triage on top of the
# honeypot/rate-limit pre-storage defenses in `KilnCMS.Forms`. Order here is
# irrelevant (weights just sum); a check that raises is dropped and logged
# rather than failing a visitor's submission. Plugins append their own via
# the `spam_checks/0` callback on `Kiln.Plugin`. See `Kiln.Forms.SpamCheck`.
config :kiln_cms, Kiln.Forms.SpamCheck,
  threshold: 50,
  checks: [
    Kiln.Forms.SpamCheck.Checks.LinkDensity,
    Kiln.Forms.SpamCheck.Checks.DisallowedKeywords,
    Kiln.Forms.SpamCheck.Checks.FillTime,
    Kiln.Forms.SpamCheck.Checks.LocaleMismatch
  ]

# `req_llm` (and its `llm_db` catalog) source a `.env` from the working
# directory into the OS environment at application start, unconditionally —
# including on a default install with drafting off. That would let a stray
# `.env` beside a release quietly populate the production environment, and a
# developer's local one bleed into `mix test`. Kiln reads no provider secrets
# itself, so nothing here needs it.
config :req_llm, load_dotenv: false
config :llm_db, load_dotenv: false

config :kiln_cms, KilnCMS.Seo,
  generator: nil,
  model: nil,
  temperature: 0.3,
  max_tokens: 700,
  timeout_ms: 20_000,
  max_input_chars: 12_000,
  min_words: 50,
  title_max: 60,
  description_max: 160,
  keyword_max: 5,
  # Both buckets must pass: per-user stops a stuck button, per-org is the
  # actual spend ceiling.
  per_user_limit: {20, :timer.minutes(1)},
  per_org_limit: {200, :timer.hours(1)}

# Block-level AI assist in the content editor (#60) — draft, continue,
# summarize, rewrite, shorten or expand one rich-text block.
#
# A SEPARATE switch from KilnCMS.Seo above, deliberately. That one sends a
# page's text and gets three short metadata strings back; this one also sends
# the editor's typed instruction and returns prose for the page body. An
# operator who accepted the first has not thereby accepted the second.
#
# Off by default: with `generator: nil` the editor renders no assist control
# and nothing leaves the deployment. See docs/ai-assist.md.
config :kiln_cms, KilnCMS.Assist,
  generator: nil,
  model: nil,
  # Warmer than SEO drafting: that path wants the most predictable phrasing of
  # a fixed fact, this one drafts prose a person will edit.
  temperature: 0.6,
  max_tokens: 1_200,
  timeout_ms: 45_000,
  max_input_chars: 8_000,
  max_instruction_chars: 500,
  max_output_chars: 6_000,
  # Tighter than SEO drafting on both counts. A generation here is many more
  # tokens than three metadata strings, so the same click costs more.
  per_user_limit: {10, :timer.minutes(1)},
  per_org_limit: {150, :timer.hours(1)}

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

# First-class static / edge export of fired artifacts (#353). The firing engine
# already produces immutable per-surface artifacts; this exports them to a
# static directory tree for CDN/air-gapped deploys (`mix kiln.export.static`, or
# the enqueuable KilnCMS.Firing.StaticExportWorker for admin/cron triggers).
# `output_dir` is the worker's destination — nil means the worker is a no-op, so
# it's safe to schedule before an operator picks a destination. See
# docs/static-export.md.
config :kiln_cms, KilnCMS.Firing.StaticExport,
  output_dir: nil,
  surfaces: [:web, :json, :json_ld, :llm]

# Nx's backend is set per-env: EXLA.Backend in dev/test (where the :exla dep is
# available — see config/dev.exs + test.exs), Nx.BinaryBackend (Nx's default)
# elsewhere. EXLA is excluded from the prod build because its from-source XLA NIF
# is too heavy for the build host; semantic search is disabled by default there.

# Organization name used as the JSON-LD publisher and as the provenance signing
# identity. Override in runtime.exs. Deliberately instance-wide: `KilnCMS.Branding`
# falls back to it, but per-site branding must not change what a signature attests.
config :kiln_cms, :site_name, "KilnCMS"

# White-label branding defaults (#48, see `KilnCMS.Branding`) — the instance-wide
# layer under each site's own `KilnCMS.CMS.SiteBranding` row. Override at runtime
# via SITE_NAME / BRAND_LOGO_URL / BRAND_PRIMARY_COLOR (config/runtime.exs).
# Unset keys fall through to the stock KilnCMS defaults, so a deployment that
# configures nothing renders exactly as before.
config :kiln_cms, :branding, []

# GraphQL schema introspection. Enabled by default for local/dev tooling;
# disabled in production (config/prod.exs) so the public /gql endpoint doesn't
# expose a full schema map for reconnaissance.
config :kiln_cms, :graphql_introspection, true

# The API documentation surface: the OpenAPI 3 document at
# `/api/json/open_api` and the Swagger UI explorer over it. Enabled by default
# for local/dev tooling; disabled in production (config/prod.exs) for the same
# reason introspection is, since #330 made the described surface include the
# write routes. `API_DOCS_ENABLED` overrides at runtime for operators
# publishing a public API. See `KilnCMSWeb.Plugs.ApiDocs`.
config :kiln_cms, :api_docs, true

# Open self-registration. `true` (default) lets anyone create a `:viewer`
# account via `/register`; set to `false` for an invite-only / internal CMS,
# which hides the registration route and rejects the registration action.
config :kiln_cms, :registration_enabled, true

# Multi-tenancy (epic #336). `true`: additional organizations may be created and
# each is served in isolation by host. The tenant axis is fully threaded — the
# `SetTenant` plug scopes the headless GraphQL/JSON:API surfaces from the request
# host, and every controller / LiveView / worker read on a per-site resource
# passes the tenant (verified by the pre-lift cross-org audit) — so a request on
# one site's host only ever sees that org's data.
#
# Resources remain `global?: true` (non-strict): a tenant-less read fails OPEN
# (spans orgs) rather than closed. That's safe today because every reachable read
# is threaded, but a future tenant-less read would silently leak. Flipping the
# per-site resources to strict `global?: false` (fail-closed) is the recommended
# next hardening — it requires first reworking the deliberate tenant-less reads
# (public newsletter-token lookups, AshOban global schedulers, `static_export`).
#
# Set to `false` to hard-refuse a second org (a kill switch for single-tenant
# installs). The seeded default org is created by the backfill migration, which
# bypasses this guard, so bootstrapping is unaffected either way.
config :kiln_cms, :multitenancy_enabled, true

# Strict (fail-closed) tenancy (#419): every action on an org-scoped resource
# REQUIRES a tenant (`global?: false`); the sanctioned exceptions are marked
# `multitenancy :bypass` per action (newsletter token lookups). COMPILE-TIME:
# the value is baked into the resource DSL — changing it needs a recompile.
# The standard test env compiles fail-open for the pre-#419 suite; a dedicated
# CI leg (KILN_STRICT_TEST=1, --only strict_tenancy) exercises the strict
# build. Set `false` only to restore the legacy fail-open rollout behavior.
config :kiln_cms, :strict_tenancy, true

# Strict host→tenant matching (#563). Unrelated to `:strict_tenancy` above:
# that one is compile-time and about resources requiring a tenant, this one is
# RUNTIME (`TENANT_STRICT_HOST`) and about which tenant an unrecognized request
# `Host` resolves to. Off ⇒ the default org, which is right for a single-host
# install and wrong for a multi-tenant one, where it serves the default site's
# content to anyone with an unmatched Host. See `KilnCMSWeb.Tenant`.
config :kiln_cms, :tenant_strict_host, false

# Tamper-evident history anchors (#356): at every publish, the document's full
# PaperTrail version chain is folded into a canonical hash and recorded
# (RSA-signed when a provenance signing key is configured — see
# `config :kiln_cms, KilnCMS.Provenance` below). Cheap (one hash fold + local
# sign per publish); disable only if the audit surface is unwanted.
config :kiln_cms, :audit_anchors_enabled, true

# Anchor EVERY versioned write, not just publishes (#356). Publish-time
# anchoring leaves edits between two publishes covered only retroactively;
# this closes that window at the cost of one signature and one `history_anchors`
# row per save. Off by default: a regulated deployment wants it, a blog does
# not. Anchors fold incrementally, so the cost does not grow with history.
#
# Override per deployment at runtime with KILN_AUDIT_ANCHOR_EVERY_WRITE=true
# (runtime.exs) — no rebuild needed to turn it back off.
config :kiln_cms, :audit_anchor_every_write, false

# Org-wide anchor-chain checkpoints (#666). Anchors make history tamper-evident
# against everything except TRUNCATION: delete a document's newest anchors and
# the surviving prefix still verifies, because nothing inside the document says
# how many there were. A checkpoint is the statement from outside — a signed
# Merkle commitment to every document's head anchor, minted on the cron below.
# Cheap: one signature per org per run plus a row per document whose head moved.
config :kiln_cms, :governance_checkpoints_enabled, true

# Where checkpoints are PUBLISHED. The default keeps them in the database, which
# still catches an attacker who deletes anchors and forgets `chain_checkpoints`
# — and does not survive one who remembers. A deployment that needs the property
# to actually hold points this at a sink its database credentials cannot rewrite:
# KILN_GOVERNANCE_WITNESS=file|s3 in runtime.exs. See KilnCMS.Governance.Witness.
config :kiln_cms, KilnCMS.Governance.Witness, adapter: KilnCMS.Governance.Witness.None

# How often a checkpoint is minted. Nightly by default because the cost is one
# signature per org, but the cadence is a SECURITY parameter, not a performance
# one: anchors minted since the last checkpoint are not yet witnessed, so the
# window in which a chain can be truncated undetected is exactly one interval.
# A regulated deployment shortens it (KILN_GOVERNANCE_CHECKPOINT_CRON="0 * * * *").
# `false` disables the scheduled run without disabling checkpoints, for a
# deployment that drives `mix kiln.audit.checkpoint` from its own scheduler.
config :kiln_cms, :governance_checkpoint_cron, "40 3 * * *"

# When the external link sweep runs (#474). Safe to leave scheduled everywhere:
# outbound checking is opt-in per site, so with nobody opted in this reads one
# settings row per org and stops. Nightly, and offset from the checkpoint run so
# two per-org sweeps don't start in the same minute. `false` disables the
# schedule for a deployment that drives `KilnCMS.Links.Sweep.run/0` itself.
config :kiln_cms, :link_check_cron, "20 4 * * *"

# When the task due-soon/overdue digest runs (#501): groups each org's open
# tasks due today-or-earlier or within the next few days by assignee and
# sends one email per assignee. Mornings, so the digest is waiting when an
# editor starts their day rather than landing overnight. `false` disables the
# schedule for a deployment that drives its own equivalent.
config :kiln_cms, :task_digest_cron, "0 8 * * *"

# Enterprise SSO via OpenID Connect (#331). Compile-time gate (like
# :registration_enabled's route conditional): `enabled: false` (default) means
# no SSO strategy is compiled — no sign-in button, no OAuth routes, zero
# surface. To enable: set `enabled: true` here (or in a deploy overlay),
# recompile, and provide OIDC_CLIENT_ID / OIDC_CLIENT_SECRET / OIDC_ISSUER /
# OIDC_REDIRECT_URI at runtime (read in runtime.exs). See docs/sso.md.
config :kiln_cms, :sso_oidc, enabled: false

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

# How many days of daily content-view buckets (KilnCMS.Analytics.ContentViewDay)
# are retained before the nightly AshOban `purge_expired` trigger deletes them.
# A bucket is (content type, id, UTC day, count) with no visitor data at all, so
# unlike search queries this is a capacity limit rather than a privacy one; a
# year-plus keeps year-over-year comparisons resolvable (#45).
config :kiln_cms, :view_analytics, retention_days: 400

# Referrer attribution (KilnCMS.Analytics.ReferrerDay, #619) — off by default.
# Runtime-readable (`Application.get_env/3`, not `compile_env`): set
# KILN_ANALYTICS_REFERRERS=true to enable without a rebuild. See
# config/runtime.exs and docs/environment-variables.md.
config :kiln_cms, :analytics_referrers, enabled: false

config :ash_graphql, authorize_update_destroy_with_error?: true

# GraphQL subscriptions (real-time headless): the DSL is opt-in while beta.
# Fields are declared per content resource (see KilnCMS.CMS.Content).
config :ash_graphql, :subscriptions, true

# `audio/mp4` and `text/vtt` are absent from the `mime` package's table (#494),
# and two things break without them: `allow_upload`'s `accept: ~w(.m4a .vtt)`
# refuses to compile an extension it can't resolve to a type, and
# `KilnCMS.Storage.S3` sets each object's stored `Content-Type` from
# `MIME.from_path/1` — an `.m4a` would go up as `application/octet-stream` and
# come back down as a file no browser will play.
#
# Note for anyone changing this: the `mime` package reads its config at COMPILE
# time, so an edit here needs `mix deps.clean mime --build` to take effect.
config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{
    "application/vnd.api+json" => ["json"],
    "audio/mp4" => ["m4a"],
    "text/vtt" => ["vtt"]
  }

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
  # `root_layout` so error pages carry the same `<html>`/`<head>` shell —
  # app.css, brand tokens, favicon, title — as an ordinary page (#681). Without
  # it, a `NoRouteError` 404 or a 500 rendered by the endpoint's error renderer
  # shipped the branded markup as raw unstyled HTML, while a `/:slug` 404 (an
  # ordinary controller render through the `:browser` pipeline) came back fully
  # styled — two 404s on one site that looked nothing alike. `layout: false`
  # stays: the error templates supply their own inner `Layouts.public` chrome,
  # so only the root shell is missing. The root layout's CSRF `<meta>` is now
  # resolved through `Layouts.csrf_token/0`, which fails safe, so an error
  # rendered from a conn outside the normal pipeline still renders the shell
  # instead of risking a second failure inside the handler.
  render_errors: [
    formats: [html: KilnCMSWeb.ErrorHTML, json: KilnCMSWeb.ErrorJSON],
    layout: false,
    root_layout: {KilnCMSWeb.Layouts, :root}
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
#
# `enabled`, `signing_key` and `retired_keys` are ALSO settable from the
# environment — KILN_PROVENANCE_ENABLED / _KEY_FILE / _RETIRED_KEY_FILES in
# runtime.exs (#608) — so a released image can turn provenance on, mount a key
# and register a rotated-out key without a rebuild. Values set there override
# the defaults below.
config :kiln_cms, KilnCMS.Provenance,
  enabled: false,
  # Human-readable signer identity; defaults to :site_name when unset.
  signer: nil,
  # Origin URL recorded in the claim; defaults to :public_base_url when unset.
  origin: nil,
  # Default AI disclosure when a document doesn't set custom_fields["ai_disclosure"]:
  # :human | :ai_assisted | :ai_generated.
  ai_disclosure: :human,
  signing_key: {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}},
  # Keys that no longer sign but must still VERIFY: manifests and history
  # anchors (#356) record the key that signed them, so without this a rotation
  # would blind everything signed before it. Register the retired key's
  # **public half** — that is all verification needs, so the old private key
  # can be destroyed. Same provider tuples as `signing_key`, or a raw PEM.
  #   retired_keys: [{:file, %{"path" => "/etc/kiln/keys/2025.pub.pem"}}]
  #
  # This is the key to use HERE. KILN_PROVENANCE_RETIRED_KEY_FILES writes a
  # separate `:retired_key_files` (bare paths) that KeyRegistry.retired/0 unions
  # with this one, so the env var can only ADD verification keys — it is a second
  # key because Config deep-merges keyword lists and a list of `{:file, %{…}}`
  # tuples is one, so a runtime write to :retired_keys would Keyword.merge into
  # this list and silently drop its :file entries. Do not set :retired_key_files
  # here: it has one writer (runtime.exs) and a runtime write REPLACES it.
  retired_keys: []

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
