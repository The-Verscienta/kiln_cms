defmodule KilnCMSWeb.Plugs.DisableGraphqlIntrospection do
  @moduledoc """
  Rejects GraphQL **schema introspection** (`__schema` / `__type`) on the public
  `/gql` endpoint when disabled by config, so an attacker can't pull the full
  schema map for reconnaissance. `__typename` is unaffected.

  Gated by `config :kiln_cms, :graphql_introspection` (default `true`; set
  `false` in production). The check matches the introspection meta-field names,
  which a query *must* use literally to introspect — aliases rename the result
  key, not the field — so this can't be evaded by aliasing.
  """
  import Plug.Conn

  # `\b__type\b` deliberately does not match `__typename` (no word boundary
  # between `__type` and `name`).
  @introspection ~r/\b__(schema|type)\b/

  def init(opts), do: opts

  def call(conn, _opts) do
    if introspection_enabled?() or not introspecting?(conn) do
      conn
    else
      body = Jason.encode!(%{errors: [%{message: "GraphQL introspection is disabled"}]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, body)
      |> halt()
    end
  end

  defp introspection_enabled?, do: Application.get_env(:kiln_cms, :graphql_introspection, true)

  defp introspecting?(conn) do
    conn = fetch_query_params(conn)

    query =
      query_field(conn.body_params) || query_field(conn.query_params) || query_field(conn.params)

    is_binary(query) and Regex.match?(@introspection, query)
  end

  defp query_field(%{"query" => query}), do: query
  defp query_field(_), do: nil
end
