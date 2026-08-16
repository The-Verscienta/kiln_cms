defmodule KilnCMSWeb.Router do
  use KilnCMSWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  # Content-Security-Policy. Directives shared by every browser response; the
  # `script-src` directive is finalized per-pipeline (see `put_*_browser_csp`).
  # `style-src` keeps 'unsafe-inline' because inline `style=` attributes can't
  # carry a nonce; everything else is locked to same-origin.
  @img_src_base "img-src 'self' data: blob:"

  # `<video>`/`<audio>`/`<track>` sources (#494). Without an explicit
  # `media-src` these fall back to `default-src 'self'`, which is correct for
  # the app-served `/media/:id/stream` route but blocks a public item served
  # from a CDN — so this carries the same operator-configured external hosts
  # `img-src` does (see `base_csp/0`), because it is the same CDN.
  @media_src_base "media-src 'self' blob:"

  @base_csp "default-src 'self'; " <>
              "style-src 'self' 'unsafe-inline'; " <>
              "#{@img_src_base}; " <>
              "#{@media_src_base}; " <>
              "font-src 'self' data:; " <>
              "connect-src 'self' ws: wss:; " <>
              "frame-src 'self' https://www.youtube.com https://player.vimeo.com; " <>
              "object-src 'none'; base-uri 'self'; " <>
              "frame-ancestors 'self'; form-action 'self'"

  # Static CSP placeholders for Sobelow / `put_secure_browser_headers`; the
  # `put_*_browser_csp` plugs immediately replace these with per-request nonces.
  @browser_csp_headers %{
    "content-security-policy" => "script-src 'self'; #{@base_csp}"
  }

  @dev_browser_csp_headers %{
    "content-security-policy" => "script-src 'self' 'unsafe-inline' 'unsafe-eval'; #{@base_csp}"
  }

  # CSP for the Swagger UI explorer (issue #37; gated by `:api_docs` since
  # #567 — this policy is one reason not to ship it to production). Swagger UI
  # loads its bundle/CSS from cdnjs and runs one inline boot script, which gets a
  # per-request nonce (see `put_swagger_csp`). `style-src` keeps 'unsafe-inline'
  # because swagger-ui injects un-nonced inline styles.
  @swagger_csp "default-src 'self'; " <>
                 "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " <>
                 "img-src 'self' data: blob: https://cdnjs.cloudflare.com; " <>
                 "font-src 'self' data: https://cdnjs.cloudflare.com; " <>
                 "connect-src 'self'; object-src 'none'; base-uri 'self'; " <>
                 "frame-ancestors 'self'; form-action 'self'"

  @swagger_csp_headers %{
    "content-security-policy" => "script-src 'self' https://cdnjs.cloudflare.com; #{@swagger_csp}"
  }

  pipeline :graphql do
    plug KilnCMSWeb.Plugs.RateLimit, :gql
    # Block schema introspection in production (config-gated).
    plug KilnCMSWeb.Plugs.DisableGraphqlIntrospection
    plug :load_from_bearer
    plug :set_actor, :user
    # API keys (`Authorization: Bearer kiln_…`) as an alternative to a JWT.
    plug KilnCMSWeb.Plugs.ApiKeyAuth
    plug AshGraphql.Plug
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KilnCMSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @browser_csp_headers
    plug :put_browser_csp
    plug :load_from_session
  end

  # Dev-only browser tooling (AshAdmin, LiveDashboard, API explorers) ships its
  # own inline scripts/styles, so it gets a relaxed `script-src`. These routes
  # only exist when `dev_routes` is enabled, never in production.
  pipeline :browser_dev_tools do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KilnCMSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @dev_browser_csp_headers
    plug :put_dev_browser_csp
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug KilnCMSWeb.Plugs.RateLimit, :api
    plug :load_from_bearer
    plug :set_actor, :user
    # API keys (`Authorization: Bearer kiln_…`) as an alternative to a JWT.
    plug KilnCMSWeb.Plugs.ApiKeyAuth
    # The OpenAPI document is served from inside the `KilnCMSWeb.AshJsonApiRouter`
    # forward below, so there is no route here to gate. This plug knows the two
    # documentation paths and passes every other `/api` request through (#567).
    plug KilnCMSWeb.Plugs.ApiDocs
  end

  # `:api` plus a guard against the specific query-param shapes `ash_json_api`
  # 1.6.6 has no parser clause for (#763) — a separate pipeline because the
  # guard is meaningless for our own hand-written `/api` handlers, which
  # already go through `KilnCMSWeb.Params` (#751).
  pipeline :ash_json_api do
    plug KilnCMSWeb.Plugs.AshJsonApiParams
  end

  # Headless sign-in — exchanges credentials for a bearer token (issue #37).
  # Tight per-IP `:auth` limit to slow credential stuffing; no bearer/actor
  # plugs (this is the endpoint that *issues* the token).
  pipeline :api_auth do
    plug :accepts, ["json"]
    plug KilnCMSWeb.Plugs.RateLimit, :auth
  end

  # MCP (Model Context Protocol) — LLM authoring clients (docs/mcp.md).
  # API-key-only, `required?: true`: unlike `:api` there is no anonymous or JWT
  # access here, a missing/invalid `Bearer kiln_…` key is a 401. What a key may
  # do is enforced by the resource policies (its `access` scope + the owning
  # user's role), not by the transport.
  pipeline :mcp do
    plug :accepts, ["json"]
    plug KilnCMSWeb.Plugs.RateLimit, :api

    plug AshAuthentication.Strategy.ApiKey.Plug,
      resource: KilnCMS.Accounts.User,
      required?: true
  end

  # Swagger UI explorer — serves the published OpenAPI spec interactively in all
  # environments (issue #37). Relaxed, swagger-specific CSP (`@swagger_csp`) plus
  # a per-request nonce for swagger-ui's inline boot script.
  pipeline :swagger_ui do
    plug :accepts, ["html"]
    # Bound unauthenticated browsing of the docs explorer (#225). The `docs`
    # bucket is generous enough for interactive use but caps sustained crawler
    # traffic against the UI + forwarded spec.
    #
    # Before the `:api_docs` gate, deliberately: a refusal is still a request,
    # and an unmetered 404 is an unauthenticated endpoint someone can hammer
    # for free.
    plug KilnCMSWeb.Plugs.RateLimit, :docs
    # Off in production by default (#567) — see `KilnCMSWeb.Plugs.ApiDocs`.
    plug KilnCMSWeb.Plugs.ApiDocs
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @swagger_csp_headers
    plug :put_swagger_csp
  end

  # Auth pages get a tighter per-IP limit to slow credential stuffing.
  pipeline :browser_auth do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KilnCMSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @browser_csp_headers
    plug :put_browser_csp
    # `:auth`, except on the registration POST, which gets its own tighter
    # bucket so the two registration doors agree (#724) — see
    # `KilnCMSWeb.Plugs.AuthRateLimit`.
    plug KilnCMSWeb.Plugs.AuthRateLimit
    # Remember-me is read *only* here, not on `:browser` (#699), and the reason
    # is the public delivery surface. `sign_in_with_remember_me` signs the
    # visitor in by writing the session, so `Plug.Session` emits `Set-Cookie` —
    # and `ContentController` marks ungated pages `public, max-age=60`. A shared
    # cache is then free to store one remembered editor's session cookie against
    # a public URL and hand it to every anonymous visitor for the next minute.
    # It also does a JWT verify plus two DB reads, which on `:browser` would run
    # ahead of the `:delivery` bucket that is supposed to bound exactly that.
    #
    # Nothing is lost: a remembered visitor who opens an authoring URL is
    # redirected here by `:live_user_required`, is signed in by this plug, and
    # `:live_no_user` sends them straight on. One extra redirect, and the
    # credential is only read on the surface that exists to establish sessions.
    #
    # Ahead of `load_from_session` so the sign-in is resolved within the same
    # request. Safe there because the plug is a no-op when the session already
    # names a user, so it cannot swap a live session for a stale cookie.
    plug :sign_in_with_remember_me
    plug :load_from_session
    # After the two above, because it needs whichever of them resolved the user
    # — and it covers the remember-me path, which never reaches
    # `AuthController.complete_sign_in/3` (#675).
    plug KilnCMSWeb.Plugs.LiveSocketId
  end

  # Preview endpoint — authorized by a signed token, not a session/bearer.
  # Tightly rate-limited per IP so a leaked/guessable token can't be used to
  # enumerate or scrape draft content. Accepts html so a browser opening the
  # link is redirected to the shared human view (#379); JSON is the default.
  pipeline :preview do
    plug :accepts, ["json", "html"]
    # The html branch only ever redirects to the live view, but set the secure
    # browser headers + CSP regardless (harmless on the JSON responses).
    plug :put_secure_browser_headers, @browser_csp_headers
    plug :put_static_browser_csp
    plug KilnCMSWeb.Plugs.RateLimit, :preview
  end

  # The human token-preview page (#379): browser pipeline for the LiveView,
  # fronted by the same tight :preview rate limit.
  pipeline :preview_page do
    plug KilnCMSWeb.Plugs.RateLimit, :preview
  end

  # Light per-IP ceiling for public HTML delivery (especially cache-miss paths).
  pipeline :delivery do
    plug KilnCMSWeb.Plugs.RateLimit, :delivery
    # Per-site code injection (#490). ONLY here — the root layout is shared with
    # the editor console, so "delivery only" is enforced by which pipeline the
    # plug lives in rather than by a conditional in the template. Runs after
    # `:browser`'s `put_browser_csp`, because it rewrites the header that plug
    # set.
    plug KilnCMSWeb.Plugs.CodeInjection
  end

  # Passphrase submissions against locked content (#496). CSRF applies (the form
  # is server-rendered into the visitor's own session by the lock page), and the
  # tight `:unlock` bucket is what bounds guessing at a shared secret.
  pipeline :content_unlock do
    plug KilnCMSWeb.Plugs.RateLimit, :unlock
  end

  # Public form submissions (admin-defined forms). No CSRF — the endpoints
  # are anonymous and fired artifacts couldn't carry a token; abuse is
  # bounded by the honeypot + the tight :form rate bucket.
  pipeline :public_form do
    plug :accepts, ["html", "json"]
    # The thank-you page is static server HTML (no scripts) — the strict
    # browser CSP applies as-is, no per-request nonce needed. (An *embedded*
    # submission swaps in the embed CSP; see FormController.submit/2.)
    plug :put_secure_browser_headers, @browser_csp_headers
    plug :put_static_browser_csp
    plug KilnCMSWeb.Plugs.RateLimit, :form
  end

  # Inbound payment-provider webhooks (#337 Phase 2). No CSRF and no session — the
  # caller is the payment provider, not a browser; authorization is the
  # `Stripe-Signature` HMAC over the raw body (preserved by
  # `KilnCMSWeb.Plugs.RawBodyReader`). Its own rate bucket, because the provider
  # bursts from a small egress IP set and a dropped entitlement event locks a
  # paying member out. No secure-browser-headers: the response is an empty JSON
  # ack, never rendered.
  pipeline :provider_webhook do
    plug :accepts, ["json"]
    plug KilnCMSWeb.Plugs.RateLimit, :billing_webhook
  end

  # The ActivityPub inbox (#491). Same situation as a payment webhook and the
  # same shape: no CSRF, no session, the caller is a remote server, and
  # authorization is an HTTP Signature over the raw body (preserved by
  # `KilnCMSWeb.Plugs.RawBodyReader`). No `:accepts` — a fediverse server sends
  # `application/activity+json`, which Phoenix does not negotiate.
  pipeline :activitypub_inbox do
    plug KilnCMSWeb.Plugs.RateLimit, :api
  end

  # The iframe page for an embeddable form. A page load, not a submission, so it
  # gets the generous `:delivery` ceiling rather than the tight `:form` bucket.
  # The controller replaces the CSP with `KilnCMSWeb.Embed.content_security_policy/1`,
  # whose `frame-ancestors` permits the parents that form allows (#648).
  pipeline :form_embed do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers, @browser_csp_headers
    plug :put_static_browser_csp
    plug KilnCMSWeb.Plugs.RateLimit, :delivery
  end

  # Per-IP ceiling for unauthenticated infra/SEO endpoints (`/up` runs a DB
  # query; sitemap cache-misses do a table scan). Generous enough never to
  # throttle real probes/crawlers — see the `:probe` bucket.
  pipeline :probe do
    plug KilnCMSWeb.Plugs.RateLimit, :probe
  end

  scope "/", KilnCMSWeb do
    pipe_through :browser

    # Signed in, but NOT necessarily an editor — the reader-facing surface (#337
    # Phase 2). Gated at the router rather than per-LiveView, like the editor and
    # admin sessions below.
    ash_authentication_live_session :authenticated_routes,
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :current_user},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org},
        {KilnCMSWeb.LiveUserAuth, :live_user_required},
        {KilnCMSWeb.LiveUserAuth, :restore_locale}
      ] do
      live "/account", AccountLive, :show
    end

    # Member payment handoffs. Plain CSRF-protected posts rather than LiveView
    # events: both end in a redirect to a provider-hosted page on another origin,
    # which a LiveView cannot navigate to. Two segments, so they must be declared
    # before the `/:type/:slug` delivery catch-all far below.
    post "/billing/checkout", BillingController, :checkout
    post "/billing/portal", BillingController, :portal

    # Authoring UIs — editors and admins only.
    ash_authentication_live_session :editor_routes,
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :current_user},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org},
        {KilnCMSWeb.LiveUserAuth, :live_editor_required},
        {KilnCMSWeb.LiveUserAuth, :restore_locale}
      ] do
      live "/media", MediaLive, :index
      live "/editor", EditorLive, :index
      live "/editor/overview", OverviewLive, :index
      live "/editor/calendar", CalendarLive, :index
      live "/editor/tasks", TaskLive, :index
      # Content releases (#500). Editor-gated like the rest; the actions that
      # actually ship content are admin-gated by the resource policy, not here.
      live "/editor/releases", ReleaseLive, :index
      live "/editor/releases/:id", ReleaseLive, :show
      live "/editor/translations", TranslationsLive, :index
      live "/editor/search", SearchPaletteLive, :index
      live "/editor/taxonomy", TaxonomyLive, :index
      # Editor-managed navigation menus (#466). Editorial, like taxonomy — the
      # menu list, and one menu's item tree.
      live "/editor/menus", MenuLive, :index
      live "/editor/menus/:id", MenuLive, :show
      live "/editor/analytics", AnalyticsLive, :index
      # Site-wide broken outbound links (#474). Editorial, so it lives here
      # rather than under the admin session; the opt-in switch on the page is
      # admin-gated by the resource policy, not by the route.
      live "/editor/links", LinkReportLive, :index
      live "/editor/settings", SettingsLive, :index
      # Generic editor route — works for any content type (incl. ones generated
      # by `mix kiln.gen.content`). The `:page`/`:post` routes are kept as
      # backward-compatible aliases.
      live "/editor/content/:type/:id", ContentEditorLive, :content
      live "/editor/pages/:id", ContentEditorLive, :page
      live "/editor/posts/:id", ContentEditorLive, :post
      live "/editor/preview/:kind/:id", PreviewLive, :show
      # In-context (front-end) editing on Kiln's own site (#354): renders the
      # page from the live draft with inline-editable text regions.
      live "/editor/site/:type/:slug", InContextEditLive, :edit
      # Presentation console (#355): iframe an EXTERNAL front end for side-by-side
      # editing, driven by bridge.js postMessage. Needs PRESENTATION_PREVIEW_URL.
      live "/editor/presentation/:type/:slug", PresentationLive, :show

      # Plugin editor panels (D18) — compiled in from each installed plugin's
      # `editor_routes/0`, editor-gated by this live_session like the rest.
      import KilnCMSWeb.PluginRouter
      plugin_editor_routes()
    end

    # Admin-only authoring UIs. Guarded at the router (live_session) level, not
    # just in each LiveView's mount/3, so non-admins can't mount the route.
    ash_authentication_live_session :admin_routes,
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :current_user},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org},
        {KilnCMSWeb.LiveUserAuth, :live_admin_required},
        {KilnCMSWeb.LiveUserAuth, :restore_locale}
      ] do
      live "/editor/trash", TrashLive, :index
      live "/editor/webhooks", WebhookLive, :index
      # Pathauto redirect management (#457) — list/prune automatic rows, add
      # manual redirects for legacy URLs.
      live "/editor/redirects", RedirectLive, :index
      # Bulk slug regeneration (#455) — dry-run preview + background apply.
      live "/editor/slugs", SlugRegenLive, :index
      # Team + granular-RBAC management (#332 slice 4).
      live "/editor/team", TeamLive, :index
      # Editorial automation (#342) — no-code "when X happens, do Y" rules.
      live "/editor/automation", AutomationLive, :index
      # Social accounts the `:social_post` automation reaction announces to
      # (#497). Admin-only: the stored credentials are the site's public voice.
      live "/editor/social", SocialLive, :index
      live "/editor/fields", FieldDefinitionLive, :index
      live "/editor/types", TypeDefinitionLive, :index
      # Per-site syndication policy (#719) — which types appear in this site's
      # feeds and which carry their full body. Org-scoped for the same reason
      # branding is: full-text syndication is a disclosure decision, and it used
      # to live in a config file no tenant admin could reach.
      live "/editor/feeds", FeedSettingsLive, :index
      # Per-site claim checking (#857) — whether the editor's Compliance panel
      # runs here, whether it gates publishing, and this site's own claims
      # vocabulary. Org-scoped for the reason feeds are: a hard publish refusal
      # used to live in a config file no tenant admin could reach.
      live "/editor/compliance", ComplianceLive, :index
      # White-label branding for the current site (#48) — name, logo, colour.
      # Org-scoped: you brand the site you're on (switch org by host).
      live "/editor/branding", BrandingLive, :index
      # Per-site custom head/footer HTML for the DELIVERY site (#490). Admin-only
      # by the live session's tier gate AND the resource policy; the snippet is
      # rendered only by the `:delivery` pipeline, never here.
      live "/editor/code-injection", CodeInjectionLive, :index
      # In-app backups (#484) — status, "back up now", retention. Admin-only:
      # the artifact list names the database dump, and an editor has no action
      # to take on it. Restore stays a documented ops procedure.
      live "/editor/backups", BackupLive, :index
      live "/editor/mail", MailSettingsLive, :index
      live "/editor/newsletter", NewsletterLive, :index
      # Paid memberships (#337 Phase 2). Instance-wide provider credentials plus
      # per-site tiers, so the page itself gates on `platform_admin?` — see the
      # LiveView's moduledoc.
      live "/editor/billing", BillingLive, :index
      # Compliance & governance dashboard (#352) — audit trail, consent, and
      # point-in-time history per content item.
      live "/editor/governance", GovernanceLive, :index
      live "/editor/governance/:type/:id", GovernanceLive, :show
      live "/editor/forms", FormLive, :index
      # Per-site form settings (#1232): the org-wide embed allowlist (#1131) and
      # the spam keyword list (#477), which had no production-reachable UI
      # (AshAdmin is compiled out under `dev_routes: false`). Declared BEFORE
      # `/editor/forms/:id` so the literal segment wins the match.
      live "/editor/forms/settings", FormSettingsLive, :index
      live "/editor/forms/:id", FormBuilderLive, :edit
      # Funnel definitions (#621, phase 4 of docs/advanced-analytics-plan.md) —
      # admin-only like the rest of this block; the derived report (#622) is
      # editor-visible on the analytics dashboard.
      live "/editor/funnels", FunnelLive, :index
      live "/editor/funnels/:id", FunnelBuilderLive, :edit
      # ActivityPub federation (#967): the gate, the handle, followers, the
      # delivery ledger and the block list. Admin-only, like webhooks.
      live "/editor/federation", FederationLive, :index
      live "/editor/api-keys", ApiKeyLive, :index
      # Which Kiln core this instance runs, and whether upstream has a newer
      # release. Reports only — updating is `mix kiln.update` (see SystemLive).
      live "/editor/system", SystemLive, :index

      # Plugin admin panels (D18) — compiled in from each installed plugin's
      # `admin_routes/0`, admin-gated by this live_session like the rest.
      import KilnCMSWeb.PluginRouter
      plugin_admin_routes()
    end

    # Self-service data export (#212). Controller route (file download), gated by
    # the signed-in user loaded in `:browser`; the controller scopes the payload
    # to `current_user`.
    get "/editor/account/export.json", AccountController, :export

    # Governance trail exports (#352) — file downloads, admin-gated in the
    # controller against the `:browser`-loaded user.
    get "/editor/governance/:type/:id/export.json", GovernanceController, :export
    get "/editor/governance/:type/:id/export.csv", GovernanceController, :export_csv

    # Form entries export (#477) — file download, admin-gated in the
    # controller (submissions are visitor-provided data, frequently PII;
    # FormSubmission's own policy is admin-only).
    get "/editor/forms/:id/entries/export.csv", FormEntriesExportController, :export_csv

    # Analytics export (#618, phase 1) — streamed file downloads, editor-gated
    # (not admin-only like governance above: `AnalyticsLive` itself is
    # editor-visible, so this route has to be declared outside `:editor_routes`
    # to be reachable as a controller download while keeping the same tier).
    get "/editor/analytics/export.json", AnalyticsExportController, :export
    get "/editor/analytics/export.csv", AnalyticsExportController, :export_csv

    # XLIFF export for translation vendors (#502) — a file download, so a
    # controller route; editor-gated in the controller for the same reason as
    # the analytics exports above (`TranslationsLive` is editor-visible).
    get "/editor/translations/export.xlf", TranslationsExportController, :export
  end

  # Headless GraphQL — always available; the interactive playground is dev-only
  # (see the `dev_routes` block below).
  #
  # Cap query cost/depth so a deeply nested or wide query can't force an
  # unbounded resolve (DoS). Tune `max_complexity` up as list queries are added.
  # One definition shared by the forward below and `PageController.gql_get/2`
  # (which re-dispatches GET-based queries to Absinthe).
  @graphql_opts [
    schema: Module.concat(["KilnCMSWeb.GraphqlSchema"]),
    analyze_complexity: true,
    max_complexity: 200
  ]

  @doc "Absinthe.Plug options for the `/gql` endpoint (see the forward below)."
  def graphql_opts, do: @graphql_opts

  scope "/gql" do
    pipe_through [:graphql]

    # A browser landing on the bare endpoint gets the developer docs instead of
    # a 400; GET-based GraphQL queries (`?query=…`) still execute (#319). Exact
    # match only — `/gql/<anything>` still falls through to the forward.
    get "/", KilnCMSWeb.PageController, :gql_get

    forward "/", Absinthe.Plug, @graphql_opts
  end

  # Interactive API docs — Swagger UI over the published OpenAPI spec (issue
  # #37), served only where `config :kiln_cms, :api_docs` is on: off in
  # production by default since #567. Registered BEFORE the `/api/json`
  # catch-all forward below so the forward can't shadow `/swaggerui`.
  scope "/api/json" do
    pipe_through :swagger_ui

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      # Nonce the inline boot script so it runs under the strict `script-src`.
      csp_nonce_assign_key: %{script: :swagger_script_nonce},
      default_model_expand_depth: 4
  end

  # Headless JSON:API. The OpenAPI spec the router itself serves at
  # `/api/json/open_api` follows the same `:api_docs` flag as the explorer
  # above (#567); the content routes are unaffected.
  scope "/api/json" do
    pipe_through [:api, :ash_json_api]

    forward "/", KilnCMSWeb.AshJsonApiRouter
  end

  # Headless sign-in: POST credentials, receive a bearer token (issue #37).
  #
  # `/sign_in/verify` is the headless mirror of `/sign-in/verify` (#726): a 2FA
  # account's password alone gets a pending token here, not a JWT, and the code
  # is redeemed at the second route. Same `:auth` bucket, and the code itself is
  # charged the per-account second-factor budget the browser prompt charges.
  scope "/api/auth", KilnCMSWeb do
    pipe_through :api_auth

    post "/sign_in", ApiAuthController, :sign_in
    post "/sign_in/verify", ApiAuthController, :verify
  end

  # MCP server for LLM authoring clients (docs/mcp.md). The tool list comes
  # from `config :kiln_cms, :mcp_tools` (compile-time, like `:content_domains`
  # in the GraphQL schema/JSON:API router) so a downstream project can expose
  # tools for its own content domain without editing the core router. Names
  # must match a `tools` block on a configured Ash domain — the core set lives
  # on `KilnCMS.CMS`. Authoring tools need a `:read_write` key on an editor
  # account; publishing/deleting are deliberately not exposed (drafts go
  # through the human review workflow).
  @mcp_tools Application.compile_env!(:kiln_cms, :mcp_tools)

  scope "/mcp" do
    pipe_through :mcp

    forward "/", AshAi.Mcp.Router,
      tools: @mcp_tools,
      protocol_version_statement: "2024-11-05",
      otp_app: :kiln_cms
  end

  # Exchange a passphrase for a grant token (#496). Its own scope so it carries
  # the tight `:unlock` bucket rather than the API's generous one — this endpoint
  # is the guessing surface for a shared secret, and the rate limit is the only
  # thing bounding it (there is no account to lock out).
  scope "/api", KilnCMSWeb do
    pipe_through [:api, :content_unlock]

    post "/content/:type/:slug/unlock", ArtifactController, :unlock
  end

  # Headless delivery of fired artifacts (Kiln v2 — D9). The v2 content API serves
  # immutable per-surface artifacts, not the raw editable block tree.
  scope "/api", KilnCMSWeb do
    pipe_through :api

    # Collection view as of a date (#338 phase 2): which documents were
    # published at that instant, reconstructed from version history.
    get "/content/:type", ArtifactController, :index_point_in_time

    get "/content/:type/:slug", ArtifactController, :show

    # Embedding-driven related content (#339 phase 2): published documents
    # semantically closest to this one.
    get "/content/:type/:slug/related", RelatedController, :show

    # Visual-editing bridge (#355): the live working copy, stega-annotated so an
    # external front end's overlay maps a rendered value back to its Kiln field.
    # Draft-visible only to an editor/admin API key; `no-store`, per-actor.
    get "/visual-editing/:type/:slug", VisualEditingController, :show

    # Locale discovery — lets a headless consumer build a locale switcher /
    # hreflang set without hard-coding the site's configured languages.
    get "/locales", LocalesController, :index

    # JSON Schema for this site's delivery payloads (#430): the block union and
    # one document schema per content type, so a typed client generates against
    # the live schema instead of a vendored copy. Per-org, because dynamic types
    # and custom fields are.
    get "/schema", SchemaController, :show

    # Editor-managed navigation (#466): the menu list, and one resolved menu
    # tree with live URLs and unpublished targets omitted. Static segment first
    # so `/menus` can't be swallowed by the `/:key` fetch.
    get "/menus", MenuController, :index
    get "/menus/:key", MenuController, :show

    # Path resolution for headless routing: what lives at this URL — published
    # content ("ok"), a pathauto redirect ("moved", 301 it yourself), or 404.
    get "/resolve", ResolveController, :show

    # Admin-defined form schemas, for headless frontends hydrating
    # `data-kiln-form` placeholders (submissions POST via :public_form below).
    get "/forms/:slug", FormController, :schema

    # Hybrid search (keyword + semantic RRF, reranked when enabled) — not
    # expressible as one Ash action, so it gets a thin controller (roadmap #4).
    get "/search", SearchApiController, :index

    # RAG "ask your content" (#339): retrieval over published content + cited
    # sources, with an optional (config-gated) generated answer.
    get "/ask", AskController, :ask

    # Signed / provenance-verified content (#340). C2PA-*style* detached
    # manifests over fired artifacts; all 404 unless provenance is enabled.
    # `public-key` is registered before the `:type/:slug` pattern (different
    # arity — no shadowing, but kept first for clarity).
    get "/provenance/public-key", ProvenanceController, :public_key
    get "/provenance/:type/:slug", ProvenanceController, :manifest
    get "/provenance/:type/:slug/verify", ProvenanceController, :verify
  end

  # Embeddable form: the iframe document a third-party site frames via
  # `/embed.js`. Its own pipeline so it can serve a framing-friendly CSP.
  scope "/", KilnCMSWeb do
    pipe_through :form_embed

    get "/forms/:slug/embed", FormController, :embed
  end

  # Public form submissions (on-site form-encoded + headless JSON).
  scope "/", KilnCMSWeb do
    pipe_through :public_form

    post "/forms/:slug", FormController, :submit
    post "/api/forms/:slug", FormController, :submit_json
  end

  scope "/preview", KilnCMSWeb do
    pipe_through :preview

    get "/:token", PreviewController, :show
  end

  # Shared human view of a token preview — external stakeholders without an
  # editor account join the same presence/cursor session as the editor
  # pop-out (#379).
  scope "/preview", KilnCMSWeb do
    pipe_through [:browser, :preview_page]

    # `:assign_current_org` so the preview resolves the tenant it is served from
    # (#563) — without it the LiveView has no `:current_org` assign and any
    # `Tenant.current_org_id/1` reached from it raises rather than silently
    # reading the default org.
    live_session :token_preview,
      on_mount: [{KilnCMSWeb.LiveUserAuth, :assign_current_org}] do
      # The site as of a content release (#500 phase 2). Declared FIRST so its
      # literal "release" segment is tried before the sibling's `:token`
      # wildcard, which would otherwise swallow `/preview/release/live`.
      live "/release/:token", ReleasePreviewLive, :show
      live "/:token/live", TokenPreviewLive, :show
    end
  end

  # Public newsletter subscribe/confirm/unsubscribe — authorized by an opaque
  # per-subscriber token, not a session. Uses the CSRF-free :public_form pipeline
  # so the RFC 8058 one-click `List-Unsubscribe-Post` POST works from mail
  # clients (and so a fired artifact, which can't carry a CSRF token, can host
  # the sign-up form).
  scope "/newsletter", KilnCMSWeb do
    pipe_through :public_form

    # POST only: sign-up mails a confirmation link, so a GET must never reach it
    # (a link prefetcher would otherwise mail whatever address was in the query
    # string). The row it creates is `:pending` and receives nothing until the
    # address owner clicks that link.
    post "/subscribe", NewsletterController, :subscribe

    get "/confirm/:token", NewsletterController, :confirm
    # GET renders a confirmation page (no state change); POST performs the
    # unsubscribe (the RFC 8058 one-click lands here). Separate actions per verb,
    # so a GET can never mutate.
    get "/unsubscribe/:token", NewsletterController, :unsubscribe_form
    post "/unsubscribe/:token", NewsletterController, :unsubscribe
  end

  # Inbound payment-provider webhooks (#337 Phase 2). POST only — there is no GET
  # here at all, so the newsletter's "a GET can never mutate" property holds
  # trivially. 404s entirely when billing isn't configured, so an unconfigured
  # instance doesn't confirm the route exists (the ProvenanceController posture).
  scope "/billing", KilnCMSWeb do
    pipe_through :provider_webhook

    post "/webhooks/stripe", BillingWebhookController, :stripe
  end

  # Public SEO files + health probe. Rate-limited (`:probe`) so an unauthenticated
  # flood can't hammer the `/up` DB check or sitemap table scan.
  scope "/", KilnCMSWeb do
    pipe_through :probe

    get "/sitemap.xml", SitemapController, :index
    get "/robots.txt", SitemapController, :robots

    # LLM content index (llmstxt.org convention) — the GEO analogue of the sitemap.
    get "/llms.txt", LlmsController, :index

    # Syndication (#486). Site-wide, then one per content type at its own public
    # prefix (`/blog/feed.xml`). The per-type routes are a `:plural` wildcard
    # rather than generated routes because dynamic types (D17) are data, not
    # compile-time — the controller resolves the segment against the org's
    # syndicated types and 404s anything else. Under `:probe` with the sitemap
    # for the same reason: an unauthenticated fetch that scans published rows.
    get "/feed.xml", FeedController, :index
    get "/feed.json", FeedController, :index_json
    get "/:plural/feed.xml", FeedController, :type
    get "/:plural/feed.json", FeedController, :type_json

    # Segment feeds (#720). A `<category>` element is only useful if there is a
    # feed narrow enough to act on, so a type's feed also comes scoped to one
    # category or one tag. `/tags/` matches the calendar's tag route, which the
    # delivery site already links.
    #
    # `/<locale>/feed.xml` needs no route of its own: `KilnCMSWeb.Plugs.SetLocale`
    # strips a supported-locale prefix before the router runs, so it arrives here
    # as plain `/feed.xml` with the locale on the conn — the same mechanism that
    # serves every other delivery URL in every locale off one set of routes.
    get "/:plural/category/:slug/feed.xml", FeedController, :category
    get "/:plural/category/:slug/feed.json", FeedController, :category_json
    get "/:plural/tags/:tag/feed.xml", FeedController, :tag
    get "/:plural/tags/:tag/feed.json", FeedController, :tag_json

    # iCalendar for event-shaped types (#480). Same `:plural` wildcard and the
    # same reason: which types have a calendar is data (a type carrying a
    # `datetime_range` field), not a compile-time fact. The document route is
    # `/<plural>/<slug>/calendar.ics` rather than a `.ics` suffix on the page
    # URL, so it cannot collide with a slug that happens to end in `.ics`.
    get "/calendar.ics", CalendarController, :index
    get "/:plural/calendar.ics", CalendarController, :type
    get "/:plural/tags/:tag/calendar.ics", CalendarController, :tag
    get "/:plural/:slug/calendar.ics", CalendarController, :show

    # The JSON "what's on" index (#766) — the machine-readable twin of the HTML
    # one at `/<plural>`, which needs no route of its own because `/:slug` in the
    # delivery scope already owns single-segment paths (see
    # `ContentController.show_page/2`). Two segments, like `calendar.ics`, so it
    # cannot be shadowed by — or shadow — a document whose slug ends in `.json`.
    # Under `:probe` with the feeds and calendars for the same reason: an
    # unauthenticated fetch that reads published rows.
    get "/:plural/index.json", EventIndexController, :index

    # Web app manifest for the installable editor PWA (#65). Per-org, so it's a
    # controller rather than a `priv/static` file. Unauthenticated by necessity
    # (the browser fetches it as a page subresource) and cheap — a cached
    # branding lookup — so `:probe` is the right ceiling.
    get "/manifest.webmanifest", ManifestController, :show

    # The service worker's offline fallback (#629). Was `priv/static/offline.html`
    # and is now per-org for the same reason the manifest is: a white-labelled
    # site should not show the KilnCMS mark the moment the network drops. Same
    # ceiling, and the same one-segment placement — declared here, ahead of the
    # `[:browser, :delivery]` content scopes, so a document could not shadow it.
    #
    # The `.html` is kept from the static path it replaces: an already-installed
    # service worker precached that exact URL, and keeping it means those clients
    # resolve rather than 404 until they update.
    get "/offline.html", OfflineController, :show

    # ActivityPub discovery (#491). Unauthenticated machine fetches of per-org
    # documents — the same shape as the manifest above, so the same ceiling.
    # All four 404 unless federation is on for both the deployment and the site.
    #
    # A single fixed `/actor` rather than Mastodon's `/users/:name`: a Kiln site
    # is one publication, not a user directory, and a fixed path cannot be
    # shadowed by a content type whose plural happens to collide. Declared here,
    # ahead of the `[:browser, :delivery]` content scopes, so it wins outright.
    get "/.well-known/webfinger", FederationController, :webfinger
    get "/actor", FederationController, :actor
    get "/actor/outbox", FederationController, :outbox
    get "/actor/followers", FederationController, :followers

    # Every activity this site delivers carries an object id under this path.
    # An id that does not dereference is a broken post on the receiving side —
    # Mastodon re-resolves objects on refresh and to confirm a Delete.
    get "/ap/object/:id", FederationController, :object

    # NB `GET /live` (DB-free liveness, #816) is answered by the endpoint plug
    # `KilnCMSWeb.Plugs.Liveness` BEFORE the router — deliberately, so it never
    # reaches SetTenant's host resolution (a DB read). It is not a route here.
    #
    # Readiness: 200 only when the database is also reachable, else 503 — for the
    # load balancer / uptime monitor deciding whether to route traffic here.
    get "/up", HealthController, :show
    # Readiness probe with DB + Oban queue-depth payload for monitoring.
    get "/ready", HealthController, :ready
  end

  # The ActivityPub inbox. Its own scope so it can skip `:accepts` and CSRF —
  # see the `:activitypub_inbox` pipeline.
  scope "/", KilnCMSWeb do
    pipe_through :activitypub_inbox

    post "/actor/inbox", FederationController, :inbox
  end

  scope "/", KilnCMSWeb do
    pipe_through :browser

    get "/", PageController, :home
    # Served summary of the headless API surfaces — the header/footer
    # "GraphQL" / "JSON:API" links land here instead of on raw endpoints (#319).
    get "/developers", PageController, :developers
    # UI locale switcher — persists the chosen locale in the session.
    get "/locale/:locale", LocaleController, :update
  end

  scope "/", KilnCMSWeb do
    pipe_through :browser_auth

    # Passkey (WebAuthn) sign-in ceremony (#331) — JSON two-step driven by
    # progressive-enhancement JS on /sign-in; same :auth rate limit + CSRF.
    # Registered BEFORE auth_routes: its catch-all under /auth would shadow
    # these paths otherwise.
    post "/auth/passkey/options", PasskeyController, :options
    post "/auth/passkey/verify", PasskeyController, :verify

    auth_routes AuthController, KilnCMS.Accounts.User, path: "/auth"
    # Two routes, not one: a `DELETE` to the controller *and* a `live` route in
    # its own `live_session`. The second is easy to miss and is joinable at the
    # channel with a scraped session blob like any other, so it needs the same
    # wrapper as the token pages below (#701).
    #
    # `layout:` / `on_mount:` / `overrides:` mirror the token routes below: this
    # route defaulted `overrides:` to the library's `Default`, so Kiln's
    # `SignOutLive` / `Components.SignOut` overrides never applied and the page
    # shipped the library's `dark:` classes instead of Kiln's `data-theme` ones,
    # and it drew no white-label banner (#884).
    sign_out_route AuthController, "/sign-out",
      live_view: KilnCMSWeb.SignOutLive,
      layout: {KilnCMSWeb.Layouts, :auth},
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :restore_locale},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org}
      ],
      overrides: [KilnCMSWeb.AuthOverrides]

    # Second-factor (TOTP) prompt after the first factor for a 2FA-enabled
    # account (#331). Gated by the signed :pending_2fa session token, not a login.
    get "/sign-in/verify", TwoFactorController, :new
    post "/sign-in/verify", TwoFactorController, :create

    # Show the registration link/route only when open self-registration is
    # enabled (the default). Set `config :kiln_cms, :registration_enabled, false`
    # for invite-only mode — the registration *action* is also gated, so this
    # just hides the UI affordance. (See KilnCMS.Accounts.Validations.RegistrationEnabled.)
    # `layout:` + `:assign_current_org` give the auth pages white-label branding
    # (#48): the AshAuthentication `Components.Banner` overrides are compile-time
    # literals, so `Layouts.auth/1` draws the per-org logo and site name instead.
    # `:assign_current_org` resolves from the socket host and needs no user.
    # `live_view:` is `KilnCMSWeb.SignInLive` — the library's page with the
    # socket's client address attached, because the sign-in submit is a LiveView
    # event and so passes none of this pipeline's plugs, `:auth` included (#715).
    if Application.compile_env(:kiln_cms, :registration_enabled, true) do
      sign_in_route register_path: "/register",
                    reset_path: "/reset",
                    auth_routes_prefix: "/auth",
                    live_view: KilnCMSWeb.SignInLive,
                    layout: {KilnCMSWeb.Layouts, :auth},
                    on_mount: [
                      {KilnCMSWeb.LiveUserAuth, :restore_locale},
                      {KilnCMSWeb.LiveUserAuth, :assign_current_org},
                      {KilnCMSWeb.LiveUserAuth, :live_no_user}
                    ],
                    overrides: [KilnCMSWeb.AuthOverrides]
    else
      sign_in_route reset_path: "/reset",
                    auth_routes_prefix: "/auth",
                    live_view: KilnCMSWeb.SignInLive,
                    layout: {KilnCMSWeb.Layouts, :auth},
                    on_mount: [
                      {KilnCMSWeb.LiveUserAuth, :restore_locale},
                      {KilnCMSWeb.LiveUserAuth, :assign_current_org},
                      {KilnCMSWeb.LiveUserAuth, :live_no_user}
                    ],
                    overrides: [KilnCMSWeb.AuthOverrides]
    end

    # `live_view:` on these three is the #701 fix, and it is the same move
    # `sign_in_route` above already makes for a different reason. `layout:` and
    # `on_mount:` here are the *route's*, and a url-less join matches no route,
    # so it skips both — including `:assign_current_org`, which is what leaves
    # the page rendering the default org's name and logo on a tenant host.
    # Pointing at a Kiln wrapper puts these views under
    # `use KilnCMSWeb, :live_view` and so under `KilnCMSWeb.LiveRouteGuard`
    # (#688), which refuses that join outright. See `KilnCMSWeb.AuthLive`.
    reset_route auth_routes_prefix: "/auth",
                live_view: KilnCMSWeb.ResetLive,
                layout: {KilnCMSWeb.Layouts, :auth},
                on_mount: [
                  {KilnCMSWeb.LiveUserAuth, :restore_locale},
                  {KilnCMSWeb.LiveUserAuth, :assign_current_org}
                ],
                overrides: [KilnCMSWeb.AuthOverrides]

    confirm_route KilnCMS.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      live_view: KilnCMSWeb.ConfirmLive,
      layout: {KilnCMSWeb.Layouts, :auth},
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :restore_locale},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org}
      ],
      overrides: [KilnCMSWeb.AuthOverrides]

    magic_sign_in_route(KilnCMS.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      live_view: KilnCMSWeb.MagicSignInLive,
      layout: {KilnCMSWeb.Layouts, :auth},
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :restore_locale},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org}
      ],
      overrides: [KilnCMSWeb.AuthOverrides]
    )
  end

  # Dev-only browser tooling (LiveDashboard, Swoosh mailbox preview, AshAdmin).
  # Registered BEFORE the public content delivery routes below so the
  # single/two-segment `/:type/:slug` and `/:slug` catch-alls can't shadow these
  # paths in development. The blocks are compile-gated to `dev_routes`, so
  # production routing is unaffected.
  if Application.compile_env(:kiln_cms, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser_dev_tools

      live_dashboard "/dashboard", metrics: KilnCMSWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:kiln_cms, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser_dev_tools

      # Default the AshAdmin actor to the signed-in user so policy-driven admin
      # actions reflect real RBAC (issue #24). The `session:` MFA forwards the
      # AshAuthentication session into AshAdmin's live_session; the actor itself
      # is resolved by `KilnCMSWeb.AshAdmin.ActorPlug` (config/dev.exs).
      ash_admin "/", session: {KilnCMSWeb.AshAdmin.ActorPlug, :admin_session, []}
    end
  end

  # The public join page (#337 Phase 2) — where the paywall CTA sends a reader.
  # Anonymous-tolerant: someone who hasn't signed up yet must be able to see what
  # is on offer. Registered BEFORE the delivery catch-alls below, or `/:slug`
  # would swallow it.
  scope "/", KilnCMSWeb do
    pipe_through [:browser, :delivery]

    ash_authentication_live_session :member_public_routes,
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :current_user},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org},
        {KilnCMSWeb.LiveUserAuth, :restore_locale}
      ] do
      live "/membership", MembershipLive, :index
    end
  end

  # Plugin public pages (D18) — compiled in from each installed plugin's
  # `public_routes/0`. Registered BEFORE the delivery catch-alls below, so a
  # plugin path (e.g. /book) can't be shadowed by a content slug. Anonymous:
  # `:current_user` assigns the user when present but requires nothing.
  scope "/" do
    pipe_through :browser

    ash_authentication_live_session :plugin_public_routes,
      on_mount: [
        {KilnCMSWeb.LiveUserAuth, :current_user},
        {KilnCMSWeb.LiveUserAuth, :assign_current_org},
        {KilnCMSWeb.LiveUserAuth, :restore_locale}
      ] do
      import KilnCMSWeb.PluginRouter
      plugin_public_routes()
    end
  end

  # Document downloads (#481) and A/V playback (#494) — anonymous-tolerant
  # like the rest of public delivery (`:browser`'s `load_from_session`
  # resolves `current_user` when a session cookie is present, without
  # requiring one), but registered here, BEFORE the `/:slug` catch-all below,
  # so `/media/<id>/download` can't be shadowed by it.
  scope "/", KilnCMSWeb do
    pipe_through [:browser, :delivery]

    get "/media/:id/download", MediaDownloadController, :show
    # Inline, Range-capable playback — the `src` of every video/audio block
    # and of their caption `<track>`. Same authorization as the download.
    get "/media/:id/stream", MediaDownloadController, :stream
  end

  # Passphrase submission from a lock page (#496). Its own scope purely so it can
  # carry the tight `:unlock` bucket without putting it on every content GET —
  # `:delivery` still applies, so the failure re-render gets the same layout and
  # code injection the lock page itself had.
  scope "/", KilnCMSWeb do
    pipe_through [:browser, :delivery, :content_unlock]

    post "/_unlock", ContentController, :unlock
  end

  # Public content delivery (HTML). Defined last among "/" routes so the
  # root-level `/:slug` page route can't shadow auth/editor/SEO/dev paths above.
  # Only published content is reachable (see ContentController).
  scope "/", KilnCMSWeb do
    pipe_through [:browser, :delivery]

    get "/blog", ContentController, :blog_index
    get "/blog/:slug", ContentController, :show_post
    # Public on-site search (#149). Literal path, before the `/:slug` catch-all.
    get "/search", ContentController, :search
    # Generic delivery for any other content type at `/<plural>/<slug>`. Defined
    # after the literal `/blog` routes (so posts win) and alongside the
    # single-segment page route (different arity — no collision).
    get "/:type/:slug", ContentController, :show_content
    get "/:slug", ContentController, :show_page
    # Anything deeper only exists as a (manual) redirect source — e.g. a legacy
    # `/2019/05/old-post` imported from a previous site (#457). 301 or 404.
    get "/*path", ContentController, :fallback
  end

  # Other scopes may use custom stacks.
  # scope "/api", KilnCMSWeb do
  #   pipe_through :api
  # end

  # API explorer UIs — dev/CI only (`config :kiln_cms, dev_routes: true` in
  # dev.exs). Production keeps `/gql` and `/api/json` headless endpoints only.
  if Application.compile_env(:kiln_cms, :dev_routes) do
    scope "/gql" do
      pipe_through [:graphql]

      forward "/playground", Absinthe.Plug.GraphiQL,
        schema: Module.concat(["KilnCMSWeb.GraphqlSchema"]),
        socket: Module.concat(["KilnCMSWeb.GraphqlSocket"]),
        interface: :simple
    end
  end

  # --- Content-Security-Policy plugs ----------------------------------------
  #
  # Override the static CSP from `put_secure_browser_headers` above with a
  # per-request nonce (strict) or a relaxed dev-only policy (AshAdmin tooling).

  defp put_browser_csp(conn, _opts) do
    nonce = generate_csp_nonce()

    conn
    |> Plug.Conn.assign(:csp_nonce, nonce)
    |> Plug.Conn.put_resp_header(
      "content-security-policy",
      "script-src 'self' 'nonce-#{nonce}'; #{base_csp()}"
    )
  end

  # Runtime variant of `@base_csp`: identical except `img-src` also allows
  # operator-configured external image hosts (`config :kiln_cms, :csp_img_src`
  # / `CSP_IMG_SRC` — for media libraries whose files serve from an external
  # CDN, e.g. Cloudflare Images) plus Unsplash's thumbnail host while the
  # media library's Unsplash integration is enabled.
  #
  # `media-src` (#494) gets the storage-CDN hosts too, but NOT the Unsplash /
  # oEmbed thumbnail hosts: those serve thumbnails, and widening `media-src`
  # to a host that will never hold a `<video>` source buys nothing.
  defp base_csp do
    # oEmbed card thumbnails (#489). Only the enabled providers' CDNs, and
    # only their *known* hosts — the resolver already refuses a thumbnail
    # URL that is not one of these, so the two lists cannot drift into
    # allowing something nothing renders (or rendering something the policy
    # blocks). Empty when the feature is off, which is the default.
    storage_hosts = Application.get_env(:kiln_cms, :csp_img_src, [])

    img_hosts =
      Enum.uniq(
        storage_hosts ++
          KilnCMS.Unsplash.csp_img_src() ++
          KilnCMS.OEmbed.Provider.thumbnail_hosts()
      )

    @base_csp
    |> widen(@img_src_base, img_hosts)
    |> widen(@media_src_base, Enum.uniq(storage_hosts))
  end

  defp widen(csp, _directive, []), do: csp

  defp widen(csp, directive, hosts),
    do: String.replace(csp, directive, directive <> " " <> Enum.join(hosts, " "))

  # For pipelines that keep the static (nonce-less) `script-src 'self'` policy:
  # re-issue the same header as `@browser_csp_headers`, but with the runtime
  # img-src so preview/public pages can render externally-hosted media too.
  defp put_static_browser_csp(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", "script-src 'self'; #{base_csp()}")
  end

  # Swagger UI CSP: strict same-origin everything except swagger-ui's cdnjs
  # bundle, plus a per-request nonce for its inline boot script.
  defp put_swagger_csp(conn, _opts) do
    nonce = generate_csp_nonce()

    conn
    |> Plug.Conn.assign(:swagger_script_nonce, nonce)
    |> Plug.Conn.put_resp_header(
      "content-security-policy",
      "script-src 'self' 'nonce-#{nonce}' https://cdnjs.cloudflare.com; #{@swagger_csp}"
    )
  end

  defp put_dev_browser_csp(conn, _opts) do
    conn
    |> Plug.Conn.assign(:csp_nonce, generate_csp_nonce())
    |> Plug.Conn.put_resp_header(
      "content-security-policy",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'; #{base_csp()}"
    )
  end

  defp generate_csp_nonce,
    do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
