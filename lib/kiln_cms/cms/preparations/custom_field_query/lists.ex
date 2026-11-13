defmodule KilnCMS.CMS.Preparations.CustomFieldQuery.Lists do
  @moduledoc """
  The `custom_filter` operators of a `multiple` scalar custom field (#2289): a
  list of phrases or terms, numbers, dates, times, links, addresses, phone
  numbers, colours or slugs (`KilnCMS.CMS.ScalarLists.types/0`).

    * `eq` — the list contains the value; `in` / `has` — it contains any of
      the values; `has_all` — it contains every one of them.
    * `not_eq` — the list does not contain the value. A record with no value
      is left out, as `not_eq` leaves it out on a single field.
    * `has_none` — the list contains none of the values. A record with no
      value **is** a match, as it is for a reference's `has_none`.
    * `count` — the number of items, compared like a reference's `count`
      (a bare number is `eq`); a record with no value has `0`.
    * `null` stays `CustomFieldQuery`'s own.

  Every operand is cast as a single field of the item type would cast it
  (`CustomFieldQuery.cast_value/3`), so `"10"` finds the number `10` on an
  integer list and `10` finds `10.0` on a float list (jsonb compares numbers
  by value).

  Membership is jsonb containment — `custom_fields @> {name: [value]}` — which
  a GIN index on the column can serve. A value stored before the field was a
  list (a retype, an unfinished reshape) is not an array: every operator reads
  it as a one-item list rather than missing it or failing on it.

  Comparing items (`gt`/`gte`/`lt`/`lte`) and matching text in them
  (`contains`/`starts_with`/`ilike`) are not supported yet, and a list is not
  sortable.
  """

  import Ash.Expr

  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.Preparations.CustomFieldQuery
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.Relations

  @operators ~w(eq not_eq in has has_all has_none count null)

  # The lists whose items the write path coerces (numbers, dates, links, …);
  # a list of phrases or terms holds strings, cast as text.
  @typed KilnCMS.CMS.ScalarLists.typed()

  @doc "The operators a scalar list takes, in the order the errors list them."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc """
  The condition `op` (already normalised: `null`, never `is_nil`) with operand
  `raw` stands for on the list field `definition`, or `{:error, message}`.
  """
  @spec condition(map(), String.t(), term()) :: {:ok, Ash.Expr.t()} | {:error, String.t()}
  def condition(definition, op, raw)

  def condition(%{name: name} = definition, "eq", raw) do
    with {:ok, value} <- cast(raw, definition, "eq"), do: {:ok, contains_any(name, [value])}
  end

  def condition(%{name: name} = definition, "not_eq", raw) do
    with {:ok, value} <- cast(raw, definition, "not_eq"),
         do: {:ok, does_not_contain(name, value)}
  end

  def condition(%{name: name} = definition, "in", raw) do
    with {:ok, values} <- cast_all(List.wrap(raw), definition, "in") do
      {:ok, if(values == [], do: expr(false), else: contains_any(name, values))}
    end
  end

  def condition(%{name: name} = definition, "has", raw) do
    with {:ok, values} <- values(raw, definition, "has"), do: {:ok, contains_any(name, values)}
  end

  def condition(%{name: name} = definition, "has_all", raw) do
    with {:ok, values} <- values(raw, definition, "has_all"),
         do: {:ok, contains_all(name, values)}
  end

  def condition(%{name: name} = definition, "has_none", raw) do
    with {:ok, values} <- values(raw, definition, "has_none") do
      {:ok, expr(not fragment("COALESCE(?, false)", ^contains_any(name, values)))}
    end
  end

  def condition(%{name: name}, "count", raw) do
    with {:ok, comparisons} <- Relations.count_comparisons(raw, name) do
      {:ok, count_condition(name, comparisons)}
    end
  end

  def condition(%{name: name}, op, _raw) do
    {:error,
     "#{op} is not supported on custom field #{inspect(name)} (a list): " <>
       "it supports #{Enum.join(@operators, "/")}"}
  end

  # --- membership ---------------------------------------------------------------

  # The list holds `value`, or — stored before the field was a list — the
  # field holds `value` itself. Both are containment against the column, so an
  # index serves either; `{name: [v]}` never matches a bare `v`, nor `{name: v}`
  # a list (array-contains-scalar applies at the top level only).
  defp contains_one(name, value) do
    expr(
      fragment(
        "(? @> jsonb_build_object(?::text, ?::text::jsonb) OR ? @> jsonb_build_object(?::text, ?::text::jsonb))",
        ^ref(:custom_fields),
        ^name,
        ^Jason.encode!([value]),
        ^ref(:custom_fields),
        ^name,
        ^Jason.encode!(value)
      )
    )
  end

  defp contains_any(name, values) do
    values
    |> Enum.map(&contains_one(name, &1))
    |> Enum.reduce(&expr(^&2 or ^&1))
  end

  # One containment of the whole array. A stale bare value holds one item, so
  # it can hold every value only when they are all that one.
  defp contains_all(name, [value]), do: contains_one(name, value)

  defp contains_all(name, values) do
    expr(
      fragment(
        "? @> jsonb_build_object(?::text, ?::text::jsonb)",
        ^ref(:custom_fields),
        ^name,
        ^Jason.encode!(values)
      )
    )
  end

  # Absent-safe: no value (a missing key or a JSON null) is SQL NULL here and
  # drops out of the `NOT`, as it does for `not_eq` on a single field.
  defp does_not_contain(name, value) do
    expr(not fragment("? @> ?::text::jsonb", ^as_list(name), ^Jason.encode!([value])))
  end

  # --- count --------------------------------------------------------------------

  defp count_condition(name, comparisons) do
    count = item_count(name)

    comparisons
    |> Enum.map(fn {cmp, n} -> compare(cmp, count, n) end)
    |> Enum.reduce(&expr(^&2 and ^&1))
  end

  # An array's length; no value is 0 items and a stale bare value is 1.
  defp item_count(name) do
    value = field(name)

    expr(
      type(
        fragment(
          "(CASE WHEN ? IS NULL THEN 0 WHEN jsonb_typeof(?) = 'array' THEN jsonb_array_length(?) WHEN jsonb_typeof(?) = 'null' THEN 0 ELSE 1 END)",
          ^value,
          ^value,
          ^value,
          ^value
        ),
        :integer
      )
    )
  end

  defp compare("eq", count, n), do: expr(^count == ^n)
  defp compare("gt", count, n), do: expr(^count > ^n)
  defp compare("gte", count, n), do: expr(^count >= ^n)
  defp compare("lt", count, n), do: expr(^count < ^n)
  defp compare("lte", count, n), do: expr(^count <= ^n)

  # --- the stored value -----------------------------------------------------------

  defp field(name), do: expr(fragment("(? -> ?::text)", ^ref(:custom_fields), ^name))

  # The value as a list: an array as it is, a stale bare value as a one-item
  # array, no value (a missing key or a JSON null) as SQL NULL.
  defp as_list(name) do
    value = field(name)

    expr(
      fragment(
        "(CASE WHEN ? IS NULL THEN NULL WHEN jsonb_typeof(?) = 'array' THEN ? WHEN jsonb_typeof(?) = 'null' THEN NULL ELSE jsonb_build_array(?) END)",
        ^value,
        ^value,
        ^value,
        ^value,
        ^value
      )
    )
  end

  # --- operands -------------------------------------------------------------------

  # An operand is coerced exactly as the write path stored each item
  # (`ApplyCustomFields.coerce_item/2`): `#FFF` finds the stored `#ffffff`,
  # `9:30` the stored `09:30`, a date-time keeps its fractional seconds.
  # Containment compares JSON exactly, so anything looser misses. An operand
  # the field could never hold falls back to the single field's cast, for
  # its error.
  #
  # An object or a list is refused first (#2739): an Ecto date cast would take
  # `%{"year" => …, "month" => …, "day" => …}` where a single field refuses it.
  defp cast(raw, %{name: name} = definition, op) do
    with :ok <- CustomFieldQuery.operand_shape(raw, op, "custom field #{inspect(name)}"),
         do: cast(raw, definition)
  end

  defp cast(raw, %{name: name, field_type: type} = definition)
       when type in @typed and (is_binary(raw) or is_number(raw)) do
    case ApplyCustomFields.coerce_item(definition, raw) do
      {:ok, value} when is_binary(value) or is_number(value) -> {:ok, value}
      _refused -> CustomFieldQuery.cast_value(raw, CustomFieldQuery.ash_type(definition), name)
    end
  end

  defp cast(raw, %{name: name} = definition),
    do: CustomFieldQuery.cast_value(raw, CustomFieldQuery.ash_type(definition), name)

  defp cast_all(raw, definition, op) do
    raw
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case cast(item, definition, op) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # `has` / `has_all` / `has_none`: one value or a non-empty list of at most
  # `Relations.max_ids/0`, as for a reference's ids.
  defp values(raw, %{name: name} = definition, op) do
    max = Relations.max_ids()
    raw = if is_list(raw), do: raw, else: [raw]

    cond do
      raw == [] ->
        {:error, "#{op} for #{inspect(name)} needs at least one value"}

      length(raw) > max ->
        {:error, "#{op} for #{inspect(name)} takes at most #{max} values"}

      true ->
        with {:ok, values} <- cast_all(raw, definition, op), do: {:ok, Enum.uniq(values)}
    end
  end
end
