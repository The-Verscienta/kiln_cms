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

  pipeline :graphql do
    plug KilnCMSWeb.Plugs.RateLimit, :gql
    plug :load_from_bearer
    plug :set_actor, :user
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
  pipeline :preview do
    plug :accepts, ["json"]
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
      on_mount: [{KilnCMSWeb.LiveUserAuth, :live_editor_required}] do
      live "/media", MediaLive, :index
      live "/editor", EditorLive, :index
      live "/editor/taxonomy", TaxonomyLive, :index
      live "/editor/trash", TrashLive, :index
      # Generic editor route — works for any content type (incl. ones generated
      # by `mix kiln.gen.content`). The `:page`/`:post` routes are kept as
      # backward-compatible aliases.
      live "/editor/content/:type/:id", ContentEditorLive, :content
      live "/editor/pages/:id", ContentEditorLive, :page
      live "/editor/posts/:id", ContentEditorLive, :post
      live "/editor/preview/:kind/:id", PreviewLive, :show
    end
  end

  # Headless GraphQL — always available; the interactive playground is dev-only
  # (see the `dev_routes` block below).
  scope "/gql" do
    pipe_through [:graphql]

    forward "/", Absinthe.Plug, schema: Module.concat(["KilnCMSWeb.GraphqlSchema"])
  end

  # Headless JSON:API — always available; Swagger UI + OpenAPI spec are dev-only.
  scope "/api/json" do
    pipe_through [:api]

    forward "/", KilnCMSWeb.AshJsonApiRouter
  end

  scope "/preview", KilnCMSWeb do
    pipe_through :preview

    get "/:token", PreviewController, :show
  end

  # Public SEO files (fixed content types; no pipeline needed).
  scope "/", KilnCMSWeb do
    get "/sitemap.xml", SitemapController, :index
    get "/robots.txt", SitemapController, :robots

    # Health probe for load balancers / uptime monitors / Coolify.
    get "/up", HealthController, :show
  end

  scope "/", KilnCMSWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", KilnCMSWeb do
    pipe_through :browser_auth

    auth_routes AuthController, KilnCMS.Accounts.User, path: "/auth"
    sign_out_route AuthController

    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{KilnCMSWeb.LiveUserAuth, :live_no_user}],
                  overrides: [KilnCMSWeb.AuthOverrides]

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

  # Public content delivery (HTML). Defined last among "/" routes so the
  # root-level `/:slug` page route can't shadow auth/editor/SEO paths above.
  # Only published content is reachable (see ContentController).
  scope "/", KilnCMSWeb do
    pipe_through :browser

    get "/blog", ContentController, :blog_index
    get "/blog/:slug", ContentController, :show_post
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

  # Enable LiveDashboard and Swoosh mailbox preview in development
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

      ash_admin "/"
    end
  end

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

    scope "/api/json" do
      pipe_through :browser_dev_tools

      forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
        path: "/api/json/open_api",
        default_model_expand_depth: 4
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
