defmodule KilnCMS.Search.Meilisearch.ReqClient do
  @moduledoc """
  Default `KilnCMS.Search.Meilisearch.Client` — talks to Meilisearch over HTTP
  with Req. Adds the base URL and `Authorization: Bearer <master_key>` header,
  decodes the JSON body, and maps non-2xx responses to `{:error, ...}`.
  """
  @behaviour KilnCMS.Search.Meilisearch.Client

  @impl true
  def request(method, path, body, %{url: url} = config) do
    options =
      [
        method: method,
        url: URI.merge(url, path) |> URI.to_string(),
        headers: auth_headers(config),
        receive_timeout: 15_000
      ]
      |> maybe_put_json(body)

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
        {:ok, resp}

      {:ok, %Req.Response{status: status, body: resp}} ->
        {:error, {:http_status, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers(%{master_key: key}) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer " <> key}]

  defp auth_headers(_config), do: []

  defp maybe_put_json(options, nil), do: options
  defp maybe_put_json(options, body), do: Keyword.put(options, :json, body)
end
