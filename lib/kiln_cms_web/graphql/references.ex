defmodule KilnCMSWeb.Graphql.References do
  @moduledoc """
  Resolvers for `references`, `referencedBy` and the records behind them
  (`KilnCMSWeb.Graphql.ContentRecord`).

  ## Batching

  Two batched steps, so a list of records costs a fixed number of reads, not
  one per row:

    1. `references` / `referencedBy` read the edges (`ContentLink`,
       `kind: :reference`) for every parent in the list at once.
    2. `target` / `source` read the records on the other end, one read per
       content type, with the fields the document selected loaded on that
       read (`AshGraphql.load_fields_on_query/3`).

  ## Who sees what

  Everything is read **as the reader**: the edges through `ContentLink`'s read
  policy, which keeps an edge only when the reader may read both of its ends
  (`KilnCMS.CMS.Checks.LinkEndsReadable`; editors see every edge of their
  site), and the records through their own type's read policy. So a reader
  never meets a draft target, or a draft source, they could not have read
  directly. Pagination counts only the edges the reader may see.
  """

  import Absinthe.Resolution.Helpers, only: [batch: 3]

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ReverseFields

  # The most rows one `references`/`referencedBy` field returns. Also the
  # default: an omitted `limit` is priced at 5 rows (`GraphqlLimits`), but
  # never returns an unbounded list.
  @max_rows 100

  @doc "Absinthe `resolve_type` for `ContentRecord`: the record's own GraphQL object."
  @spec resolve_type(struct(), Absinthe.Resolution.t()) :: atom() | nil
  def resolve_type(%resource{}, _resolution), do: AshGraphql.Resource.Info.type(resource)
  def resolve_type(_other, _resolution), do: nil

  @doc "Resolver for `references(field:, limit:, offset:)`."
  def references(%{id: id}, args, resolution) do
    window = window(args)
    key = {:references, args.field, window, actor(resolution), tenant(resolution)}

    batch({__MODULE__, :load_edges, key}, id, &{:ok, Map.get(&1, id, [])})
  end

  @doc "Resolver for `referencedBy(field:, sourceType:, inverse:, limit:, offset:)`."
  def referenced_by(%{id: id} = parent, %{inverse: inverse} = args, resolution)
      when is_binary(inverse) do
    if args[:field] || args[:source_type] do
      {:error, "pass either inverse, or field and sourceType, not both"}
    else
      key = {:inverse, inverse, window(args), actor(resolution), tenant(resolution)}
      item = {id, ContentTypes.type_name_for(parent)}

      batch({__MODULE__, :load_inverse_edges, key}, item, &{:ok, Map.get(&1, id, [])})
    end
  end

  def referenced_by(%{id: id}, args, resolution) do
    window = window(args)

    key =
      {:referenced_by, {args[:field], args[:source_type]}, window, actor(resolution),
       tenant(resolution)}

    batch({__MODULE__, :load_edges, key}, id, &{:ok, Map.get(&1, id, [])})
  end

  @doc false
  # Absinthe batch function for `referencedBy(inverse:)` (R4). The name is a
  # reverse field of each parent's own type, which stands for one reference
  # field on one source type, so the parents are grouped by type and each
  # group reads its edges as `field:` + `sourceType:` would. A type with no
  # reverse field of that name lists nothing, as an unknown `field:` does.
  def load_inverse_edges({:inverse, name, window, actor, tenant}, items) do
    items
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.reduce(%{}, fn {type, ids}, acc ->
      case ReverseFields.find(type, name, tenant) do
        nil ->
          acc

        reverse ->
          scope = {reverse.field, reverse.source_type}
          Map.merge(acc, load_edges({:referenced_by, scope, window, actor, tenant}, ids))
      end
    end)
  end

  @doc false
  # Absinthe batch function: every parent's edges in one read, then each
  # parent's window. Returns `%{parent_id => [row]}`.
  def load_edges({direction, scope, {offset, limit}, actor, tenant}, parent_ids) do
    parent_ids = Enum.uniq(parent_ids)

    [query: edge_query(direction, scope, parent_ids), actor: actor, tenant: tenant]
    |> CMS.list_content_links()
    |> case do
      {:ok, edges} ->
        edges
        |> Enum.group_by(&parent_id(direction, &1))
        |> Map.new(fn {parent_id, edges} ->
          {parent_id,
           edges |> Enum.drop(offset) |> Enum.take(limit) |> Enum.map(&row(direction, &1))}
        end)

      {:error, _error} ->
        %{}
    end
  end

  defp edge_query(:references, field, ids) do
    [
      filter: [source_id: [in: ids], kind: :reference, field: field],
      sort: [position: :asc, id: :asc]
    ]
  end

  defp edge_query(:referenced_by, {field, source_type}, ids) do
    filter =
      [target_id: [in: ids], kind: :reference]
      |> put_present(:field, field)
      |> put_present(:source_type, source_type)

    [filter: filter, sort: [field: :asc, source_type: :asc, position: :asc, id: :asc]]
  end

  defp put_present(filter, _key, nil), do: filter
  defp put_present(filter, key, value), do: Keyword.put(filter, key, value)

  defp parent_id(:references, edge), do: edge.source_id
  defp parent_id(:referenced_by, edge), do: edge.target_id

  # The edge's own payload is passed through as stored: R3's link fields fill
  # `metadata` (and the snapshot's `"link"`), this module only carries it.
  defp row(:references, edge) do
    %{
      position: edge.position,
      link: edge.metadata,
      record: {edge.target_type, edge.target_id}
    }
  end

  defp row(:referenced_by, edge) do
    %{
      field: edge.field,
      position: edge.position,
      link: edge.metadata,
      record: {edge.source_type, edge.source_id}
    }
  end

  @doc "Resolver for `ContentReference.target`."
  def target(%{record: record}, _args, resolution), do: resolve_record(record, resolution)

  @doc "Resolver for `ContentReferrer.source`."
  def source(%{record: record}, _args, resolution), do: resolve_record(record, resolution)

  defp resolve_record({type_name, id}, resolution) do
    tenant = tenant(resolution)

    case resource_for(type_name, tenant) do
      nil ->
        {:ok, nil}

      resource ->
        # Every row of one list shares the field node, so they share the
        # selection, and the field node's place in the document is a key that
        # groups exactly them. The query travels with each item; the batch
        # takes the first.
        query =
          resource
          |> AshGraphql.load_fields_on_query(resolution)
          |> Ash.Query.ensure_selected([:id])

        key = {resource, resolution.definition.source_location, actor(resolution), tenant}

        batch({__MODULE__, :load_records, key}, {id, query}, &{:ok, Map.get(&1, id)})
    end
  end

  @doc false
  # Absinthe batch function: one read per content type, as the reader.
  def load_records({resource, _location, actor, tenant}, [{_id, query} | _] = items) do
    ids = items |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    query = Ash.Query.filter(query, id in ^ids)

    resource
    |> read(query, actor: actor, tenant: tenant)
    |> Map.new(&{&1.id, &1})
  end

  # Dynamic types share the `Entry` tier (D17): ids are unique across it, so
  # one read covers every dynamic type in the list.
  defp read(CMS.Entry, query, opts) do
    case CMS.list_entries([query: query] ++ opts) do
      {:ok, records} -> records
      {:error, _error} -> []
    end
  end

  defp read(resource, query, opts) do
    ContentTypes.list!(ContentTypes.type_atom(resource), [query: query] ++ opts)
  rescue
    # A refused or failed read lists nothing; denying is the safe direction.
    _error -> []
  end

  # An edge names its ends' content types (`"page"`, a dynamic type's name).
  # A type that no longer exists, or an edge written before types were
  # recorded, resolves to nothing rather than to a guess.
  defp resource_for(nil, _tenant), do: nil

  defp resource_for(type_name, tenant) do
    case ContentTypes.get(type_name, tenant) do
      %{source: :dynamic} -> CMS.Entry
      %{resource: resource} when not is_nil(resource) -> resource
      _unknown -> nil
    end
  end

  defp window(args) do
    offset = max(args[:offset] || 0, 0)
    limit = args[:limit] |> Kernel.||(@max_rows) |> max(0) |> min(@max_rows)
    {offset, limit}
  end

  defp actor(%{context: context}), do: Map.get(context, :actor)

  defp tenant(%{context: context}) do
    case Map.get(context, :tenant) do
      %{id: id} -> id
      other -> other
    end
  end
end
