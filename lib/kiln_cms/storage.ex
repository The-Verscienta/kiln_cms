defmodule KilnCMS.Storage do
  @moduledoc """
  Pluggable blob storage for media binaries.

  The default adapter (`KilnCMS.Storage.Local`) writes to the local filesystem
  — fine for development and single-node deployments. Production can swap in an
  S3/MinIO adapter via config without touching callers:

      config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3

  Callers go through this module (`Storage.store/2`, `Storage.url/1`, …) rather
  than a concrete adapter.

  ## A site's own store (#1559)

  A site can bring its own bucket (`/editor/site-storage`). Every function
  here takes an optional last argument saying which store to use — see
  `t:at/0`. The rule every caller follows:

    * **A new upload** asks `upload_target/1` for the site's current store and
      records it on the media row (`MediaItem.storage_profile_id`,
      `profile_id/1`).
    * **Anything about an existing file** — reading it, deleting it, deriving
      variants, posters or transforms from it, moving it between the public and
      private buckets — passes the *item*, so it goes to the store the row
      names, never to the site's current setting. A derived file goes to its
      item's store too, so an item's files never straddle two stores.

  `nil` (the default) is the operator's store, so every existing call and every
  existing row behave exactly as before.
  """

  alias KilnCMS.Storage.{Profile, S3, SiteProfiles}

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

  @doc """
  A time-limited URL a client can `PUT` exactly `byte_size` bytes to, landing
  at `key` in **private** storage — the first leg of the direct-upload API
  (`KilnCMS.Media.DirectUpload`).

  Optional, because only an adapter with a separate object store has a URL
  that is not this app: the S3 adapter presigns one against its private
  bucket, the Local adapter has nothing to presign and does not implement it
  (a file uploaded "directly" to the Local adapter would be uploaded to this
  app, which is what `POST /api/media` already is). `direct_uploads_available?/0`
  is the check.

  The returned `headers` are part of the signature and the client MUST send
  them as given — `content-length` among them, which is what makes the object
  store itself refuse a body of any other size.
  """
  @callback presign_private_put(
              key :: String.t(),
              byte_size :: pos_integer(),
              expires_in :: pos_integer()
            ) ::
              {:ok, %{url: String.t(), headers: %{String.t() => String.t()}}} | {:error, term()}

  @optional_callbacks presign_private_put: 3

  @spec adapter() :: module()
  def adapter do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, KilnCMS.Storage.Local)
  end

  @typedoc """
  Which store an operation is aimed at (#1559):

    * `nil` — the operator's (`adapter/0`), as every call was before sites
      could bring their own;
    * a `KilnCMS.Storage.Profile` — a site's own, already resolved;
    * a media item (anything with `:org_id` and `:storage_profile_id`) — the
      store that item's file is in, resolved through
      `KilnCMS.Storage.SiteProfiles.for_item/1`. A `nil` profile on the row is
      the operator's.

  An item whose profile can't be resolved fails the operation with
  `{:error, {:site_storage, reason}}` — never a quiet retry against the
  operator's store, which doesn't have the file. `url/2` takes only `nil` or a
  resolved profile: it returns a string, so it has no way to fail.
  """
  @type at :: Profile.t() | map() | nil

  @doc """
  Resolves `at` (see `t:at/0`) to `nil` (the operator's store) or a site's
  `Profile` — once, for a caller about to make several calls against the same
  item's store.
  """
  @spec locate(at()) :: {:ok, Profile.t() | nil} | {:error, {:site_storage, term()}}
  def locate(nil), do: {:ok, nil}
  def locate(%Profile{} = profile), do: {:ok, profile}

  def locate(item) when is_map(item) do
    case SiteProfiles.for_item(item) do
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, {:site_storage, reason}}
    end
  end

  @doc """
  Where a new upload for the site `org_id` goes: `{:ok, nil}` for the
  operator's store or `{:ok, profile}` for the site's own. `{:error,
  {:site_storage, reason}}` when the site's own is set but unusable — the
  upload must then be refused, never written to the operator's store (see
  `KilnCMS.Storage.SiteProfiles`). Record the profile's id on the media row.
  """
  @spec upload_target(Ash.UUID.t() | nil) ::
          {:ok, Profile.t() | nil} | {:error, {:site_storage, term()}}
  def upload_target(org_id) do
    # A tenant-less upload is created in the default org, so it goes where the
    # default org's files go.
    case SiteProfiles.for_upload(KilnCMS.Accounts.org_id(org_id)) do
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, {:site_storage, reason}}
    end
  end

  @doc "The profile id to record on a media row for `at`: `nil` for the operator's store."
  @spec profile_id(Profile.t() | nil) :: Ash.UUID.t() | nil
  def profile_id(nil), do: nil
  def profile_id(%Profile{id: id}), do: id

  @spec store(String.t(), String.t(), at()) :: {:ok, String.t()} | {:error, term()}
  def store(key, source_path, at \\ nil),
    do: run(at, fn -> adapter().store(key, source_path) end, &S3.store(key, source_path, &1))

  @spec fetch(String.t(), at()) :: {:ok, binary()} | {:error, term()}
  def fetch(key, at \\ nil), do: run(at, fn -> adapter().fetch(key) end, &S3.fetch(key, &1))

  @doc """
  Remove the blob at `key` — except in demo mode, where the delete of an
  operator-store blob is deferred to the next reset and this returns `:ok`
  (`KilnCMS.Demo.Blobs`): a visitor purging or re-deriving a golden image must
  not remove a file the golden snapshot still references. The golden snapshot
  is never in a site's own store, so those deletes are not deferred.
  """
  @spec delete(String.t(), at()) :: :ok | {:error, term()}
  def delete(key, at \\ nil) do
    run(
      at,
      fn ->
        if KilnCMS.Demo.enabled?(),
          do: KilnCMS.Demo.Blobs.defer(key),
          else: adapter().delete(key)
      end,
      &S3.delete(key, &1)
    )
  end

  @spec url(String.t(), Profile.t() | nil) :: String.t()
  def url(key, site \\ nil)
  def url(key, nil), do: adapter().url(key)
  def url(key, %Profile{} = profile), do: S3.url(key, profile)

  @spec store_private(String.t(), String.t(), at()) :: {:ok, String.t()} | {:error, term()}
  def store_private(key, source_path, at \\ nil),
    do:
      run(
        at,
        fn -> adapter().store_private(key, source_path) end,
        &S3.store_private(key, source_path, &1)
      )

  @spec fetch_private(String.t(), at()) :: {:ok, binary()} | {:error, term()}
  def fetch_private(key, at \\ nil),
    do: run(at, fn -> adapter().fetch_private(key) end, &S3.fetch_private(key, &1))

  @doc "`delete/2` for private storage — deferred in demo mode the same way."
  @spec delete_private(String.t(), at()) :: :ok | {:error, term()}
  def delete_private(key, at \\ nil) do
    run(
      at,
      fn ->
        if KilnCMS.Demo.enabled?(),
          do: KilnCMS.Demo.Blobs.defer(key),
          else: adapter().delete_private(key)
      end,
      &S3.delete_private(key, &1)
    )
  end

  @doc """
  Whether `at`'s store has private storage. An item whose store can't be
  resolved has none, as far as a caller deciding whether to gate it is
  concerned.
  """
  @spec private_available?(at()) :: boolean()
  def private_available?(at \\ nil) do
    case locate(at) do
      {:ok, nil} -> adapter().private_available?()
      {:ok, profile} -> S3.private_available?(profile)
      {:error, _reason} -> false
    end
  end

  @doc """
  Whether the direct-upload API can run against `at`'s store: the store
  presigns (`presign_private_put/3`) AND has private storage to presign into.
  The staging object holds an upload nobody has sniffed or stripped yet, so it
  must never land anywhere a delivery route serves from — hence private, and
  hence no fallback to the public bucket when there is none. A site's own store
  is always S3, so it presigns whenever it has a private bucket.
  """
  @spec direct_uploads_available?(at()) :: boolean()
  def direct_uploads_available?(at \\ nil) do
    case locate(at) do
      {:ok, nil} ->
        adapter = adapter()

        Code.ensure_loaded?(adapter) and function_exported?(adapter, :presign_private_put, 3) and
          adapter.private_available?()

      {:ok, profile} ->
        S3.private_available?(profile)

      {:error, _reason} ->
        false
    end
  end

  @spec presign_private_put(String.t(), pos_integer(), pos_integer(), at()) ::
          {:ok, %{url: String.t(), headers: %{String.t() => String.t()}}} | {:error, term()}
  def presign_private_put(key, byte_size, expires_in, at \\ nil) do
    with {:ok, site} <- locate(at) do
      cond do
        not direct_uploads_available?(site) -> {:error, :direct_uploads_unavailable}
        is_nil(site) -> adapter().presign_private_put(key, byte_size, expires_in)
        true -> S3.presign_private_put(key, byte_size, expires_in, site)
      end
    end
  end

  @type range_read :: %{
          bytes: binary(),
          first: non_neg_integer(),
          last: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec fetch_range(String.t(), non_neg_integer(), non_neg_integer() | :eof, at()) ::
          {:ok, range_read()} | {:error, term()}
  def fetch_range(key, first, last, at \\ nil),
    do:
      run(
        at,
        fn -> adapter().fetch_range(key, first, last) end,
        &S3.fetch_range(key, first, last, &1)
      )

  @spec fetch_private_range(String.t(), non_neg_integer(), non_neg_integer() | :eof, at()) ::
          {:ok, range_read()} | {:error, term()}
  def fetch_private_range(key, first, last, at \\ nil),
    do:
      run(
        at,
        fn -> adapter().fetch_private_range(key, first, last) end,
        &S3.fetch_private_range(key, first, last, &1)
      )

  # Resolve `at` once, then run the operator's or the site's half.
  defp run(at, operator, site) do
    case locate(at) do
      {:ok, nil} -> operator.()
      {:ok, profile} -> site.(profile)
      {:error, _reason} = error -> error
    end
  end

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
  item's blob, and `at:` (`t:at/0`) for a file in a site's own store — it is
  resolved once, not per chunk.

  A zero-length blob copies successfully as an empty file; only a failure on
  the FIRST read is an error, since a later one means a short file is already
  on disk and whatever reads it next will reject it on its own terms.
  """
  # `dest` is server-built (System.tmp_dir! + a UUID) at every call site, never
  # user input — the File traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  @spec copy_to_file(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def copy_to_file(key, dest, opts \\ []) do
    with {:ok, site} <- locate(Keyword.get(opts, :at)),
         {:ok, io} <- File.open(dest, [:write, :binary]) do
      read =
        if Keyword.get(opts, :private?, false),
          do: &fetch_private_range(&1, &2, &3, site),
          else: &fetch_range(&1, &2, &3, site)

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
