defmodule KilnCMS.CMS.Validations.FieldCondition do
  @moduledoc """
  Keeps a `FieldDefinition`'s conditional rules (`visible_when`,
  `required_when`; `KilnCMS.CMS.Conditions`, #2277) writable and readable:

    * each rule has a valid shape;
    * a link field, a `:computed` field and a `:group` as a whole carry none;
    * every field a rule names is a sibling in the same scope (the same
      content type or dynamic type, or the same group), not the field itself,
      not private (a private value must not steer what a viewer sees), and a
      scalar type (`FieldDefinition.link_field_types/0`);
    * `gt` / `lt` only test a number or a date, and never a list of them
      (`multiple`) — a list has no single value to order;
    * the rules form no cycle through this field.

  The other direction is guarded too. **Destroying** a field other rules read
  is refused, naming them. **Retyping**, making **private** or making
  **multiple** a field other rules read is refused when a rule would no
  longer be valid. A **rename**
  needs no guard: `Changes.SyncFieldValues` rewrites the rules that read it.

  A sibling whose field type this release does not know (#2605,
  `FieldDefinition.unknown_type?/1`) is still a sibling: a rule naming it
  stays valid, and so does its own rule, so neither field turns unwritable
  after a rollback. Such a target's type and operators are not checked —
  this release cannot say what its value holds.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Conditions
  alias KilnCMS.CMS.FieldDefinition

  @rules [:visible_when, :required_when]
  @ordered_types [:integer, :float, :date, :datetime]

  @impl true
  def validate(%{action_type: :destroy} = changeset, _opts, _context) do
    dependents = dependents(changeset.data, changeset.to_tenant)

    if dependents == [] do
      :ok
    else
      error(
        :name,
        gettext("is used in the conditions of %{fields}; remove those conditions first",
          fields: labels(dependents)
        )
      )
    end
  end

  def validate(changeset, _opts, _context) do
    rules =
      for attr <- @rules,
          rule = Conditions.normalize(Ash.Changeset.get_attribute(changeset, attr)),
          do: {attr, rule}

    with :ok <- check_own(changeset, rules) do
      check_dependents(changeset)
    end
  end

  # --- this field's rules ----------------------------------------------------

  defp check_own(_changeset, []), do: :ok

  defp check_own(changeset, rules) do
    with :ok <- check_owner(changeset),
         :ok <- check_shapes(rules) do
      siblings = siblings(changeset, changeset.to_tenant)
      self = Ash.Changeset.get_attribute(changeset, :name)

      with :ok <- check_references(rules, siblings, self) do
        check_cycle(rules, siblings, self)
      end
    end
  end

  defp check_owner(changeset) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    cond do
      not is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) ->
        error(:visible_when, gettext("is not available for a link field"))

      type in [:computed, :group] ->
        error(:visible_when, gettext("is not available for a %{type} field", type: type))

      true ->
        :ok
    end
  end

  defp check_shapes(rules) do
    Enum.find_value(rules, :ok, fn {attr, rule} ->
      case Conditions.check_shape(rule) do
        :ok ->
          nil

        {:error, reason} ->
          error(attr, gettext("is not a valid condition: it %{reason}", reason: reason))
      end
    end)
  end

  defp check_references(rules, siblings, self) do
    by_name = Map.new(siblings, &{&1.name, &1})

    Enum.find_value(rules, :ok, fn {attr, rule} ->
      Enum.find_value(Conditions.references(rule), &ref_problem(&1, attr, rule, by_name, self))
    end)
  end

  defp ref_problem(ref, attr, _rule, _by_name, self) when ref == self,
    do: error(attr, gettext("can't depend on the field itself"))

  defp ref_problem(ref, attr, rule, by_name, _self) do
    case Map.fetch(by_name, ref) do
      {:ok, target} ->
        reference_problem(attr, rule, ref, target)

      :error ->
        error(attr, gettext("names %{field}, which is not a field beside this one", field: ref))
    end
  end

  defp reference_problem(attr, rule, ref, target) do
    case problem(target, ops_on(rule, ref)) do
      nil -> nil
      message -> error(attr, message)
    end
  end

  defp ops_on(rule, ref), do: for({^ref, op} <- Conditions.leaves(rule), do: op)

  # What is wrong with testing `ops` against `target`, if anything.
  defp problem(target, ops) do
    cond do
      FieldDefinition.unknown_type?(target) ->
        nil

      target.private ->
        gettext("can't depend on %{field}, a private field", field: target.name)

      target.field_type not in FieldDefinition.link_field_types() ->
        gettext("can't depend on %{field}: a %{type} field has no simple value to test",
          field: target.name,
          type: target.field_type
        )

      Enum.any?(ops, &(&1 in Conditions.ordering_ops())) and
          target.field_type not in @ordered_types ->
        gettext("can't compare %{field} with greater/less than: it is not a number or a date",
          field: target.name
        )

      Enum.any?(ops, &(&1 in Conditions.ordering_ops())) and Map.get(target, :multiple) == true ->
        gettext("can't compare %{field} with greater/less than: it holds a list",
          field: target.name
        )

      true ->
        nil
    end
  end

  # The graph is acyclic without this field (every write is checked), so a
  # cycle must run through it: walk from what it reads and look for it.
  defp check_cycle(rules, siblings, self) do
    graph = Map.new(siblings, &{&1.name, edges(&1)})

    start =
      rules |> Enum.flat_map(fn {_attr, rule} -> Conditions.references(rule) end) |> Enum.uniq()

    if reaches?(start, self, graph, %{}) do
      error(elem(hd(rules), 0), gettext("would depend on itself through other conditions"))
    else
      :ok
    end
  end

  defp reaches?([], _self, _graph, _seen), do: false

  defp reaches?([name | rest], self, graph, seen) do
    cond do
      name == self -> true
      Map.has_key?(seen, name) -> reaches?(rest, self, graph, seen)
      true -> reaches?(Map.get(graph, name, []) ++ rest, self, graph, Map.put(seen, name, true))
    end
  end

  defp edges(definition) do
    @rules
    |> Enum.flat_map(&Conditions.references(Map.get(definition, &1)))
    |> Enum.uniq()
  end

  # --- rules that read this field --------------------------------------------

  # Retyping, privatising or making a list of a field must not leave a rule
  # that reads it invalid. (A rename is rewritten by
  # `Changes.SyncFieldValues`.)
  defp check_dependents(%{action_type: :update} = changeset) do
    changing = Enum.filter([:field_type, :private, :multiple], &changing?(changeset, &1))

    if changing != [] do
      target = %{
        name: changeset.data.name,
        field_type: Ash.Changeset.get_attribute(changeset, :field_type),
        private: Ash.Changeset.get_attribute(changeset, :private),
        multiple: Ash.Changeset.get_attribute(changeset, :multiple)
      }

      # The error sits under the control that caused it: the list toggle when
      # only `multiple` moved.
      field = if changing == [:multiple], do: :multiple, else: :field_type

      changeset.data
      |> dependents(changeset.to_tenant)
      |> Enum.find_value(:ok, &dependent_problem(&1, target, field))
    else
      :ok
    end
  end

  defp check_dependents(_changeset), do: :ok

  # `ClearMultiple` may force `multiple` back to what it was, which
  # `changing_attribute?/2` still reports as a change.
  defp changing?(changeset, :multiple),
    do: Ash.Changeset.get_attribute(changeset, :multiple) != changeset.data.multiple

  defp changing?(changeset, attr), do: Ash.Changeset.changing_attribute?(changeset, attr)

  defp dependent_problem(dependent, target, field) do
    Enum.find_value(@rules, fn attr ->
      rule = Map.get(dependent, attr)

      if target.name in Conditions.references(rule) do
        dependent_message(dependent, problem(target, ops_on(rule, target.name)), field)
      end
    end)
  end

  defp dependent_message(_dependent, nil, _field), do: nil

  defp dependent_message(dependent, message, field) do
    error(
      field,
      gettext("%{field} reads this field in its condition: %{message}",
        field: dependent.label,
        message: message
      )
    )
  end

  @doc """
  The sibling definitions of `definition` (a record, or a changeset's
  attributes as a map with `content_type`, `type_definition_id`,
  `group_of_id`): the other fields in its scope, sub-fields loaded for a
  group's members. `[]` for a link field, which has none. Read as the cms
  registry, under `tenant`, with fields of a type this release does not know
  included (#2605): a caller that offers siblings as choices filters them.
  """
  @spec siblings(Ash.Changeset.t() | map(), term()) :: [FieldDefinition.t()]
  def siblings(%Ash.Changeset{} = changeset, tenant) do
    attrs =
      Map.new([:content_type, :type_definition_id, :group_of_id, :link_of_id], fn attr ->
        {attr, Ash.Changeset.get_attribute(changeset, attr)}
      end)

    attrs |> Map.put(:id, changeset.data.id) |> siblings(tenant)
  end

  def siblings(scope, tenant) do
    opts = [
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: tenant,
      context: FieldDefinition.all_types_context()
    ]

    all =
      cond do
        scope.link_of_id ->
          []

        scope.group_of_id ->
          group_members(scope.group_of_id, opts)

        scope.type_definition_id ->
          ok_list(CMS.field_definitions_for_definition(scope.type_definition_id, opts))

        scope.content_type ->
          ok_list(CMS.field_definitions_for(scope.content_type, opts))

        true ->
          []
      end

    Enum.reject(all, &(not is_nil(scope.id) and &1.id == scope.id))
  end

  # Read directly rather than as the group's loaded `group_fields`: a
  # relationship load leaves out a sub-field of an unknown type (#2605).
  defp group_members(group_id, opts) do
    ok_list(
      CMS.list_field_definitions(
        Keyword.put(opts, :query, filter: [group_of_id: group_id], sort: [position: :asc])
      )
    )
  end

  defp ok_list({:ok, list}), do: list
  defp ok_list(_error), do: []

  @doc "The siblings of `definition` whose rules read it."
  @spec dependents(FieldDefinition.t(), term()) :: [FieldDefinition.t()]
  def dependents(definition, tenant) do
    definition
    |> Map.take([:id, :content_type, :type_definition_id, :group_of_id, :link_of_id])
    |> siblings(tenant)
    |> Enum.filter(fn sibling -> definition.name in edges(sibling) end)
  end

  defp labels(definitions), do: Enum.map_join(definitions, ", ", & &1.label)

  defp error(field, message, value \\ nil),
    do: {:error, InvalidAttribute.exception(field: field, message: message, value: value)}
end
