defmodule KilnCMS.CMS.Validations.FlexibleField do
  @moduledoc """
  The rules for the flexible-content model (#2282,
  `docs/flexible-content-plan.md`), the twin of
  `KilnCMS.CMS.Validations.GroupField` for the other end of a `flex_of_id`:

  An **item type** (`flex_of_id` set):

    * its parent is a `:flexible` field of the same site — read under the
      changeset's tenant, so an id from another site does not resolve;
    * it is itself a `:group`: its sub-fields are the keys of one item;
    * the flexible field it hangs off is no deeper than
      `FieldDefinition.max_flexible_depth/0`;
    * it stays with the flexible field it was added to — moving it would
      strand its items under the old one;
    * its `min_items` / `max_items` are the per-type bounds on how many items
      of that type one value holds (`Changes.ClearMultiple` keeps them).

  A **flexible field** (`field_type: :flexible`) takes none of the options that
  only fit a plain value, so each is refused rather than silently ignored:
  `names_record`, `private`, a `default`, and being a setting. `searchable` is
  allowed: `KilnCMS.CMS.SearchableFields` reads an item's sub-fields by their
  definitions and never its `_id`, `_type` or `_settings`.
  `unique` is refused by `Validations.FieldConstraints` (no constraint applies
  to a flexible field); the other exclusions — no list column, no
  index or `custom_filter` leaf — are the readers' (`ListFields`,
  `IndexedCustomFields`, `Preparations.CustomFieldQuery`). Its own
  `visible_when` / `required_when` are refused by `Validations.FieldCondition`,
  as for a group.

  Every other definition passes untouched.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- unmoved(changeset),
         :ok <- item_type(changeset) do
      flexible(changeset)
    end
  end

  @doc """
  How deep a `:flexible` field sits: 1 for a top-level one, plus one for each
  flexible field above it (an item type's owner, found through the sub-field's
  group). Stops counting past the cap, so a malformed chain cannot loop.
  """
  @spec depth(map(), term()) :: pos_integer()
  def depth(flexible, tenant), do: depth(flexible, tenant, 1)

  # Read at run time, not baked in: `FieldDefinition` names this module in its
  # DSL, so a compile-time call back would deadlock the compiler.
  defp depth(%{group_of_id: nil}, _tenant, depth), do: depth

  defp depth(%{group_of_id: item_type_id}, tenant, depth) do
    with true <- depth <= FieldDefinition.max_flexible_depth(),
         %{flex_of_id: owner_id} when not is_nil(owner_id) <- parent(item_type_id, tenant),
         %{} = owner <- parent(owner_id, tenant) do
      depth(owner, tenant, depth + 1)
    else
      _broken_or_past_the_cap -> depth + 1
    end
  end

  @doc """
  The definition `id` names on the site `tenant`, or nil: read as the cms
  registry, under the write's tenant — this is the schema, not content, and
  the writer is already an admin by the time a validation runs.
  """
  @spec parent(Ash.UUID.t() | nil, term()) :: struct() | nil
  def parent(nil, _tenant), do: nil

  def parent(id, tenant) do
    case KilnCMS.CMS.get_field_definition(id,
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           tenant: tenant
         ) do
      {:ok, definition} -> definition
      _error -> nil
    end
  end

  defp unmoved(%{action_type: :update} = changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :flex_of_id),
      do: error(:flex_of_id, "an item type stays in the flexible field it was added to"),
      else: :ok
  end

  defp unmoved(_changeset), do: :ok

  defp item_type(changeset) do
    case Ash.Changeset.get_attribute(changeset, :flex_of_id) do
      nil -> :ok
      parent_id -> check_item_type(changeset, parent_id)
    end
  end

  defp check_item_type(changeset, parent_id) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    case parent(parent_id, changeset.to_tenant) do
      nil ->
        error(:flex_of_id, "is not a field of this site")

      %{field_type: parent_type} when parent_type != :flexible ->
        error(:flex_of_id, "item types can only be added to a flexible field")

      _flexible when type != :group ->
        error(:field_type, "an item type must be a group", type)

      flexible ->
        if depth(flexible, changeset.to_tenant) <= FieldDefinition.max_flexible_depth(),
          do: :ok,
          else:
            error(
              :flex_of_id,
              "flexible fields nest at most #{FieldDefinition.max_flexible_depth()} levels deep"
            )
    end
  end

  defp flexible(changeset) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :flexible,
      do: first_refusal(changeset),
      else: :ok
  end

  defp first_refusal(changeset) do
    Enum.find_value(refused(), :ok, fn {attribute, check, message} ->
      if check.(Ash.Changeset.get_attribute(changeset, attribute)),
        do: error(attribute, message)
    end)
  end

  defp refused do
    [
      {:names_record, &(&1 == true), "a flexible field can't be a name of the record"},
      {:private, &(&1 == true), "a flexible field can't be private"},
      {:default, &(&1 not in [nil, ""]), "a flexible field takes no default value"},
      {:item_setting, &(&1 == true), "a flexible field can't be a setting"}
    ]
  end

  defp error(field, message, value \\ nil),
    do: {:error, InvalidAttribute.exception(field: field, message: message, value: value)}
end
