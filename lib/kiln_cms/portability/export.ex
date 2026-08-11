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
    error ->
      # A read this actor is not allowed to make contributes nothing — the
      # envelope then honestly contains what they can see. ANY other failure
      # aborts: `[]` makes `Stream.resource` halt, so a DB timeout at offset 400
      # of 10,000 used to end the stream, write a 400-record file, print
      # "Wrote N bytes" and exit 0. A truncated export that reports success is
      # the worst failure mode this feature has.
      if forbidden?(error), do: [], else: reraise(error, __STACKTRACE__)
  end

  defp forbidden?(%Ash.Error.Forbidden{}), do: true

  defp forbidden?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &match?(%Ash.Error.Forbidden.Policy{}, &1))

  defp forbidden?(_other), do: false

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
      # Slug AND name. Carrying the slug alone made the importer rebuild every
      # term as %{name: slug}, so a fresh target org showed "how-to" and
      # "case-studies" in its nav instead of "How To" and "Case Studies", with
      # nothing in the envelope to recover the originals from.
      "category" => term_ref(Map.get(record, :category)),
      "tags" => record |> Map.get(:tags) |> term_refs(),
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

    # Deliberately NOT rescued to `[]`. Returning an empty list here stripped the
    # record's whole body while `record_map/2` still emitted its title, slug and
    # state — so the envelope looked complete, nothing appeared in any report,
    # and importing it produced a document with a title and no content. A body
    # that cannot be dumped is a broken export, and the caller must hear about it.
    {:ok, dumped} =
      Ash.Type.dump_to_embedded(attribute.type, record.blocks || [], attribute.constraints)

    dumped |> Jason.encode!() |> Jason.decode!()
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

  # Suffix matching, not the literal key "media_id" — `Blocks.Video` declares
  # `poster_media_id` and `captions_media_id`, and `KilnCMS.Firing.References`
  # already reads media ids this way (it gained an explicit Gallery clause
  # because #482 proved the naive path drops gallery media silently). Keying on
  # one literal name left a round-tripped video pointing at the SOURCE
  # database's uuids for its poster and caption track.
  defp block_media_ids(%{} = map) do
    own = for {key, value} <- map, media_id_key?(key), is_binary(value), do: value

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

  @doc false
  @spec media_id_key?(term()) :: boolean()
  def media_id_key?(key) when is_atom(key), do: key |> Atom.to_string() |> media_id_key?()

  def media_id_key?(key) when is_binary(key),
    do: String.ends_with?(key, "media_id") or String.ends_with?(key, "image_id")

  def media_id_key?(_other), do: false

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

  # `KilnCMS.Accounts.org_id/1` is the canonical normalization (#527). The private
  # copy this replaced had the loose `%{id: id}` clause that helper exists to
  # prevent, plus a catch-all silently falling back to the default org — so a
  # tenant shape neither clause matched made the registry answer for the DEFAULT
  # org while the reads ran under the caller's.
  defp org_id(opts), do: KilnCMS.Accounts.org_id(Keyword.get(opts, :tenant))

  defp term_ref(%{slug: slug, name: name}), do: %{"slug" => slug, "name" => name}
  defp term_ref(%{slug: slug}), do: %{"slug" => slug}
  defp term_ref(_other), do: nil

  defp term_refs(tags) when is_list(tags), do: Enum.map(tags, &term_ref/1)
  defp term_refs(_other), do: []

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(other), do: to_string(other)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
