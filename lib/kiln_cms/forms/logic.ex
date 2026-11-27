defmodule KilnCMS.Forms.Logic do
  @moduledoc """
  Which fields of a public form apply to a submission (#2262): the fields
  this release knows, and which of them are shown given the answers so far.

  ## Known fields

  `KilnCMS.CMS.FormField.field_type` is a `KilnCMS.Types.KnownAtom`, so a
  row a newer release wrote with a type this one lacks loads as a
  `KilnCMS.Types.UnknownAtom`. `known_fields/1` leaves such a row out, and
  every reader of a form's fields goes through it: the submission pipeline,
  the renderer, the headless schema, the CSV export, the autoresponder and
  the builder.

  ## Conditions

  A field may carry a `KilnCMS.CMS.FormFieldCondition`: show (or hide) it
  while a `KilnCMS.CMS.Conditions` rule holds. The rule is evaluated by that
  module, the one custom fields use, and in the browser by its twin
  (`assets/js/conditions.js`, through `assets/js/form_logic.js`). This module
  only adds the ordering layer, held to
  `test/support/fixtures/form_visibility_cases.json` on both sides:

    1. Fields are evaluated in form order (`position`, then `name`).
    2. A rule may name only strictly earlier fields, so there is no cycle.
    3. The values a rule sees are those of earlier **shown** fields only: a
       hidden field's value is dropped, so a rule naming it sees it empty.
       That is what makes chains work.
    4. `:show` shows the field while the rule holds; `:hide` hides it while
       the rule holds.
    5. **Fail shown.** A condition this release can't apply leaves its field
       shown, with its own `required`: a rule with a broken shape, one that
       names a field that is missing or not earlier, an action it doesn't
       know, or a condition on a field type that takes none (`:hidden`).
       `effective/2` answers `nil` for it, so it is never rendered or put
       in the schema either.

  A field hidden by its condition is not required, and its value is never
  stored, sent to the webhook or shown to the spam checks.
  """

  alias KilnCMS.CMS.Conditions
  alias KilnCMS.CMS.FormField
  alias KilnCMS.Types.UnknownAtom

  @type condition :: %{action: :show | :hide, rule: Conditions.rule()}

  # A condition decides whether the visitor is asked at all, so a field the
  # visitor never sees (`:hidden`) takes none. It may still be named by one.
  @unconditional_types [:hidden]

  # Which operators each field type's value can meaningfully be tested with
  # (`op_allowed?/2`). `eq`, `neq`, `empty` and `not_empty` fit every type.
  @ordered_types [:integer, :number, :rating, :date]
  @text_types [:string, :text, :email, :phone, :url, :select, :radio, :checkboxes, :hidden]
  @in_types [:select, :radio, :checkboxes, :integer, :rating]

  @doc "Whether this release knows `field`'s type."
  @spec known?(map()) :: boolean()
  def known?(%{field_type: %UnknownAtom{}}), do: false
  def known?(%{field_type: type}) when is_atom(type), do: type in FormField.field_types()
  def known?(_field), do: false

  @doc """
  `fields` without the ones whose type this release doesn't know, in the
  order given.
  """
  @spec known_fields([map()]) :: [map()]
  def known_fields(fields) when is_list(fields), do: Enum.filter(fields, &known?/1)

  @doc "Whether a field of `type` may carry a condition."
  @spec conditionable?(term()) :: boolean()
  def conditionable?(type),
    do: type in FormField.field_types() and type not in @unconditional_types

  @doc """
  Whether operator `op` (a string) can test the value of a field of `type`:
  `gt`/`lt` need a number, rating or date; the text operators a text or
  choice field; `in` a choice or whole-number field.
  """
  @spec op_allowed?(String.t(), term()) :: boolean()
  def op_allowed?(op, type) when op in ["gt", "lt"], do: type in @ordered_types
  def op_allowed?("in", type), do: type in @in_types

  def op_allowed?(op, type) when is_binary(op) do
    if op in Conditions.text_ops(),
      do: type in @text_types,
      else: op in Conditions.ops() and type in FormField.field_types()
  end

  def op_allowed?(_op, _type), do: false

  @doc """
  `field`'s condition as `%{action, rule}` (rule normalized), or `nil` when it
  has none. Read from a `KilnCMS.CMS.FormFieldCondition` or a plain map with
  atom or string keys. An action this release doesn't know comes back as
  `:unknown`.
  """
  @spec stored(map()) :: %{action: :show | :hide | :unknown, rule: term()} | nil
  def stored(%{condition: condition}) when is_map(condition) do
    %{
      action: action(fetch(condition, :action)),
      rule: Conditions.normalize(fetch(condition, :rule))
    }
  end

  def stored(_field), do: nil

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp action(action) when action in [:show, "show"], do: :show
  defp action(action) when action in [:hide, "hide"], do: :hide
  defp action(_unknown), do: :unknown

  @doc """
  The condition this release applies to `field`, given the names of the
  known fields before it (`earlier`, a `MapSet`), or `nil` for none: no
  condition, or one it can't apply (rule 5 above).
  """
  @spec effective(map(), MapSet.t(String.t())) :: condition() | nil
  def effective(field, earlier) do
    with %{action: action, rule: rule} when action in [:show, :hide] <- stored(field),
         true <- conditionable?(Map.get(field, :field_type, :string)),
         :ok <- Conditions.check_shape(rule),
         true <- Enum.all?(Conditions.references(rule), &MapSet.member?(earlier, &1)) do
      %{action: action, rule: rule}
    else
      _none_or_unusable -> nil
    end
  end

  @doc """
  `effective/2` for each of `fields` (known fields, in form order), as
  `[{field, condition | nil}]`.
  """
  @spec effective_all([map()]) :: [{map(), condition() | nil}]
  def effective_all(fields) do
    {pairs, _earlier} =
      Enum.map_reduce(fields, MapSet.new(), fn field, earlier ->
        {{field, effective(field, earlier)}, MapSet.put(earlier, field.name)}
      end)

    pairs
  end

  @doc "Whether any of `fields` has a condition this release applies."
  @spec conditional?([map()]) :: boolean()
  def conditional?(fields), do: Enum.any?(effective_all(fields), &(elem(&1, 1) != nil))

  @doc """
  Whether a field with `condition` (from `effective/2`) is shown, given
  `scope`: the values of the earlier shown fields.
  """
  @spec shown?(condition() | nil, Conditions.scope()) :: boolean()
  def shown?(nil, _scope), do: true
  def shown?(%{action: :show, rule: rule}, scope), do: Conditions.evaluate(rule, scope)
  def shown?(%{action: :hide, rule: rule}, scope), do: not Conditions.evaluate(rule, scope)

  @doc """
  Which of `fields` (known fields, in form order) are shown for `values` (a
  map of field name to the value sent): `%{name => shown?}`. A hidden field's
  value is left out of what later rules see.
  """
  @spec visibility([map()], map()) :: %{String.t() => boolean()}
  def visibility(fields, values) do
    {shown, _scope} =
      fields
      |> effective_all()
      |> Enum.reduce({%{}, %{}}, fn {field, condition}, {shown, scope} ->
        visible? = shown?(condition, scope)

        scope =
          if visible?, do: Map.put(scope, field.name, Map.get(values, field.name)), else: scope

        {Map.put(shown, field.name, visible?), scope}
      end)

    shown
  end

  @doc """
  Every way `fields`, laid out in the order given (unknown types included),
  would break the earlier-only rule: `[{field, target}]` for each field whose
  condition names `target`, a field of the form that does not come before it
  (itself included), in order.

  A name the form doesn't have is not this check's concern: such a rule
  already leaves its field shown, and must not stop a reorder.
  """
  @spec order_violations([map()]) :: [{map(), map()}]
  def order_violations(fields) do
    by_name = Map.new(fields, &{&1.name, &1})

    {violations, _earlier} =
      Enum.flat_map_reduce(fields, MapSet.new(), fn field, earlier ->
        {violations_of(field, earlier, by_name), MapSet.put(earlier, field.name)}
      end)

    violations
  end

  defp violations_of(field, earlier, by_name) do
    case stored(field) do
      %{rule: rule} ->
        for name <- Conditions.references(rule),
            Map.has_key?(by_name, name),
            not MapSet.member?(earlier, name),
            do: {field, by_name[name]}

      nil ->
        []
    end
  end

  @doc "`fields` in form order: `position`, then `name`."
  @spec sort([map()]) :: [map()]
  def sort(fields), do: Enum.sort_by(fields, &{&1.position, &1.name})
end
