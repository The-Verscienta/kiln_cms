defmodule KilnCMS.Firing.References do
  @moduledoc """
  Reference extraction + the re-fire wave (Kiln v2 — decision D13).

  References resolve/embed at fire time (decision A3), so a referrer's artifact
  goes stale when its target re-fires. This module:

    * `extract/1` / `references/1` — pull reference edges out of a typed block tree
    * `rebuild/3` — replace a document's outgoing edges (called on every fire)
    * `invalidate/3` — enqueue cycle-safe re-fire jobs for a changed doc's referrers

  References live either in a block's DSL `:reference` field(s) or, for legacy
  content bridged to `Custom`, in `data["ref"]` / `data["refs"]`
  (`%{"type" => "page"|"post", "id" => uuid}`).
  """
  alias KilnCMS.Blocks.{Columns, Custom, Gallery}
  alias KilnCMS.CMS
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing
  alias KilnCMS.Firing.{Engine, RefireWorker}

  require Ash.Query

  # `"entry"` is the generic tier holding every admin-defined dynamic type
  # (D17) — one storage key, the dynamic name is recoverable from the row.
  # Compiled content types beyond these resolve through the ContentTypes
  # registry (see `type_atom/1`), so a `mix kiln.gen.content` type fires
  # without touching this module.
  @types %{"page" => :page, "post" => :post, "entry" => :entry}

  @doc "Reference edges out of a document: `[%{from: {type,id}, to: {type,id}}]`."
  @spec references(struct()) :: [%{from: {atom(), term()}, to: {atom(), term()}}]
  def references(document) do
    from = {Engine.document_type(document), document.id}

    document
    |> document_refs()
    |> Enum.map(&%{from: from, to: &1})
  end

  @doc """
  Every `{to_type, to_id}` a *document* references — its block tree plus the
  references that live on the document itself rather than in a block (#403).

  `extract/1` sees only blocks, which is all the re-fire wave ever needed. Media
  usage tracking needs the whole picture: an image can be a document's featured
  image or the value of a `:media` custom field without appearing in any block,
  and an editor asking "where is this used" before deleting it must be told
  about those too.
  """
  @spec document_refs(struct()) :: [{atom(), term()}]
  def document_refs(document) do
    blocks = document |> Map.get(:blocks) |> TypedBlocks.to_typed()

    (extract(blocks) ++ media_refs(blocks) ++ document_media_refs(document))
    |> Enum.uniq()
  end

  # Media a document points at outside its blocks: the featured image, and any
  # `:media` custom field (whose stored shape is a resolved snapshot map, so the
  # id is read from it rather than from a bare uuid).
  defp document_media_refs(document) do
    featured = document |> Map.get(:featured_image_id) |> List.wrap()

    custom =
      document
      |> Map.get(:custom_fields)
      |> case do
        map when is_map(map) -> map |> Map.values() |> Enum.flat_map(&custom_field_media_id/1)
        _other -> []
      end

    (featured ++ custom)
    |> Enum.filter(&valid_uuid?/1)
    |> Enum.map(&{:media, &1})
  end

  # A `:media` custom field stores `%{"id", "url", "alt", ...}`; a `:reference`
  # field stores `%{"id", "type", "slug", "title"}` for a *document*. Both carry
  # an `"id"`, so matching on that alone recorded every content reference as a
  # media edge — asserting a media dependency on a row that is not a media item.
  # `"url"` is what distinguishes an asset from a document.
  defp custom_field_media_id(%{"id" => id, "url" => url}) when is_binary(id) and is_binary(url),
    do: [id]

  defp custom_field_media_id(_value), do: []

  @doc """
  Media referenced from a typed block tree.

  Separate from `extract/1` because a media id is *not* a DSL `:reference`
  field — image blocks carry a plain `media_id` string, and typing them as
  references would enrol media in the re-fire wave, which is a different
  decision from tracking usage.
  """
  @spec media_refs([struct()]) :: [{atom(), term()}]
  def media_refs(typed_blocks) do
    typed_blocks
    |> List.wrap()
    |> Enum.flat_map(&block_media_refs/1)
    |> Enum.uniq()
  end

  defp block_media_refs(%Columns{} = block),
    do: block |> Columns.child_blocks_flat() |> Enum.flat_map(&block_media_refs/1)

  # A gallery's ids sit inside an `{:array, :map}` field, so the field-name
  # convention below cannot see them — `images` does not end in `media_id`, and
  # the value is a list of maps rather than a list of ids. Left to the generic
  # clause a gallery records *no* media edges at all, which loses usage counts,
  # re-fire on media change, and delivery cache busts, all silently (#482).
  defp block_media_refs(%Gallery{} = block) do
    block
    |> Gallery.media_ids()
    |> Enum.filter(&valid_uuid?/1)
    |> Enum.map(&{:media, &1})
  end

  defp block_media_refs(%mod{} = block) do
    mod
    |> Kiln.Block.Info.fields()
    |> Enum.filter(&media_field?/1)
    |> Enum.flat_map(fn field -> block |> Map.get(field.name) |> List.wrap() end)
    |> Enum.filter(&valid_uuid?/1)
    |> Enum.map(&{:media, &1})
  end

  defp block_media_refs(_block), do: []

  # Named by convention (`media_id`, `image_id`, `poster_id`, …) because a media
  # pointer has no DSL type of its own. A block author gets tracking for free by
  # naming the field the way every existing block already does.
  defp media_field?(%{name: name}) do
    name = to_string(name)
    String.ends_with?(name, "media_id") or String.ends_with?(name, "image_id")
  end

  # A block's `media_id` is a free-text string field, so it can hold anything an
  # importer put there. Only a real uuid becomes an edge — `to_id` is a `:uuid`
  # column and a bulk insert of junk would fail the whole rebuild.
  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  @doc "Distinct `{to_type, to_id}` targets referenced by a typed block list."
  @spec extract([struct()]) :: [{atom(), term()}]
  def extract(typed_blocks) do
    typed_blocks
    |> List.wrap()
    |> Enum.flat_map(&block_refs/1)
    |> Enum.uniq()
  end

  @doc """
  Replace a document's outgoing edges to match its current references.

  Takes the `document` rather than its id because the edge set is no longer
  derivable from the block tree alone — a featured image and a `:media` custom
  field are references the document carries directly (#403).
  """
  @spec rebuild(Ash.UUID.t(), atom(), struct(), [struct()]) :: :ok
  def rebuild(org_id, from_type, document, typed_blocks) do
    from_id = document.id

    # Tenant-scoped (epic #336): destroy/create only touch this org's edges, so a
    # rebuild can never delete or upsert across a tenant boundary. `org_id` is set
    # from the tenant (writable? false), so it's not in the built attrs maps.
    Firing.ReferenceEdge
    |> Ash.Query.filter(from_type == ^from_type and from_id == ^from_id)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, tenant: org_id)

    (extract(typed_blocks) ++ media_refs(typed_blocks) ++ document_media_refs(document))
    |> Enum.uniq()
    |> Enum.map(fn {to_type, to_id} ->
      %{from_type: from_type, from_id: from_id, to_type: to_type, to_id: to_id}
    end)
    |> Ash.bulk_create!(Firing.ReferenceEdge, :upsert,
      authorize?: false,
      tenant: org_id,
      return_errors?: true,
      stop_on_error?: true,
      # The :edge identity spans every attribute, so a conflicting row is
      # already identical — bulk upsert just needs *some* field to "update".
      upsert_fields: [:to_id]
    )

    :ok
  end

  @doc """
  Enqueue re-fire jobs for everything that references `{to_type, to_id}`, skipping
  any node already in `visited` (cycle-safe). The originating doc's key should be
  in `visited` so it is not re-fired by its own wave.
  """
  @spec invalidate(Ash.UUID.t(), atom(), term(), [String.t()]) :: :ok
  def invalidate(org_id, to_type, to_id, visited) do
    # Tenant-scoped `edges_to` (epic #336): a wave only ever sees same-org
    # referrers, so a re-fire can never cross a tenant boundary. `org_id` is
    # carried in the job args so the worker restores it as its tenant.
    {:ok, edges} = Firing.edges_to(to_type, to_id, authorize?: false, tenant: org_id)

    edges
    |> Enum.map(&{&1.from_type, &1.from_id})
    |> Enum.uniq()
    |> Enum.reject(fn {ft, fid} -> key(ft, fid) in visited end)
    |> Enum.each(fn {ft, fid} ->
      %{"org_id" => org_id, "type" => to_string(ft), "id" => fid, "visited" => visited}
      |> RefireWorker.new()
      |> Oban.insert()
    end)

    :ok
  end

  # A widely-used asset — a site logo, a shared stock photo — can be referenced
  # by every document on the site, and each referrer costs its own fetch. The
  # list is context for a delete decision, so a bounded sample plus a count is
  # worth more than a thousand-row list that blocks the LiveView to build.
  @usage_limit 25

  @doc """
  The documents that reference a media item (#403).

  Answers "where is this used" before a delete or a replace. Reads the same
  edges the fire path already maintains, so it costs one indexed lookup plus one
  fetch per referrer rather than a scan of every document's block tree. Returns
  at most `#{@usage_limit}` entries alongside the true total.

  > #### Published references only {: .warning}
  >
  > Edges are written when a document **fires**, which happens on publish. A
  > draft that has never been published references nothing as far as this is
  > concerned, so an image used only by drafts reports as unused. Deletes are
  > soft (AshArchival), so a restore covers the mistake either way.

  Referrers whose record has since been purged are dropped rather than reported
  as a broken row: an edge outlives a hard delete (`reference_source?: false` is
  the same trade the version tables make), and an editor asking what uses an
  image does not want to be told about documents that no longer exist.
  """
  @spec usages(Ash.UUID.t(), term()) :: %{total: non_neg_integer(), items: [map()]}
  def usages(org_id, media_id) do
    {:ok, edges} = Firing.edges_to(:media, media_id, authorize?: false, tenant: org_id)

    referrers =
      edges
      |> Enum.map(&{&1.from_type, &1.from_id})
      |> Enum.uniq()

    items =
      referrers
      |> Enum.take(@usage_limit)
      |> Enum.flat_map(fn {type, id} -> usage(org_id, type, id) end)
      |> Enum.sort_by(& &1.title)

    %{total: length(referrers), items: items}
  end

  @doc """
  How many published documents reference each of `media_ids` (#403).

  One query for a whole grid, so the media library can warn *at the point of
  deletion* rather than only inside a drawer the editor may never open — which
  is what the issue asked for. Ids with no referrers are absent from the map.
  """
  @spec usage_counts(Ash.UUID.t(), [term()]) :: %{optional(term()) => pos_integer()}
  def usage_counts(_org_id, []), do: %{}

  def usage_counts(org_id, media_ids) do
    Firing.ReferenceEdge
    |> Ash.Query.filter(to_type == :media and to_id in ^media_ids)
    |> Ash.Query.select([:to_id, :from_type, :from_id])
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> Enum.uniq_by(&{&1.to_id, &1.from_type, &1.from_id})
    |> Enum.frequencies_by(& &1.to_id)
  end

  defp usage(org_id, type, id) do
    case load_any(org_id, type, id) do
      {:ok, record} ->
        [
          %{
            type: type,
            id: id,
            title: record.title,
            state: record.state,
            kind: editor_kind(record)
          }
        ]

      :error ->
        []
    end
  end

  # The segment `/editor/content/:kind/:id` expects. `from_type` is the STORAGE
  # tier, so every dynamic type is stored as `:entry` — and `/editor/content/entry/…`
  # resolves to no descriptor and bounces the editor back to `/editor`. The
  # record itself knows its own dynamic name.
  defp editor_kind(%KilnCMS.CMS.Entry{} = record) do
    # A dynamic entry's editor segment is its own type's NAME, which lives on
    # its definition — `:entry` is only the storage tier.
    case CMS.get_type_definition(record.type_definition_id, authorize?: false) do
      {:ok, definition} -> definition.name
      _other -> nil
    end
  end

  defp editor_kind(%module{}), do: CMS.ContentTypes.type_name(module)

  # `load_published/3` deliberately answers only for published documents — the
  # re-fire wave has no business with drafts. This one loads whatever is there,
  # so a document unpublished since it last fired still shows as a usage.
  defp load_any(org_id, :page, id), do: any(CMS.get_page(id, authorize?: false, tenant: org_id))
  defp load_any(org_id, :post, id), do: any(CMS.get_post(id, authorize?: false, tenant: org_id))
  defp load_any(org_id, :entry, id), do: any(CMS.get_entry(id, authorize?: false, tenant: org_id))

  defp load_any(org_id, type, id) do
    case CMS.ContentTypes.get(type) do
      %{source: :compiled, resource: resource} ->
        any(Ash.get(resource, id, authorize?: false, tenant: org_id))

      _ ->
        :error
    end
  end

  defp any({:ok, %{} = doc}), do: {:ok, doc}
  defp any(_other), do: :error

  @doc "Stable wave key for a node."
  @spec key(atom(), term()) :: String.t()
  def key(type, id), do: "#{type}:#{id}"

  @doc "Map a stored type string to its atom (whitelisted; avoids dynamic atoms)."
  @spec type_atom(atom() | String.t()) :: atom() | nil
  def type_atom(type) when is_atom(type), do: type

  def type_atom(type) when is_binary(type) do
    case Map.get(@types, type) do
      nil ->
        # Any other compiled content type registered on a content domain —
        # `ContentTypes.get/1` resolves strings via safe_existing_atom, so no
        # dynamic atoms are created.
        case CMS.ContentTypes.get(type) do
          %{source: :compiled, type: atom} -> atom
          _ -> nil
        end

      atom ->
        atom
    end
  end

  @doc """
  The published document to fire, or why there isn't one.

  The four outcomes are deliberately distinct, because callers must act on them
  differently (#664):

    * `{:ok, doc}` — fire it.
    * `:absent` — the row is gone, or exists and is not published. **Settled
      fact**: its artifacts are garbage and a caller may delete them.
    * `:unknown_type` — no compiled resource answers to this type, so the
      document cannot be addressed at all. Nothing to retry and nothing safe to
      delete.
    * `{:error, reason}` — the read itself failed. Says nothing about whether
      the document exists.

  Until #664 all three failures collapsed to a bare `:error`, and both callers
  read that as "nothing to fire, we're done". Two bugs lived in the gap: a
  transient read failure made a just-published document silently never fire
  (with `max_attempts: 3` never engaging, because the job had *succeeded*), and
  an orphan artifact could not be cleaned up because no caller could tell
  "definitely not published" from "we could not find out".
  """
  @spec load_published(Ash.UUID.t(), atom(), term()) ::
          {:ok, struct()} | :absent | :unknown_type | {:error, term()}
  def load_published(org_id, :page, id),
    do: published(CMS.get_page(id, authorize?: false, tenant: org_id))

  def load_published(org_id, :post, id),
    do: published(CMS.get_post(id, authorize?: false, tenant: org_id))

  def load_published(org_id, :entry, id),
    do: published(CMS.get_entry(id, authorize?: false, tenant: org_id))

  # Any other compiled content type: resolve its resource from the registry.
  def load_published(org_id, type, id) do
    case CMS.ContentTypes.get(type) do
      %{source: :compiled, resource: resource} ->
        published(Ash.get(resource, id, authorize?: false, tenant: org_id))

      _ ->
        :unknown_type
    end
  end

  defp published({:ok, %{state: :published} = doc}), do: {:ok, doc}

  # It exists and is not published — settled, and the case unpublish intended to
  # purge artifacts for.
  defp published({:ok, %{}}), do: :absent

  defp published({:error, error}), do: if(not_found?(error), do: :absent, else: {:error, error})

  # Anything else is a shape we did not anticipate, which is not the same as
  # "no document" — treat it as a failed read rather than a licence to delete.
  defp published(other), do: {:error, other}

  # Ash wraps the not-found in an `Invalid`/`Query` envelope whose `errors` list
  # carries the real class, so the check has to recurse rather than match the
  # top-level struct.
  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &not_found?/1)
  defp not_found?(_other), do: false

  # A `columns` container has no refs of its own, but its nested children may —
  # recurse so a reference inside a column is tracked like a top-level one.
  defp block_refs(%Columns{} = block),
    do: block |> Columns.child_blocks_flat() |> Enum.flat_map(&block_refs/1)

  defp block_refs(%mod{} = block), do: dsl_refs(mod, block) ++ custom_refs(block)

  defp dsl_refs(mod, block) do
    mod
    |> Kiln.Block.Info.fields()
    |> Enum.filter(&reference_field?/1)
    |> Enum.flat_map(fn field -> block |> Map.get(field.name) |> normalize_refs() end)
  end

  defp reference_field?(%{type: :reference}), do: true
  defp reference_field?(%{type: {:array, :reference}}), do: true
  defp reference_field?(_), do: false

  defp custom_refs(%Custom{data: data}) when is_map(data) do
    normalize_refs(List.wrap(Map.get(data, "ref")) ++ (Map.get(data, "refs") || []))
  end

  defp custom_refs(_), do: []

  defp normalize_refs(nil), do: []
  defp normalize_refs(list) when is_list(list), do: Enum.flat_map(list, &normalize_refs/1)

  defp normalize_refs(%{"type" => type, "id" => id}) do
    case type_atom(type) do
      nil -> []
      atom -> [{atom, id}]
    end
  end

  defp normalize_refs(_), do: []
end
