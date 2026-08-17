import Config
config :kiln_cms, Oban, testing: :manual

# No boot-time occurrence backfill (#766). Every test runs inside a rolled-back
# sandbox, but application boot is OUTSIDE them — so an enqueue there commits a
# real `oban_jobs` row, which `DataCase.drain_oban/0` then re-executes inside
# whichever unrelated test drains next. `test_helper.exs` deletes stray rows and
# warns when it does; leaving this on would make that warning fire on every run
# and train away a signal that exists to catch real leakage.
config :kiln_cms, :occurrence_backfill_on_boot, false

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

# oEmbed (#489) is OFF by default everywhere, including here — the tests that
# need it turn it on themselves, so nothing accidentally makes an outbound
# request. `req_options` points at a Req.Test stub for when they do; the
# SafeUrl `resolve_dns: false` below is what lets a stub host resolve at all.
config :kiln_cms, KilnCMS.OEmbed,
  enabled: false,
  req_options: [plug: {Req.Test, KilnCMS.OEmbed}]

# Webhook URL validation: skip DNS resolution for Req.Test stub hosts.
config :kiln_cms, KilnCMS.Webhooks.SafeUrl, require_https: false, resolve_dns: false

# ActivityPub federation (#491). **Off**, like production — the federation
# tests turn it on for themselves via `KilnCMS.FederationFixtures`. Leaving it
# on globally would make every publish in the whole suite enqueue an
# announcement job, which is a side effect on tests that have nothing to do
# with federation (and did visibly perturb the hybrid-search suite).
# Outbound requests (actor fetches, inbox deliveries) go through a Req.Test stub.
config :kiln_cms, KilnCMS.Federation,
  enabled: false,
  req_options: [plug: {Req.Test, KilnCMS.Federation}]

# Content experiments (#499). Off, like production — the experiment tests turn it
# on for themselves. On globally it would make every delivery request in the
# suite consult the running-experiment cache, and would flip experimented pages
# to `no-store` under tests that assert cache headers.
config :kiln_cms, KilnCMS.Experiments, enabled: false

# Outbound link checking (#474). Every request goes to a Req.Test stub; nothing
# in the suite may reach the real web. The per-host throttle is widened to
# effectively off, because pacing is tested directly (`Links.Throttle`) and
# leaving it at its two-second production window would make any test that
# checks two URLs on one stub host wait for it.
config :kiln_cms, KilnCMS.Links.External, req_options: [plug: {Req.Test, KilnCMS.Links.External}]
config :kiln_cms, KilnCMS.Links.Throttle, per_host: {10_000, 1_000}

# S3 storage adapter: dummy credentials + route ExAws HTTP through a Req.Test
# stub, so the adapter is exercised end-to-end (signing included) with no live S3.
config :ex_aws, access_key_id: "test", secret_access_key: "test", region: "us-east-1"

config :kiln_cms, KilnCMS.Storage.S3,
  bucket: "kiln-test",
  public_base_url: "https://cdn.test/kiln-test",
  req_options: [plug: {Req.Test, KilnCMS.Storage.S3}]

# Route Unsplash HTTP through a Req.Test stub. No access key here — the
# integration stays disabled unless a test opts in by merging one into the
# `:unsplash` app env.
config :kiln_cms, :unsplash, req_options: [plug: {Req.Test, KilnCMS.Unsplash}]

# Route the upstream update check through a Req.Test stub, so no test ever
# reaches api.github.com. Left enabled so the enabled/disabled branches can
# both be exercised by overriding this per-test.
config :kiln_cms, Kiln.Updates, req_options: [plug: {Req.Test, Kiln.Updates}]

# The HTTP governance witness (#733) reaches an operator-configured transparency
# log. Never dialled for real in tests; the stub stands in for the log.
config :kiln_cms, KilnCMS.Governance.Witness.HTTP,
  req_options: [plug: {Req.Test, KilnCMS.Governance.Witness.HTTP}]

