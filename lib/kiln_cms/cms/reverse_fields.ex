defmodule KilnCMS.CMS.ReverseFields do
  @moduledoc """
  Reverse fields (R4 in `docs/relationships-plan.md`): the other side of a
  `:reference` custom field, as its targets see it.

  A reference definition that names an `inverse_label` / `inverse_name`
  ("Recipes using this ingredient", `used_in_recipes`) gives every record of
  each type it may point at a **reverse field**: the records that connect to
  it through that field. Nothing is stored for it. It is read from the edges
  the reference already writes (`KilnCMS.CMS.ContentLinks`): `kind:
  :reference`, this `field`, from this `source_type`, at this `target_id`.

  ## Who sees what

  `rows/3` reads as the caller, twice over, so it is the both-ends read rule
  unchanged: the edges through `ContentLink`'s read policy, which keeps an
  edge only when the reader may read both of its ends, and the sources
  through their own type's read policy. A reader never meets a draft source
  they could not have opened directly, and the count counts only what they
  may see.

  Which reverse fields a type has is schema, not content, so `for_type/2`
  reads the definitions as the cms registry reader, the way the editor and
  the schema export read a type's own fields.
  """

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.WorkingCopy

  @typedoc """
  One reverse field of a type: its own `name` and `label`, and the reference
  it mirrors — `field` on `source_type` records, whose definition is
  `definition` (with its link fields loaded).
  """
  @type t :: %{
          name: String.t(),
          label: String.t(),
          field: String.t(),
          source_type: String.t(),
          source_label: String.t(),
          definition: FieldDefinition.t()
        }

  @typedoc """
  One record that connects to the target: the connection's `link`
  (`metadata`, `position`) and whether its working copy holds a change to it
  (`pending`, R4b).
  """
  @type row :: %{
          source: struct(),
          link: %{metadata: map(), position: non_neg_integer()},
          pending: nil | :add | :remove | :move,
          editable?: boolean(),
          count: non_neg_integer()
        }

  @doc """
  The reverse fields records of `type` show, in the source fields' order.
  `type` is a content type name (`"page"`, a dynamic type's name) or atom.
  A definition whose owning type no longer exists is left out.
  """
  @spec for_type(atom() | String.t() | nil, Ash.UUID.t() | struct() | nil) :: [t()]
  def for_type(nil, _org), do: []

  def for_type(type, org) do
    org_id = KilnCMS.Accounts.org_id(org)

    type
    |> to_string()
    |> CMS.reverse_field_definitions_for!(
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: org_id
    )
    |> Enum.flat_map(&describe(&1, org_id))
  end

  @doc "The reverse field of `type` named `name`, or nil."
  @spec find(atom() | String.t() | nil, String.t(), Ash.UUID.t() | struct() | nil) :: t() | nil
  def find(type, name, org), do: type |> for_type(org) |> Enum.find(&(&1.name == name))

  defp describe(definition, org_id) do
    case source(definition, org_id) do
      nil ->
        []

      %{type: source_type, label: source_label} ->
        [
          %{
            name: definition.inverse_name,
            label: definition.inverse_label,
            field: definition.name,
            source_type: to_string(source_type),
            source_label: source_label,
            definition: definition
          }
        ]
    end
  end

  # The content type owning the reference: a compiled type by name, or the
  # dynamic type whose definition id it carries.
  defp source(%{type_definition_id: nil, content_type: type}, org_id) do
    if FieldDefinition.orphaned?(%{type_definition_id: nil, content_type: type}),
      do: nil,
      else: ContentTypes.get(type, org_id)
  end

  defp source(%{type_definition_id: id}, org_id),
    do: org_id |> ContentTypes.dynamic_all() |> Enum.find(&(&1.definition.id == id))

  @doc """
  One page of the records connecting to `target` through `reverse`, as the
  caller (`:actor`, `:tenant`) may see them, ordered by title — and how many
  there are in all. `:offset` and `:limit` (default 10) pick the page.

  A connection is listed once it is **live** (an edge) or **pending**: a
  published source whose working copy connects the target, not yet published
  (R4b). Each row carries the connection as `link` — `metadata` (the
  link-field values, R3) and `position` (the target's place in the source's
  own list) — and `pending`: `nil` when what is live is what the source will
  publish, else `:add`, `:remove` or `:move`, the change its working copy
  holds for this connection.

  Returns `%{rows: [row()], total: non_neg_integer(), ids: [Ash.UUID.t()]}`;
  `ids` are every connected source the caller may see, on any page, so an
  add control can leave them out of its search.
  """
  @spec rows(struct(), t(), keyword()) ::
          %{rows: [row()], total: non_neg_integer(), ids: [Ash.UUID.t()]}
  def rows(target, reverse, opts) do
    tenant = Keyword.get(opts, :tenant) || target.org_id
    read_opts = [actor: Keyword.get(opts, :actor), tenant: tenant]

    edges =
      CMS.list_content_links!(
        read_opts ++
          [
            query: [
              filter: [
                target_id: target.id,
                kind: :reference,
                field: reverse.field,
                source_type: reverse.source_type
              ]
            ]
          ]
      )
      |> Map.new(&{&1.source_id, &1})

    ids = Map.keys(edges) ++ held_source_ids(target, reverse, Map.keys(edges), read_opts)

    page(ids, edges, target, reverse, read_opts, opts)
  end

  # Published sources whose working copy connects the target and whose live
  # value does not yet — no edge, since edges follow the live value only. As
  # the caller, so a source they cannot read is not found.
  defp held_source_ids(target, reverse, edge_ids, read_opts) do
    reverse.source_type
    |> ContentTypes.list!(
      read_opts ++
        [
          query: [
            filter:
              expr(
                state == :published and not is_nil(working_copy_at) and id not in ^edge_ids and
                  ^holds(reverse.field, target.id, reverse.definition.multiple)
              )
          ]
        ]
    )
    # A working copy is the editors' business: a held connection is listed
    # only to a caller who could write that source, never to a reader.
    |> Enum.filter(&editable?(&1, reverse, Keyword.get(read_opts, :actor), read_opts))
    |> Enum.map(& &1.id)
  end

  # Whether the working copy's value of `field` holds an item with this id —
  # jsonb containment, built in SQL so the id stays a plain text parameter.
  defp holds(field, id, true) do
    expr(
      fragment(
        "((? -> 'custom_fields' -> ?) @> jsonb_build_array(jsonb_build_object('id', ?::text)))",
        working_fields,
        ^field,
        ^id
      )
    )
  end

  defp holds(field, id, _single) do
    expr(
      fragment(
        "((? -> 'custom_fields' -> ?) @> jsonb_build_object('id', ?::text))",
        working_fields,
        ^field,
        ^id
      )
    )
  end

  defp page([], _edges, _target, _reverse, _read_opts, _opts), do: %{rows: [], total: 0, ids: []}

  defp page(ids, edges, target, reverse, read_opts, opts) do
    filter = [id: [in: ids]]

    total = ContentTypes.count!(reverse.source_type, read_opts ++ [query: [filter: filter]])

    sources =
      ContentTypes.list!(
        reverse.source_type,
        read_opts ++
          [
            query: [
              filter: filter,
              sort: [title: :asc, id: :asc],
              offset: Keyword.get(opts, :offset, 0),
              limit: Keyword.get(opts, :limit, 10)
            ]
          ]
      )

    actor = Keyword.get(read_opts, :actor)

    rows =
      Enum.map(sources, fn source ->
        row(
          source,
          Map.get(edges, source.id),
          target,
          reverse,
          editable?(source, reverse, actor, read_opts)
        )
      end)

    %{rows: rows, total: total, ids: ids}
  end

  # The working copy is read only for a caller who may write the source; to
  # anyone else a row is what is live.
  defp row(source, edge, target, reverse, editable?) do
    live = edge && %{metadata: edge.metadata, position: edge.position}

    case editable? && held_items(source, reverse.field) do
      items when is_list(items) ->
        held = find_item(items, target.id)

        %{
          source: source,
          link: held_link(held) || live,
          pending: pending(live, held),
          editable?: true,
          count: length(items)
        }

      _live ->
        %{
          source: source,
          link: live,
          pending: nil,
          editable?: editable?,
          count:
            source.custom_fields
            |> Kernel.||(%{})
            |> Map.get(reverse.field)
            |> items()
            |> length()
        }
    end
  end

  defp pending(nil, nil), do: nil
  defp pending(nil, _held), do: :add
  defp pending(_live, nil), do: :remove
  defp pending(%{position: same}, %{position: same}), do: nil
  defp pending(_live, _held), do: :move

  defp held_link(nil), do: nil

  defp held_link(%{item: item, position: position}),
    do: %{metadata: item["link"] || %{}, position: position}

  # The field's items as the source's working copy holds them, or `:none`
  # when there is no copy, or it leaves custom fields as they are live.
  defp held_items(source, field) do
    with true <- WorkingCopy.pending?(source),
         %{"custom_fields" => %{} = custom} <- WorkingCopy.held_fields(source) do
      custom |> Map.get(field) |> items()
    else
      _live -> :none
    end
  end

  defp items(value), do: value |> List.wrap() |> Enum.filter(&match?(%{"id" => _}, &1))

  defp find_item(items, id) do
    items
    |> Enum.with_index()
    |> Enum.find_value(fn {item, index} ->
      if item["id"] == id, do: %{item: item, position: index}
    end)
  end

  # ── writes (R4b, D23) ─────────────────────────────────────────────────────

  @doc """
  Whether `actor` may change `source`'s connections from the other side: the
  write its own editor's Save would run (`ContentTypes.can_write?/4`).
  """
  @spec editable?(struct(), t(), term(), keyword()) :: boolean()
  def editable?(_source, _reverse, nil, _opts), do: false

  def editable?(source, reverse, actor, opts) do
    ContentTypes.can_write?(reverse.source_type, source, actor, Keyword.take(opts, [:tenant]))
  rescue
    _error -> false
  end

  @doc """
  Connect `target` to `source` through `reverse`'s field — appended to a
  list, or set on an empty single reference — as an edit of the **source**
  (D23): its update, or its working copy's save when it is published, as the
  caller (`:actor`, `:tenant`). Policies, the source's own validations
  (`max_items`, …), versioning and the optimistic lock all apply; `source` is
  the struct the caller last read, so a source changed since fails the lock.

  `{:error, :occupied}` when a single reference already connects another
  record: replacing it is the source's own decision, made in its editor.
  """
  @spec connect(struct(), t(), struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def connect(target, reverse, source, opts) do
    edit(source, reverse, opts, fn items ->
      cond do
        find_item(items, target.id) ->
          {:ok, items}

        reverse.definition.multiple ->
          {:ok, items ++ [%{"id" => target.id, "type" => ContentTypes.type_name_for(target)}]}

        items == [] ->
          {:ok, [%{"id" => target.id, "type" => ContentTypes.type_name_for(target)}]}

        true ->
          {:error, :occupied}
      end
    end)
  end

  @doc "Disconnect `target` from `source`: `connect/4`'s counterpart, the same write."
  @spec disconnect(struct(), t(), struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def disconnect(target, reverse, source, opts) do
    edit(source, reverse, opts, fn items ->
      {:ok, Enum.reject(items, &(&1["id"] == target.id))}
    end)
  end

  @doc """
  Move `target` one place `:up` or `:down` in `source`'s list — reordering
  from the target side, which can only mean the target's place among the
  source's own connections. The same write as `connect/4`.
  """
  @spec move(struct(), t(), struct(), :up | :down, keyword()) ::
          {:ok, struct()} | {:error, term()}
  def move(target, reverse, source, direction, opts) when direction in [:up, :down] do
    edit(source, reverse, opts, &{:ok, shift(&1, target.id, direction)})
  end

  defp shift(items, id, direction) do
    with %{position: index} <- find_item(items, id),
         other = if(direction == :up, do: index - 1, else: index + 1),
         true <- other >= 0 and other < length(items) do
      swap(items, index, other)
    else
      _nowhere_to_go -> items
    end
  end

  defp swap(items, a, b) do
    items
    |> List.replace_at(a, Enum.at(items, b))
    |> List.replace_at(b, Enum.at(items, a))
  end

  # The field's items as the source's editor shows them — the working copy
  # over the live row — edited by `fun`, and saved the way that editor's
  # Save would. Nothing is written when nothing moved.
  defp edit(source, reverse, opts, fun) do
    current = source |> WorkingCopy.view() |> Map.get(:custom_fields, %{}) |> Kernel.||(%{})
    items = current |> Map.get(reverse.field) |> items()

    case fun.(items) do
      {:ok, ^items} -> {:ok, source}
      {:ok, new_items} -> save(source, reverse, value(new_items, reverse.definition), opts)
      {:error, _reason} = error -> error
    end
  end

  defp value(items, %{multiple: true}), do: items
  defp value([], _single), do: nil
  defp value([item | _], _single), do: item

  defp save(source, reverse, value, opts) do
    opts = Keyword.take(opts, [:actor, :tenant]) |> Keyword.put_new(:tenant, source.org_id)
    custom_fields = %{reverse.field => value}

    if source.state == :published do
      ContentTypes.save_working_copy(
        reverse.source_type,
        source,
        %{fields: %{"custom_fields" => custom_fields}},
        opts
      )
    else
      ContentTypes.update(reverse.source_type, source, %{custom_fields: custom_fields}, opts)
    end
  end
end
