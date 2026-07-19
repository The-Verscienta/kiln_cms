defmodule KilnCMSWeb.CORS do
  @moduledoc """
  Cross-origin policy for the headless API surfaces (`/api/*`, `/gql`).

  Browser clients served from a different origin — a decoupled SPA, browser-side
  `fetch` from the LiveView showcase, third-party integrators — can't read the
  JSON/GraphQL endpoints without CORS headers. Corsica adds them; this module
  decides which origins are allowed, resolved **per request** from application
  config so `CORS_ORIGINS` can be set at runtime (see `config/runtime.exs`).

  Config shape (`config :kiln_cms, :cors_origins, …`):

    * `:all` — echo any origin (dev default; safe here because the API
      authenticates via bearer/API-key headers, never cookies, so there are no
      ambient credentials to leak).
    * `[origin, …]` — an allowlist of exact origin strings.
    * `[]` (the production default) — deny all cross-origin reads; same-origin
      requests are unaffected since Corsica only acts when an `Origin` header is
      present.

  Used as `plug Corsica, origins: {KilnCMSWeb.CORS, :allowed_origin?, []}` — the
  MFA form calls `allowed_origin?/2` with the conn and the request origin.
  """

  @doc "Whether `origin` is permitted, per the runtime `:cors_origins` config."
  @spec allowed_origin?(Plug.Conn.t(), String.t()) :: boolean()
  def allowed_origin?(_conn, origin) do
    case configured_origins() do
      :all -> true
      origins when is_list(origins) -> origin in origins
      _ -> false
    end
  end

  @doc """
  Whether a WebSocket `Origin` (as a `%URI{}`) is permitted — the socket-transport
  analogue of `allowed_origin?/2`, wired as Phoenix `check_origin: {mod, fun, []}`
  for the visual-editing bridge socket (#355). Reuses the same `:cors_origins`
  allowlist as the HTTP API, so one config governs both cross-origin reads and
  the live-preview push.
  """
  @spec check_socket_origin?(URI.t()) :: boolean()
  def check_socket_origin?(%URI{} = uri) do
    case configured_origins() do
      :all -> true
      origins when is_list(origins) -> origin_string(uri) in origins
      _ -> false
    end
  end

  defp origin_string(%URI{scheme: scheme, host: host, port: port}) do
    if port in [nil, 80, 443] do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp configured_origins, do: Application.get_env(:kiln_cms, :cors_origins, [])

  @doc """
  Parses a `CORS_ORIGINS` env value into the config shape. `"*"` → `:all`;
  otherwise a comma-separated allowlist (blank entries dropped). Returns `[]`
  for a blank/empty value (deny all).
  """
  @spec parse_env(String.t() | nil) :: :all | [String.t()]
  def parse_env(nil), do: []

  def parse_env(value) when is_binary(value) do
    case String.trim(value) do
      "*" ->
        :all

      trimmed ->
        trimmed
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end
