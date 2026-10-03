defmodule KilnCMS.CMS.ContentLinks do
  @moduledoc """
  Reference edges: the `KilnCMS.CMS.ContentLink` rows that mirror a record's
  `:reference` custom fields (#1594, decision D20 in
  `docs/content-organization-plan.md`).

  A `:reference` field stores a snapshot in `custom_fields` —
  `%{"id", "type", "slug", "title"}` — and that value keeps its shape and its
  meaning for every reader of 1.0. What the snapshot cannot do is answer
  "what links here": that took a jsonb scan across every content table. So
  every live reference value now also has an edge:

    * `kind: :reference`, `field` the custom field's name, `position` its place
      in the field (always 0 for a single reference);
    * `source_type` / `target_type` the content type names of both ends, in the
      same vocabulary as the snapshot's `"type"`.

  ## When edges are written

  `KilnCMS.CMS.Changes.SyncReferenceLinks` calls `reconcile/1` after every
  content write whose **live** `custom_fields` changed — a create, a save, a
  version restore, publishing a working copy, an unpublish folding one. The
  edges are rebuilt from the stored value, never from the request, so the
  snapshot and the edge cannot disagree.

  A published record's working copy holds its draft custom fields in
  `working_fields` (docs/working-copy.md). Those are **not** edges: a
  reference nobody can follow yet is not a link. It becomes one when
  `publish_changes` moves it into the live column.

  A hard delete (`:purge`) removes the record's outgoing edges. Edges pointing
  **at** a trashed or purged record stay: they are the broken references the
  backlinks panel and `broken/2` report, and they go away when the referrer is
  next saved with the field cleared or re-pointed.

  ## Existing data

  `KilnCMS.CMS.ContentLinks.Backfill` writes the edges for references stored
  before 1.1, from a data migration and from `mix kiln.links.backfill`.
  """

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Bookkeeping
  alias KilnCMS.CMS.ContentTypes

  @typedoc "One edge a record's custom fields imply."
  @type edge :: %{
          field: String.t(),
          target_id: Ash.UUID.t(),
          target_type: String.t() | nil,
          position: non_neg_integer()
        }

  @doc """
  The reference edges `custom_fields` implies, given the record's `:reference`
  field definitions. Values that are not a resolved snapshot (no uuid `"id"`)
  imply nothing; a list value implies one edge per element, in order.
  """
  @spec desired(map() | nil, [struct()]) :: [edge()]
  def desired(custom_fields, definitions) when is_map(custom_fields) do
    Enum.flat_map(definitions, fn definition ->
      custom_fields
      |> Map.get(definition.name)
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(&edge(&1, definition))
    end)
  end

  def desired(_custom_fields, _definitions), do: []

  defp edge({%{"id" => id} = value, position}, definition) when is_binary(id) do
    if uuid?(id) do
      [
        %{
          field: definition.name,
          target_id: id,
          target_type: string_or(value["type"], definition.target_type),
          position: position
        }
      ]
    else
      []
    end
  end

  defp edge(_value, _definition), do: []

  defp string_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp string_or(_value, fallback), do: fallback

  @doc """
  The `:reference` field definitions governing `record`, read as the cms
  bookkeeping (registry metadata, not user data) and failing closed: a refused
  read raising beats reconciling against "no reference fields", which would
  delete every edge the record has.
  """
  @spec reference_definitions(struct()) :: [struct()]
  def reference_definitions(%resource{} = record) do
    opts = [actor: Bookkeeping.system(), authorize_with: :error, tenant: record.org_id]

    cond do
      function_exported?(resource, :__kiln_dynamic_entry__, 0) ->
        case Map.get(record, :type_definition_id) do
          nil -> []
          id -> CMS.field_definitions_for_definition!(id, opts)
        end

      function_exported?(resource, :__kiln_content_type__, 0) ->
        CMS.field_definitions_for!(resource.__kiln_content_type__(), opts)

      true ->
        []
    end
    |> Enum.filter(&(&1.field_type == :reference))
  end

  @doc """
  Bring `record`'s outgoing reference edges in line with its live
  `custom_fields`: create the missing ones, delete the ones no value implies
  any more, and replace any whose target type or position moved. Idempotent.
  """
  @spec reconcile(struct()) :: :ok
  def reconcile(record) do
    wanted =
      record
      |> Map.get(:custom_fields)
      |> desired(reference_definitions(record))
      |> Map.new(&{{&1.field, &1.target_id}, &1})

    existing = existing(record)

    stale =
      Enum.reject(existing, fn link ->
        case Map.get(wanted, {link.field, link.target_id}) do
          nil -> false
          want -> link.target_type == want.target_type and link.position == want.position
        end
      end)

    kept = MapSet.new(existing -- stale, &{&1.field, &1.target_id})
    opts = write_opts(record)

    Enum.each(stale, &CMS.destroy_content_link!(&1, opts))

    source_type = ContentTypes.type_name_for(record)

    for {key, want} <- wanted, not MapSet.member?(kept, key) do
      want
      |> Map.merge(%{source_id: record.id, source_type: source_type, kind: :reference})
      |> CMS.create_content_link!(opts)
    end

    :ok
  end

  @doc "Delete every outgoing reference edge of `record` (its hard delete)."
  @spec clear(struct()) :: :ok
  def clear(record) do
    opts = write_opts(record)
    record |> existing() |> Enum.each(&CMS.destroy_content_link!(&1, opts))
  end

  defp existing(record) do
    CMS.list_reference_links!(record.id,
      actor: Bookkeeping.system(),
      authorize_with: :error,
      tenant: record.org_id
    )
  end

  defp write_opts(record), do: [actor: Bookkeeping.system(), tenant: record.org_id]

  @doc """
  "What links here": the edges pointing at `record`, each with its `source`
  record loaded, as the actor sees them.

  Both halves are the actor's: the edge read is policy-checked
  (`Checks.LinkEndsReadable` — an edge whose source the actor may not read is
  not returned at all), and the sources are read under the same
  authorization, so a link the actor could not open is never offered.
  Returns `[%{link: ContentLink.t(), source: struct()}]`, ordered by `kind`,
  `field`, `position`.
  """
  @spec backlinks(struct(), keyword()) :: [%{link: struct(), source: struct() | nil}]
  def backlinks(record, opts) do
    opts = Keyword.put_new(opts, :tenant, record.org_id)

    links =
      CMS.list_backlinks!(record.id, Keyword.take(opts, [:actor, :tenant, :authorize?]))
      |> Enum.reject(&(&1.source_id == record.id))

    sources = load_sources(links, opts)

    links
    |> Enum.map(&%{link: &1, source: Map.get(sources, &1.source_id)})
    |> Enum.reject(&is_nil(&1.source))
  end

  # The referrers, by id, across every content resource — a link written
  # before 1.1 carries no `source_type`, so the type is not trusted to route
  # the read. A handful of reads, one per resource.
  defp load_sources([], _opts), do: %{}

  defp load_sources(links, opts) do
    ids = links |> Enum.map(& &1.source_id) |> Enum.uniq()
    read_opts = Keyword.take(opts, [:actor, :tenant, :authorize?])

    ContentTypes.blocks_resources()
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.flat_map(fn resource ->
      resource
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select(source_fields(resource))
      |> Ash.read(read_opts)
      |> case do
        {:ok, records} -> records
        {:error, _error} -> []
      end
    end)
    |> Map.new(&{&1.id, &1})
  end

  # Enough to list and link a referrer; a dynamic entry also needs its type
  # definition to name its editor route.
  defp source_fields(resource) do
    base = [:id, :title, :slug, :state, :org_id]

    if Ash.Resource.Info.attribute(resource, :type_definition_id),
      do: [:type_definition_id | base],
      else: base
  end

  @doc """
  The `record`'s reference edges whose target the actor can no longer read —
  trashed, purged, or (for a reader who sees published content only)
  unpublished. Editors see trashed and purged targets here; a published-only
  reader would never be shown the edge in the first place.
  """
  @spec broken(struct(), keyword()) :: [struct()]
  def broken(record, opts) do
    opts = Keyword.put_new(opts, :tenant, record.org_id)
    read_opts = Keyword.take(opts, [:actor, :tenant, :authorize?])

    links =
      record.id
      |> CMS.list_reference_links!(read_opts)

    readable =
      KilnCMS.CMS.Checks.LinkEndsReadable.readable_ids(
        Keyword.get(opts, :actor),
        opts[:tenant],
        Enum.map(links, & &1.target_id)
      )

    Enum.reject(links, &MapSet.member?(readable, &1.target_id))
  end

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
