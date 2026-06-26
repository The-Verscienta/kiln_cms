defmodule KilnCMS.Storage do
  @moduledoc """
  Pluggable blob storage for media binaries.

  The default adapter (`KilnCMS.Storage.Local`) writes to the local filesystem
  — fine for development and single-node deployments. Production can swap in an
  S3/MinIO adapter via config without touching callers:

      config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3

  Callers go through this module (`Storage.store/2`, `Storage.url/1`, …) rather
  than a concrete adapter.
  """

  @doc "Persist the file at `source_path` under `key`; returns `{:ok, key}`."
  @callback store(key :: String.t(), source_path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Read the blob at `key` back into memory. Lets background work (e.g. variant
  generation) re-fetch an original from storage on any node, rather than relying
  on a node-local temp file.
  """
  @callback fetch(key :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Remove the blob at `key`. Missing blobs are treated as success."
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @doc "Public URL at which the blob at `key` is served."
  @callback url(key :: String.t()) :: String.t()

  @spec adapter() :: module()
  def adapter do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, KilnCMS.Storage.Local)
  end

  @spec store(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def store(key, source_path), do: adapter().store(key, source_path)

  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(key), do: adapter().fetch(key)

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key), do: adapter().delete(key)

  @spec url(String.t()) :: String.t()
  def url(key), do: adapter().url(key)

  @doc """
  Builds a collision-resistant storage key from an upload's filename, keeping
  the original extension (lowercased).
  """
  @spec generate_key(String.t()) :: String.t()
  def generate_key(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    "#{Ecto.UUID.generate()}#{ext}"
  end
end
