defmodule KilnCMS.CMS.SectionLayouts do
  @moduledoc """
  Keeps a type's section layouts (`KilnCMS.CMS.FieldSection`, #2280) in step
  with the fields that name them.

  A layout is keyed by a section *name*, and a section exists only while some
  top-level field of the type carries that name. Whoever removes the last such
  field (the fields admin, a pruning field sync import) or saves the type's
  sections calls `prune/3` to drop the layouts left with nothing to lay out.

  Every read here is fresh, never a caller's copy: two admins on the same
  type each see the other's new sections, so a prune decided from a page
  loaded earlier would destroy a layout the other admin just set.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition

  @typedoc "A layout's owner: a compiled content type or a dynamic type's id."
  @type owner :: {:compiled, atom()} | {:dynamic, Ecto.UUID.t()}

  @doc "The owner's stored layouts, read now."
  @spec layouts(owner(), keyword()) :: {:ok, [struct()]} | {:error, term()}
  def layouts({:compiled, type}, opts), do: CMS.field_sections_for(type, scope(opts))
  def layouts({:dynamic, id}, opts), do: CMS.field_sections_for_definition(id, scope(opts))

  @doc "The section names the owner's top-level fields carry, read now."
  @spec carried(owner(), keyword()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def carried(owner, opts) do
    with {:ok, fields} <- fields(owner, scope(opts)) do
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

  defp fields({:compiled, type}, opts), do: CMS.field_definitions_for(type, opts)
  defp fields({:dynamic, id}, opts), do: CMS.field_definitions_for_definition(id, opts)

  # The reads take only who and where; the writes keep the caller's context.
  defp scope(opts), do: Keyword.take(opts, [:actor, :tenant])
end
