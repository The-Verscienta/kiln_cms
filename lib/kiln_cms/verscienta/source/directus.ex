defmodule KilnCMS.Verscienta.Source.Directus do
  @moduledoc """
  `KilnCMS.Verscienta.Source` implementation backed by the live Directus 11
  REST API.

  Pages through `GET {url}/items/{collection}` with a static read token,
  requesting `fields=*.*` by default so every relation (M2M aliases, O2M
  children, and file M2O references such as the Cloudflare-offloaded image
  objects) is expanded one level deep in a single pass.
  """

  @behaviour KilnCMS.Verscienta.Source

  @page_size 100

  @impl true
  def fetch_all(%{url: url, token: token}, collection, opts) do
    fields = Keyword.get(opts, :fields, "*.*")
    fetch_pages(url, token, collection, fields, 1, [])
  end

  defp fetch_pages(url, token, collection, fields, page, acc) do
    params = [limit: @page_size, page: page, fields: fields]

    req =
      [
        url: "#{url}/items/#{collection}",
        params: params,
        auth: {:bearer, token},
        retry: :transient,
        max_retries: 3,
        receive_timeout: 60_000
      ]
      |> Keyword.merge(req_options())
      |> Req.new()

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        acc = acc ++ data

        if length(data) < @page_size do
          {:ok, acc}
        else
          fetch_pages(url, token, collection, fields, page + 1, acc)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Directus #{collection} returned HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Directus #{collection} request failed: #{inspect(reason)}"}
    end
  end

  # Extra Req options (e.g. a `Req.Test` plug in the test env), mirroring the
  # webhook/S3 clients so outbound HTTP can be stubbed offline.
  defp req_options do
    Application.get_env(:kiln_cms, __MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
