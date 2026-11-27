defmodule KilnCMSWeb.FormConditionsBuilder do
  @moduledoc """
  State behind the "Conditional logic" section of the form builder's field
  settings (`KilnCMSWeb.FormBuilderLive`, #2262): the rows an admin is
  building for a field's `condition` (`KilnCMS.CMS.FormFieldCondition`).

  Like `KilnCMSWeb.ConditionsBuilder`, the custom-field twin it is modelled
  on, it adds no storage. Each change event hands it the posted `condition`
  params (`apply_params/3`), and `condition_params/2` turns the rows into the
  `condition` the resource validates
  (`KilnCMS.CMS.Validations.FormFieldCondition`).

  One level deep: a list of tests joined by "all" or "any". A stored rule
  that nests further (the API allows it) is shown as a note and left as it is
  until the admin removes it.

  `targets` is always the fields the rule may name: the selected field's
  earlier fields, of a type this release knows.
  """
  alias KilnCMS.CMS.Conditions
  alias KilnCMS.Forms.Logic

  # The operators the builder offers, in menu order. Storage takes every
  # `Conditions` operator; `in` and the prefix/suffix tests are API-only.
  @ops ~w(eq neq empty not_empty contains not_contains gt lt)

  @type row :: %{String.t() => String.t()}
  @type t :: %{action: String.t(), mode: String.t(), rows: [row()], nested?: boolean()}

  @doc "The operators the builder offers."
  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc "The builder's operators a field of `type` can be tested with."
  @spec ops_for(term()) :: [String.t()]
  def ops_for(type), do: Enum.filter(@ops, &Logic.op_allowed?(&1, type))

  @doc "A state from a field's stored condition (none: no rows)."
  @spec new(map() | nil) :: t()
  def new(field) do
    case field && Logic.stored(field) do
      %{action: action, rule: rule} when action in [:show, :hide] ->
        from_rule(Atom.to_string(action), rule)

      %{action: _unknown} ->
        %{empty() | nested?: true}

      nil ->
        empty()
    end
  end

  defp from_rule(action, rule) do
    case rule do
      %{"all" => children} when is_list(children) -> flat(action, "all", children)
      %{"any" => children} when is_list(children) -> flat(action, "any", children)
      %{"field" => _} = leaf -> flat(action, "all", [leaf])
      _other -> %{empty() | action: action, nested?: true}
    end
  end

  defp flat(action, mode, children) do
    if Enum.all?(children, &(leaf?(&1) and Map.get(&1, "op") in @ops)),
      do: %{empty() | action: action, mode: mode, rows: Enum.map(children, &row/1)},
      else: %{empty() | action: action, nested?: true}
  end

  defp leaf?(%{"field" => _, "op" => _}), do: true
  defp leaf?(_other), do: false

  defp row(leaf) do
    %{"field" => leaf["field"], "op" => leaf["op"], "value" => display(Map.get(leaf, "value"))}
  end

  defp display(nil), do: ""
  defp display(value), do: to_string(value)

  defp empty, do: %{action: "show", mode: "all", rows: [], nested?: false}

  @doc "Whether the state holds a condition (rows, or a stored rule shown as a note)."
  @spec present?(t()) :: boolean()
  def present?(state), do: state.rows != [] or state.nested?

  @doc """
  A new row testing the first of `targets`, with a value it can take: its
  first option, "Checked" for a checkbox, else blank.
  """
  @spec blank_row([map()]) :: row()
  def blank_row(targets) do
    case targets do
      [target | _rest] ->
        %{"field" => target.name, "op" => "eq", "value" => default_value(target)}

      [] ->
        %{"field" => "", "op" => "eq", "value" => ""}
    end
  end

  defp default_value(%{field_type: :boolean}), do: "true"

  defp default_value(%{field_type: type, options: [first | _]})
       when type in [:select, :radio, :checkboxes], do: first

  defp default_value(_target), do: ""

  @doc "Add a blank row (also replaces a nested rule the builder can't show)."
  @spec add(t(), [map()]) :: t()
  def add(%{nested?: true} = state, targets),
    do: %{state | nested?: false, rows: [blank_row(targets)]}

  def add(state, targets), do: %{state | rows: state.rows ++ [blank_row(targets)]}

  @doc "Remove the row at `index`."
  @spec remove(t(), integer()) :: t()
  def remove(state, index) when is_integer(index),
    do: %{state | rows: List.delete_at(state.rows, index)}

  @doc """
  Take the posted `condition` params into `state`. A row whose field changed
  gets a value that field can take, and an operator it can't use falls back
  to "eq".
  """
  @spec apply_params(t(), map() | nil, [map()]) :: t()
  def apply_params(state, %{} = params, targets) do
    action = if params["action"] in ["show", "hide"], do: params["action"], else: state.action
    mode = if params["mode"] in ["all", "any"], do: params["mode"], else: state.mode

    rows =
      case params["rows"] do
        %{} = rows ->
          rows
          |> Enum.sort_by(fn {index, _row} -> index_of(index) end)
          |> Enum.map(fn {index, row} ->
            posted_row(row, Enum.at(state.rows, index_of(index)), targets)
          end)

        _none ->
          state.rows
      end

    %{state | action: action, mode: mode, rows: rows}
  end

  def apply_params(state, _none, _targets), do: state

  defp index_of(index) do
    case Integer.parse(to_string(index)) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp posted_row(posted, before, targets) do
    field = to_string(posted["field"] || "")
    target = Enum.find(targets, &(&1.name == field))
    type = target && target.field_type
    op = to_string(posted["op"] || "eq")
    op = if op in ops_for(type), do: op, else: "eq"

    value =
      if before && before["field"] != field && target,
        do: default_value(target),
        else: to_string(posted["value"] || "")

    %{"field" => field, "op" => op, "value" => value}
  end

  @doc """
  The `condition` param for `state`: `nil` with no complete row (removing
  it), `:keep` for a stored rule the builder can't show (left as it is),
  else `%{action, rule}`.
  """
  @spec condition_params(t(), [map()]) :: map() | nil | :keep
  def condition_params(%{nested?: true}, _targets), do: :keep

  def condition_params(state, targets) do
    leaves = for row <- state.rows, row["field"] not in [nil, ""], do: leaf(row, targets)

    rule =
      case leaves do
        [] -> nil
        [only] -> only
        many -> %{state.mode => many}
      end

    rule && %{action: String.to_existing_atom(state.action), rule: rule}
  end

  defp leaf(%{"field" => field, "op" => op, "value" => value}, targets) do
    type = Enum.find_value(targets, &(&1.name == field && &1.field_type))

    if op in ["empty", "not_empty"],
      do: %{"field" => field, "op" => op},
      else: %{"field" => field, "op" => op, "value" => typed(type, op, value)}
  end

  defp typed(_type, op, value) when op in ["contains", "not_contains"], do: value
  defp typed(:boolean, _op, value), do: value == "true"

  defp typed(type, _op, value) when type in [:integer, :number, :rating] do
    case Float.parse(String.trim(value)) do
      {number, ""} -> if trunc(number) == number, do: trunc(number), else: number
      _ -> value
    end
  end

  defp typed(_type, _op, value), do: value

  @doc "Whether `rule` (normalized) names a field that `targets` doesn't hold."
  @spec dangling?(map() | nil, [map()]) :: boolean()
  def dangling?(field, targets) do
    case Logic.stored(field) do
      %{rule: rule} ->
        names = MapSet.new(targets, & &1.name)
        not Enum.all?(Conditions.references(rule), &MapSet.member?(names, &1))

      nil ->
        false
    end
  end
end
