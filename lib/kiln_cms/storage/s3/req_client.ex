defmodule KilnCMS.Storage.S3.ReqClient do
  @moduledoc """
  `ExAws.Request.HttpClient` implementation backed by `Req`.

  Keeps the project on a single HTTP client (Req is already used for outbound
  webhooks) instead of pulling in hackney. Extra Req options can be injected via

      config :kiln_cms, KilnCMS.Storage.S3, req_options: [...]

  which the test env uses to route requests through a `Req.Test` stub.
  """
  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(method, url, body, headers, _http_opts) do
    opts =
      [method: method, url: url, body: body, headers: headers, decode_body: false, retry: false] ++
        req_options()

    case Req.request(Req.new(opts)) do
      {:ok, response} ->
        {:ok,
         %{
           status_code: response.status,
           headers: Req.get_headers_list(response),
           body: response.body
         }}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  defp req_options do
    :kiln_cms
    |> Application.get_env(KilnCMS.Storage.S3, [])
    |> Keyword.get(:req_options, [])
  end
end
