defmodule KilnCMSWeb.Plugs.GraphqlBatchLimit do
  @moduledoc """
  Limits a batched `/gql` request, both in how many operations it may carry and
  in what it costs against the rate limit.

  `Absinthe.Plug` runs a JSON array body (`[{"query": …}, …]`, which Plug parses
  into `params["_json"]`) as a batch: each element is a separate operation, each
  with its own complexity allowance. Absinthe sets no maximum on the array. The
  `:gql` bucket counted the request once, so one request within the 60/min budget
  could carry thousands of operations, as many as the body size limit allows.

  This plug runs after `KilnCMSWeb.Plugs.RateLimit` and does two things:

    * A batch of more than `max_operations/0` is refused with a 400 before any of
      it is parsed as GraphQL. The body is in the same shape as Absinthe's own
      input errors.
    * A batch within the limit is charged once per operation. The rate-limit plug
      has already charged the first, so this charges the rest. A client that
      batches pays the same as one that sends each operation separately. Over
      budget, it gets the rate-limit plug's 429.

  To count operations it reads the request the way Absinthe.Plug.Request
  does. That includes a multipart `operations` field and a `_json` that arrives
  as a JSON string. A request Absinthe would not run as a batch counts as one
  operation.
  """
  import Plug.Conn

  alias KilnCMSWeb.RateLimit

  @max_operations 10

  @doc "The most operations one batched request may carry."
  @spec max_operations() :: pos_integer()
  def max_operations, do: @max_operations

  def init(bucket) when is_atom(bucket), do: bucket

  def call(conn, bucket) do
    case operation_count(conn) do
      count when count > @max_operations -> refuse(conn, count)
      count when count > 1 -> charge(conn, bucket, count - 1)
      _one -> conn
    end
  end

  defp charge(conn, bucket, extra) do
    case RateLimit.check(bucket, RateLimit.client_key(conn.remote_ip), extra) do
      :allow -> conn
      {:deny, retry_after_ms} -> KilnCMSWeb.Plugs.RateLimit.deny(conn, retry_after_ms)
    end
  end

  defp refuse(conn, count) do
    message =
      "A batched request may carry at most #{@max_operations} operations; this one carries #{count}"

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{errors: [%{message: message}]}))
    |> halt()
  end

  # `Absinthe.Plug.Request.extract_body_and_params/2`: a body with a `query` is
  # one operation, whatever else is in the params.
  defp operation_count(%Plug.Conn{body_params: %{"query" => _}}), do: 1

  defp operation_count(conn) do
    case batch(fetch_query_params(conn).params) do
      operations when is_list(operations) -> length(operations)
      _not_a_batch -> 1
    end
  end

  # A multipart upload's `operations` field takes the place of `_json`
  # (`convert_operations_param/1`), and a `_json` string is decoded
  # (`extract_body_and_params_batched/3`).
  defp batch(%{"operations" => operations}) when is_binary(operations), do: decode(operations)
  defp batch(%{"_json" => json}) when is_binary(json), do: decode(json)
  defp batch(%{"_json" => json}), do: json
  defp batch(_params), do: nil

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      {:error, _invalid} -> nil
    end
  end
end
