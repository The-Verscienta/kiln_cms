import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.
#
# ## Boolean environment variables
#
# All eight on/off variables below go through `KilnCMS.Config.Env` — one
# parser, one set of accepted spellings, one rule for a value it cannot read
# (#607). Do not hand-roll an eighth: matching the raw value is how
# `DATABASE_SSL=True` came to silently disable Postgres TLS (#606) and
# `VISUAL_EDITING_ENABLED=False` came to leave the bridge on.
#
#   * trimmed and downcased, so `TRUE`, `On` and `" true "` all work
#   * `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off` are recognized
#   * anything else is never interpreted: it keeps the default and warns, so a
#     typo can flip nothing in either direction
#
# `Env.flag/2` returns a boolean; `Env.fetch/1` distinguishes "unset" from
# "explicitly false" for the flags that must only override config when the
# operator actually set them. See the moduledoc for the per-flag caveats — this
# fails to the *default*, which is only the safe side when the default is.
alias KilnCMS.Config.Env

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kiln_cms start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
#
# `truthy?/1`, not `flag/2`: this is the one variable documented as "any truthy
# value", so a blank or unrecognized value must keep starting the server exactly
# as the generator's bare `if System.get_env(...)` did. It is also the one
# variable the generator's form got wrong in the dangerous direction —
# `PHX_SERVER=false` started the server anyway, because every string is truthy
# in Elixir. Nothing catches that: the release boots, runs migrations, answers
# `bin/kiln_cms rpc`, so the Docker healthcheck stays green, and it serves no
# HTTP at all.
if Env.truthy?("PHX_SERVER") do
  config :kiln_cms, KilnCMSWeb.Endpoint, server: true
end

config :kiln_cms, KilnCMSWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Extra origins allowed in the browser CSP's `img-src` (space-separated), for
# media libraries whose files serve from an external CDN — e.g.
# CSP_IMG_SRC="https://imagedelivery.net" for Cloudflare Images. Overrides any
# `:csp_img_src` default from a project overlay.
if csp_img_src = System.get_env("CSP_IMG_SRC") do
  config :kiln_cms, :csp_img_src, String.split(csp_img_src)
end

# Unsplash media-library integration — the Unsplash tab appears in the media
# library whenever an access key is configured.
if unsplash_key = System.get_env("UNSPLASH_ACCESS_KEY") do
  config :kiln_cms, :unsplash, access_key: unsplash_key
end

# Environment indicator (#469) — a strip across the top of the console naming
# this deployment. Read in EVERY environment, not just prod: a scrubbed staging
# clone is a byte-for-byte copy of production's content and branding, so the two
# consoles are visually identical, and a developer running against a copy of
# prod data wants the same warning.
#
# Absent means no strip, so **production stays clean by default** — it is the
# environment you recognise by the absence of a label, and the one where nothing
# has to be configured for that to be true. KILN_ENV_COLOR names a design-kit
# tone (see `KilnCMS.Environment`), never a hex.
#
# Guarded on the label being present, like CSP_IMG_SRC above: `Config`
# deep-merges keyword lists, so an unconditional `label: nil` would overwrite a
# project overlay's own `config :kiln_cms, :environment` — silently, and only in
# the deployment that had bothered to set one.
#
# Skipped in `:test` for the reason EMBED_ORIGINS is: this one injects markup
# into every rendered console page, so a developer with KILN_ENV_LABEL exported
# would get different HTML from CI on identical code.
if config_env() != :test do
  if env_label = System.get_env("KILN_ENV_LABEL") do
    config :kiln_cms, :environment,
      label: env_label,
      tone: System.get_env("KILN_ENV_COLOR")
  end
end

# ## Error tracking (Sentry)
#
# Enabled — in any environment — only when SENTRY_DSN is set. With no DSN every
# Sentry capture is a no-op, so dev/test/CI stay offline. The logger handler that
# turns crashes into Sentry events is attached in KilnCMS.Application only when a
# DSN is present.
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: System.get_env("SENTRY_ENV") || to_string(config_env()),
    # Tag events with the running release version when available (set by the
    # release runtime), so regressions can be pinned to a deploy.
    release: System.get_env("RELEASE_VSN")
end

# ## Distributed tracing (OpenTelemetry)
#
# Enabled only when an OTLP collector endpoint is configured. Flips the flag
# KilnCMS.Application reads to attach the Phoenix/Ecto/Bandit/Oban
# instrumentation, and points the OTLP exporter at the collector. Honors the
# standard OTEL_* env vars (OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_PROTOCOL,
# OTEL_EXPORTER_OTLP_HEADERS) for the rest.
if otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :kiln_cms, :otel_enabled, true

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp,
    resource: %{service: %{name: System.get_env("OTEL_SERVICE_NAME") || "kiln_cms"}}

  config :opentelemetry_exporter,
    otlp_protocol:
      "OTEL_EXPORTER_OTLP_PROTOCOL" |> System.get_env("http_protobuf") |> String.to_atom(),
    otlp_endpoint: otlp_endpoint
end

# ## Cross-origin (CORS) for the headless API surfaces
#
# Set CORS_ORIGINS to allow browser clients from other origins to read
# `/api/*` and `/gql` (comma-separated allowlist, or `*` to echo any origin).
# Only overrides the per-env default when the var is present, so dev keeps its
# permissive default and prod stays same-origin-only (`[]`) unless configured.
# See KilnCMSWeb.CORS.
if cors_origins = System.get_env("CORS_ORIGINS") do
  config :kiln_cms, :cors_origins, KilnCMSWeb.CORS.parse_env(cors_origins)
end

# ## Embeddable forms — which parents may iframe `/forms/:slug/embed`
#
# Defaults to same-origin only (#562): cross-site embedding is OFF until you set
# EMBED_ORIGINS to your allowlist, e.g. `https://acme.com,https://blog.acme.com`.
# `*` re-opens it to any site — the old default, and a clickjacking surface,
# since form submission is deliberately CSRF-free. See KilnCMSWeb.Embed. Skipped
# in test so the suite never depends on what is exported in a developer's shell.
if config_env() != :test do
  if embed_origins = System.get_env("EMBED_ORIGINS") do
    config :kiln_cms, :embed_origins, KilnCMSWeb.Embed.parse_env(embed_origins)
  end
end

