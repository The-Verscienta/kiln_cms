defmodule KilnCMSWeb.Plugs.PublicCache do
  @moduledoc """
  Shared-cache headers for **anonymous** reads of the headless read APIs —
  JSON:API (`/api/json`), GraphQL `GET` (`/gql`) and `/api/search`.

  Before this, only the fired-artifact API (`/api/content/:type/:slug`) told a
  CDN anything; every other read went out with Plug's default
  `max-age=0, private, must-revalidate`, so each delivery request reached the
  app. This plug registers a `before_send` callback that decides the caching
  story from the finished response.

  ## Anonymous, or not at all

  A request is **anonymous** when it carries none of:

    * an `Authorization` header — a JWT or `kiln_…` API key authorizes as an
      account, and an editor's token sees drafts on these same URLs;
    * an `x-api-key` header (allowed by CORS; treated like `Authorization`);
    * an unlock grant (#496) — the `x-kiln-unlock` header or `?unlock=` param.
      These three surfaces never honour one (their read policies exclude
      locked rows for every non-editor), but a caller presenting a grant is
      asking for a per-caller answer and gets a per-caller header;
    * a `Cookie`. Nothing on these surfaces reads one today —
      `KilnCMSWeb.Plugs.SetLocale` puts the session's locale in the assigns,
      but the APIs take their locale from `?locale=`/arguments only — so this
      is the conservative reading of "anonymous", not a known dependency.

  An anonymous, successful (`200`) `GET` that carries no request body, whose
  response sets no cookie and whose handler left Plug's default `cache-control`
  alone gets:

    * `cache-control: public, max-age=N, stale-while-revalidate=M`;
    * an `ETag` — a digest of the **body and its content type**, so it covers
      everything that shapes the response by construction (#1079 was an ETag
      keyed on fields that missed one input); a matching `If-None-Match` turns
      the response into a bodyless `304`. It is *weak* (`W/"…"`) on purpose:
      Bandit will not gzip a response carrying a strong one (a strong validator
      promises byte-identical bodies, and the compressed body is not), and
      `If-None-Match` only ever uses the weak comparison anyway;
    * `surrogate-key` / `cache-tag` naming the site (`put_surrogate_keys/1`),
      which `KilnCMS.CDN` purges on publish.

  Everything else keeps what the handler chose, except that a non-anonymous
  response still carrying the default is tightened to `private, no-store` — a
  bearer token is exactly the request whose body is not the URL's.

  A handler that set its own `cache-control` is never overridden — the plug
  only ever replaces Plug's untouched default, so a route that later decides
  it is per-caller (`private, no-store`) keeps that decision.

  ## Vary

  Every response — anonymous or not, cached or not — gets
  `Vary: Accept, Authorization, Origin`, **merged** into any `Vary` already
  present. The anonymous response is the one a cache stores, and it is served
  to later requests that *do* carry a token unless the cache is told the token
  changes the answer. `Accept` because JSON:API negotiates its media type on
  it. `Origin` always, not only when Corsica adds it: Corsica sets
  `Access-Control-Allow-Origin` (and its own `Vary: origin`) only on a request
  that *has* an allowed `Origin`, so a copy cached from a server-side fetch
  with no `Origin` would otherwise be handed to a browser without the header
  it needs, and the browser would refuse it. The header only protects caches
  that honour it; `docs/api.md` spells out the bypass rule for a CDN that does
  not.

  Deliberately **not** `Accept-Language` or `Cookie`: the locale of all three
  surfaces is a URL input (`?locale=`, a GraphQL argument, a JSON:API filter or
  a `/fr/` path prefix), already in every cache key, and varying on either would
  split one cached answer into one per browser for nothing. If a surface ever
  starts reading either, it belongs here.

  ## GraphQL

  `opts[:graphql]` adds one refusal: the operation must have completed without
  an `errors` member — a resolver timeout is a `200` with `errors`, and must not
  be pinned for a minute. Mutations need no rule of their own: only a `GET` is
  considered, Absinthe refuses a mutation over `GET` with a `405`, and only a
  `200` is cached. A subscription over `GET` is a chunked event stream, which
  is never a candidate either (only a buffered body can be digested).

  And the document must be in the URL (`?query=`). Absinthe reads the request
  *body* as the document when the query string names none, so a `GET /gql/x`
  with a body could otherwise have any query's answer stored under a URL that
  says nothing about it. Every surface also refuses a `GET` that declares a body
  (`content-length`/`transfer-encoding`), as a second line.
  """
  @behaviour Plug

  import Plug.Conn

  # Plug's own initial value (`Plug.Conn`'s `resp_headers` default). A handler
  # that changed it made a decision this plug must not second-guess.
  @plug_default "max-age=0, private, must-revalidate"

  @vary ~w(accept authorization origin)

  @credential_headers ~w(authorization x-api-key x-kiln-unlock cookie)

  @impl true
  def init(opts), do: %{graphql: Keyword.get(opts, :graphql, false)}

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, opts) do
    conn = fetch_query_params(conn)
    anonymous? = anonymous?(conn)
    # GraphQL: only a document named by the URL. See the moduledoc.
    url_document? = not opts.graphql or Map.has_key?(conn.query_params, "query")
    register_before_send(conn, &finalize(&1, anonymous?, url_document?, opts))
  end

  # A write is never cacheable and never 304s; it still says the body is
  # per-credential, so a cache that stored a GET under this URL knows why.
  def call(conn, _opts), do: register_before_send(conn, &put_vary/1)

  @doc "Whether `conn` presents no credential, grant or cookie (see the moduledoc)."
  @spec anonymous?(Plug.Conn.t()) :: boolean()
  def anonymous?(conn) do
    conn = fetch_query_params(conn)

    Enum.all?(@credential_headers, &(get_req_header(conn, &1) == [])) and
      not Map.has_key?(conn.query_params, "unlock")
  end

  @doc """
  Put `surrogate-key` (Fastly, space-separated) and `cache-tag` (Cloudflare,
  comma-separated) naming the conn's site — `KilnCMS.CDN.surrogate_keys/1`.
  Also used by the fired-artifact API, so a publish purge reaches it too.
  """
  @spec put_surrogate_keys(Plug.Conn.t()) :: Plug.Conn.t()
  def put_surrogate_keys(%Plug.Conn{assigns: %{current_org: %{id: org_id}}} = conn) do
    keys = KilnCMS.CDN.surrogate_keys(org_id)

    conn
    |> put_resp_header("surrogate-key", Enum.join(keys, " "))
    |> put_resp_header("cache-tag", Enum.join(keys, ","))
  end

  def put_surrogate_keys(conn), do: conn

  @doc """
  The configured `cache-control` for an anonymous API read, or `nil` when
  `enabled: false` (`KILN_API_CACHE=false`) turns public marking off.
  """
  @spec cache_control(keyword()) :: String.t() | nil
  def cache_control(config \\ Application.get_env(:kiln_cms, __MODULE__, [])) do
    max_age = Keyword.get(config, :max_age, 60)
    swr = Keyword.get(config, :stale_while_revalidate, 60)

    if Keyword.get(config, :enabled, true),
      do: "public, max-age=#{max_age}, stale-while-revalidate=#{swr}"
  end

  defp finalize(conn, anonymous?, url_document?, opts) do
    conn = put_vary(conn)

    cond do
      not handler_default?(conn) ->
        conn

      anonymous? and url_document? and cacheable?(conn, opts) ->
        case cache_control() do
          nil ->
            conn

          value ->
            conn
            |> put_resp_header("cache-control", value)
            |> put_surrogate_keys()
            |> put_etag()
        end

      anonymous? ->
        conn

      true ->
        put_resp_header(conn, "cache-control", "private, no-store")
    end
  end

  defp handler_default?(conn), do: get_resp_header(conn, "cache-control") == [@plug_default]

  defp cacheable?(conn, opts) do
    conn.state == :set and conn.status == 200 and not request_body?(conn) and
      not sets_cookie?(conn) and not (opts.graphql and graphql_errors?(conn.resp_body))
  end

  defp request_body?(conn) do
    get_req_header(conn, "transfer-encoding") != [] or
      Enum.any?(get_req_header(conn, "content-length"), &(String.trim(&1) not in ["", "0"]))
  end

  # `before_send` callbacks run newest first, so `Plug.Session`'s — registered
  # in the endpoint, before this one — has not written its cookie yet when this
  # runs. A session marked for writing is about to be one.
  defp sets_cookie?(conn) do
    conn.resp_cookies != %{} or get_resp_header(conn, "set-cookie") != [] or
      conn.private[:plug_session_info] in [:write, :renew]
  end

  # Absinthe encodes a result map, so a top-level `"errors"` key is the literal
  # `"errors":` with unescaped quotes. A string *value* containing the word has
  # its quotes escaped (`\"errors\"`) and cannot match. An alias named `errors`
  # can — that only costs the query its caching, which is the safe direction.
  defp graphql_errors?(body),
    do: :binary.match(IO.iodata_to_binary(body), ~s("errors":)) != :nomatch

  defp put_etag(conn) do
    [content_type | _] = get_resp_header(conn, "content-type") ++ [""]

    digest =
      :crypto.hash_init(:sha256)
      |> :crypto.hash_update(content_type)
      |> :crypto.hash_update(<<0>>)
      |> :crypto.hash_update(conn.resp_body)
      |> :crypto.hash_final()
      |> binary_part(0, 16)
      |> Base.url_encode64(padding: false)

    etag = ~s(W/"#{digest}")
    conn = put_resp_header(conn, "etag", etag)

    if fresh?(conn, etag), do: %{conn | status: 304, resp_body: ""}, else: conn
  end

  # RFC 9110 §13.1.2: `If-None-Match` uses the *weak* comparison — opaque tags
  # compared with any `W/` stripped — and `*` matches any current
  # representation.
  defp fresh?(conn, etag) do
    tag = String.replace_prefix(etag, "W/", "")

    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.any?(&(&1 == tag or &1 == "*"))
  end

  # `put_resp_header/3` replaces only the first `vary` it finds and Corsica
  # *prepends* its own, so every existing value is folded into one header.
  defp put_vary(conn) do
    {existing, rest} = Enum.split_with(conn.resp_headers, fn {k, _} -> k == "vary" end)

    values =
      existing
      |> Enum.flat_map(fn {_, v} -> String.split(v, ",") end)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Kernel.++(@vary)
      |> Enum.uniq()

    %{conn | resp_headers: [{"vary", Enum.join(values, ", ")} | rest]}
  end
end
