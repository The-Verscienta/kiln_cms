defmodule KilnCMS.Portability.Export do
  @moduledoc """
  Dumps content to a portable JSON envelope (#487) — the other half of
  `KilnCMS.Portability.Import`, and the answer to "can I get my content out".

  ## Shape

      %{
        "kiln_export" => %{"version" => 1, "exported_at" => "...", "types" => [...]},
        "records" => [%{"type" => "post", "title" => ..., "blocks" => [...], ...}],
        "media" => [%{"id" => ..., "url" => ..., "filename" => ..., ...}]
      }

  `blocks` is the typed-block tree in its **storage** shape, which is what the
  create action accepts on the way back in. That is the whole point: an export
  a human can read but the importer cannot load is a report, not a backup.

  ## References are carried by slug, not by id

  Category, tags and content type travel as slugs; media travels as a manifest
  entry the record points at by its *source* id. A uuid is meaningless in the
  target database, so an envelope full of them would import as content with
  every relationship dropped — which is exactly the failure mode that makes
  people distrust "export" buttons. Slugs survive the trip.

  ## What is not exported

  Workflow history, versions, anchors, view counters, comments and form
  submissions. Those describe what happened to the content *on this site*; they
  are not the content, and several of them (anchors especially) would be
  actively wrong to replay into another system as though they had happened
  there. `mix kiln.audit.checkpoint` and the governance exports cover that
  ground deliberately.

  Media **bytes** are not embedded either — the manifest carries URLs. An
  envelope with base64 images is unusable at any real site's scale, and the
  importer sideloads from the manifest anyway.

  ## Authorization

  Reads run under the caller's `:actor`/`:tenant`, so an export contains
  exactly what that actor could have read one page at a time. There is no
  `authorize?: false` here — an export endpoint that bypassed policy would be
  the most efficient data-exfiltration primitive in the system.
  """

  alias KilnCMS.CMS.ContentTypes

  @version 1

  # Read in pages rather than one unbounded query, so no single SQL round trip
  # has to return every row. Note this bounds the QUERY, not the result: the
  # envelope is assembled in memory and encoded as one binary, so a very large
  # site is still a very large allocation. `--type` and `--limit` are the tools
  # for that; a genuinely streaming export would have to give up the single
  # JSON document.
  @page_size 200

  @typedoc "The JSON-serializable envelope."
  @type envelope :: %{required(String.t()) => term()}

  @doc """
  Export `types` (a list of type names/atoms, or `:all`).

  Options:

    * `:actor` / `:tenant` — every read runs under them
    * `:states` — which workflow states to include (default `[:published, :draft]`)
    * `:locale` — restrict to one locale (default: all)
    * `:limit` — cap the number of records per type
  """
  @spec run([atom() | String.t()] | :all, keyword()) :: {:ok, envelope()} | {:error, term()}
  def run(types \\ :all, opts \\ []) do
    resolved = resolve_types(types, opts)

    records = Enum.flat_map(resolved, &export_type(&1, opts))

    {:ok,
     %{
       "kiln_export" => %{
         "version" => @version,
         "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "types" => Enum.map(resolved, &to_string(&1.type))
       },
       "records" => records,
       "media" => media_manifest(records, opts)
     }}
  end

  @doc """
  `run/2` encoded as JSON text.

  Pretty-printed: an export is a file a human opens to check before trusting
  it, and the size difference is noise next to the block trees inside.
  """
  @spec to_json([atom() | String.t()] | :all, keyword()) :: {:ok, String.t()} | {:error, term()}
  def to_json(types \\ :all, opts \\ []) do
    with {:ok, envelope} <- run(types, opts) do
      Jason.encode(envelope, pretty: true)
    end
  end

  # ── Types ──────────────────────────────────────────────────────────────────

  defp resolve_types(:all, opts), do: ContentTypes.all() ++ dynamic_types(opts)

  defp resolve_types(types, opts) when is_list(types) do
    org = org_id(opts)

    types
    |> Enum.map(&ContentTypes.get(&1, org))
    |> Enum.reject(&is_nil/1)
  end

  defp dynamic_types(opts) do
    ContentTypes.dynamic_all(org_id(opts))
  rescue
    _error -> []
  end

  # ── Records ────────────────────────────────────────────────────────────────

  defp export_type(descriptor, opts) do
    states = Keyword.get(opts, :states, [:published, :draft])

    descriptor
    |> stream_records(states, opts)
    |> Enum.map(&record_map(&1, descriptor))
  end

  # Keyset-free paging on `inserted_at` would need a tiebreaker to be correct
  # under equal timestamps; offset paging is correct for a snapshot read and an
  # export is exactly that. `:limit` caps the total, not the page.
  defp stream_records(descriptor, states, opts) do
    limit = Keyword.get(opts, :limit)

    Stream.resource(
      fn -> 0 end,
      fn
        :halt ->
          {:halt, :halt}

        offset ->
          case page(descriptor, states, offset, opts) do
            [] -> {:halt, :halt}
            rows when length(rows) < @page_size -> {rows, :halt}
            rows -> {rows, offset + @page_size}
          end
      end,
      fn _acc -> :ok end
    )
    |> then(fn stream -> if limit, do: Stream.take(stream, limit), else: stream end)
  end

  defp page(descriptor, states, offset, opts) do
    filter = [state: [in: states]] |> maybe_locale(opts[:locale])

    ContentTypes.list!(
      descriptor,
      scope(opts) ++
        [
          load: [tags: nil, category: nil],
          query: [
            filter: filter,
            sort: [inserted_at: :asc, id: :asc],
            limit: @page_size,
            offset: offset
          ]
        ]
    )
  rescue
    # A type whose read action refuses the actor contributes nothing rather
    # than aborting the whole export — the envelope then honestly contains
    # what this actor can see.
    _error -> []
  end

  defp maybe_locale(filter, nil), do: filter
  defp maybe_locale(filter, locale), do: Keyword.put(filter, :locale, locale)

  # Every optional field is read with `Map.get/2`, never with dot access.
  # Content types do NOT share one attribute set — a `Page` has no `excerpt`
  # (`ContentTypes.get(:page).excerpt? == false`), and a dynamic type has
  # whatever its definition declares. Dot access raises `KeyError` on the first
  # type that omits a field, which would make the export work for posts and
  # fail for everything else.
  defp record_map(record, descriptor) do
    %{
      "type" => to_string(descriptor.type),
      "title" => record.title,
      "slug" => record.slug,
      "locale" => record.locale,
      "state" => to_string(record.state),
      "blocks" => dump_blocks(record),
      "excerpt" => Map.get(record, :excerpt),
      "seo_title" => Map.get(record, :seo_title),
      "seo_description" => Map.get(record, :seo_description),
      "seo_keywords" => Map.get(record, :seo_keywords),
      "seo_image" => Map.get(record, :seo_image),
      "canonical_url" => Map.get(record, :canonical_url),
      "path_alias" => Map.get(record, :path_alias),
      "audience" => record |> Map.get(:audience) |> to_string_or_nil(),
      "custom_fields" => Map.get(record, :custom_fields),
      "published_at" => record |> Map.get(:published_at) |> iso8601(),
      "category" => term_slug(Map.get(record, :category)),
      "tags" => record |> Map.get(:tags) |> term_slugs(),
      "featured_image_id" => Map.get(record, :featured_image_id)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Back through the union's storage shape, the same route
  # `KilnCMS.CMS.ContentCopy` takes — the create action re-casts (and
  # re-sanitizes) it on import, so what leaves is what can come back.
  #
  # Then normalized through JSON. `dump_to_embedded` emits the union tag as an
  # ATOM (`"type" => :heading`) and the value map with atom keys, which encode
  # to correct JSON but are *not* the shape a caller sees when it uses the
  # envelope in memory. Without this the same envelope behaves differently
  # depending on whether it went through a file: `Export.run/2` piped straight
  # into `Import.run_envelope/2` would fail to match a single block, while the
  # identical data written out and read back would import fine. Paying one
  # encode/decode here makes the in-memory envelope byte-identical to the file.
  defp dump_blocks(record) do
    attribute = Ash.Resource.Info.attribute(record.__struct__, :blocks)

    with {:ok, dumped} <-
           Ash.Type.dump_to_embedded(attribute.type, record.blocks || [], attribute.constraints),
         {:ok, json} <- Jason.encode(dumped) do
      Jason.decode!(json)
    else
      _error -> []
    end
  rescue
    _error -> []
  end

  # ── Media manifest ─────────────────────────────────────────────────────────

  # Every media item the exported records actually reference — featured images
  # and image/gallery blocks. Exporting the whole library instead would make
  # the manifest mostly noise, and the importer only ever fetches what a block
  # points at.
  defp media_manifest(records, opts) do
    ids =
      records
      |> Enum.flat_map(&referenced_media_ids/1)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    ids
    |> Enum.chunk_every(100)
    |> Enum.flat_map(&fetch_media(&1, opts))
  end

  defp referenced_media_ids(record) do
    [record["featured_image_id"] | block_media_ids(record["blocks"] || [])]
  end

  defp block_media_ids(blocks) when is_list(blocks),
    do: Enum.flat_map(blocks, &block_media_ids/1)

  defp block_media_ids(%{} = map) do
    own = for {key, value} <- map, key in ["media_id", :media_id], is_binary(value), do: value

    nested =
      map
      |> Map.values()
      |> Enum.flat_map(fn
        value when is_list(value) or is_map(value) -> block_media_ids(value)
        _other -> []
      end)

    own ++ nested
  end

  defp block_media_ids(_other), do: []

  # Under the caller's own actor and tenant, like every other read here.
  #
  # This was `authorize?: false` with no tenant, which failed in two directions
  # at once. With `strict_tenancy` on (the production default) `MediaItem` is
  # `global?: false`, so a tenant-less read RAISES and the rescue below turned
  # every production export's manifest into `[]` — silently losing every
  # featured image on every round trip. And in a fail-open build the same read
  # spanned every organization *and* bypassed the read policy that gates
  # non-public items, handing a viewer the storage URLs of media they cannot
  # see. The moduledoc's promise that there is no `authorize?: false` here is
  # now true.
  defp fetch_media(ids, opts) do
    KilnCMS.CMS.list_media_items!(scope(opts) ++ [query: [filter: [id: [in: ids]]]])
    |> Enum.map(
      &%{
        "id" => &1.id,
        "filename" => &1.filename,
        "url" => &1.url,
        "content_type" => &1.content_type,
        "alt" => &1.alt,
        "caption" => &1.caption
      }
    )
  rescue
    _error -> []
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp scope(opts), do: Keyword.take(opts, [:actor, :tenant])

  defp org_id(opts) do
    case Keyword.get(opts, :tenant) do
      %{id: id} -> id
      id when is_binary(id) -> id
      _ -> KilnCMS.Accounts.default_org_id()
    end
  end

  defp term_slug(%{slug: slug}), do: slug
  defp term_slug(_other), do: nil

  defp term_slugs(tags) when is_list(tags), do: Enum.map(tags, & &1.slug)
  defp term_slugs(_other), do: []

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(other), do: to_string(other)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
