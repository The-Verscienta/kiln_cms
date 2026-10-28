defmodule KilnCMSWeb.GraphqlOmittedOffsetTest do
  @moduledoc """
  #1883 over HTTP `/gql`, the transport the issue reproduced on: an omitted
  `offset` means `0`, so `hasNextPage` is a boolean, not a nulled field.
  AshGraphql 1.13.0 defaults the offset itself (ash-project/ash_graphql#480).
  `KilnCMSWeb.DeliveryGraphqlTest` covers every offset query via `Absinthe.run/3`.
  """
  use KilnCMSWeb.ConnCase, async: true

  test "publishedEntries answers hasNextPage without an offset", %{conn: conn} do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/gql",
        Jason.encode!(%{query: "{ publishedEntries(limit: 2) { hasNextPage results { slug } } }"})
      )
      |> json_response(200)

    refute Map.has_key?(body, "errors"), inspect(body["errors"])
    assert is_boolean(body["data"]["publishedEntries"]["hasNextPage"])
  end
end
