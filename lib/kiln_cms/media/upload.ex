defmodule KilnCMS.Media.Upload do
  @moduledoc """
  The media upload API's domain half — what `POST /api/media`,
  `POST /api/media/import-url` and the direct-upload completion
  (`KilnCMS.Media.DirectUpload`) share before and after
  `KilnCMS.Media.Ingest`.

  Ingest is the pipeline — sniff, size-cap, strip, store, create, derive — and
  it is the same one the editor's media library runs; nothing here restates a
  step of it. What an API caller adds is two things the LiveView never needed:

    * **Authorization before work.** `Ingest` authorizes at its last step, the
      `MediaItem` create, which is correct for the library (only a signed-in
      editor ever reaches it) and wasteful for an API anyone can send a
      500 MB body to: a read-only key would have its video remuxed and stored
      before the create refused it. `authorize/2` asks the same policies up
      front, and `KilnCMSWeb.MediaUploadController` asks it *before reading
      the request body at all*. The create still re-checks — this is an early
      answer, not a replacement.

    * **Metadata on upload.** Alt text, caption, the decorative flag, the
      focal point and tags, in one request rather than an upload plus a PATCH.
      `metadata/1` casts and validates them against the `:create` action's own
      attribute constraints, so a bad focal point is a 422 before any bytes are
      processed rather than a stored blob and a refused row.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Media.Ingest

  # What a client may set on upload — the editor-settable fields the library's
  # drawer edits, and the same set `:update_metadata` accepts afterwards.
  # Everything the pipeline owns (`url`, `storage_key`, `variants`, sizes,
  # `content_type`) comes from the bytes, never from the request.
  @attributes [:alt, :caption, :decorative, :focal_x, :focal_y]

  @type metadata :: keyword()

  @doc "The metadata fields `metadata/1` reads, as the request spells them."
  @spec metadata_fields() :: [String.t()]
  def metadata_fields, do: Enum.map(@attributes ++ [:tag_ids], &Atom.to_string/1)

  @doc """
  May `actor` upload media into `tenant` at all? `:ok`,
  `{:error, :unauthenticated}` for no actor, `{:error, :forbidden}` for an
  actor the `MediaItem` create policy refuses — a read-only API key
  (`ApiKeyWithoutWriteAccess`), or a `:viewer`.
  """
  @spec authorize(term(), term()) :: :ok | {:error, :unauthenticated | :forbidden}
  def authorize(nil, _tenant), do: {:error, :unauthenticated}

  def authorize(actor, tenant) do
    if CMS.can_create_media_item?(actor, %{filename: "upload"}, tenant: tenant),
      do: :ok,
      else: {:error, :forbidden}
  end

  @doc """
  Cast and validate the upload metadata in `params` (string keys, as a
  multipart form or a JSON body delivers them). Unknown keys are ignored.

  Returns `{:ok, opts}` — `Ingest` options — or
  `{:error, {:invalid, field, message}}` for the first field that fails.
  """
  @spec metadata(map()) :: {:ok, metadata()} | {:error, {:invalid, String.t(), String.t()}}
  def metadata(params) when is_map(params) do
    input =
      params
      |> Map.take(metadata_fields())
      |> Map.put("filename", "upload")

    changeset = Ash.Changeset.for_create(MediaItem, :create, input)

    if changeset.valid? do
      {:ok,
       Enum.flat_map(@attributes, &present(&1, Ash.Changeset.get_attribute(changeset, &1))) ++
         present(:tag_ids, Ash.Changeset.get_argument(changeset, :tag_ids))}
    else
      {:error, first_error(changeset)}
    end
  end

  def metadata(_params), do: {:error, {:invalid, "data", "must be an object"}}

  # Only what the request actually carried: an absent field keeps the
  # attribute's default (focal point 0.5, not decorative) rather than writing
  # a nil over it. `decorative: false` is a value, not an absence.
  defp present(_key, nil), do: []
  defp present(key, value), do: [{key, value}]

  defp first_error(changeset) do
    case changeset.errors do
      [error | _] -> {:invalid, error_field(error), Exception.message(error)}
      [] -> {:invalid, "data", "is invalid"}
    end
  end

  defp error_field(%{field: field}) when not is_nil(field), do: to_string(field)
  defp error_field(%{fields: [field | _]}), do: to_string(field)
  defp error_field(_error), do: "data"

  @doc """
  Normalize a client-supplied filename to the name to record: its basename,
  trimmed. `{:error, {:invalid, "filename", message}}` for an empty one or one
  past the column's length — refused up front, because the create would
  otherwise refuse it only after the file had been stripped and stored.
  """
  @spec filename(term()) :: {:ok, String.t()} | {:error, {:invalid, String.t(), String.t()}}
  def filename(name) when is_binary(name) do
    name = name |> Path.basename() |> String.trim()

    cond do
      name in ["", ".", ".."] ->
        {:error, {:invalid, "filename", "is required"}}

      String.length(name) > KilnCMS.Limits.identifier() ->
        {:error, {:invalid, "filename", "is too long"}}

      true ->
        {:ok, name}
    end
  end

  def filename(_name), do: {:error, {:invalid, "filename", "is required"}}

  @doc """
  Ingest the file at `path` (a server-owned temp file) as `filename`, under
  `actor`/`tenant`, with `metadata` from `metadata/1`. The uploader is stamped
  from the actor — an API key's owning user.
  """
  @spec from_file(Path.t(), String.t(), metadata(), term(), term()) ::
          {:ok, struct()} | {:error, term()}
  def from_file(path, filename, metadata, actor, tenant) do
    Ingest.store_file(path, filename, ingest_opts(metadata, actor, tenant))
  end

  # How many redirects an import follows. Asset URLs routinely sit behind one
  # (a CDN's canonical host, `http` → `https`); `SafeFetch` re-validates and
  # re-pins every hop, so following a few costs no SSRF ground.
  @import_redirects 3

  @doc """
  Download `url` through `KilnCMS.SafeFetch` (via `Ingest.store_url/2`) and
  ingest it. `filename` overrides the name the URL's path implies. Capped at
  `import_max_bytes/0` — the download is buffered in memory.
  """
  @spec from_url(String.t(), String.t() | nil, metadata(), term(), term()) ::
          {:ok, struct()} | {:error, term()}
  def from_url(url, filename, metadata, actor, tenant) do
    opts =
      metadata
      |> ingest_opts(actor, tenant)
      |> Keyword.merge(max_redirects: @import_redirects, filename: filename)

    Ingest.store_url(url, opts)
  end

  @doc "The largest body `from_url/5` will download (see `Ingest.store_url/2`)."
  @spec import_max_bytes() :: pos_integer()
  defdelegate import_max_bytes, to: Ingest, as: :max_download_size

  defp ingest_opts(metadata, actor, tenant) do
    Keyword.merge(metadata, actor: actor, tenant: tenant)
  end

  @doc """
  The item as an API response wants it: tags loaded, under the same actor, so
  the caller sees what it just attached.
  """
  @spec load_for_response(struct(), term(), term()) :: struct()
  def load_for_response(item, actor, tenant) do
    case Ash.load(item, [:tags], actor: actor, tenant: tenant) do
      {:ok, loaded} -> loaded
      {:error, _reason} -> item
    end
  end
end