# Route social-provider HTTP (#497) through a Req.Test stub, so no test ever
# reaches bsky.social or somebody's Mastodon instance. Nothing posts without a
# configured account, so this is a safety net rather than the gate.
config :kiln_cms, KilnCMS.Social, req_options: [plug: {Req.Test, KilnCMS.Social}]

# App-icon verification (#629) fetches an operator-supplied URL server-side to
# measure it. Stubbed here so the suite never dials out; tests that exercise the
# absolute-URL branch install their own `Req.Test.stub/2`.
config :kiln_cms, KilnCMS.Branding.AppIcon,
  req_options: [plug: {Req.Test, KilnCMS.Branding.AppIcon}]

# Web Push (#628). No VAPID keys by default, so `KilnCMS.Push.enabled?/0` is
# false and the suite's editorial actions enqueue no push jobs — the push tests
# configure a pair explicitly. `req_options` points the sender at a stub for
# when they do.
config :kiln_cms, KilnCMS.Push, req_options: [plug: {Req.Test, KilnCMS.Push}]

# Route payment-provider HTTP through a Req.Test stub, so no test ever reaches
# api.stripe.com. Billing still stays inert unless a test configures credentials
# on the `KilnCMS.Billing.Settings` singleton — `configured?/0` gates every
# surface — so the stub is only reachable once a test opts in.
config :kiln_cms, KilnCMS.Billing, req_options: [plug: {Req.Test, KilnCMS.Billing}]

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

# Rate-limit overrides for the suite.
#
# `:api` / `:delivery` / `:gql` / `:probe` stay raised: those doors still see
# enough traffic from a *single* test's own address (or from `build_conn/0`
# callers that have not moved onto ConnCase's unique default) that the real
# production ceilings would 429 unrelated assertions.
#
# `:register` used to be raised alongside `:auth` (#715, #724), because every
# ConnCase request peered from `127.0.0.1` and shared one bucket. ConnCase's
# setup now mints a per-test address (#936), so `:register` exercises the
# shipped ceiling. Files that deliberately share an address — proving a
# per-account budget is not per-IP — opt back in with `loopback_conn/0`.
#
# `:auth` itself went back to being raised (#747), not because #936 didn't
# work — it did, for every test that uses ConnCase's per-test `conn` — but a
# long tail of controller/LiveView tests still build their own bare
# `build_conn()` against an `:auth`-bucket route (a redirect-to-/sign-in
# assertion, a replay/hold/tamper case reusing the setup `conn`, …), which
# peers from loopback and pools onto one `auth:127.0.0.1` bucket regardless of
# #936. #726 then added real volume to that shared bucket — every two-factor
# verify is a *second* `:auth` request alongside its sign-in — and #747 also
# doubled the production ceiling for the same reason, so the untouched test
# default would have filled twice as fast per 2FA test as it used to. Sized
# generously against the suite's own volume, not against production —
# `SignInRateLimitTest` reads this value rather than hardcoding it, so it
# still spends a real, finite budget on its own address to prove the
# boundary; it is just a larger one now.
#
# `:unlock` stays raised: the lock suite still posts a dozen passphrases from
# one address in a window (#496).
config :kiln_cms, KilnCMSWeb.RateLimit,
  limits: %{
    api: {1_000_000, :timer.minutes(1)},
    delivery: {1_000_000, :timer.minutes(1)},
    auth: {500, :timer.minutes(1)},
    # Same reason (#496): the lock suite posts a dozen passphrases from one
    # address in one window, and the shipped 10/min would 429 whichever test
    # happened to run last. `RateLimit.default_limits/0` still pins the real
    # number, so the threat model stays asserted.
    unlock: {200, :timer.minutes(1)},
    gql: {1_000_000, :timer.minutes(1)},
    probe: {1_000_000, :timer.minutes(1)},
    # Every `live/2` in the suite is a root join from the same (unresolved)
    # address (#1183); `LiveJoinBudgetTest` lowers this back for its own tests.
    live_join: {1_000_000, :timer.minutes(1)},
    # Every frame the collab suite pushes is charged to the seeded actor
    # (#1305), and one test's actor may push many; raised out of the way, and
    # `CollabChannelTest`/`SocketEventBudgetTest` lower it back for their own
    # budget tests.
    collab_event: {1_000_000, :timer.minutes(1)}
  }

