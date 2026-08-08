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

  Shares the split/trim/wildcard half with `EMBED_ORIGINS` via
  `KilnCMS.Config.OriginList` (#651). What differs, deliberately, is what a
  malformed entry costs: `EMBED_ORIGINS` discards the whole value, because a bad
  entry there can widen a CSP. A CORS origin is only ever compared for equality
  (`allowed_origin?/2`, `check_socket_origin?/1`), so a malformed one can do
  nothing but fail to match — failing the whole list closed over a stray typo
  would take a working integration down to fix a nuisance. So the bad entries
  are named on stderr and the rest are applied.

  That warning is the point. An entry that can never match is invisible
  otherwise: the browser reports a CORS failure, the server logs a clean 200,
  and nothing connects the two to a trailing slash in an env var.
  """
  @spec parse_env(String.t() | nil) :: :all | [String.t()]
  def parse_env(value) do
    KilnCMS.Config.OriginList.parse(value,
      name: "CORS_ORIGINS",
      validator: &valid_origin?/1,
      on_invalid: :keep,
      describe: "origin",
      example: "https://app.acme.com or http://localhost:3000"
    )
  end

  @doc """
  Whether `origin` has the shape a browser's `Origin` header actually takes:
  scheme, host, optional port — and nothing else.

  The mistakes this catches are the ones that produce a silent no-match: a
  trailing slash (`https://acme.com/`), a path, a bare host with no scheme, or a
  `*` mixed into a list. A browser never sends any of those, so an allowlist
  entry in that shape is dead weight the operator believes is live.

  `null` is rejected too. Browsers do send `Origin: null` — sandboxed iframes,
  `file://`, some redirects — but allowlisting it grants every one of those at
  once, so it is worth saying out loud rather than accepting quietly. The
  warning does not remove it (`on_invalid: :keep`), so an operator who means it
  keeps it.
  """
  @spec valid_origin?(String.t()) :: boolean()
  def valid_origin?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        path in [nil, ""]

      _otherwise ->
        false
    end
  end

  def valid_origin?(_origin), do: false
end
