defmodule Verscienta.Source.Fixtures do
  @moduledoc """
  `Verscienta.Source` implementation that reads collections from JSON
  files on disk, so the transform/load pipeline can be exercised offline.

  Each collection lives in `<dir>/<collection>.json`, containing either a raw
  JSON array of items or a Directus-style `{"data": [...]}` envelope. A missing
  file is treated as an empty collection (not an error), which keeps the
  importer's two-pass logic happy when only a subset of collections is provided.
  """

  @behaviour Verscienta.Source

  @impl true
  def fetch_all(%{dir: dir}, collection, _opts) do
    path = Path.join(dir, "#{collection}.json")

    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, "could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, data} when is_list(data) -> {:ok, data}
      {:ok, other} -> {:error, "expected a JSON array or {data: [...]}, got #{inspect(other)}"}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end
end
