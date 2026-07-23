defmodule KilnCMS.Unsplash do
  @moduledoc """
  Unsplash stock-photo search for the media library.

  Enabled by configuring an access key (the Unsplash API "Access Key"):

      config :kiln_cms, :unsplash, access_key: "..."

  — set via `UNSPLASH_ACCESS_KEY` in `config/runtime.exs`. With a key present
  the media library grows an Unsplash tab (`KilnCMSWeb.MediaLive`): search
  hits `GET /search/photos`, and importing a photo first reports the download
  to Unsplash (required by the API guidelines) and then fetches the bytes from
  the URL that report returns.

  Tests stub the HTTP layer through `:req_options` in the same config entry
  (`req_options: [plug: {Req.Test, KilnCMS.Unsplash}]`).
  """

  @api_base "https://api.unsplash.com"
  # Search-result thumbnails hotlink from here; the router adds it to the CSP
  # img-src while the integration is enabled (see `csp_img_src/0`).
  @thumb_host "https://images.unsplash.com"
  @per_page 24
  # Unsplash attribution links must carry these referral parameters.
  @utm "utm_source=kiln_cms&utm_medium=referral"

  @type photo :: %{
          id: String.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          alt: String.t() | nil,
          thumb_url: String.t() | nil,
          page_url: String.t() | nil,
          download_location: String.t() | nil,
          photographer: String.t() | nil,
          photographer_url: String.t() | nil
        }

  @spec enabled?() :: boolean()
  def enabled? do
    is_binary(access_key()) and access_key() != ""
  end

  @doc "Extra CSP `img-src` origins the admin needs while the tab is enabled."
  @spec csp_img_src() :: [String.t()]
  def csp_img_src, do: if(enabled?(), do: [@thumb_host], else: [])

  @doc """
  Search Unsplash photos. Returns `{:ok, %{photos: [photo], more?: boolean}}`
  with `more?` telling whether another page exists past `page`.
  """
  @spec search(String.t(), pos_integer()) ::
          {:ok, %{photos: [photo()], more?: boolean()}} | {:error, term()}
  def search(query, page \\ 1) do
    with {:ok, body} <-
           get_json(@api_base <> "/search/photos",
             params: [query: query, page: page, per_page: @per_page]
           ) do
      {:ok,
       %{
         photos: body |> Map.get("results", []) |> Enum.map(&photo/1),
         more?: page < (body["total_pages"] || 0)
       }}
    end
  end

  @doc """
  Fetch a photo's bytes into a temp file the caller must delete.

  Per the Unsplash API guidelines an import must be reported via the photo's
  `download_location`; that report's response carries the actual file URL.
  """
  @spec download(photo()) :: {:ok, Path.t()} | {:error, term()}
  def download(%{download_location: location}) when is_binary(location) do
    case get_json(location) do
      {:ok, %{"url" => url}} when is_binary(url) -> fetch_to_tmp(url)
      {:ok, _other} -> {:error, :bad_download_response}
      error -> error
    end
  end

  def download(_photo), do: {:error, :bad_download_response}

  @doc "Attribution line stored as the imported item's caption."
  @spec attribution(photo()) :: String.t()
  def attribution(%{photographer: name}) when is_binary(name) and name != "",
    do: "Photo by #{name} on Unsplash"

  def attribution(_photo), do: "Photo from Unsplash"

  defp photo(p) do
    %{
      id: p["id"],
      width: p["width"],
      height: p["height"],
      alt: p["alt_description"] || p["description"],
      thumb_url: get_in(p, ["urls", "small"]),
      page_url: with_utm(get_in(p, ["links", "html"])),
      download_location: get_in(p, ["links", "download_location"]),
      photographer: get_in(p, ["user", "name"]),
      photographer_url: with_utm(get_in(p, ["user", "links", "html"]))
    }
  end

  defp with_utm(nil), do: nil
  defp with_utm(url), do: url <> if(String.contains?(url, "?"), do: "&", else: "?") <> @utm

  defp get_json(url, extra \\ []) do
    case request(url, extra) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — dest is a server-generated UUID path.
  defp fetch_to_tmp(url) do
    dest = Path.join(System.tmp_dir!(), "unsplash-#{Ecto.UUID.generate()}")

    case request(url, []) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_binary(body) ->
        case File.write(dest, body) do
          :ok -> {:ok, dest}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(url, extra) do
    [
      url: url,
      headers: [
        {"authorization", "Client-ID " <> access_key()},
        {"accept-version", "v1"}
      ],
      receive_timeout: 30_000,
      # Search and import are interactive (LiveView-triggered) — fail fast and
      # let the editor retry rather than stalling the UI on backoff retries.
      retry: false
    ]
    |> Keyword.merge(extra)
    |> Keyword.merge(req_options())
    |> Req.request()
  end

  defp access_key, do: config()[:access_key]

  defp req_options, do: Keyword.get(config(), :req_options, [])

  defp config, do: Application.get_env(:kiln_cms, :unsplash, [])
end