# ## Reading time (#492) — words per minute for `reading_time_minutes`
#
# 230 is the usual mid-range figure for adult silent reading of English prose.
# An unparseable or non-positive value keeps the default and warns rather than
# being interpreted — see KilnCMS.CMS.Calculations.ReadingTime. A release only
# evaluates this file, so without this block the documented config key would be
# unreachable on a Docker deployment.
if wpm = System.get_env("KILN_READING_TIME_WPM") do
  case Integer.parse(String.trim(wpm)) do
    {parsed, ""} when parsed > 0 ->
      config :kiln_cms, :reading_time_wpm, parsed

    _ ->
      IO.warn(
        "KILN_READING_TIME_WPM must be a positive integer (got #{inspect(wpm)}); " <>
          "keeping the default.",
        []
      )
  end
end

# ## Visual-editing bridge (#355) — the annotated preview read + `/bridge.js`
#
# Enabled by default. Set VISUAL_EDITING_ENABLED=false to switch the whole
# surface off (the annotated `/api/visual-editing/...` route 404s). Which origins
# may fetch it cross-origin and round-trip writes is governed by CORS_ORIGINS
# (the annotated read and the write API both live under `/api`); draft visibility
# is governed by the caller's API key. See KilnCMS.VisualEditing.
#
# Only a recognized spelling writes config, so an unset var keeps the compiled
# default (or a project overlay's). See the header for the spellings.
with {:ok, enabled?} <- Env.fetch("VISUAL_EDITING_ENABLED") do
  config :kiln_cms, :visual_editing_enabled, enabled?
end

# ## Tamper-evident history — master kill switch (#356, #611)
#
# `:audit_anchors_enabled` gates BOTH publish-time anchor minting AND the
# `:audit_anchor_every_write` extension below — `Chain.extend/2` requires
# both, so `KILN_AUDIT_ANCHOR_EVERY_WRITE=true` was a complete no-op whenever
# this stayed off with no runtime override to recover it, contradicting its
# documented status (docs/deploy-p3.md) as an operator-facing kill switch
# reversible without a rebuild.
#
# Compiled default is `true` (anchoring on unless an operator turns it off),
# so an unrecognized value keeps history signed — the safe side, opposite of
# `KILN_AUDIT_ANCHOR_EVERY_WRITE`'s.
#
# Skipped under :test for the same reason as KILN_AUDIT_ANCHOR_EVERY_WRITE.
if config_env() != :test do
  with {:ok, enabled?} <- Env.fetch("KILN_AUDIT_ANCHORS_ENABLED") do
    config :kiln_cms, :audit_anchors_enabled, enabled?
  end
end

# ## Tamper-evident history — anchor every write (#356)
#
# Anchors are always minted at publish. This additionally extends the signed
# chain after *every* versioned write, closing the window between two publishes
# — #356's "sign every version, not just published artifacts". It costs a
# signature and a `history_anchors` row per save, AND it disables autosave
# coalescing (#671), so a draft keeps one version row per debounce. Hence false.
#
# Runtime rather than compile-time on purpose — an operator must be able to turn
# this off without rebuilding the image. See KilnCMS.Governance.Chain and
# docs/editorial-consent.md.
#
# Only RECOGNIZED spellings write config: an unrecognized value (`enabled`, a
# typo, a quote-wrapped `"true"` from `docker run --env-file`) leaves the
# compiled default alone and warns, rather than disabling an audit trail the
# deployment deliberately turned on. Note the compiled default here is `false`,
# so the warning is also the only signal that a typo failed to turn signing ON.
#
# Skipped under :test so the suite is deterministic regardless of the developer's
# environment — the flag causes a DB write per save, and the governance tests
# drive it explicitly with Application.put_env instead.
if config_env() != :test do
  with {:ok, every_write?} <- Env.fetch("KILN_AUDIT_ANCHOR_EVERY_WRITE") do
    config :kiln_cms, :audit_anchor_every_write, every_write?
  end
end

# ## Governance checkpoint witness (#666)
#
# Where the org-wide anchor-chain commitment gets published. Runtime rather than
# compile time because it is the one knob that decides whether the truncation
# guarantee holds against an attacker with full database access, and an operator
# must be able to point it at a bucket without rebuilding the image.
#
# An unrecognized value leaves the compiled default (`none`) rather than
# guessing. That is the *weaker* side, so it is warned about explicitly here
# rather than left to `Env`'s generic stderr line — see KilnCMS.Config.Env on
# why "fail to default" is not "fail safe".
#
# Skipped under :test so the suite does not depend on the developer's shell; the
# checkpoint tests set the adapter explicitly.
if config_env() != :test do
  witness =
    case System.get_env("KILN_GOVERNANCE_WITNESS") do
      nil ->
        nil

      value ->
        case value |> String.trim() |> String.downcase() do
          "" ->
            nil

          "none" ->
            KilnCMS.Governance.Witness.None

          "file" ->
            KilnCMS.Governance.Witness.File

          "s3" ->
            KilnCMS.Governance.Witness.S3

          other ->
            # ASCII only: config providers write to stderr before Logger exists,
            # and non-ASCII comes back escaped in exactly the line an operator
            # needs to read.
            IO.puts(
              :standard_error,
              "KILN_GOVERNANCE_WITNESS=#{inspect(other)} is not one of none|file|s3 - " <>
                "governance checkpoints will NOT be published outside the database, " <>
                "which is the weaker side of the default. See #666."
            )

            nil
        end
    end

  if witness do
    config :kiln_cms, KilnCMS.Governance.Witness, adapter: witness
  end

  if dir = System.get_env("KILN_GOVERNANCE_WITNESS_DIR") do
    config :kiln_cms, KilnCMS.Governance.Witness.File, dir: dir
  end

  if bucket = System.get_env("KILN_GOVERNANCE_WITNESS_BUCKET") do
    config :kiln_cms, KilnCMS.Governance.Witness.S3,
      bucket: bucket,
      prefix: System.get_env("KILN_GOVERNANCE_WITNESS_PREFIX", "")
  end

  # How often the commitment is refreshed. The exposure window for a truncated
  # chain is one interval wide, so a regulated deployment shortens this
  # ("0 * * * *" for hourly) rather than leaving the nightly default.
  #
  # A plain `:kiln_cms` key rather than a reach into `Oban`'s nested plugin
  # keyword list: `Config` deep-merges those, and overriding one entry of one
  # plugin tuple from here is the #608 shape. `KilnCMS.Application.oban_config/0`
  # assembles the crontab from this.
  if cron = System.get_env("KILN_GOVERNANCE_CHECKPOINT_CRON") do
    config :kiln_cms, :governance_checkpoint_cron, cron
  end
