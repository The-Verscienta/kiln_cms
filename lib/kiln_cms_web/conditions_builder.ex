defmodule KilnCMSWeb.ConditionsBuilder do
  @moduledoc """
  State behind the "Conditions" disclosure on `/editor/fields`
  (`KilnCMSWeb.ConditionsBuilderComponents`, #2277): the rows an admin is
  building for a field's `visible_when` and `required_when` rules.

  Like `KilnCMSWeb.ComputedBuilder`, it adds no storage. It sits in front of
  the definition's two rule attributes: each change event hands it the
  `conditions` params the form posted (`apply_params/3`), and `rule_params/2`
  turns the rows into the `visible_when` / `required_when` params the resource
  validates (`KilnCMS.CMS.Validations.FieldCondition`).

  The builder is one level deep: a list of tests joined by "all" or "any". A
  stored rule that nests further (the API allows it) is shown as a note and
  left untouched until the admin removes it.
  """
  alias KilnCMS.CMS.Conditions

  @rules ~w(visible_when required_when)
  @ordered_types [:integer, :float, :date, :datetime]

  @type row :: %{String.t() => String.t()}
  @type rule_state :: %{
          mode: String.t(),
          rows: [row()],
          nested?: boolean(),
          held?: boolean()
        }
  @type t :: %{String.t() => rule_state()}

  @doc "The two rules' names."
  def rules, do: @rules

  @doc "The field types `gt` / `lt` apply to."
  def ordered_types, do: @ordered_types

  @doc "A state from a definition's stored rules (or empty for a new field)."
  @spec new(map() | nil) :: t()
  def new(definition \\ nil) do
    Map.new(@rules, fn rule ->
      {rule, from_rule(definition && Map.get(definition, String.to_existing_atom(rule)))}
    end)
  end

  defp from_rule(rule) do
    case Conditions.normalize(rule) do
      nil -> empty()
      %{"all" => children} -> flat(children, "all", rule)
      %{"any" => children} -> flat(children, "any", rule)
      %{"field" => _} = leaf -> flat([leaf], "all", rule)
      _other -> %{empty() | nested?: true}
    end
  end

  defp flat(children, mode, _rule) do
    if Enum.all?(children, &leaf?/1) do
      %{empty() | mode: mode, rows: Enum.map(children, &row/1)}
    else
      %{empty() | nested?: true}
    end
  end

  defp leaf?(%{"field" => _, "op" => _}), do: true
  defp leaf?(_other), do: false

  defp row(leaf) do
    %{
      "field" => leaf["field"],
      "op" => leaf["op"],
      "value" => display(Map.get(leaf, "value"))
    }
  end

  defp display(nil), do: ""
  defp display(list) when is_list(list), do: Enum.map_join(list, ", ", &display/1)
  defp display(value), do: to_string(value)

  defp empty, do: %{mode: "all", rows: [], nested?: false, held?: false}

  @doc """
  Keep as stored every rule that names one of `names`: siblings of a field
  type this release does not know (#2605). The field picker offers no such
  field, so showing the rule as rows would rewrite it on the next save; it is
  shown as a note instead, like a nested rule, and left out of
  `rule_params/2` until the admin removes it.
  """
  @spec hold(t(), [String.t()]) :: t()
  def hold(state, []), do: state

  def hold(state, names) do
    Map.new(state, fn {rule, rs} ->
      if Enum.any?(rs.rows, &(&1["field"] in names)),
        do: {rule, %{rs | nested?: true, held?: true}},
        else: {rule, rs}
    end)
  end

  @doc "An empty row, for \"Add a condition\"."
  def blank_row(siblings) do
    %{
      "field" => siblings |> List.first() |> then(&(&1 && &1.name)) || "",
      "op" => "eq",
      "value" => ""
    }
  end

  @doc "Add a blank row to `rule`."
  def add(state, rule, siblings) when rule in @rules do
    update_in(state[rule], fn rs ->
      %{rs | rows: rs.rows ++ [blank_row(siblings)], nested?: false, held?: false}
    end)
  end

  @doc "Remove the row at `index` from `rule`."
  def remove(state, rule, index) when rule in @rules and is_integer(index) do
    update_in(state[rule], fn rs -> %{rs | rows: List.delete_at(rs.rows, index)} end)
  end

  @doc "Drop `rule` altogether (also a nested rule the builder can't show)."
  def clear(state, rule) when rule in @rules do
    put_in(state[rule], empty())
  end

  @doc """
  Take the posted `conditions` params into `state`. A rule the form did not
  post (no rows rendered) is left as it is. A changed field resets an
  operator its type can't use.
  """
  @spec apply_params(t(), map() | nil, [map()]) :: t()
  def apply_params(state, %{} = posted, siblings) do
    Enum.reduce(@rules, state, fn rule, acc ->
      case posted do
        %{^rule => %{} = rule_params} ->
          put_in(acc[rule], posted_rule(acc[rule], rule_params, siblings))

        _none ->
          acc
      end
    end)
  end

  def apply_params(state, _none, _siblings), do: state

  defp posted_rule(rs, params, siblings) do
    mode = if params["mode"] in ["all", "any"], do: params["mode"], else: rs.mode

    rows =
      case params["rows"] do
        %{} = rows ->
          rows
          |> Enum.sort_by(fn {index, _row} -> index_of(index) end)
          |> Enum.map(fn {_index, row} -> posted_row(row, siblings) end)

        _none ->
          rs.rows
      end

    %{rs | mode: mode, rows: rows}
  end

  defp index_of(index) do
    case Integer.parse(to_string(index)) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp posted_row(row, siblings) do
    field = to_string(row["field"] || "")
    type = type_of(siblings, field)
    op = to_string(row["op"] || "eq")

    op =
      cond do
        op not in Conditions.ops() -> "eq"
        op in Conditions.ordering_ops() and type not in @ordered_types -> "eq"
        true -> op
      end

    %{"field" => field, "op" => op, "value" => to_string(row["value"] || "")}
  end

  @doc "The field type of the sibling called `name`, or nil."
  def type_of(siblings, name) do
    Enum.find_value(siblings, fn s -> s.name == name && s.field_type end)
  end

  @doc """
  The `visible_when` / `required_when` params for the rows in `state`. A rule
  with no complete row is `nil` (removing it); a nested rule the builder can't
  show is left out so the stored one is kept.
  """
  @spec rule_params(t(), [map()]) :: map()
  def rule_params(state, siblings) do
    for rule <- @rules,
        rs = state[rule],
        not rs.nested?,
        into: %{} do
      {rule, to_rule(rs, siblings)}
    end
  end

  defp to_rule(%{rows: rows, mode: mode}, siblings) do
    leaves = for row <- rows, row["field"] not in [nil, ""], do: leaf(row, siblings)

    case leaves do
      [] -> nil
      [only] -> only
      many -> %{mode => many}
    end
  end

  defp leaf(%{"field" => field, "op" => op, "value" => value}, siblings) do
    type = type_of(siblings, field)

    case op do
      op when op in ["empty", "not_empty"] ->
        %{"field" => field, "op" => op}

      "in" ->
        values =
          value
          |> to_string()
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&typed(type, &1))

        %{"field" => field, "op" => op, "value" => values}

      op ->
        %{"field" => field, "op" => op, "value" => typed(type, to_string(value))}
    end
  end

  defp typed(:boolean, value), do: value == "true"

  defp typed(type, value) when type in [:integer, :float] do
    case Float.parse(value) do
      {number, ""} ->
        if type == :integer and trunc(number) == number, do: trunc(number), else: number

      _ ->
        value
    end
  end

  defp typed(_type, value), do: value
end
