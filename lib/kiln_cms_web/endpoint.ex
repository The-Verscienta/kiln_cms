defmodule KilnCMSWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :kiln_cms
  # Absinthe.Phoenix.Endpoint + AshGraphql's run_docset override, which routes
  # subscription resolution through the Batcher (skipping data the subscriber
  # isn't allowed to see instead of erroring).
  use AshGraphql.Subscription.Endpoint

  # Mark the cookie `Secure` in production (served over HTTPS via `force_ssl`);
  # left off in dev/test/e2e, which run over plain HTTP where a Secure cookie
  # would never be sent. Config-driven so each env opts in explicitly. It also
  # decides the cookie's `__Host-` prefix, which browsers honour only alongside
  # `Secure` — one flag, so the two cannot disagree (#686).
  @secure_session_cookie Application.compile_env(:kiln_cms, :secure_session_cookie, false)

  # The session cookie's whole shape — name, salts, and the attributes the
  # `__Host-` prefix depends on — lives in `KilnCMSWeb.SessionCookie`, so the
  # production shape is constructible (and therefore assertable) from a
  # non-production build. Evaluated at compile time; `plug Plug.Session` below
  # and the `/live` socket's `connect_info` share the one list.
  @session_options KilnCMSWeb.SessionCookie.options(@secure_session_cookie)

  # Test hook: lets the suite assert that this endpoint takes its cookie from
  # `KilnCMSWeb.SessionCookie` rather than restating it. Not endpoint API.
  @doc false
  @spec session_options() :: keyword()
  def session_options, do: @session_options

  # `connect_info: [:uri]` for the same reason the three sockets below carry it,
  # and it is load-bearing here rather than convenient: a CONNECTED LiveView
  # mount's `socket.host_uri` is rebuilt from the client's join payload, so
  # without this the client names its own organization (#654). `:uri` is the
  # handshake's own request URI — the `Host` header the browser sets from the
  # page's origin, which is exactly the value `SetTenant` trusts over HTTP.
  # `KilnCMSWeb.LiveUserAuth`'s `:assign_current_org` resolves from it and
  # refuses a socket claiming a different org. Declared on both transports:
  # longpoll builds `connect_info` from its own initial HTTP request the same
  # way, so dropping it there would leave that transport unpinned.
  #
  # `:peer_data` and `:x_headers` are what `KilnCMSWeb.Plugs.ClientIp.resolve/2`
  # keys the socket's client address off (#715). The browser sign-in submits its
  # credentials as a LiveView event, never as a form POST, so the router's
  # `:auth` bucket never sees it — `KilnCMSWeb.SignInLive` charges that bucket
  # itself, and this is where it learns whose attempt it is. The plug above
  # rewrites `conn.remote_ip`; a socket has no conn to rewrite, so it needs the
  # raw pair instead.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:uri, :peer_data, :x_headers, session: @session_options]],
    longpoll: [connect_info: [:uri, :peer_data, :x_headers, session: @session_options]]

  # `connect_info: [:uri]` so the socket can resolve its tenant from the
  # connecting host (epic #336) — a raw transport bypasses the SetTenant plug, so
  # without this GraphQL subscriptions/queries over the socket would span orgs.
  # `:peer_data`/`:x_headers` (threat-model item 10, the `/ws/*` half of the
  # #1183 follow-up) are what `KilnCMSWeb.SocketJoinBudget` keys the join
  # budget's client address off — the same pair `/live` already carries, and
  # for the same reason: a socket has no `conn.remote_ip` to read.
  socket "/ws/gql", KilnCMSWeb.GraphqlSocket,
    websocket: [connect_info: [:uri, :peer_data, :x_headers]],
    longpoll: [connect_info: [:uri, :peer_data, :x_headers]]

  # Collaborative-editing CRDT prototype (token-authenticated; joins refuse
  # unless :collab_prototype is enabled — see KilnCMSWeb.CollabChannel).
  # `connect_info: [:uri]` for the same reason as `/ws/gql` above: the socket
  # resolves its tenant from the connecting host, and every join authorizes the
  # document under it (#655). This is also what brings the socket inside
  # `TENANT_STRICT_HOST` (#563), which it previously sat outside. `:peer_data`/
  # `:x_headers` for the join budget, same reason as `/ws/gql` above.
  socket "/ws/collab", KilnCMSWeb.CollabSocket,
    websocket: [connect_info: [:uri, :peer_data, :x_headers]],
    longpoll: false

  # Visual-editing bridge live-preview push (#355). A raw transport socket (plain
  # JSON frames) so the dependency-free `bridge.js` consumes it without a Phoenix
  # JS client. Deliberately cross-origin (an external front end), so origin is
  # gated by the shared `KilnCMSWeb.CORS.check_socket_origin?/1` allowlist rather
  # than the endpoint host, and every connection additionally authorizes the API
  # key against the document's read policy. It carries no ambient credentials
  # (auth is the explicit `api_key` param, never a cookie), so Sobelow's CSWH
  # finding here is a false positive — ignored with rationale in `.sobelow-conf`.
  socket "/ws/bridge", KilnCMSWeb.BridgeSocket,
    websocket: [
      check_origin: {KilnCMSWeb.CORS, :check_socket_origin?, []},
      # The request URI carries the host the socket resolves its tenant from
      # (epic #336) — raw transports bypass the SetTenant plug pipeline.
      # `:peer_data`/`:x_headers` for the join budget, same reason as
      # `/ws/gql` above.
      connect_info: [:uri, :peer_data, :x_headers]
    ],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  #
  # When code reloading is disabled (e.g., in production),
  # the `gzip` option is enabled to serve compressed
  # static files generated by running `phx.digest`.
  plug Plug.Static,
    at: "/",
    from: :kiln_cms,
    gzip: not code_reloading?,
    only: KilnCMSWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  # User-uploaded media (KilnCMS.Storage.Local). Served from priv/uploads,
  # which the Local adapter writes to (the app-dir paths stay in sync). In
  # production a remote adapter (S3/MinIO) would serve these instead.
  plug :secure_upload_headers

  # Storage keys are UUIDs, so a blob never changes under its URL — mark the
  # responses immutable. Without this, Plug.Static's default forces a
  # revalidation round-trip per image per page view on media-heavy pages.
  plug Plug.Static,
    at: "/uploads",
    from: {:kiln_cms, "priv/uploads"},
    gzip: false,
    cache_control_for_etags: "public, max-age=31536000, immutable"

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug AshPhoenix.Plug.CheckCodegenStatus
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :kiln_cms
  end

  # Gated on `dev_routes` — the same flag that mounts `/dashboard` in the
  # router — rather than `code_reloading?`: this plug exists only to serve
  # that route, and every production request otherwise paid a `fetch_cookies`
  # plus a `request_logger` cookie lookup for a dashboard that isn't mounted
  # there, plus a second unprefixed cookie name on the endpoint (#702).
  if Application.compile_env(:kiln_cms, :dev_routes) do
    plug Phoenix.LiveDashboard.RequestLogger,
      param_key: "request_logger",
      cookie_key: "request_logger"
  end

  # DB-free liveness (#816): answer GET /live before SetTenant resolves the host
  # (a DB read), so a restart-triggering healthcheck survives a database outage.
  plug KilnCMSWeb.Plugs.Liveness

  # Resolve the real client IP from X-Forwarded-For when behind a trusted proxy,
  # before anything (rate limiting, logging) reads conn.remote_ip.
  plug KilnCMSWeb.Plugs.ClientIp

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # `Plug.Parsers.JSON` already matches any `application/*+json` subtype, which
  # covers the `application/activity+json` a fediverse server POSTs to the
  # ActivityPub inbox (#491) — so that route reaches the body reader below with
  # no parser change.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json, AshJsonApi.Plug.Parser, Absinthe.Plug.Parser],
    pass: ["*/*"],
    # Explicit request-body cap (Plug's default is 8MB). Bounds the memory a
    # single request can force us to buffer; raise per-endpoint if large uploads
    # are ever needed.
    length: 8_000_000,
    # Preserves the raw bytes for the inbound payment-webhook and ActivityPub
    # inbox paths only, so their signatures can be verified over exactly what
    # was sent. Every other request reads exactly as before — see the module.
    body_reader: {KilnCMSWeb.Plugs.RawBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  # Strip a `/<locale>/…` prefix and set the locale before routing.
  plug KilnCMSWeb.Plugs.SetLocale

  # Resolve the request's organization from its host and set it as the Ash tenant
  # (epic #336), so every pipeline — delivery controllers, GraphQL, JSON:API — is
  # scoped to the right site. Bare-host/localhost requests resolve to the default org.
  plug KilnCMSWeb.Plugs.SetTenant

  # Attach request context (method, path, scrubbed headers/params) to any Sentry
  # event raised while handling this request. No-op without a configured DSN. On
  # Bandit this is the capture path — `Sentry.PlugCapture` is deliberately
  # omitted (it would double-report). See KilnCMS.Application.setup_observability/0.
  #
  # The scrubber is ours rather than Sentry's default, which masks only
  # `password`/`passwd`/`secret`. That was already a partial list — it does not
  # cover the second factor — and #726 added two more secrets to the request
  # body: a `pending_token` plus a `code` is a complete sign-in for a 2FA
  # account, so a single 500 on `/api/auth/sign_in/verify` would ship one to
  # anyone with Sentry read access.
  plug Sentry.PlugContext, body_scrubber: &KilnCMSWeb.SentryScrubber.scrub_params/1

  # CORS for the headless API surfaces (`/api/*`, `/gql`). Ahead of the router so
  # it can answer preflight `OPTIONS` requests, which never match a `get`/`post`
  # route. Scoped to API paths — browser pages stay same-origin.
  plug KilnCMSWeb.Plugs.ApiCORS

  # The console/delivery origin split (#740): with KILN_CONSOLE_HOST set, a
  # console route is only served on that host and tenant content never is.
  # No-op when unset. Ahead of the router because it decides by the route the
  # router *would* match, without dispatching.
  plug KilnCMSWeb.Plugs.ConsoleHost

  plug KilnCMSWeb.Router

  # Force user-uploaded media to download rather than render inline, and disable
  # content-type sniffing — defense-in-depth against a stored file being
  # interpreted as active content in the app origin. (Content-Disposition is
  # ignored for <img>/subresource loads, so legitimate images still render.)
  defp secure_upload_headers(%{path_info: ["uploads" | _]} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("content-disposition", "attachment")
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
  end

  defp secure_upload_headers(conn, _opts), do: conn
end
