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

  @doc """
  Persist `source_path` under `key` in **private** storage (#481) — reachable
  only by re-fetching it through this module, never at a public URL. Used for
  gated documents: unlike `store/2`, there is no `url/1` counterpart, because
  a private blob has no public address to hand out.
  """
  @callback store_private(key :: String.t(), source_path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Read a private blob back into memory — the only way to reach its bytes."
  @callback fetch_private(key :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Remove a private blob. Missing blobs are treated as success."
  @callback delete_private(key :: String.t()) :: :ok | {:error, term()}

  @doc """
  Whether this adapter can actually store privately right now. The Local
  adapter always can (a second on-disk directory needs no configuration); the
  S3 adapter needs an operator-configured private bucket — see its moduledoc.
  Callers that gate content on an audience must check this before allowing
  the gate, rather than let `store_private/2` silently degrade.
  """
  @callback private_available?() :: boolean()

  @doc """
  Read the byte range `first..last` (inclusive, `last` may be `:eof` for "to
  the end") out of the blob at `key`, without loading the rest of it.

  Added for A/V streaming (#494): a browser seeking in a video issues
  `Range:` requests, and answering one by `fetch/1`-ing a 200 MB file into
  memory and slicing it would put the whole file in the BEAM heap per seek.
  The Local adapter `pread`s; the S3 adapter forwards the range to S3.

  Returns the bytes alongside the range actually served (adapters clamp
  `last` to the end of the blob) and the blob's **total** size, which the
  caller needs for `Content-Range` and cannot get any other way — notably
  not from `MediaItem.byte_size`, which is the client-reported upload size.

  `{:error, {:range_not_satisfiable, total}}` when `first` is at or past the
  end and the adapter knows the total, `{:error, :range_not_satisfiable}` when
  it doesn't — a 416 has to state the resource's real length, and only the
  adapter can supply it.
  """
  @callback fetch_range(
              key :: String.t(),
              first :: non_neg_integer(),
              last :: non_neg_integer() | :eof
            ) ::
              {:ok,
               %{
                 bytes: binary(),
                 first: non_neg_integer(),
                 last: non_neg_integer(),
                 total: non_neg_integer()
               }}
              | {:error, term()}

  @doc "`fetch_range/3` against private storage — the gated counterpart, same contract."
  @callback fetch_private_range(
              key :: String.t(),
              first :: non_neg_integer(),
              last :: non_neg_integer() | :eof
            ) ::
              {:ok,
               %{
                 bytes: binary(),
                 first: non_neg_integer(),
                 last: non_neg_integer(),
                 total: non_neg_integer()
               }}
              | {:error, term()}

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

  @spec store_private(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def store_private(key, source_path), do: adapter().store_private(key, source_path)

  @spec fetch_private(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_private(key), do: adapter().fetch_private(key)

  @spec delete_private(String.t()) :: :ok | {:error, term()}
  def delete_private(key), do: adapter().delete_private(key)

  @spec private_available?() :: boolean()
  def private_available?, do: adapter().private_available?()

  @type range_read :: %{
          bytes: binary(),
          first: non_neg_integer(),
          last: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec fetch_range(String.t(), non_neg_integer(), non_neg_integer() | :eof) ::
          {:ok, range_read()} | {:error, term()}
  def fetch_range(key, first, last), do: adapter().fetch_range(key, first, last)

  @spec fetch_private_range(String.t(), non_neg_integer(), non_neg_integer() | :eof) ::
          {:ok, range_read()} | {:error, term()}
  def fetch_private_range(key, first, last), do: adapter().fetch_private_range(key, first, last)

  # Bytes held in memory at once by `copy_to_file/3`.
  @copy_chunk 8 * 1024 * 1024

  @doc """
  Copies the blob at `key` to `dest` on the local filesystem a chunk at a time,
  never holding more than 8 MB of it in memory.

  The counterpart of `fetch/1` for anything that needs the *file* rather than
  the bytes. Video changed the arithmetic here (#494): the media library
  accepts uploads up to 500 MB, so every `fetch/1` that exists only to write a
  temp file became a half-gigabyte binary on the heap — several at once, given
  a background queue with concurrency. Pass `private?: true` for a gated
  item's blob.

  A zero-length blob copies successfully as an empty file; only a failure on
  the FIRST read is an error, since a later one means a short file is already
  on disk and whatever reads it next will reject it on its own terms.
  """
  # `dest` is server-built (System.tmp_dir! + a UUID) at every call site, never
  # user input — the File traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  @spec copy_to_file(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def copy_to_file(key, dest, opts \\ []) do
    read =
      if Keyword.get(opts, :private?, false), do: &fetch_private_range/3, else: &fetch_range/3

    with {:ok, io} <- File.open(dest, [:write, :binary]) do
      try do
        copy_chunks(read, key, io, 0)
      after
        File.close(io)
      end
    end
  end

  defp copy_chunks(read, key, io, offset) do
    case read.(key, offset, offset + @copy_chunk - 1) do
      {:ok, %{bytes: bytes, total: total}} ->
        IO.binwrite(io, bytes)
        next = offset + byte_size(bytes)
        if next >= total, do: :ok, else: copy_chunks(read, key, io, next)

      # An empty blob has no satisfiable range; an empty file is the right copy.
      {:error, {:range_not_satisfiable, 0}} ->
        :ok

      {:error, _reason} when offset > 0 ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds a collision-resistant storage key from an upload's filename, keeping
  the original extension (lowercased).
  """
  @spec generate_key(String.t()) :: String.t()
  def generate_key(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    "#{Ecto.UUID.generate()}#{ext}"
  end

  @doc "Builds a collision-resistant storage key from an already-validated extension (e.g. \".png\")."
  @spec generate_key_with_ext(String.t()) :: String.t()
  def generate_key_with_ext(ext) when is_binary(ext), do: "#{Ecto.UUID.generate()}#{ext}"
end
