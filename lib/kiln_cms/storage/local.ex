defmodule KilnCMS.Storage.Local do
  @moduledoc """
  Local-filesystem `KilnCMS.Storage` adapter.

  Files are written under the configured `:root` directory (default:
  `priv/uploads` resolved via the app dir, kept in sync with the `Plug.Static`
  mount in `KilnCMSWeb.Endpoint`) and served from `:base_url` (default
  `/uploads`).
  """
  @behaviour KilnCMS.Storage

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def store(key, source_path) do
    with {:ok, dest} <- safe_path(key) do
      File.mkdir_p!(Path.dirname(dest))

      case File.cp(source_path, dest) do
        :ok -> {:ok, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def delete(key) do
    with {:ok, dest} <- safe_path(key) do
      case File.rm(dest) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Reject keys with path separators or traversal segments so a caller can
  # never escape the storage root (keys from `Storage.generate_key/1` are
  # already safe basenames; this guards direct callers).
  defp safe_path(key) do
    if is_binary(key) and key == Path.basename(key) and key not in ["", ".", ".."] do
      {:ok, Path.join(root(), key)}
    else
      {:error, :invalid_key}
    end
  end

  @impl true
  def url(key), do: "#{base_url()}/#{key}"

  @doc "Absolute directory blobs are written to."
  def root do
    config() |> Keyword.get_lazy(:root, fn -> Application.app_dir(:kiln_cms, "priv/uploads") end)
  end

  defp base_url, do: Keyword.get(config(), :base_url, "/uploads")

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
