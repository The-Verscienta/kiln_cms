defmodule KilnCMS.Search.Meilisearch.ReqClient do
  @moduledoc """
  Default `KilnCMS.Search.Meilisearch.Client` — talks to Meilisearch over HTTP
  with Req. Adds the base URL and `Authorization: Bearer <master_key>` header,
  decodes the JSON body, and maps non-2xx responses to `{:error, ...}`.

  Two transports, chosen by the config's `safe:` flag:

    * **The operator's instance** (`MEILI_URL`) is dialled directly with Req.
      The operator is trusted, and an internal address is where their instance
      usually lives.
    * **A site's own instance** (`safe: true`, set by
      `KilnCMS.Search.Meilisearch.SiteInstance`) goes through
      `KilnCMS.SafeFetch`: resolved once, refused if the address is private,
      connected to by address with TLS verified against the name, and never
      redirected — a redirect would carry the bearer key and the site's content
      to a host nobody checked. The response is capped at 5 MB.
  """
  @behaviour KilnCMS.Search.Meilisearch.Client

  @max_response_bytes 5 * 1024 * 1024
  @receive_timeout 15_000

  @impl true
  def request(method, path, body, %{safe: true} = config) do
    opts = [
      headers: [{"accept", "application/json"} | auth_headers(config)] ++ json_header(body),
      max_bytes: @max_response_bytes,
      receive_timeout: @receive_timeout
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :body, Jason.encode!(body))

    case KilnCMS.SafeFetch.request(method, join(config.url, path), opts) do
      {:ok, %{status: status, body: resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, %{status: status, body: resp}} -> {:error, {:http_status, status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def request(method, path, body, %{url: url} = config) do
    options =
      [
        method: method,
        url: join(url, path),
        headers: auth_headers(config),
        receive_timeout: @receive_timeout
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

  @doc false
  # Appended to the base URL, so an instance behind a reverse proxy at a path
  # (`https://example.com/meili`) keeps its prefix — `URI.merge/2` with an
  # absolute path would drop it.
  @spec join(String.t(), String.t()) :: String.t()
  def join(url, path), do: String.trim_trailing(url, "/") <> path

  defp auth_headers(%{master_key: key}) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer " <> key}]

  defp auth_headers(_config), do: []

  defp json_header(nil), do: []
  defp json_header(_body), do: [{"content-type", "application/json"}]

  defp decode(""), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _not_json} -> body
    end
  end

  defp maybe_put_json(options, nil), do: options
  defp maybe_put_json(options, body), do: Keyword.put(options, :json, body)
end
