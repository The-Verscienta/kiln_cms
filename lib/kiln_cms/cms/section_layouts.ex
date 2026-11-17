defmodule KilnCMS.CMS.SectionLayouts do
  @moduledoc """
  Keeps a type's section layouts (`KilnCMS.CMS.FieldSection`, #2280) in step
  with the fields that name them.

  A layout is keyed by a section *name*, and a section exists only while some
  top-level field of the type carries that name. `prune/2` drops the layouts
  left with nothing to lay out; `carry/4` moves a layout to the new name when
  a section's last field is renamed out of it.

  Their callers:

    * every `KilnCMS.CMS.FieldDefinition` update and destroy that takes a
      field out of a section (a rename, a clear, an owner move, a delete),
      through `KilnCMS.CMS.Changes.KeepSectionLayouts`, in the field write's
      own transaction and as its actor. A carry runs only when the write asks
      for it (the fields admin's rename);
    * the fields admin, when it saves a type's sections;
    * a field sync import, once at the end of its transaction
      (`prune_names/2`), since it defers the per-write prune.

  Every read here is fresh, never a caller's copy: two admins on the same
  type each see the other's new sections, so a prune decided from a page
  loaded earlier would destroy a layout the other admin just set. A field of
  a type this release does not register (#2605) still carries its section.

  The reads fail closed (`authorize_with: :error`): a read the actor may not
  make is an error, not an empty list, so a refused read never makes every
  layout look uncarried and prunes them all.

  A field created in a section concurrently with the prune that saw it empty
  renders that section with the default layout: a layout can be lost to that
  race, but no row is left without a field.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldSection

  @typedoc "A layout's owner: a compiled content type or a dynamic type's id."
  @type owner :: {:compiled, atom()} | {:dynamic, Ecto.UUID.t()}

  @doc "The owner's stored layouts, read now."
  @spec layouts(owner(), keyword()) :: {:ok, [struct()]} | {:error, term()}
  def layouts({:compiled, type}, opts), do: CMS.field_sections_for(type, read_opts(opts))
  def layouts({:dynamic, id}, opts), do: CMS.field_sections_for_definition(id, read_opts(opts))

  @doc "The section names the owner's top-level fields carry, read now."
  @spec carried(owner(), keyword()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def carried(owner, opts) do
    with {:ok, fields} <- fields(owner, read_opts(opts)) do
      {:ok,
       for(
         field <- fields,
         is_nil(FieldDefinition.parent_id(field)),
         is_binary(field.section),
         into: MapSet.new(),
         do: field.section
       )}
    end
  end

  @doc """
  Destroys the owner's layouts whose name no top-level field carries any
  more. With `only:` a list of names, only those are candidates.
  """
  @spec prune(owner(), keyword()) :: :ok | {:error, term()}
  def prune(owner, opts) do
    {only, opts} = Keyword.pop(opts, :only)

    with {:ok, carried} <- carried(owner, opts),
         {:ok, rows} <- layouts(owner, opts) do
      rows
      |> Enum.reject(&MapSet.member?(carried, &1.name))
      |> Enum.filter(&(is_nil(only) or &1.name in only))
      |> Enum.reduce_while(:ok, &destroy(&1, &2, opts))
    end
  end

  @doc """
  `prune/2` for each owner of `[{owner, [name]}]`, with only those names as
  candidates. An owner listed twice is pruned once, over all its names.
  """
  @spec prune_names([{owner(), [String.t()]}], keyword()) :: :ok | {:error, term()}
  def prune_names(candidates, opts) do
    candidates
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce_while(:ok, fn {owner, names}, :ok ->
      case prune(owner, [only: names |> List.flatten() |> Enum.uniq()] ++ opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Moves the layout of section `from` to `to` when a field was renamed out of
  `from`, decided from a fresh read made after the rename:

    * a top-level field still carries `from`: nothing moves, the layout
      stays with them;
    * `from` has no row, or only a row at the defaults: nothing to carry;
    * `to` has no row: it gets `from`'s layout, even when other fields
      already carry `to` (the admin renamed the section one field at a
      time);
    * `to` has a row at the defaults (stored by an older release): it is
      replaced by `from`'s layout;
    * `to` has a layout of its own: it is kept.

  `from`'s row is left for the `prune/2` that follows the rename to drop.
  Returns `:ok` or the first refused read or write.
  """
  @spec carry(owner(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def carry(_owner, same, same, _opts), do: :ok

  def carry(owner, from, to, opts) do
    with {:ok, carried} <- carried(owner, opts),
         {:ok, rows} <- layouts(owner, opts) do
      source = Enum.find(rows, &(&1.name == from))
      target = Enum.find(rows, &(&1.name == to))

      cond do
        MapSet.member?(carried, from) -> :ok
        is_nil(source) or FieldSection.default?(source) -> :ok
        is_nil(target) -> create_carried(owner, source, to, opts)
        FieldSection.default?(target) -> update_carried(target, source, opts)
        true -> :ok
      end
    end
  end

  # Another admin may have given `to` a row between the read above and this
  # create: that row is `to`'s own layout, and it stands. A refused insert
  # would abort the field write's whole transaction, so the create is an
  # upsert that changes nothing on conflict (`upsert_fields: []`, as
  # `KilnCMS.Accounts.LegacyAffiliation` does): it returns the row that won.
  defp create_carried(owner, source, to, opts) do
    attrs =
      owner
      |> owner_attrs()
      |> Map.merge(%{name: to, display: source.display, initially: source.initially})

    upsert = [upsert?: true, upsert_identity: identity(owner), upsert_fields: []]

    case CMS.create_field_section(attrs, opts ++ upsert) do
      {:ok, _row} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp update_carried(target, source, opts) do
    case CMS.update_field_section(
           target,
           %{display: source.display, initially: source.initially},
           opts
         ) do
      {:ok, _row} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp identity({:compiled, _type}), do: :unique_section
  defp identity({:dynamic, _id}), do: :unique_definition_section

  defp destroy(row, :ok, opts) do
    case CMS.destroy_field_section(row, opts) do
      :ok -> {:cont, :ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  @doc """
  The owner of a top-level field definition, or `nil` for one that has no
  layouts (a link or group sub-field, or a field of a vanished type).
  """
  @spec owner_of(struct()) :: owner() | nil
  def owner_of(definition) do
    cond do
      not is_nil(FieldDefinition.parent_id(definition)) ->
        nil

      not is_nil(definition.type_definition_id) ->
        {:dynamic, definition.type_definition_id}

      FieldDefinition.orphaned?(definition) ->
        nil

      is_atom(definition.content_type) and not is_nil(definition.content_type) ->
        {:compiled, definition.content_type}

      true ->
        nil
    end
  end

  defp fields(owner, opts) do
    opts = Keyword.put(opts, :context, FieldDefinition.all_types_context())

    case owner do
      {:compiled, type} -> CMS.field_definitions_for(type, opts)
      {:dynamic, id} -> CMS.field_definitions_for_definition(id, opts)
    end
  end

  defp owner_attrs({:compiled, type}), do: %{content_type: type}
  defp owner_attrs({:dynamic, id}), do: %{type_definition_id: id}

  # The reads take only who, where and whether to authorize, and fail
  # closed: a refused read must not look like "no rows" or "no fields". The
  # writes keep the caller's options, its context included.
  defp read_opts(opts),
    do:
      opts |> Keyword.take([:actor, :tenant, :authorize?]) |> Keyword.put(:authorize_with, :error)
end