end

# ## Outbound link checking (#474)
#
# When the sweep runs, and who it says it is. Both are safe to leave alone:
# checking is opt-in per site, so an unconfigured deployment makes no outbound
# requests at all. The user-agent is worth setting on a public site — it is what
# an operator on the receiving end reads before deciding whether to block you,
# and a contact URL of your own beats Kiln's.
if cron = System.get_env("KILN_LINK_CHECK_CRON") do
  config :kiln_cms, :link_check_cron, cron
end

# ## Editorial tasks (#501)
#
# When the due-soon/overdue digest email runs. Safe to leave scheduled
# everywhere: with no tasks assigned in any org, the sweep enqueues nothing.
if cron = System.get_env("KILN_TASK_DIGEST_CRON") do
  config :kiln_cms, :task_digest_cron, cron
end

if user_agent = System.get_env("KILN_LINK_CHECK_USER_AGENT") do
  config :kiln_cms, KilnCMS.Links.External, user_agent: user_agent
end

# ## Signed provenance / C2PA-style content manifests (#340)
#
# `KilnCMS.Provenance` was configured in `config/config.exs` alone, which is
# compile time — so on a prebuilt image the only settable knob was the default
# `KILN_PROVENANCE_PRIVATE_KEY` binding, and `enabled`, a file-mounted signing
# key and `retired_keys` all needed a source edit and a rebuild (#608). Each of
# those is something the docs tell operators to do, so each gets a var here.
#
# Skipped under :test for the same reason as KILN_AUDIT_ANCHOR_EVERY_WRITE
# above: whether provenance is on decides between a 404 and a signed manifest on
# every /api/provenance/* route, and the suite must not depend on what happens
# to be exported in the developer's shell. The provenance tests drive the config
# explicitly instead.
if config_env() != :test do
  # Whether manifests are produced at all. The compiled default is `false` and
  # there was no runtime override, so every /api/provenance/* route 404s on a
  # released image no matter what key the operator configures — they set the
  # key, get signed anchors, and then get a 404 from the endpoint the docs point
  # them at, with nothing to change.
  #
  # `Env.fetch/1` rather than a sixth bespoke parser (#607): unset and
  # unrecognized both leave the compiled default alone, which matters in both
  # directions here — a deployment publishing manifests to consumers must not
  # stop because someone wrote `On`, and one that has never enabled provenance
  # must not start signing because of a typo.
  with {:ok, provenance?} <- Env.fetch("KILN_PROVENANCE_ENABLED") do
    config :kiln_cms, KilnCMS.Provenance, enabled: provenance?
  end

  # ActivityPub federation (#491). The deployment-wide half of a two-part gate:
  # off here means every federation route 404s regardless of what any tenant
  # admin has enabled. Federation makes this server sign and POST to hosts
  # chosen by strangers who followed the site, so an operator whose egress
  # policy forbids that must be able to say so once, centrally.
  #
  # `Env.fetch/1` for the same reason as above (#607): unset and unrecognized
  # both leave the compiled default (off) alone.
  with {:ok, federation?} <- Env.fetch("KILN_FEDERATION_ENABLED") do
    config :kiln_cms, KilnCMS.Federation, enabled: federation?
  end

  # Mount the signing key as a file instead of exporting it. The key is a
  # multi-line PKCS#1 PEM and most .env parsers (docker-compose included) do not
  # carry embedded newlines, so a file is the route .env.example already
  # recommends — it just had no way to say so without editing config.
  #
  # Overrides the compiled `{:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}`
  # default when set, so an operator migrating from the env var can mount the
  # file first and unset the var afterwards.
  provenance_key_file = "KILN_PROVENANCE_KEY_FILE" |> System.get_env("") |> String.trim()

  if provenance_key_file != "" do
    config :kiln_cms, KilnCMS.Provenance, signing_key: {:file, %{"path" => provenance_key_file}}
  end

  # Public halves of keys that no longer sign but must still VERIFY — a
  # comma-separated list of PEM paths. Manifests (#340) and history anchors
  # (#356) record the key_id that signed them, so without this a rotation blinds
  # everything signed before it, and the outgoing private half cannot safely be
  # destroyed.
  #
  # Writes :retired_key_files (paths), NOT :retired_keys (provider tuples), and
  # KeyRegistry.retired/0 unions the two. A list of `{:file, %{…}}` tuples is a
  # keyword list, and Config deep-merges keyword lists — so writing :retired_keys
  # here would Keyword.merge into any :retired_keys set in source and silently
  # delete every :file entry already there. Losing a verification key is the one
  # outcome this must never produce. :retired_key_files is the runtime channel
  # and this is its only writer; source config belongs in :retired_keys.
  # See KilnCMS.Provenance.KeyRegistry.
  #
  # A value that parses to NO paths warns and writes nothing rather than writing
  # `[]`. `KILN_PROVENANCE_RETIRED_KEY_FILES=","` — or a shell expanding an unset
  # variable into a bare separator — otherwise clears the list, and silently
  # deregistering every retired key is precisely the failure this feature exists
  # to prevent.
  retired_key_files =
    "KILN_PROVENANCE_RETIRED_KEY_FILES" |> System.get_env("") |> String.trim()

  case KilnCMS.Provenance.parse_key_files(retired_key_files) do
    [] when retired_key_files != "" ->
      IO.warn("""
      KILN_PROVENANCE_RETIRED_KEY_FILES is set to #{inspect(retired_key_files)}, \
      which contains no paths; keeping the configured default. Expected a \
      comma-separated list of PEM file paths.\
      """)

    [] ->
      :ok

    paths ->
      config :kiln_cms, KilnCMS.Provenance, retired_key_files: paths
  end
end

# ## Presentation console (#355) — where the external front end serves content
#
# The Kiln-hosted side-by-side editing console iframes the external front end.
# Kiln doesn't render that front end, so point it here — a URL template with
# `{path}`/`{type}`/`{slug}`/`{locale}` placeholders (a bare base URL gets
# `{path}` appended). Unset ⇒ the console shows a setup hint. The origin is
# derived from this for `postMessage` validation. See `KilnCMSWeb.Presentation`.
if preview_url = System.get_env("PRESENTATION_PREVIEW_URL") do
  config :kiln_cms, :presentation_preview_url, preview_url
end

