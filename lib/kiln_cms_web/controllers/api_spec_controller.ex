defmodule KilnCMSWeb.ApiSpecController do
  @moduledoc """
  `GET /api/graphql/schema.graphql` — the running site's GraphQL schema as SDL.

  Introspection is how a GraphQL client normally learns a schema, and a
  production build turns it off (`config :kiln_cms, :graphql_introspection`).
  The committed `docs/api/schema.graphql` fills that gap for the stock build,
  but not for a site with its own content domains: their types exist only in
  that site's compiled schema. This route serves that schema to the callers
  who need it:

    * **anyone**, wherever introspection is on — the SDL says nothing
      introspection would not;
    * **a caller with an API key** (`Authorization: Bearer kiln_…`), wherever
      it is off. The reasoning is `KilnCMSWeb.Plugs.ApiDocs`'s for the OpenAPI
      document: an admin minted the key, so its holder is an integration the
      site chose, not a stranger mapping the surface.

  Everyone else gets the 404 any unrouted path gets, for the reason
  `KilnCMSWeb.Plugs.ApiDocs` gives.

  A route of its own rather than introspection-by-key on `/gql`: the query
  pipeline is the place that refuses introspection, and a file at a URL is
  what codegen tools already accept. `graphql-codegen`'s URL loader reads a
  pointer ending in `.graphql` as SDL rather than introspecting it, and sends
  the headers it is configured with, so the path ends in `.graphql`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMSWeb.ApiSpecs

  @doc false
  def graphql_sdl(conn, _params) do
    if introspection_enabled?() or ApiSpecs.api_key_caller?(conn) do
      conn
      # The response depends on the Authorization header wherever
      # introspection is off, so no shared cache may keep it.
      |> put_resp_header("cache-control", "private, no-cache")
      |> put_resp_header("vary", "authorization")
      |> put_resp_content_type("application/graphql")
      |> send_resp(200, ApiSpecs.cached_graphql_sdl())
    else
      KilnCMSWeb.ApiError.send(conn, :not_found, "not_found", "Not found.")
    end
  end

  defp introspection_enabled?, do: Application.get_env(:kiln_cms, :graphql_introspection, true)
end
