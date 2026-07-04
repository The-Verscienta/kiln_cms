defmodule ShowcaseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :showcase

  # LiveView socket. A short signing salt is fine for a local demo; nothing
  # sensitive rides the session (there are no accounts here).
  @session_options [
    store: :cookie,
    key: "_showcase_key",
    signing_salt: "kiln-showcase",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :showcase,
    gzip: false,
    only: ShowcaseWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ShowcaseWeb.Router
end
