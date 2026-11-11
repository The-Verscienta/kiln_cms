defmodule Kiln.Plugins.Health.Hex do
  @moduledoc """
  Asks hex.pm about one installed plugin release (#2244): the package document
  (`/api/packages/<name>`, for retirements and release dates) and the release
  document (`/api/packages/<name>/releases/<version>`, for its checksum,
  retirement, requirements and security advisories).

  Both are unauthenticated public GETs through `KilnCMS.SafeFetch`, with the
  bare `KilnCMS` user-agent, a 2 MB body cap and a 10-second timeout. The path
  is the plugin's package name and version, which is what hex.pm learns from
  this instance; nothing else is sent.

  Coordinates are checked before anything is sent: a package name that isn't
  a Hex name, or a version that doesn't parse, is `{:error,
  :invalid_coordinates}` with no request, so a strange lock entry can never
  turn into a request for some other path on hex.pm.
  """

  alias KilnCMS.SafeFetch

  @package_name ~r/\A[a-z][a-z0-9_]*\z/
  @max_bytes 2_000_000

  @doc """
  `{:ok, %{package: map, release: map}}`, `{:error, :not_found}` when hex.pm
  answers 404 for either document, `{:error, :invalid_coordinates}` (no
  request made), `{:error, :unparseable}`, `{:error, {:http_status, status}}`
  or `{:error, reason}` for a transport failure or a refused or oversized
  response.

  Options: `:base_url` (default `"https://hex.pm/api"`) and `:req_options`.
  """
  @spec fetch(String.t(), String.t(), keyword()) ::
          {:ok, %{package: map(), release: map()}} | {:error, term()}
  def fetch(package, version, opts \\ []) do
    base = opts |> Keyword.get(:base_url, "https://hex.pm/api") |> String.trim_trailing("/")

    with :ok <- validate(package, version),
         {:ok, package_doc} <- get_json("#{base}/packages/#{package}", opts),
         {:ok, release_doc} <-
           get_json("#{base}/packages/#{package}/releases/#{encode(version)}", opts) do
      {:ok, %{package: package_doc, release: release_doc}}
    end
  end

  @doc "Whether `package`/`version` are coordinates Hex could have published."
  @spec valid_coordinates?(term(), term()) :: boolean()
  def valid_coordinates?(package, version), do: validate(package, version) == :ok

  defp validate(package, version) when is_binary(package) and is_binary(version) do
    if Regex.match?(@package_name, package) and match?({:ok, _}, Version.parse(version)),
      do: :ok,
      else: {:error, :invalid_coordinates}
  end

  defp validate(_package, _version), do: {:error, :invalid_coordinates}

  defp encode(version), do: URI.encode(version, &URI.char_unreserved?/1)

  defp get_json(url, opts) do
    case SafeFetch.get(url,
           headers: [{"accept", "application/json"}, {"user-agent", "KilnCMS"}],
           max_bytes: @max_bytes,
           receive_timeout: 10_000,
           req_options: Keyword.get(opts, :req_options, [])
         ) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, doc} when is_map(doc) -> {:ok, doc}
          _other -> {:error, :unparseable}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
