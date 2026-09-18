defmodule KilnCMS.Storage.Local do
  @moduledoc """
  Local-filesystem `KilnCMS.Storage` adapter.

  Files are written under the configured `:root` directory (default:
  `priv/uploads` resolved via the app dir; `<KILN_MEDIA_ROOT>/public` when that
  is set — see `KilnCMS.Config.MediaRoot`) and served from `:base_url`
  (default `/uploads`). The `Plug.Static` mount in `KilnCMSWeb.Endpoint` reads
  `root/0` itself on each request, so the two cannot drift apart.

  ## Private storage (#481)

  `store_private/2` writes to a **second, separate** directory (`:private_root`,
  default `priv/private_uploads`) that `KilnCMSWeb.Endpoint` has no
  `Plug.Static` mount for — nothing serves it over HTTP. The only way to read
  a private blob's bytes is `fetch_private/1`, called from an
  authorization-checked path (`KilnCMSWeb.MediaDownloadController`). This is
  genuine privacy, not obscurity: a public blob's key merely isn't *linked*
  anywhere, but `/uploads/<key>` still serves it to anyone who has the key; a
  private blob's key resolves to nothing over HTTP at all.
  """
  @behaviour KilnCMS.Storage

  @impl true
  def store(key, source_path), do: write(root(), key, source_path)

  @impl true
  def fetch(key), do: read(root(), key)

  @impl true
  def delete(key), do: remove(root(), key)

  @impl true
  def url(key), do: "#{base_url()}/#{key}"

  @impl true
  def store_private(key, source_path), do: write(private_root(), key, source_path)

  @impl true
  def fetch_private(key), do: read(private_root(), key)

  @impl true
  def delete_private(key), do: remove(private_root(), key)

  @impl true
  # A second local directory needs no operator configuration, unlike the S3
  # adapter's private bucket — always available.
  def private_available?, do: true

  @impl true
  def fetch_range(key, first, last), do: read_range(root(), key, first, last)

  @impl true
  def fetch_private_range(key, first, last), do: read_range(private_root(), key, first, last)

  # `:file.pread/3` reads straight out of the file at an offset, so a seek into
  # the middle of a large video never materializes the bytes before it (#494).
  # Path goes through `safe_path/2` first — the traversal warning is the same
  # false positive as `read/2`'s above.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_range(dir, key, first, last) do
    with {:ok, path} <- safe_path(dir, key),
         {:ok, %{size: total}} <- File.stat(path),
         {:ok, {first, last}} <- clamp_range(first, last, total),
         {:ok, io} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(io, first, last - first + 1) do
          {:ok, bytes} -> {:ok, %{bytes: bytes, first: first, last: last, total: total}}
          # `eof` from a range we already clamped inside the file means the file
          # shrank underneath us; report it as unreadable, not as an empty body.
          :eof -> {:error, {:range_not_satisfiable, total}}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(io)
      end
    end
  end

  # An empty blob has no satisfiable range at all (`first` 0 is already at the
  # end), which is exactly what RFC 9110 says a byte-range request against a
  # zero-length representation is.
  #
  # The total rides along in the error because RFC 9110 §14.4 requires a 416
  # to state the resource's real length (`Content-Range: bytes */<total>`),
  # and this is the only place that knows it.
  defp clamp_range(first, _last, total) when total == 0 or first >= total,
    do: {:error, {:range_not_satisfiable, total}}

  defp clamp_range(first, :eof, total), do: {:ok, {first, total - 1}}
  defp clamp_range(first, last, total), do: {:ok, {first, min(last, total - 1)}}

  # `dest`/`source_path` pass through `safe_path/2`'s basename-only guard
  # first (traversal segments rejected) — the false positive is sobelow
  # not following that check into this shared helper.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(dir, key, source_path) do
    with {:ok, dest} <- safe_path(dir, key) do
      File.mkdir_p!(Path.dirname(dest))

      case File.cp(source_path, dest) do
        :ok -> {:ok, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(dir, key) do
    with {:ok, path} <- safe_path(dir, key), do: File.read(path)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove(dir, key) do
    with {:ok, dest} <- safe_path(dir, key) do
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
  defp safe_path(dir, key) do
    if is_binary(key) and key == Path.basename(key) and key not in ["", ".", ".."] do
      {:ok, Path.join(dir, key)}
    else
      {:error, :invalid_key}
    end
  end

  @doc "Absolute directory public blobs are written to."
  def root do
    config() |> Keyword.get_lazy(:root, fn -> Application.app_dir(:kiln_cms, "priv/uploads") end)
  end

  @doc "Absolute directory private blobs are written to — no Plug.Static mount serves it."
  def private_root do
    config()
    |> Keyword.get_lazy(:private_root, fn ->
      Application.app_dir(:kiln_cms, "priv/private_uploads")
    end)
  end

  @doc """
  Creates both storage directories if needed and proves each can be written
  to, by writing and removing a probe file.

  Called at boot (`KilnCMS.Application`) so an unwritable directory is named
  once in the logs instead of failing every upload. The usual cause is a
  platform volume mounted root-owned while the image runs as `nobody` (#1529).
  """
  @spec check_writable() :: :ok | {:error, Path.t(), term()}
  def check_writable do
    Enum.reduce_while([root(), private_root()], :ok, fn dir, :ok ->
      case probe(dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, dir, reason}}
      end
    end)
  end

  # A fixed probe name, never a storage key: keys are UUIDs, so it cannot
  # collide with a blob, and a probe left behind by a crash is harmless.
  # sobelow_skip ["Traversal.FileModule"]
  defp probe(dir) do
    path = Path.join(dir, ".kiln-write-probe")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, "") do
      File.rm(path)
    end
  end

  defp base_url, do: Keyword.get(config(), :base_url, "/uploads")

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