# Per-account auth budgets (#478). The whole suite signs in as seeded users and
# sends reset/magic-link mail, and every bucket keys on the email — so the real
# limits would have unrelated auth tests refusing each other's sign-ins and
# swallowing each other's mail (the ETS table is node-wide and is not reset
# between test files). `KilnCMS.Accounts.AccountThrottleTest` tightens all four
# back down per-test, under `async: false`, to assert the real behaviour.
config :kiln_cms, KilnCMS.Accounts.AccountThrottle,
  budget: 1_000_000,
  window: :timer.minutes(15),
  mail_budget: 1_000_000,
  mail_window: :timer.hours(1),
  # The second-factor budget (#714) keys on a user id rather than an email, so
  # it cannot collide across test files the way the others can — but the 2FA
  # controller suite drives several attempts against one seeded user, and the
  # real budget of 5 is small enough to reach by accident. Raised on the same
  # principle; `AccountThrottleTest` tightens it back per-test.
  second_factor_budget: 1_000_000,
  second_factor_window: :timer.minutes(15)

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :kiln_cms, KilnCMS.Repo,
  username: "postgres",
  password: "postgres",
  # "localhost" reaches a `services:` postgres from a job running directly on
  # the runner. A job running inside a `container:` (the qpdf CI leg, #907) is
  # on a separate Docker network where the service is only reachable by its
  # service name instead, hence the override.
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
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

# Same idea for embeddable forms (#562): a fixed allowlist so the route tests
# assert a real configured policy rather than the shipped default, which is
# same-origin only. Because this override is global, the shipped default is NOT
# covered by anything in an async test — that is what
# `test/kiln_cms_web/controllers/form_embed_default_test.exs` and
# `test/kiln_cms_web/live/form_builder_embed_warning_test.exs` are for: both are
# `async: false` and clear this key, so the zero-config path #562 is about is
# exercised through the real request pipeline rather than by passing a setting
# as an argument.
config :kiln_cms, :embed_origins, ["https://embedder.test"]

# OIDC SSO (#331): enabled in test with placeholder settings so the strategy,
# its routes, and the register action compile and are testable. No live IdP is
# contacted — tests drive the register action directly.
config :kiln_cms, :sso_oidc,
  enabled: true,
  client_id: "kiln-test-client",
  client_secret: "kiln-test-secret",
  base_url: "https://idp.example.test",
  redirect_uri: "http://localhost:4002/auth"

# Passkeys (#331): stub the Wax verification seam — tests exercise the real
# base64url plumbing, storage, counter regression, and token minting around it.
config :kiln_cms, KilnCMS.Accounts.WebAuthn, verifier: KilnCMS.StubWebAuthnVerifier

# RBAC scope memoization off: tests mutate memberships/roles mid-process and
# assert the new scope immediately (prod keeps the few-second process memo).
config :kiln_cms, KilnCMS.Accounts.Scoping, memo_ttl_ms: 0

# Strict tenancy (#419) is COMPILE-TIME; the main suite predates it and calls
# interfaces tenant-less (resolving the default org), so tests compile
# fail-open. The strict CI leg sets KILN_STRICT_TEST=true (or 1/yes/on) and
# runs the @moduletag :strict_tenancy smoke suite against a strict-compiled
# build. Parsed by the standalone snippet in strict_test_flag.exs — see its
# header for why this can't just call KilnCMS.Config.Env (#646).
Code.require_file("strict_test_flag.exs", __DIR__)

config :kiln_cms,
       :strict_tenancy,
       KilnCMS.Config.StrictTestFlag.strict?(System.get_env("KILN_STRICT_TEST"))
