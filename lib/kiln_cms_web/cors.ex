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
  would take a working integration down to fix a nuisance. So the suspect
  entries are named on stderr and the value is applied **unchanged**: the
  validator below is a heuristic about what browsers send, and dropping an entry
  on a heuristic would be the same outage by a quieter route.

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
  scheme, host, optional port — and nothing else, byte for byte.

  Every entry here is compared for **exact equality** against what the browser
  sent, so "close enough" is the same as absent. The mistakes this catches are
  the ones that then produce a silent no-match: the browser reports a CORS
  failure, the server logs a clean 200, and nothing connects the two to a
  trailing slash in an env var.

    * a trailing slash, a path, a query or a fragment — `https://acme.com/`
    * a bare host with no scheme — `acme.com`
    * a `*` anywhere, including `https://*.acme.com`: there is no wildcard
      matching here, so that entry matches nothing at all
    * an uppercase scheme or host — browsers send both downcased
    * a non-ASCII host — browsers send punycode (`xn--…`)

  **Any scheme, not just http(s).** An `Origin` is a *serialized origin*, and
  browsers legitimately send `chrome-extension://…`, `moz-extension://…`,
  `capacitor://localhost`, `tauri://localhost`, `app://…`. Restricting this to
  http/https would warn about working allowlist entries, which trains an
  operator to ignore the warning — the one outcome that makes it worthless.

  `null` is called out, though. Browsers do send `Origin: null` — sandboxed
  iframes, `file://`, some redirects — but allowlisting it grants every one of
  those at once, so it is worth saying out loud. Nothing is removed
  (`on_invalid: :keep`), so an operator who means it keeps it.
  """
  # RFC 3986 scheme grammar, already downcased by the guard above it.
  @scheme ~r/\A[a-z][a-z0-9+.\-]*\z/
  # A registered name as a browser serializes it: downcased, punycode for IDNs.
  # The bracketed form is an IPv6 literal, which `URI.parse/1` hands back
  # unbracketed.
  @host ~r/\A[a-z0-9]([a-z0-9.\-]*[a-z0-9])?\z/
  @ipv6 ~r/\A[0-9a-f:.]+\z/

  @spec valid_origin?(String.t()) :: boolean()
  def valid_origin?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        path in [nil, ""] and Regex.match?(@scheme, scheme) and
          (Regex.match?(@host, host) or Regex.match?(@ipv6, host))

      _otherwise ->
        false
    end
  end

  def valid_origin?(_origin), do: false
end
