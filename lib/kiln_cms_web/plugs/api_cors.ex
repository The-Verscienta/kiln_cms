defmodule KilnCMSWeb.Plugs.ApiCORS do
  @moduledoc """
  Applies CORS to the headless API surfaces (`/api/*`, `/gql`) only.

  Mounted in the endpoint **before** the router: a CORS preflight is an
  `OPTIONS` request, and Phoenix matches a route (by method) before running its
  pipeline — so an `OPTIONS` to a `get`-only route would 404 before any pipeline
  plug could answer it. Handling CORS here, ahead of routing, lets Corsica reply
  to (and halt) preflight requests, and adds the response headers to actual
  cross-origin reads. Non-API paths pass through untouched so browser pages keep
  their same-origin posture.

  Allowed origins are resolved per request by `KilnCMSWeb.CORS` from runtime
  config; see that module and `config/runtime.exs`.
  """
  @behaviour Plug

  # Built once at compile time; the `{mod, fun, args}` origin is still evaluated
  # per request, so runtime `CORS_ORIGINS` changes are honoured.
  # `PATCH`/`DELETE` are needed for the write API (#330) so an external front end
  # (e.g. the visual-editing bridge, #355) can round-trip edits cross-origin —
  # a `PATCH /api/json/<type>/:id` preflight must be answered. Reads stay GET.
  # `retry-after` is exposed because the API documents it as part of a contract:
  # the second-factor exchange (#726) and every rate-limited route answer a 429
  # with it, and `docs/api.md` tells clients to back off by it. A browser hides
  # every response header that is not on this list, so without it
  # `res.headers.get('retry-after')` is `null` for exactly the allow-listed
  # front ends `CORS_ORIGINS` exists to serve — a documented header that the
  # audience it was documented for cannot read.
  @corsica Corsica.init(
             origins: {KilnCMSWeb.CORS, :allowed_origin?, []},
             allow_methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
             allow_headers: ["authorization", "content-type", "x-api-key"],
             expose_headers: ["retry-after"],
             max_age: 600
           )

  @impl true
  def init(_opts), do: []

  @impl true
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts), do: Corsica.call(conn, @corsica)
  def call(%Plug.Conn{path_info: ["gql" | _]} = conn, _opts), do: Corsica.call(conn, @corsica)
  def call(conn, _opts), do: conn
end
