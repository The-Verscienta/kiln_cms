defmodule Verscienta.Source do
  @moduledoc """
  Read-only source of Verscienta content for the one-off migration importer
  (`mix kiln.import.verscienta`).

  A source knows how to return every row of a Directus collection (with its
  immediate relations expanded) as a list of plain maps with string keys —
  exactly the shape the Directus REST API returns. Two implementations ship:

    * `Verscienta.Source.Directus` — paginates the live Directus REST
      API using a static read token.
    * `Verscienta.Source.Fixtures` — reads JSON files from a directory,
      so the full transform/load pipeline can be exercised offline and in tests
      without access to the production database.

  Selecting an implementation is the caller's job; see
  `Verscienta.Source.resolve/1`.
  """

  @typedoc "A single Directus item as returned by the REST API (string keys)."
  @type item :: %{optional(String.t()) => term()}

  @typedoc "An opaque source handle: `{module, config}`."
  @type t :: {module(), term()}

  @doc """
  Fetch every row of `collection`, with relations expanded one level deep.

  `opts` may carry a `:fields` override (a Directus `fields` selector string);
  implementations that ignore relations may ignore it.
  """
  @callback fetch_all(config :: term(), collection :: String.t(), opts :: keyword()) ::
              {:ok, [item()]} | {:error, term()}

  @doc """
  Resolve a source spec into a `{module, config}` handle.

  Accepts:

    * `:directus` / `{:directus, opts}` — live REST API. Reads `DIRECTUS_URL`
      and `DIRECTUS_TOKEN` from the environment unless `:url` / `:token` are
      given in `opts`.
    * `{:fixtures, dir}` — JSON files under `dir`.
  """
  @spec resolve(atom() | {atom(), term()}) :: {:ok, t()} | {:error, term()}
  def resolve(:directus), do: resolve({:directus, []})

  def resolve({:directus, opts}) do
    url = opts[:url] || System.get_env("DIRECTUS_URL")
    token = opts[:token] || System.get_env("DIRECTUS_TOKEN")

    cond do
      is_nil(url) or url == "" ->
        {:error, "DIRECTUS_URL is not set (or pass url: in opts)"}

      is_nil(token) or token == "" ->
        {:error, "DIRECTUS_TOKEN is not set (or pass token: in opts)"}

      true ->
        {:ok, {__MODULE__.Directus, %{url: String.trim_trailing(url, "/"), token: token}}}
    end
  end

  def resolve({:fixtures, dir}) do
    if File.dir?(dir) do
      {:ok, {__MODULE__.Fixtures, %{dir: dir}}}
    else
      {:error, "fixtures dir not found: #{dir}"}
    end
  end

  def resolve(other), do: {:error, "unknown source spec: #{inspect(other)}"}

  @doc "Dispatch `fetch_all/3` to the resolved implementation."
  @spec fetch_all(t(), String.t(), keyword()) :: {:ok, [item()]} | {:error, term()}
  def fetch_all({module, config}, collection, opts \\ []) do
    module.fetch_all(config, collection, opts)
  end
end
