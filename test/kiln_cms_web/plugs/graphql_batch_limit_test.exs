defmodule KilnCMSWeb.Plugs.GraphqlBatchLimitTest do
  @moduledoc """
  A batched `/gql` body (a JSON array of operations) has a maximum size, and
  every operation in it is charged to the `:gql` bucket. Before this, one
  request carried any number of operations for the price of one.
  """
  # async: false — `put_limit/2` changes the global RateLimit env.
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.RateLimitHelpers, only: [put_limit: 2, restore_limits_on_exit: 0, spent: 2]

  alias KilnCMSWeb.Plugs.GraphqlBatchLimit
  alias KilnCMSWeb.RateLimit

  setup do
    restore_limits_on_exit()
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/gql", Jason.encode!(body))
  end

  defp batch(n), do: List.duplicate(%{query: "{ health }"}, n)

  defp client(conn), do: RateLimit.client_key(conn.remote_ip)

  test "a batch over the maximum is refused whole", %{conn: conn} do
    max = GraphqlBatchLimit.max_operations()

    assert %{"errors" => [%{"message" => message}]} =
             conn |> post_json(batch(max + 1)) |> json_response(400)

    assert message ==
             "A batched request may carry at most #{max} operations; this one carries #{max + 1}"
  end

  test "a batch at the maximum runs, and is charged once per operation", %{conn: conn} do
    max = GraphqlBatchLimit.max_operations()

    results = conn |> post_json(batch(max)) |> json_response(200)

    assert length(results) == max
    assert Enum.all?(results, &(&1["payload"]["data"] == %{"health" => "ok"}))
    assert spent(:gql, client(conn)) == max
  end

  test "a single operation is charged once", %{conn: conn} do
    assert %{"data" => %{"health" => "ok"}} =
             conn |> post_json(%{query: "{ health }"}) |> json_response(200)

    assert spent(:gql, client(conn)) == 1
  end

  test "a batch that would spend past the budget gets the rate limit's 429", %{conn: conn} do
    put_limit(:gql, 3)

    refused = post_json(conn, batch(4))

    assert refused.status == 429
    assert get_resp_header(refused, "retry-after") != []
  end

  # A multipart upload's `operations` field is read as the batch in place of a
  # JSON array body (`Absinthe.Plug.Request`), so it is counted the same way.
  test "counts a batch sent as a multipart `operations` field", %{conn: conn} do
    max = GraphqlBatchLimit.max_operations()

    conn = post(conn, "/gql", %{"operations" => Jason.encode!(batch(max + 1))})

    assert %{"errors" => [%{"message" => message}]} = json_response(conn, 400)
    assert message =~ "at most #{max} operations"
  end
end