# ## Upstream update check
#
# The admin update page asks GitHub whether a newer Kiln release exists. The
# request carries a bare `KilnCMS` user-agent with no version and no instance
# identifier, so it discloses nothing about this deployment beyond its IP. It
# is made only when an admin opens the page, and results are cached (24h for a
# comparison, 15 minutes for a failure), so an outage cannot turn page loads
# into a request stream.
#
# This is the only outbound integration that is on by default — the others all
# need a credential, so leaving it unset implicitly disables them. Set
# KILN_UPDATE_CHECK=false for an instance that must make no third-party
# requests at all; the page then reports the running version and the update
# command without the comparison. See `Kiln.Updates`.
#
# Accepted spellings are the shared ones (see the header): an operator who set
# this because they need *no* egress must not be defeated by `Off` or `FALSE`.
#
# An explicit on-spelling now writes `enabled: true` as well, where this used to
# write only on the off path. That is deliberate — it lets an operator re-enable
# the check against a build whose compiled config turned it off (`config/e2e.exs`
# does exactly that) without a rebuild.
with {:ok, enabled?} <- Env.fetch("KILN_UPDATE_CHECK") do
  config :kiln_cms, Kiln.Updates, enabled: enabled?
end

# Where this project keeps its pinned Kiln checkout, relative to the project
# repo root — `kiln/upstream`, `upstream`, whatever the layout uses. Purely
# cosmetic: the admin page prefixes the update command with a matching `cd`.
#
# Unset by default rather than guessed. The pin is a submodule *or* a fetched
# ref at a path the project chooses (see projects/README.md), so a default
# would be a wrong, copy-pasteable `cd` baked into the image for everyone on a
# different layout. Left unset, the page just says to run it from the Kiln
# checkout.
pin_path = "KILN_PIN_PATH" |> System.get_env("") |> String.trim()

if pin_path != "" do
  config :kiln_cms, Kiln.Updates, pin_path: pin_path
end

# Which repo this build compares itself against. `The-Verscienta/kiln_cms` is
# the default because an unmodified install genuinely is that repo — but a fork
# that keeps the default is told about someone else's releases, and the failure
# is silent in the dangerous direction: a fork *ahead* of upstream compares as
# newer, so the page reports "Up to date" forever and the fork's own security
# releases never surface.
#
# KILN_UPDATE_RELEASES_URL additionally repoints the API endpoint, for GitHub
# Enterprise or an internal mirror — installs that can't reach api.github.com
# at all and would otherwise be stuck in a permanent error state. It overrides
# the endpoint only, so set KILN_UPDATE_REPO alongside it. See `Kiln.Updates`.
update_repo = "KILN_UPDATE_REPO" |> System.get_env("") |> String.trim()

if update_repo != "" do
  config :kiln_cms, Kiln.Updates, repo: update_repo
end

releases_url = "KILN_UPDATE_RELEASES_URL" |> System.get_env("") |> String.trim()

if releases_url != "" do
  config :kiln_cms, Kiln.Updates, releases_url: releases_url
end

# ## Referrer attribution (#619, phase 2 of docs/advanced-analytics-plan.md)
#
# Off by default. This gate is a plain operator switch (unlike
# `:view_analytics`'s `retention_days`, which is baked into an AshOban `where`
# expression and stays `compile_env`), so it must be — and is — readable at
# runtime: `KilnCMS.Analytics.referrers_enabled?/0` calls
# `Application.get_env/3`, never `compile_env`. See #608 for the defect class
# this avoids.
#
# Only a recognized spelling writes config, so an unset var keeps the
# compiled `false` default. See the header for the accepted spellings.
with {:ok, enabled?} <- Env.fetch("KILN_ANALYTICS_REFERRERS") do
  config :kiln_cms, :analytics_referrers, enabled: enabled?
end

