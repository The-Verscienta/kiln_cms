defmodule KilnCMS.CMS.Validations.FormFieldCondition do
  @moduledoc """
  The write-side rules of a `KilnCMS.CMS.FormField`'s `condition` (#2262),
  on the resource so every writer gets them, the builder and the API alike.

  **The field's own condition**, when it is written (create, or an update
  that changes it):

    * the rule has a valid `KilnCMS.CMS.Conditions` shape, and no value in it
      is longer than `KilnCMS.Limits.line/0`;
    * the field's type takes a condition (`:hidden` does not);
    * every field the rule names is a field of the same form, not the field
      itself, and comes strictly **before** it (`position`, then `name`), so
      no chain of conditions can loop;
    * each operator fits the type of the field it tests
      (`KilnCMS.Forms.Logic.op_allowed?/2`);
    * as a second line of defence, no cycle through the other fields'
      conditions.

  A retype checks only that the new type takes a condition, and a rename only
  that the rule doesn't name the field's new name. Neither re-checks the rest,
  so a rule an older release let dangle (it names a field since removed) never
  blocks them; at run time it leaves the field shown.

  **The fields whose conditions name this one** ("dependents"):

    * a delete, or a move to another form (`form_id`), is refused while there
      are any. A move is also refused while the field has a condition, or
      when the same write gives it one;
    * a retype is refused when a dependent tests it with an operator the new
      type can't answer;
    * a `position` change, or a rename (it can reorder fields at the same
      position), is refused when it would put a field after one its condition
      names, unless the arrangement already did. Saving a whole new order is
      `KilnCMS.Forms.FieldOrder`'s: it checks the final order once and sets
      `form_field_reorder: true` in the context, so its in-between moves skip
      this.

  A rename is not refused for having dependents:
  `KilnCMS.CMS.Changes.RewriteConditionReferences` carries their rules along.

  The form's other fields are read with the caller's actor, tenant and
  authorization, and `authorize_with: :error`: a refused read refuses the
  write instead of reading as "no other fields" (#1659).
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Conditions
  alias KilnCMS.Forms.Logic

  @impl true
  def validate(changeset, _opts, context) do
    case checks(changeset) do
      [] ->
        :ok

      checks ->
        with {:ok, siblings} <- siblings(changeset, context),
             do: run_all(checks, changeset, siblings)
    end
  end

  defp run_all(checks, changeset, siblings) do
    Enum.find_value(checks, :ok, fn check ->
      case run(check, changeset, siblings) do
        :ok -> nil
        error -> error
      end
    end)
  end

  # --- which checks a write needs ---------------------------------------------

  defp checks(%{action_type: :destroy}), do: [:not_used]

  defp checks(%{action_type: :create} = changeset) do
    if Ash.Changeset.get_attribute(changeset, :condition), do: [:own], else: []
  end

  defp checks(%{action_type: :update} = changeset) do
    changing = &Ash.Changeset.changing_attribute?(changeset, &1)
    reorder? = changeset.context[:form_field_reorder] == true

    [
      {changing.(:form_id), [:not_used, :no_condition]},
      {condition_changed?(changeset), [:own]},
      {changing.(:field_type), [:own_type, :dependents_type]},
      {changing.(:name), [:own_name]},
      {(changing.(:position) or changing.(:name)) and not reorder?, [:order]}
    ]
    |> Enum.flat_map(fn {needed?, checks} -> if needed?, do: checks, else: [] end)
  end

  # Ash keeps an embedded value as changing even when it equals the stored
  # one, so compare what each would apply.
  defp condition_changed?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :condition) and
      Logic.stored(%{condition: Ash.Changeset.get_attribute(changeset, :condition)}) !=
        Logic.stored(changeset.data)
  end

  # --- the checks ---------------------------------------------------------------

  defp run(:own, changeset, siblings) do
    self = resulting(changeset)

    case Logic.stored(self) do
      nil -> :ok
      %{action: :unknown} -> :ok
      %{rule: rule} -> own(self, rule, siblings)
    end
  end

  defp run(:own_type, changeset, _siblings) do
    self = resulting(changeset)

    if Logic.stored(self) != nil and not Logic.conditionable?(self.field_type),
      do: error(:condition, gettext("a hidden field can't have a condition")),
      else: :ok
  end

  defp run(:own_name, changeset, _siblings) do
    self = resulting(changeset)

    case Logic.stored(self) do
      %{rule: rule} ->
        if self.name in Conditions.references(rule),
          do: error(:name, gettext("its condition already names this field")),
          else: :ok

      nil ->
        :ok
    end
  end

  defp run(:not_used, changeset, siblings) do
    case dependents(changeset.data.name, siblings) do
      [] ->
        :ok

      dependents when changeset.action_type == :destroy ->
        {:error, message: in_use_message(dependents)}

      dependents ->
        error(:form_id, in_use_message(dependents))
    end
  end

  # The stored condition or the one this write sets: either names fields of
  # the form the field is leaving, and the siblings read here are that form's.
  defp run(:no_condition, changeset, _siblings) do
    if Logic.stored(changeset.data) || Logic.stored(resulting(changeset)),
      do:
        error(
          :form_id,
          gettext("has a condition: remove it before moving the field to another form")
        ),
      else: :ok
  end

  defp run(:dependents_type, changeset, siblings) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)
    name = changeset.data.name

    unfit =
      Enum.filter(dependents(name, siblings), fn dependent ->
        dependent
        |> Logic.stored()
        |> Map.fetch!(:rule)
        |> Conditions.leaves()
        |> Enum.any?(fn {field, op} -> field == name and not Logic.op_allowed?(op, type) end)
      end)

    case unfit do
      [] ->
        :ok

      unfit ->
        error(
          :field_type,
          gettext(
            "the conditions of %{fields} test this field in a way this type can't answer: change those conditions first",
            fields: labels(unfit)
          )
        )
    end
  end

  defp run(:order, changeset, siblings) do
    before = Logic.sort([changeset.data | siblings])
    self = resulting(changeset)
    renamed = Enum.map(siblings, &rename_references(&1, changeset.data.name, self.name))
    after_write = Logic.sort([self | renamed])

    case new_violations(after_write, before) do
      [] ->
        :ok

      [{dependent, target} | _rest] ->
        key =
          if Ash.Changeset.changing_attribute?(changeset, :position), do: :position, else: :name

        error(key, order_message(dependent, target))
    end
  end

  # --- own condition --------------------------------------------------------------

  defp own(self, rule, siblings) do
    with :ok <- own_shape(rule),
         :ok <- own_type(self),
         :ok <- own_references(self, rule, siblings) do
      no_cycle(self, siblings)
    end
  end

  defp own_shape(rule) do
    case Conditions.check_shape(rule) do
      :ok ->
        if Enum.all?(values(rule), &within_line?/1),
          do: :ok,
          else:
            error(
              :condition,
              gettext("each value must be at most %{max} characters", max: KilnCMS.Limits.line())
            )

      {:error, reason} ->
        error(:condition, gettext("is not a valid condition: %{reason}", reason: reason))
    end
  end

  defp own_type(self) do
    if Logic.conditionable?(self.field_type),
      do: :ok,
      else: error(:condition, gettext("a hidden field can't have a condition"))
  end

  defp own_references(self, rule, siblings) do
    known = siblings |> Logic.known_fields() |> Map.new(&{&1.name, &1})
    order = &{&1.position, &1.name}

    Enum.find_value(Conditions.leaves(rule), :ok, fn {name, op} ->
      target = known[name]

      cond do
        name == self.name ->
          error(:condition, gettext("can't depend on the field itself"))

        target == nil ->
          error(
            :condition,
            gettext("names %{field}, which is not a field on this form", field: inspect(name))
          )

        order.(target) >= order.(self) ->
          error(
            :condition,
            gettext(
              "names %{field}, which comes after this field: conditions can only use earlier answers",
              field: label(target)
            )
          )

        not Logic.op_allowed?(op, target.field_type) ->
          error(
            :condition,
            gettext("can't test %{field} with %{op}", field: label(target), op: op)
          )

        true ->
          nil
      end
    end)
  end

  # Defence in depth: the earlier-only rule above already makes a loop
  # impossible. Follows every rule from this field through the others'.
  defp no_cycle(self, siblings) do
    graph =
      Map.new([self | siblings], fn field ->
        refs =
          case Logic.stored(field) do
            %{rule: rule} -> Conditions.references(rule)
            nil -> []
          end

        {field.name, refs}
      end)

    if reaches?(graph, graph[self.name] || [], self.name, %{}),
      do: error(:condition, gettext("would depend on itself through other conditions")),
      else: :ok
  end

  defp reaches?(_graph, [], _target, _seen), do: false

  defp reaches?(graph, [name | rest], target, seen) do
    cond do
      name == target ->
        true

      Map.has_key?(seen, name) ->
        reaches?(graph, rest, target, seen)

      true ->
        seen = Map.put(seen, name, true)
        reaches?(graph, Map.get(graph, name, []) ++ rest, target, seen)
    end
  end

  # Every scalar a rule compares with, `in` lists included.
  defp values(%{"all" => children}) when is_list(children), do: Enum.flat_map(children, &values/1)
  defp values(%{"any" => children}) when is_list(children), do: Enum.flat_map(children, &values/1)
  defp values(%{"value" => value}) when is_list(value), do: value
  defp values(%{"value" => value}), do: [value]
  defp values(_leaf), do: []

  defp within_line?(value) when is_binary(value),
    do: String.length(value) <= KilnCMS.Limits.line()

  defp within_line?(_value), do: true

  # --- helpers ------------------------------------------------------------------

  # The field as the write would leave it.
  defp resulting(changeset) do
    Enum.reduce([:name, :field_type, :position, :condition], changeset.data, fn key, field ->
      Map.put(field, key, Ash.Changeset.get_attribute(changeset, key))
    end)
  end

  # The form's other fields, all types included: a field this release doesn't
  # know still holds its place in the order.
  defp siblings(changeset, context) do
    form_id =
      if changeset.action_type == :create,
        do: Ash.Changeset.get_attribute(changeset, :form_id),
        else: changeset.data.form_id

    if is_nil(form_id) do
      {:ok, []}
    else
      opts =
        context
        |> Ash.Context.to_opts()
        |> Keyword.put(:tenant, changeset.to_tenant)
        |> Keyword.put(:authorize_with, :error)

      with {:ok, fields} <- CMS.form_fields_for(form_id, opts) do
        own_id = changeset.data && Map.get(changeset.data, :id)
        {:ok, Enum.reject(fields, &(&1.id == own_id and not is_nil(own_id)))}
      end
    end
  end

  defp dependents(name, siblings) do
    Enum.filter(siblings, fn field ->
      case Logic.stored(field) do
        %{rule: rule} -> name in Conditions.references(rule)
        nil -> false
      end
    end)
  end

  defp rename_references(field, from, to) when from == to, do: field

  defp rename_references(field, from, to) do
    case Logic.stored(field) do
      %{action: action, rule: rule} ->
        %{field | condition: %{action: action, rule: Conditions.rename(rule, from, to)}}

      nil ->
        field
    end
  end

  defp new_violations(after_write, before) do
    seen = before |> Logic.order_violations() |> MapSet.new(fn {d, t} -> {d.id, t.id} end)

    after_write
    |> Logic.order_violations()
    |> Enum.reject(fn {d, t} -> MapSet.member?(seen, {d.id, t.id}) end)
  end

  defp in_use_message(dependents) do
    gettext("is used in the conditions of %{fields}: remove those conditions first",
      fields: labels(dependents)
    )
  end

  @doc false
  # Also `KilnCMS.Forms.FieldOrder`'s refusal.
  @spec order_message(map(), map()) :: String.t()
  def order_message(dependent, target) do
    gettext(
      "%{dependent} is shown based on %{target}, which would come after it: conditions can only use earlier answers",
      dependent: label(dependent),
      target: label(target)
    )
  end

  defp labels(fields), do: Enum.map_join(fields, ", ", &label/1)
  defp label(field), do: "“" <> (field.label || field.name) <> "”"

  defp error(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
