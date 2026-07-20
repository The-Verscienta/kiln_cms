defmodule KilnCMSWeb.Router do
  use KilnCMSWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  # Content-Security-Policy. Directives shared by every browser response; the
  # `script-src` directive is finalized per-pipeline (see `put_*_browser_csp`).
  # `style-src` keeps 'unsafe-inline' because inline `style=` attributes can't
  # carry a nonce; everything else is locked to same-origin.
  @base_csp "default-src 'self'; " <>
              "style-src 'self' 'unsafe-inline'; " <>
              "img-src 'self' data: blob:; " <>
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

  # CSP for the Swagger UI explorer (always available — issue #37). Swagger UI
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
    # Bound unauthenticated browsing of the always-on docs explorer (#225). The
    # `docs` bucket is generous enough for interactive use but caps sustained
    # crawler traffic against the UI + forwarded spec.
    plug KilnCMSWeb.Plugs.RateLimit, :docs
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
    plug KilnCMSWeb.Plugs.RateLimit, :auth
    plug :load_from_session
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
    plug KilnCMSWeb.Plugs.RateLimit, :form
  end

  # The iframe page for an embeddable form. A page load, not a submission, so it
  # gets the generous `:delivery` ceiling rather than the tight `:form` bucket.
  # The controller replaces the CSP with `KilnCMSWeb.Embed.content_security_policy/0`,
  # whose `frame-ancestors` permits third-party parents.
  pipeline :form_embed do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers, @browser_csp_headers
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

    ash_authentication_live_session :authenticated_routes do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {KilnCMSWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {KilnCMSWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {KilnCMSWeb.LiveUserAuth, :live_no_user}
    end

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
      live "/editor/translations", TranslationsLive, :index
      live "/editor/search", SearchPaletteLive, :index
      live "/editor/taxonomy", TaxonomyLive, :index
      live "/editor/analytics", AnalyticsLive, :index
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
      # Team + granular-RBAC management (#332 slice 4).
      live "/editor/team", TeamLive, :index
      # Editorial automation (#342) — no-code "when X happens, do Y" rules.
      live "/editor/automation", AutomationLive, :index
      live "/editor/fields", FieldDefinitionLive, :index
      live "/editor/types", TypeDefinitionLive, :index
      live "/editor/mail", MailSettingsLive, :index
      live "/editor/newsletter", NewsletterLive, :index
      # Compliance & governance dashboard (#352) — audit trail, consent, and
      # point-in-time history per content item.
      live "/editor/governance", GovernanceLive, :index
      live "/editor/governance/:type/:id", GovernanceLive, :show
      live "/editor/forms", FormLive, :index
      live "/editor/api-keys", ApiKeyLive, :index

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

  # Interactive API docs — Swagger UI over the published OpenAPI spec. Always
  # available (issue #37). Registered BEFORE the `/api/json` catch-all forward
  # below so the forward can't shadow `/swaggerui`.
  scope "/api/json" do
    pipe_through :swagger_ui

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      # Nonce the inline boot script so it runs under the strict `script-src`.
      csp_nonce_assign_key: %{script: :swagger_script_nonce},
      default_model_expand_depth: 4
  end

  # Headless JSON:API — always available, including the OpenAPI spec served by
  # the router itself at `/api/json/open_api`.
  scope "/api/json" do
    pipe_through [:api]

    forward "/", KilnCMSWeb.AshJsonApiRouter
  end

  # Headless sign-in: POST credentials, receive a bearer token (issue #37).
  scope "/api/auth", KilnCMSWeb do
    pipe_through :api_auth

    post "/sign_in", ApiAuthController, :sign_in
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

    live_session :token_preview do
      live "/:token/live", TokenPreviewLive, :show
    end
  end

  # Public newsletter confirm/unsubscribe — authorized by an opaque per-subscriber
  # token, not a session. Uses the CSRF-free :public_form pipeline so the RFC 8058
  # one-click `List-Unsubscribe-Post` POST works from mail clients.
  scope "/newsletter", KilnCMSWeb do
    pipe_through :public_form

    get "/confirm/:token", NewsletterController, :confirm
    # GET renders a confirmation page (no state change); POST performs the
    # unsubscribe (the RFC 8058 one-click lands here). Separate actions per verb,
    # so a GET can never mutate.
    get "/unsubscribe/:token", NewsletterController, :unsubscribe_form
    post "/unsubscribe/:token", NewsletterController, :unsubscribe
  end

  # Public SEO files + health probe. Rate-limited (`:probe`) so an unauthenticated
  # flood can't hammer the `/up` DB check or sitemap table scan.
  scope "/", KilnCMSWeb do
    pipe_through :probe

    get "/sitemap.xml", SitemapController, :index
    get "/robots.txt", SitemapController, :robots

    # LLM content index (llmstxt.org convention) — the GEO analogue of the sitemap.
    get "/llms.txt", LlmsController, :index

    # Health probe for load balancers / uptime monitors / Coolify.
    get "/up", HealthController, :show
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
    sign_out_route AuthController

    # Second-factor (TOTP) prompt after the first factor for a 2FA-enabled
    # account (#331). Gated by the signed :pending_2fa session token, not a login.
    get "/sign-in/verify", TwoFactorController, :new
    post "/sign-in/verify", TwoFactorController, :create

    # Show the registration link/route only when open self-registration is
    # enabled (the default). Set `config :kiln_cms, :registration_enabled, false`
    # for invite-only mode — the registration *action* is also gated, so this
    # just hides the UI affordance. (See KilnCMS.Accounts.Validations.RegistrationEnabled.)
    if Application.compile_env(:kiln_cms, :registration_enabled, true) do
      sign_in_route register_path: "/register",
                    reset_path: "/reset",
                    auth_routes_prefix: "/auth",
                    on_mount: [{KilnCMSWeb.LiveUserAuth, :live_no_user}],
                    overrides: [KilnCMSWeb.AuthOverrides]
    else
      sign_in_route reset_path: "/reset",
                    auth_routes_prefix: "/auth",
                    on_mount: [{KilnCMSWeb.LiveUserAuth, :live_no_user}],
                    overrides: [KilnCMSWeb.AuthOverrides]
    end

    reset_route auth_routes_prefix: "/auth",
                overrides: [KilnCMSWeb.AuthOverrides]

    confirm_route KilnCMS.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [KilnCMSWeb.AuthOverrides]

    magic_sign_in_route(KilnCMS.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
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
      "script-src 'self' 'nonce-#{nonce}'; #{@base_csp}"
    )
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
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'; #{@base_csp}"
    )
  end

  defp generate_csp_nonce,
    do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