# ## Low-count suppression threshold (#620, phase 3 of docs/advanced-analytics-plan.md)
#
# A referrer category's hit count below this renders — in the dashboard and
# the export — as "< n" rather than an exact number, because a single-digit
# bucket can describe one visitor's arrival (design doc, "Where 'aggregate'
# gets thin: low counts"). Runtime-readable for the same reason as the gate
# above: an operator tightening or loosening this must not need a rebuild.
# `KilnCMS.Config.Env` only parses booleans, so this is a plain integer parse
# in the same shape as `KILN_READING_TIME_WPM` above — an unparseable or
# non-positive value keeps the default and warns rather than being
# interpreted (e.g. silently disabling suppression at threshold 0).
#
# This `config` call deep-merges with the `enabled:` one above (`Config`
# merges successive calls for the same key rather than overwriting), so both
# land in the same `:analytics_referrers` keyword list — see #608 for why
# that merge behavior matters here and can also bite.
if threshold = System.get_env("KILN_ANALYTICS_LOW_COUNT_THRESHOLD") do
  case Integer.parse(String.trim(threshold)) do
    {parsed, ""} when parsed > 0 ->
      config :kiln_cms, :analytics_referrers, low_count_threshold: parsed

    _ ->
      IO.warn(
        "KILN_ANALYTICS_LOW_COUNT_THRESHOLD must be a positive integer " <>
          "(got #{inspect(threshold)}); keeping the default.",
        []
      )
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if Env.flag("ECTO_IPV6", false), do: [:inet6], else: []

  # Encrypt the Postgres connection by default. Set DATABASE_SSL=false only for a
  # provider that genuinely cannot offer TLS (most managed Postgres — RDS,
  # Supabase, Neon, Fly — require or strongly prefer it). When DATABASE_SSL_CACERTFILE
  # points at the provider's CA bundle we verify the server certificate; otherwise
  # we still encrypt but skip peer verification (verify_none) so deployment isn't
  # blocked on cert plumbing.
  #
  # This is the #606 site the header refers to. Only an explicit off-spelling
  # disables TLS now; anything unreadable keeps it on.
  database_ssl? = Env.flag("DATABASE_SSL", true)

  # A blank value counts as unset, like every flag above. Matching only `nil`
  # sent `DATABASE_SSL_CACERTFILE=` — a routine .env/compose artifact — to the
  # verify_peer branch with an empty path; :ssl then fails to read the bundle
  # and every connection dies at boot, which is the opposite of the fallback
  # this case exists to provide.
  database_ssl_opts =
    case String.trim(System.get_env("DATABASE_SSL_CACERTFILE", "")) do
      "" ->
        [verify: :verify_none]

      cacertfile ->
        [verify: :verify_peer, cacertfile: cacertfile, depth: 3]
    end

  config :kiln_cms,
         KilnCMS.Repo,
         [
           url: database_url,
           # Shared by web requests and Oban workers (~34 concurrent across the
           # split queues) — size up from 10 in production. See the pool-sizing
           # formula in docs/performance.md.
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
           # For machines with several cores, consider starting multiple pools of `pool_size`
           # pool_count: 4,
           socket_options: maybe_ipv6,
           ssl: database_ssl?
         ] ++ if(database_ssl?, do: [ssl_opts: database_ssl_opts], else: [])

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # PHX_HOST is meant to be a bare host (e.g. "be.verscienta.com"), but is
  # easy to misconfigure as a full URL. Strip any scheme/trailing slash so a
  # `https://host` value doesn't get baked into the Endpoint's `url: [host:
  # ...]` — Phoenix uses that host as-is (not re-parsed) both for generating
  # absolute URLs and for validating the LiveView/channel socket's Origin
  # header (check_origin), so a raw scheme prefix silently breaks both.
  host =
    (System.get_env("PHX_HOST") || "example.com")
    |> String.replace_leading("https://", "")
    |> String.replace_leading("http://", "")
    |> String.trim_trailing("/")

  # CHECK_ORIGINS: comma-separated allowlist of extra origins permitted to
  # open LiveView/channel sockets, for when the app is reachable on more than
  # one hostname (e.g. mid domain migration). Entries may be full origins
  # ("https://cms.example.com"), scheme-less ("//cms.example.com" — any
  # scheme/port), or bare hosts (normalized to "//host"). The PHX_HOST origin
  # is always kept, so this can only widen the allowlist. Unset ⇒ Phoenix's
  # default: sockets are only accepted from the PHX_HOST origin.
  extra_origins =
    "CHECK_ORIGINS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn origin ->
      origin = String.trim_trailing(origin, "/")

      if String.starts_with?(origin, ["https://", "http://", "//"]) do
        origin
      else
        "//" <> origin
      end
    end)

  # Accept sockets from the canonical host AND any of its subdomains — multi-tenant
  # sites are served at `<org>.<host>` (epic #336), so a per-org LiveView/channel
  # would otherwise fail the Origin check. `//*.host` matches any scheme/port. The
  # explicit list (not `true`) is required for the wildcard; `CHECK_ORIGINS` still
  # widens it (e.g. a custom domain mid-migration).
  #
  # The wildcard covers every subdomain of the base host, registered as an org or
  # not, so passing it says nothing about WHICH org a socket may act as. That is
  # each socket's own tenant resolution (#654) — every one of the four resolves
  # from the host it connected on, whatever origin admitted it.
  check_origin = ["https://" <> host, "//*." <> host | extra_origins]

  config :kiln_cms, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Trusted reverse-proxy CIDRs. When set (comma-separated, e.g.
  # "10.0.0.0/8,172.16.0.0/12"), KilnCMSWeb.Plugs.ClientIp rewrites remote_ip from
  # X-Forwarded-For so rate limiting keys on the real client. Leave unset when the
  # app is internet-facing directly (X-Forwarded-For would be spoofable).
  # Entries are trimmed, matching CHECK_ORIGINS above: `split(trim: true)` drops
  # empty segments but not whitespace, so `10.0.0.0/8, 172.16.0.0/12` (a space
  # after the comma) or a trailing newline from a mounted secret file would reach
  # `RemoteIp.init/1` as a malformed CIDR — which raises.
  config :kiln_cms,
         :trusted_proxies,
         "TRUSTED_PROXIES"
         |> System.get_env("")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))

  # The base host multi-tenant subdomains are carved from (epic #336): a request
  # to `<org>.<TENANT_BASE_HOST>` resolves to that org. Defaults to PHX_HOST — set
  # it explicitly only if tenant subdomains live under a different apex than the
  # canonical URL host.
  config :kiln_cms, :tenant_base_host, System.get_env("TENANT_BASE_HOST") || host

  # Reject requests whose Host matches no organization instead of serving them
  # the default org (#563). Recommended for any multi-tenant deployment; leave
  # off for a single-host install, where the bare host / an IP / the load
  # balancer's health-check Host all legitimately arrive unmatched and would
  # start 404ing.
  #
  # `fetch/1`, not `flag/2`: this must only OVERRIDE config when the operator
  # actually set the variable. `flag/2` writes unconditionally, so an unset
  # variable would rewrite a project overlay's `config :kiln_cms,
  # :tenant_strict_host, true` back to false — silently, in production, on the
  # multi-org deployment most likely to have set it. See `KilnCMS.Config.Env`.
  with {:ok, strict_host?} <- KilnCMS.Config.Env.fetch("TENANT_STRICT_HOST") do
    config :kiln_cms, :tenant_strict_host, strict_host?
  end

  # API documentation surface — the OpenAPI document and the Swagger explorer
  # (#567). Off in a production build; an operator publishing a public API
  # turns it back on here. `fetch/1` rather than `flag/2` for the reason above:
  # an unset variable must not rewrite a project overlay's own setting.
  with {:ok, api_docs?} <- Env.fetch("API_DOCS_ENABLED") do
    config :kiln_cms, :api_docs, api_docs?
  end

  # White-label branding (#48, see `KilnCMS.Branding`) — the instance-wide layer
  # beneath each site's own editor-managed row. Unset vars fall through to the
  # stock KilnCMS defaults. BRAND_PRIMARY_COLOR must be a hex colour (`#1d4ed8`);
  # anything else is ignored with a warning, since the value drives the emitted
  # theme tokens. Off-origin BRAND_LOGO_URL hosts must also be in CSP_IMG_SRC or
  # the browser will block the image.
  config :kiln_cms, :branding,
    site_name: System.get_env("SITE_NAME"),
    logo_url: System.get_env("BRAND_LOGO_URL"),
    favicon_url: System.get_env("BRAND_FAVICON_URL"),
    primary_color: System.get_env("BRAND_PRIMARY_COLOR")

  config :kiln_cms, KilnCMSWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :kiln_cms,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # OIDC SSO settings (#331) — only read when the strategy was compiled in
  # (`config :kiln_cms, :sso_oidc, enabled: true`). OIDC_ISSUER is the
  # provider's base URL (discovery at /.well-known/openid-configuration);
  # OIDC_REDIRECT_URI is this site's callback base, e.g.
  # "https://cms.example.com/auth".
  if Application.get_env(:kiln_cms, :sso_oidc, [])[:enabled] do
    config :kiln_cms, :sso_oidc,
      enabled: true,
      client_id: System.get_env("OIDC_CLIENT_ID"),
      client_secret: System.get_env("OIDC_CLIENT_SECRET"),
      base_url: System.get_env("OIDC_ISSUER"),
      redirect_uri: System.get_env("OIDC_REDIRECT_URI")
  end

  # In-app backups (#484). Every one of these mirrors an environment variable
  # `scripts/backup.sh` already reads, and by the same name — the cron path and
  # the app path are two front doors to one backup directory, and an operator
  # who configured the script should not have to configure this separately.
  #
  # BACKUP_ENABLED=false turns the in-app path off (the panel then explains
  # why) without touching the cron one.

  # Blank counts as UNSET, the convention this file already follows for
  # DATABASE_SSL_CACERTFILE. `MEDIA_DIR=` is a routine `.env`/compose artifact,
  # and reading it as set gave `media_dir: ""` — `File.dir?("")` is false, so
  # every in-app backup failed, while `backup.sh`'s `[ -n … ]` correctly
  # skipped media and succeeded. `BACKUP_DIR=` was worse: `""` is truthy in
  # Elixir, so backups would land in a relative `db/` under the release's cwd.
  backup_env = fn var ->
    case System.get_env(var) do
      nil -> nil
      raw -> if String.trim(raw) == "", do: nil, else: raw
    end
  end

  # `Env.flag/2` handles the boolean (the one shared parser — see this file's
  # header); the counts get a plain `Integer.parse` in the same shape as
  # `KILN_ANALYTICS_LOW_COUNT_THRESHOLD` above, because `Env` parses only
  # booleans. An unparseable or non-positive value keeps the default and warns
  # rather than being interpreted — `BACKUP_KEEP_DAYS=0` read literally would
  # delete every backup it had just taken.
  backup_int = fn var, default ->
    case backup_env.(var) do
      nil ->
        default

      raw ->
        case Integer.parse(String.trim(raw)) do
          {parsed, ""} when parsed > 0 ->
            parsed

          _ ->
            IO.warn("#{var} must be a positive integer — keeping the default of #{default}")
            default
        end
    end
  end

  backup_opts =
    [
      enabled: Env.flag("BACKUP_ENABLED", true),
      dir: backup_env.("BACKUP_DIR") || "/var/backups/kiln",
      keep_days: backup_int.("BACKUP_KEEP_DAYS", 14),
      stale_after_hours: backup_int.("BACKUP_STALE_AFTER_HOURS", 36)
    ]

  # Same variable the script uses, so the app path copies off-site too — a
  # backup that exists only on the machine being backed up is not a backup of
  # that machine.
  backup_opts =
    case backup_env.("BACKUP_RCLONE_REMOTE") do
      nil -> backup_opts
      remote -> Keyword.put(backup_opts, :rclone_remote, remote)
    end

  # Escape hatch for a connection `KilnCMS.Backups.database_url/0` can't
  # derive — a unix-socket repo, or one whose `DATABASE_URL` reaches the
  # database through something `pg_dump` can't use. Ordinary deployments never
  # set it: `DATABASE_URL` is already the first thing consulted.
  backup_opts =
    case backup_env.("BACKUP_DATABASE_URL") do
      nil -> backup_opts
      url -> Keyword.put(backup_opts, :database_url, url)
    end

  # Unset on an S3 deployment, deliberately — the bucket is backed up
  # provider-side, and tarring the wrong directory yields an archive that
  # looks like a media backup and restores nothing.
  backup_opts =
    case backup_env.("MEDIA_DIR") do
      nil -> backup_opts
      media_dir -> Keyword.put(backup_opts, :media_dir, media_dir)
    end

  config :kiln_cms, KilnCMS.Backups, backup_opts

  # ## Object storage (S3-compatible)
  #
  # Opt into the S3 adapter by setting S3_BUCKET. Works with AWS S3, Cloudflare
  # R2, Backblaze B2, Wasabi, MinIO, etc. For any non-AWS provider, also set
  # S3_ENDPOINT_HOST (see KilnCMS.Storage.S3 docs for per-provider hosts).
  if bucket = System.get_env("S3_BUCKET") do
    config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3

    s3_opts =
      [
        bucket: bucket,
        public_base_url:
          System.get_env("S3_PUBLIC_BASE_URL") ||
            raise("S3_BUCKET is set but S3_PUBLIC_BASE_URL is missing")
      ]

    # Most buckets are made public at the bucket level; only send a per-object
    # canned ACL (e.g. "public_read") if the provider/bucket needs one.
    s3_opts =
      case System.get_env("S3_ACL") do
        nil -> s3_opts
        acl -> Keyword.put(s3_opts, :acl, String.to_atom(acl))
      end

    # Optional (#481): a SEPARATE bucket for gated documents — this app's own
    # AWS credentials read it directly, so it needs no public-read config, no
    # CDN, and no S3_PUBLIC_BASE_URL equivalent (see KilnCMS.Storage.S3 docs).
    # Without it, gating a document is refused rather than silently falling
    # back to the public bucket.
    s3_opts =
      case System.get_env("S3_PRIVATE_BUCKET") do
        nil -> s3_opts
        private_bucket -> Keyword.put(s3_opts, :private_bucket, private_bucket)
      end

    config :kiln_cms, KilnCMS.Storage.S3, s3_opts

    config :ex_aws,
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      # R2 uses "auto"; B2/Wasabi/AWS use a real region.
      region: System.get_env("AWS_REGION") || "us-east-1"

    # Custom endpoint for any non-AWS S3-compatible store (R2/B2/Wasabi/MinIO).
    # Leave unset for AWS S3 (ExAws derives the host from the region).
    if endpoint_host = System.get_env("S3_ENDPOINT_HOST") do
      config :ex_aws, :s3,
        scheme: System.get_env("S3_ENDPOINT_SCHEME") || "https://",
        host: endpoint_host,
        port: String.to_integer(System.get_env("S3_ENDPOINT_PORT") || "443")
    end
  end

  # ## Meilisearch (optional, Phase 6)
  #
  # Opt into the typo-tolerant search backend by setting MEILI_URL. Leave it
  # unset to keep Postgres full-text search as the only backend. Run
  # `mix kiln.meili.reindex` once after enabling to backfill the index.
  if meili_url = System.get_env("MEILI_URL") do
    config :kiln_cms, KilnCMS.Search.Meilisearch,
      enabled: true,
      url: meili_url,
      master_key: System.get_env("MEILI_MASTER_KEY"),
      index: System.get_env("MEILI_INDEX") || "kiln_content"
  end

  # ## AI-assisted SEO drafting (optional)
  #
  # Opt in by setting SEO_MODEL to a `req_llm` model spec. Leave it unset and
  # the editor's "Suggest" control never renders and nothing leaves the
  # deployment; the deterministic SEO analysis is unaffected either way.
  #
  #     SEO_MODEL=ollama:llama3.1          # on-prem, no egress
  #     SEO_MODEL=anthropic:claude-sonnet-5 # hosted; also needs ANTHROPIC_API_KEY
  #
  # Provider API keys are read by `req_llm` from its own environment variables
  # (ANTHROPIC_API_KEY, OPENAI_API_KEY, …) — Kiln never reads or stores them.
  # SEO_GENERATOR overrides the adapter module for a bespoke implementation.
  if seo_model = System.get_env("SEO_MODEL") do
    seo_generator =
      case System.get_env("SEO_GENERATOR") do
        nil -> KilnCMS.Seo.Generator.ReqLLM
        module -> Module.concat([module])
      end

    config :kiln_cms, KilnCMS.Seo, model: seo_model, generator: seo_generator
  end

  # ## AI block assist in the editor (optional)
  #
  # The body-copy twin of SEO_MODEL, and a deliberately separate switch: this
  # one sends a block's prose *and the editor's typed instruction* on each
  # request, and returns text bound for the page body. Setting SEO_MODEL alone
  # leaves it off; the per-block "AI" control never renders.
  #
  #     ASSIST_MODEL=ollama:llama3.1           # on-prem, no egress
  #     ASSIST_MODEL=anthropic:claude-sonnet-5 # hosted; also needs ANTHROPIC_API_KEY
  #
  # Provider API keys are read by `req_llm` from its own environment variables
  # — Kiln never reads or stores them. ASSIST_GENERATOR overrides the adapter
  # module for a bespoke implementation. See docs/ai-assist.md.
  if assist_model = System.get_env("ASSIST_MODEL") do
    assist_generator =
      case System.get_env("ASSIST_GENERATOR") do
        nil -> KilnCMS.Assist.Generator.ReqLLM
        module -> Module.concat([module])
      end

    config :kiln_cms, KilnCMS.Assist, model: assist_model, generator: assist_generator
  end

  # ## Generated answers for /api/ask (optional)
  #
  # The third AI switch, and the one to think hardest about: `/api/ask` is a
  # **public, anonymous** endpoint. Leave ASK_MODEL unset and it stays what it
  # is by default — retrieval-only, returning cited published passages and
  # `"answer": null` — with nothing leaving the deployment. Set it and a
  # stranger's question causes the retrieved passages to be sent to the model.
  #
  #     ASK_MODEL=ollama:llama3.1           # on-prem, no egress
  #     ASK_MODEL=anthropic:claude-sonnet-5 # hosted; also needs ANTHROPIC_API_KEY
  #
  # Only *published, world-readable* content is ever retrieved — for EVERY
  # caller, bearer token or not (#916). Generation carries its own rate-limit
  # buckets on top of the pipeline's per-IP limiter, keyed on the client address
  # for anonymous callers; an exhausted bucket degrades to retrieval-only rather
  # than refusing the request. Provider API keys are read by `req_llm` from its
  # own environment — Kiln never reads or stores them. ASK_GENERATOR overrides
  # the adapter module. See docs/rag.md.
  if ask_model = System.get_env("ASK_MODEL") do
    ask_generator =
      case System.get_env("ASK_GENERATOR") do
        nil -> KilnCMS.Ask.Generator.ReqLLM
        module -> Module.concat([module])
      end

    config :kiln_cms, KilnCMS.Ask, model: ask_model, generator: ask_generator
  end

  # ### Rich embed cards (#489)
  #
  # `OEMBED_ENABLED=true` lets Kiln fetch oEmbed metadata — title, author,
  # thumbnail — for an embed block's URL, so it renders a card instead of a bare
  # link. **Off by default, and it is egress**: enabling it means the server
  # makes an outbound HTTPS request when an editor saves a document containing
  # an embed whose URL a known provider claims.
  #
  # Requests only ever go to the curated provider endpoints in
  # `KilnCMS.OEmbed.Provider` — never to a URL discovered from content — and
  # through the pinned, size-capped `KilnCMS.SafeFetch`. Provider HTML is
  # discarded; only scalars are stored.
  #
  #     OEMBED_ENABLED=true
  #     OEMBED_PROVIDERS=YouTube,Vimeo   # optional: narrow the shipped list
  #
  # `OEMBED_PROVIDERS` can only *restrict* the built-in list, never extend it —
  # adding a provider is a code change, because it is a host this server will
  # dial. Names are the `name` field of each entry in `KilnCMS.OEmbed.Provider`.
  if KilnCMS.Config.Env.flag("OEMBED_ENABLED", false) do
    providers =
      case System.get_env("OEMBED_PROVIDERS") do
        nil -> nil
        "" -> nil
        list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    config :kiln_cms, KilnCMS.OEmbed, enabled: true, providers: providers
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kiln_cms, KilnCMSWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kiln_cms, KilnCMSWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # config/config.exs defaults to Swoosh.Adapters.Local — a dev-only in-memory
  # mailbox with no delivery, and no supervised storage process outside `mix
  # phx.server`. All outbound email is queued through KilnCMS.Mail onto the
  # Oban :mail queue, so with no real adapter configured in production the
  # triggering requests still succeed but every delivery job fails and retries
  # in Oban (visible in the oban_jobs table / logs) — no email actually leaves.
  #
  # Two real-delivery modes (docs/direct-email-delivery-plan.md):
  #
  #   * MAIL_MODE=smtp (or just setting SMTP_HOST, the pre-MAIL_MODE opt-in) —
  #     relay through any SMTP server (Postmark, SES, Gmail, ...). TLS is on
  #     by default (STARTTLS on 587); set SMTP_TLS=false for an unencrypted
  #     relay (e.g. a local dev/test relay).
  #   * MAIL_MODE=direct — no relay: deliver straight to each recipient
  #     domain's MX hosts on port 25, DKIM-signed once a key is configured.
  #     Requires MAIL_FROM_EMAIL (its domain is the sending domain) and
  #     correct DNS (SPF/DKIM/DMARC/PTR) — see /editor/mail once Phase 5
  #     lands, and mind that many cloud hosts block outbound port 25.
  # Treat a blank MAIL_MODE ("" — a common `MAIL_MODE=` .env/compose artifact)
  # as unset rather than an unknown mode: an empty string is truthy in Elixir,
  # so without this it would fall through to the `other -> raise` clause and
  # crash boot (and mask a set SMTP_HOST, since `||` wouldn't fall back).
  mail_mode =
    case System.get_env("MAIL_MODE") do
      blank when blank in [nil, ""] -> System.get_env("SMTP_HOST") && "smtp"
      mode -> mode
    end

  case mail_mode do
    "smtp" ->
      smtp_host =
        System.get_env("SMTP_HOST") ||
          raise "MAIL_MODE=smtp requires SMTP_HOST (the relay to send through)"

      # Explicit TLS options for STARTTLS: since OTP 26 the ssl app defaults to
      # `verify_peer` with no CA store configured, so gen_smtp's handshake to any
      # relay dies with :tls_failed unless we supply one. Verify against
      # CAStore's bundle (with SNI, required by multi-tenant relays) by default;
      # SMTP_TLS_VERIFY=false keeps the connection encrypted but skips peer
      # verification, for relays with self-signed or mismatched certificates.
      smtp_tls_options =
        if Env.flag("SMTP_TLS_VERIFY", true) do
          [
            verify: :verify_peer,
            cacertfile: CAStore.file_path(),
            server_name_indication: String.to_charlist(smtp_host),
            depth: 3
          ]
        else
          [verify: :verify_none]
        end

      config :kiln_cms, KilnCMS.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        tls: if(Env.flag("SMTP_TLS", true), do: :always, else: :never),
        tls_options: smtp_tls_options,
        auth: :always

    "direct" ->
      unless System.get_env("MAIL_FROM_EMAIL") do
        raise """
        MAIL_MODE=direct requires MAIL_FROM_EMAIL: its domain is the sending
        (and DKIM signing) domain, and async bounces are delivered to it.
        """
      end

      helo_host =
        case System.get_env("MAIL_HELO_HOST") do
          empty when empty in [nil, ""] -> host
          helo -> helo
        end

      config :kiln_cms, KilnCMS.Mailer,
        adapter: KilnCMS.Mailer.DirectMX,
        # HELO name; deliverability requires the sending IP's PTR record to
        # resolve to this host.
        hostname: helo_host

    nil ->
      :ok

    other ->
      raise "unknown MAIL_MODE #{inspect(other)} — expected \"smtp\" or \"direct\""
  end

  # Persist the resolved mode so the admin mail page reports it authoritatively
  # instead of reverse-inferring it from the adapter module (which mislabels a
  # downstream project's custom Swoosh adapter as "no real delivery").
  config :kiln_cms, :mail_mode, mail_mode

  if from_email = System.get_env("MAIL_FROM_EMAIL") do
    config :kiln_cms, email_from: {System.get_env("MAIL_FROM_NAME") || "KilnCMS", from_email}
  end
