defmodule KilnCMS.CMS.ReferenceEdits do
  @moduledoc """
  Connect, disconnect and reorder the targets of a `:reference` custom field
  (relationships plan, R8) — the edits behind GraphQL's `add<Type>References`,
  `remove<Type>References` and `move<Type>Reference`.

  Each edit is the **source record's own `:update`** with one key of
  `custom_fields` rewritten (D23): never a bare edge insert. So everything an
  update does applies unchanged — the type's update policy and API-key scope,
  `expected_lock_version`, the optimistic lock, version history, the
  `<type>.updated` webhook and the re-fire on a published record, the field's
  own coercion and bounds (`Changes.ApplyCustomFields`), and the edge
  reconcile in the same transaction (`KilnCMS.CMS.ContentLinks`). A rule the
  update path gains later covers these edits too.

  The new value is built from the record as the caller read it, so a write
  that lands between that read and this update is caught by the update's
  optimistic lock (a stale-record error), never silently overwritten.

  ## Positions

  `position` follows Hygraph's `connect`: `:start`, `:end` (the default),
  `{:before, id}` or `{:after, id}`, where `id` is a target already in the
  field. Several targets added at once keep the order they were given in, as
  one block at that position.

  ## Idempotent by design

  Adding a target the field already holds moves it to `position` and merges
  any link values given, rather than refusing it as a duplicate, so a retried
  add converges on the same list. Removing a target the field does not hold is
  a no-op.

  ## A single-valued field

  A reference field without `multiple` holds one target. `add` sets it (one
  target, `position` is not consulted), `remove` clears it when it names the
  stored target, and `move` is refused — there is no order to change.
  """

  alias Ash.Error.Changes.InvalidArgument
  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.ContentTypes

  @typedoc "Where added or moved targets go."
  @type position :: :start | :end | {:before, Ash.UUID.t()} | {:after, Ash.UUID.t()}

  @typedoc """
  A target to connect: its `id`, its content type `type` (needed only when the
  field allows several), and the connection's `link` values (R3), if any.
  """
  @type target :: %{
          required(:id) => Ash.UUID.t(),
          optional(:type) => String.t() | nil,
          optional(:link) => map() | nil
        }

  @type edit ::
          {:add, [target()], position()}
          | {:remove, [Ash.UUID.t()]}
          | {:move, Ash.UUID.t(), position()}

  @doc """
  Apply `edit` to `field` of `record` through the record's `:update`.

  `opts` are the update's (`:actor`, `:tenant`, …) plus
  `:expected_lock_version`, passed to the action as its argument.
  """
  @spec run(Ash.Resource.Record.t(), String.t(), edit(), keyword()) ::
          {:ok, Ash.Resource.Record.t()} | {:error, term()}
  def run(%resource{} = record, field, edit, opts \\ []) do
    {expected, opts} = Keyword.pop(opts, :expected_lock_version)

    with {:ok, edit} <- cast_ids(edit),
         {:ok, definition} <- definition(resource, record, field, opts[:tenant]),
         {:ok, value} <- edit_value(definition, stored(record, field), edit) do
      params =
        %{custom_fields: %{field => value}}
        |> then(
          &if(is_nil(expected), do: &1, else: Map.put(&1, :expected_lock_version, expected))
        )

      update(resource, record, params, opts)
    end
  end

  @doc """
  The field's new value after `edit`, from the `stored` value and whether the
  field is `multiple`. Pure, with ids already cast; `run/4` runs it and
  writes the result.
  """
  @spec edit_value(%{multiple: boolean()} | map(), term(), edit()) ::
          {:ok, term()} | {:error, Exception.t()}
  def edit_value(%{multiple: true}, stored, edit), do: edit_list(items(stored), edit)
  def edit_value(_single, stored, edit), do: edit_single(stored, edit)

  # -- input ----------------------------------------------------------------

  # Every id in canonical form, so `ABC…` and `abc…` name the same target.
  defp cast_ids({:add, targets, position}) do
    with {:ok, targets} <- map_ok(targets, &cast_target/1),
         {:ok, position} <- cast_position(position),
         do: {:ok, {:add, targets, position}}
  end

  defp cast_ids({:remove, ids}) do
    with {:ok, ids} <- map_ok(ids, &cast_id(&1, :targets)), do: {:ok, {:remove, ids}}
  end

  defp cast_ids({:move, id, position}) do
    with {:ok, id} <- cast_id(id, :target),
         {:ok, position} <- cast_position(position),
         do: {:ok, {:move, id, position}}
  end

  defp cast_target(%{id: id} = target) do
    with {:ok, id} <- cast_id(id, :targets), do: {:ok, %{target | id: id}}
  end

  defp cast_position({side, id}) when side in [:before, :after] do
    with {:ok, id} <- cast_id(id, :position), do: {:ok, {side, id}}
  end

  defp cast_position(position) when position in [:start, :end], do: {:ok, position}

  defp cast_id(id, field) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> invalid(field, "#{inspect(id)} is not a record id")
    end
  end

  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, cast} -> {:cont, {:ok, [cast | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cast} -> {:ok, Enum.reverse(cast)}
      error -> error
    end
  end

  # -- the field --------------------------------------------------------------

  defp definition(resource, record, field, tenant) do
    resource
    |> ApplyCustomFields.definitions(Map.get(record, :type_definition_id), tenant)
    |> Enum.find(&(&1.name == field))
    |> case do
      %{field_type: :reference} = definition ->
        {:ok, definition}

      nil ->
        invalid(:field, "#{inspect(field)} is not a custom field of this content type")

      %{} ->
        invalid(:field, "#{inspect(field)} is not a reference field")
    end
  end

  defp stored(record, field), do: Map.get(record.custom_fields || %{}, field)

  # A stored list, a lone snapshot from before the field was `multiple`, or
  # nothing yet — always a list of snapshot maps here.
  defp items(nil), do: []
  defp items(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp items(%{} = item), do: [item]
  defp items(_other), do: []

  # -- many-valued ------------------------------------------------------------

  defp edit_list(current, {:add, targets, position}) do
    ids = Enum.map(targets, & &1.id)

    with :ok <- no_repeats(ids),
         {:ok, rest, insert_at} <- place(current, ids, position) do
      by_id = Map.new(current, &{&1["id"], &1})
      added = Enum.map(targets, &item(&1, by_id[&1.id]))
      {:ok, Enum.take(rest, insert_at) ++ added ++ Enum.drop(rest, insert_at)}
    end
  end

  defp edit_list(current, {:remove, ids}),
    do: {:ok, Enum.reject(current, &(&1["id"] in ids))}

  defp edit_list(current, {:move, id, position}) do
    case Enum.find(current, &(&1["id"] == id)) do
      nil -> invalid(:target, "#{id} is not connected through this field")
      item -> edit_list(current, {:add, [%{id: id, type: item["type"]}], position})
    end
  end

  defp no_repeats(ids) do
    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [id | _] -> invalid(:targets, "lists #{id} twice — each record can only be connected once")
    end
  end

  # The list without the targets being placed, and the index they go at.
  defp place(current, ids, position) do
    rest = Enum.reject(current, &(&1["id"] in ids))

    case position do
      :start ->
        {:ok, rest, 0}

      :end ->
        {:ok, rest, length(rest)}

      {side, anchor} when side in [:before, :after] ->
        anchor_index(rest, ids, side, anchor)
    end
  end

  defp anchor_index(rest, ids, side, anchor) do
    cond do
      anchor in ids ->
        invalid(
          :position,
          "can't place records #{side} #{anchor}, one of the records being placed"
        )

      index = Enum.find_index(rest, &(&1["id"] == anchor)) ->
        {:ok, rest, if(side == :before, do: index, else: index + 1)}

      true ->
        invalid(:position, "#{anchor} is not connected through this field")
    end
  end

  # The input item for one target. A target the field already holds keeps its
  # stored snapshot (type and link values), with any link values given merged
  # over it; `ApplyCustomFields` re-reads the record and merges link values
  # per connection in any case.
  defp item(target, nil) do
    %{"id" => target.id}
    |> put_present("type", target[:type])
    |> put_present("link", target[:link])
  end

  defp item(target, existing) do
    link =
      case {existing["link"], target[:link]} do
        {stored, nil} -> stored
        {nil, given} -> given
        {stored, given} -> Map.merge(stored, given)
      end

    existing
    |> Map.take(["id", "type"])
    |> put_present("type", target[:type])
    |> put_present("link", link)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # -- single-valued ----------------------------------------------------------

  defp edit_single(stored, {:add, [target], _position}) do
    existing = if is_map(stored) and stored["id"] == target.id, do: stored
    {:ok, item(target, existing)}
  end

  defp edit_single(_stored, {:add, _targets, _position}),
    do: invalid(:targets, "this field connects one record — give exactly one target")

  defp edit_single(stored, {:remove, ids}) do
    if is_map(stored) and stored["id"] in ids, do: {:ok, nil}, else: {:ok, stored}
  end

  defp edit_single(_stored, {:move, _id, _position}),
    do: invalid(:field, "this field connects one record, so it has no order to change")

  # -- the write --------------------------------------------------------------

  # The type's own `update_<type>` code interface (`update_entry` for every
  # dynamic type), the one `updatePage` / `PATCH /api/json/pages/:id` reach.
  defp update(resource, record, params, opts) do
    domain = Ash.Resource.Info.domain(resource)
    fun = String.to_existing_atom("update_#{ContentTypes.type_atom(resource)}")
    Kernel.apply(domain, fun, [record, params, opts])
  end

  defp invalid(field, message),
    do: {:error, InvalidArgument.exception(field: field, message: message)}
end