end

# ## Signed provenance — the claim fields (#644, residual from #608/#641)
#
# The remaining `KilnCMS.Provenance` keys #608 couldn't reach at runtime: the
# `signer` identity and `origin` URL embedded in every manifest a consumer
# verifies, and the default `ai_disclosure`. They live here, at the end, rather
# than in the main provenance block above (search `KILN_PROVENANCE_ENABLED`)
# because that block is dense with the line anchors `docs/environment-variables.md`
# cites, and inserting there would shift every one below it —
# `test/kiln_cms/docs/env_var_anchors_test.exs` guards exactly that.
#
# Skipped in `:test` like the rest of the provenance config: these values ride
# into a signed claim, and the suite must not depend on a developer's shell.
if config_env() != :test do
  # `signer` and `origin` default to something a released image can already set
  # (`:site_name` / `:public_base_url`), so they are lower stakes than #608's
  # three — but there is no reason a prebuilt image should have to rebuild to
  # override the claim. Written only when set, so the `nil`-means-fall-back
  # semantics survive an unset or blank var; scalar values merge cleanly.
  provenance_signer = "KILN_PROVENANCE_SIGNER" |> System.get_env("") |> String.trim()

  if provenance_signer != "" do
    config :kiln_cms, KilnCMS.Provenance, signer: provenance_signer
  end

  provenance_origin = "KILN_PROVENANCE_ORIGIN" |> System.get_env("") |> String.trim()

  if provenance_origin != "" do
    config :kiln_cms, KilnCMS.Provenance, origin: provenance_origin
  end

  # The default AI-disclosure embedded when a document declares none. Unlike
  # `signer`/`origin`, a garbage value here is written into a SIGNED claim, so an
  # unrecognized spelling warns and keeps the configured default rather than
  # being written — `KilnCMS.Provenance.normalize_disclosure/1` coerces unknown
  # to "human" for per-document reads, the wrong direction for a value an
  # operator set on purpose.
  provenance_disclosure =
    "KILN_PROVENANCE_AI_DISCLOSURE" |> System.get_env("") |> String.trim() |> String.downcase()

  cond do
    provenance_disclosure == "" ->
      :ok

    provenance_disclosure in KilnCMS.Provenance.disclosures() ->
      config :kiln_cms, KilnCMS.Provenance, ai_disclosure: provenance_disclosure

    true ->
      IO.warn("""
      KILN_PROVENANCE_AI_DISCLOSURE is set to an unrecognized value \
      (#{inspect(provenance_disclosure)}); keeping the configured default. \
      Expected one of: #{Enum.join(KilnCMS.Provenance.disclosures(), "/")}.\
      """)
  end
end

# ── Boot-time config warnings ────────────────────────────────────────────────
#
# MUST STAY LAST. `KilnCMS.Config.Env` warns on stderr for a variable it cannot
# parse, and in a release that line reaches container stdout and nothing else —
# no Sentry, no OTel, no log sink — because config providers run before `Logger`
# exists (#634). `Env.take_collected/0` returns what this evaluation warned
# about, so `KilnCMS.Application` can replay it once observability is attached.
# It DRAINS (unlike the plain `collected/0` reader), so a process that evaluates
# this file twice — the test harness does — reports only that pass's reads.
#
# Anything calling `Env` *below* this line is warned about on stderr only, which
# is the failure mode #634 exists to close. `test/kiln_cms/config/env_test.exs`
# fails if that happens.
#
# Written unconditionally rather than `if warnings != []`: `Config` deep-merges,
# so skipping the empty case would leave a previous evaluation's list in place
# on the config-provider path.
config :kiln_cms, :config_warnings, Env.take_collected()
