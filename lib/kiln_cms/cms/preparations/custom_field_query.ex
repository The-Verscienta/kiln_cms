defmodule KilnCMS.CMS.Preparations.CustomFieldQuery do
  @moduledoc """
  Makes admin-defined custom fields **filterable and sortable** on the read
  actions that expose them (JSON:API `custom_filter[...]`/`custom_sort=`,
  GraphQL `customFilter`/`customSort` — see `docs/json-api.md`).

  `custom_fields` is one JSONB map, so the derived `filter[...]`/`sort=`
  machinery can't see inside it. This preparation closes that gap with two
  explicit read-action arguments:

    * `custom_filter` — `%{"price" => %{"gt" => "10"}, "color" => "red"}`;
      a bare value means equality, a map holds operators (`eq`, `not_eq`,
      `gt`, `gte`, `lt`, `lte`, `in`, `ilike`, `null`). Conditions are ANDed.
      Cross-field OR: the reserved keys `or`/`and` take a *list* of nested
      groups — `%{"or" => [%{"price" => %{"gt" => 10}}, %{"color" => "red"}]}`
      — recursively, capped at `@max_group_depth`. (`FieldDefinition` rejects
      `or`/`and` as field names, so the keys can't collide.)
    * `custom_sort` — comma-separated field names, `-` prefix for descending
      (`"-price,title"`), appended to any explicit `sort` so it wins over an
      action's *default* order but not over a caller's.

  Each referenced field is resolved against the `FieldDefinition` registry —
  unknown names are rejected (400), and input values are cast to the
  definition's declared type, then compared/sorted **as jsonb** so numbers
  compare numerically without a SQL cast that could raise on off-type rows
  (see `jsonb_condition/3`). Rows without the key are `NULL`: excluded by
  comparisons, last in sorts (`*_nils_last`).

  On the shared entry tier the definitions in scope depend on the dynamic
  type, which we recover from the query's own `type_definition_id`/`type_name`
  equality filter; unscoped queries fall back to *all* dynamic-type fields and
  reject names whose type differs across owners rather than guess.

  `media`/`reference` fields filter by their snapshot's stable `id`
  (equality-shaped operators only) and are not sortable. Definitions are read
  with `authorize?: false` (registry metadata, not user data). No index backs
  these predicates — promote a hot field to a compiled attribute when that
  starts to matter (D4/D17).
  """
  use Ash.Resource.Preparation

  import Ash.Expr

  require Ash.Sort

  alias Ash.Error.Query.InvalidArgument

  @operators ~w(eq not_eq gt gte lt lte in ilike null)

  @impl true
  def prepare(query, _opts, _context) do
    filter = Ash.Query.get_argument(query, :custom_filter) || %{}
    sort = Ash.Query.get_argument(query, :custom_sort) || ""

    if filter == %{} and sort == "" do
      query
    else
      defs = definitions(query)

      query
      |> apply_filter(filter, defs)
      |> apply_sort(sort, defs)
    end
  end

  # --- definitions in scope ---------------------------------------------------

  # Compiled types own a fixed content-type atom; the entry tier's schema
  # depends on which dynamic type the query is scoped to (see moduledoc).
  defp definitions(%{resource: resource} = query) do
    if function_exported?(resource, :__kiln_dynamic_entry__, 0) do
      entry_definitions(query)
    else
      KilnCMS.CMS.field_definitions_for!(resource.__kiln_content_type__(), authorize?: false)
    end
  end

  defp entry_definitions(query) do
    cond do
      id = equality_filter_value(query, :type_definition_id) ->
        KilnCMS.CMS.field_definitions_for_definition!(id, authorize?: false)

      name = equality_filter_value(query, :type_name) ->
        case KilnCMS.CMS.get_type_definition_by_name(name, authorize?: false) do
          {:ok, definition} ->
            KilnCMS.CMS.field_definitions_for_definition!(definition.id, authorize?: false)

          _ ->
            []
        end

      true ->
        KilnCMS.CMS.list_field_definitions!(
          query: [filter: [type_definition_id: [is_nil: false]]],
          authorize?: false
        )
    end
  end

  # The value of a `field == value` predicate already on the query (the
  # JSON:API layer applies `filter[...]` before `for_read`, so it's visible
  # here), or nil.
  defp equality_filter_value(%{filter: %Ash.Filter{expression: expression}}, field) do
    Ash.Filter.find_simple_equality_predicate(expression, field)
  end

  defp equality_filter_value(_query, _field), do: nil

  # One field name may exist under several dynamic types; that's fine as long
  # as every owner agrees on the value type (the SQL cast is the same).
  defp resolve(defs, name) do
    case Enum.filter(defs, &(&1.name == name)) do
      [] ->
        {:error, "unknown custom field #{inspect(name)}"}

      [definition | _] = matches ->
        if matches |> Enum.map(& &1.field_type) |> Enum.uniq() |> length() == 1 do
          {:ok, definition}
        else
          {:error,
           "custom field #{inspect(name)} has a different type per content type — " <>
             "scope the query with filter[type_name] (or type_definition_id)"}
        end
    end
  end

  # --- filtering ---------------------------------------------------------------

  # How deep `or`/`and` groups may nest (the whole filter is depth 1). A cap,
  # not a real limit anyone should hit — it bounds adversarial nesting.
  @max_group_depth 5

  defp apply_filter(query, filter, defs) when is_map(filter) do
    case group_condition(filter, defs, 1) do
      {:ok, nil} -> query
      {:ok, condition} -> Ash.Query.do_filter(query, condition)
      {:error, message} -> invalid(query, :custom_filter, message)
    end
  end

  defp apply_filter(query, _filter, _defs) do
    invalid(query, :custom_filter, "must be a map of custom field names to conditions")
  end

  # One filter group: field conditions plus nested `or`/`and` combinators,
  # ANDed together. Returns {:ok, nil} for an empty group (contributes no
  # condition).
  defp group_condition(_group, _defs, depth) when depth > @max_group_depth do
    {:error, "custom_filter groups nest too deeply (max #{@max_group_depth})"}
  end

  defp group_condition(group, defs, depth) when is_map(group) do
    Enum.reduce_while(group, {:ok, nil}, fn {key, value}, {:ok, acc} ->
      case entry_condition(to_string(key), value, defs, depth) do
        {:ok, condition} -> {:cont, {:ok, combine(acc, condition, :and)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp group_condition(_group, _defs, _depth) do
    {:error, "each custom_filter group must be a map of field names to conditions"}
  end

  # `or`/`and` are reserved combinator keys (FieldDefinition rejects them as
  # field names): a list of nested groups, OR'd/AND'd together — cross-field
  # OR lives here. Everything else is a field condition.
  defp entry_condition(combinator, value, defs, depth) when combinator in ["or", "and"] do
    with {:ok, groups} <- combinator_groups(value, combinator) do
      combine_groups(groups, combinator, defs, depth)
    end
  end

  defp entry_condition(name, condition, defs, _depth) do
    with {:ok, definition} <- resolve(defs, name),
         {:ok, exprs} <- conditions(definition, condition) do
      {:ok, Enum.reduce(exprs, nil, &combine(&2, &1, :and))}
    end
  end

  defp combine_groups(groups, combinator, defs, depth) do
    connective = String.to_existing_atom(combinator)

    groups
    |> Enum.reduce_while({:ok, nil}, fn group, {:ok, acc} ->
      case branch_condition(group, combinator, defs, depth) do
        {:ok, condition} -> {:cont, {:ok, combine(acc, condition, connective)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nil} -> {:error, "#{combinator} needs at least one condition group"}
      result -> result
    end
  end

  # An empty branch would be "always true" — reject it rather than silently
  # changing what the OR means.
  defp branch_condition(group, combinator, defs, depth) do
    case group_condition(group, defs, depth + 1) do
      {:ok, nil} -> {:error, "each #{combinator} branch needs a condition"}
      result -> result
    end
  end

  # The nested groups of a combinator. JSON callers (GraphQL) send a real
  # list; the query-param form (`custom_filter[or][0][price][gt]=10`) arrives
  # as an integer-keyed map — normalize it by index order.
  defp combinator_groups(value, _combinator) when is_list(value), do: {:ok, value}

  defp combinator_groups(value, combinator) when is_map(value) and value != %{} do
    keys = Map.keys(value)

    if Enum.all?(keys, &(to_string(&1) =~ ~r/\A\d+\z/)) do
      {:ok,
       value
       |> Enum.sort_by(fn {key, _group} -> String.to_integer(to_string(key)) end)
       |> Enum.map(fn {_key, group} -> group end)}
    else
      {:error,
       "#{combinator} takes a list of condition groups " <>
         "(e.g. custom_filter[#{combinator}][0][field]=value)"}
    end
  end

  defp combinator_groups(_value, combinator) do
    {:error, "#{combinator} takes a non-empty list of condition groups"}
  end

  defp combine(nil, condition, _combinator), do: condition
  defp combine(acc, nil, _combinator), do: acc
  defp combine(acc, condition, :and), do: expr(^acc and ^condition)
  defp combine(acc, condition, :or), do: expr(^acc or ^condition)

  # A bare value is an equality match; a map is `%{operator => value}`.
  defp conditions(definition, condition) when not is_map(condition) do
    conditions(definition, %{"eq" => condition})
  end

  defp conditions(definition, condition) do
    Enum.reduce_while(condition, {:ok, []}, fn {op, raw}, {:ok, acc} ->
      case condition(definition, to_string(op), raw) do
        {:ok, expr} -> {:cont, {:ok, [expr | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp condition(%{name: name}, op, _raw) when op not in @operators do
    {:error, "unknown operator #{inspect(op)} for custom field #{inspect(name)}"}
  end

  # Presence testing works for every field type, media/reference included.
  defp condition(%{name: name}, "null", raw) do
    path = expr(get_path(custom_fields, [^name]))

    case raw do
      t when t in [true, "true", "1"] -> {:ok, expr(is_nil(^path))}
      f when f in [false, "false", "0"] -> {:ok, expr(not is_nil(^path))}
      _ -> {:error, "null for custom field #{inspect(name)} must be true or false"}
    end
  end

  # media/reference snapshots: match on the stable id inside the map.
  defp condition(%{field_type: type, name: name}, op, raw) when type in [:media, :reference] do
    field = expr(get_path(custom_fields, [^name, "id"]))

    case op do
      "eq" -> {:ok, expr(^field == ^to_string(raw))}
      "not_eq" -> {:ok, expr(^field != ^to_string(raw))}
      "in" -> cast_list(raw, nil, name, fn values -> expr(^field in ^values) end)
      _ -> {:error, "custom field #{inspect(name)} (#{type}) only supports eq/not_eq/in/null"}
    end
  end

  # An OR of eq conditions rather than `= ANY(...)`: list params splice into
  # fragments as text literals, which can't be cast to jsonb.
  defp condition(%{name: name} = definition, "in", raw) do
    cast_list(raw, ash_type(definition), name, fn
      [] ->
        expr(false)

      values ->
        values
        |> Enum.map(&jsonb_condition("eq", name, &1))
        |> Enum.reduce(&expr(^&2 or ^&1))
    end)
  end

  defp condition(%{name: name} = definition, "ilike", raw) do
    if ash_type(definition) do
      {:error, "ilike is only supported on text-like custom fields (#{inspect(name)})"}
    else
      {:ok, expr(ilike(get_path(custom_fields, [^name]), ^to_string(raw)))}
    end
  end

  defp condition(%{name: name} = definition, op, raw) do
    with {:ok, value} <- cast_value(raw, ash_type(definition), name) do
      {:ok, jsonb_condition(op, name, value)}
    end
  end

  # Compare at the jsonb level (`->` keeps the value's JSON type) rather than
  # casting extracted text: jsonb ordering compares numbers numerically and
  # ISO-8601 date/datetime strings lexically-correctly, and — unlike a `::int`
  # cast — can never raise on a row whose value has another type (dynamic
  # types share the column, and a definition can be re-typed after rows were
  # written). The input value goes through `Ash.Type.cast_input` and is bound
  # against a `::jsonb` param — the cast makes Postgrex JSON-encode the cast
  # Elixir term, so `10` compares as a JSON number, `true` as a boolean, etc.
  defp jsonb_condition(op, name, raw_value) do
    field = expr(fragment("(? -> ?::text)", ^ref(:custom_fields), ^name))
    value = expr(fragment("?::jsonb", ^raw_value))

    case op do
      "eq" -> expr(^field == ^value)
      "not_eq" -> expr(^field != ^value)
      "gt" -> expr(^field > ^value)
      "gte" -> expr(^field >= ^value)
      "lt" -> expr(^field < ^value)
      "lte" -> expr(^field <= ^value)
    end
  end

  # --- sorting -----------------------------------------------------------------

  defp apply_sort(query, sort, defs) when is_binary(sort) do
    sort
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce(query, fn token, query ->
      {direction, name} =
        case token do
          "-" <> name -> {:desc_nils_last, name}
          name -> {:asc_nils_last, name}
        end

      case resolve(defs, name) do
        {:ok, %{field_type: type}} when type in [:media, :reference] ->
          invalid(query, :custom_sort, "custom field #{inspect(name)} (#{type}) is not sortable")

        {:ok, definition} ->
          Ash.Query.sort(query, [{sort_expr(definition), direction}])

        {:error, message} ->
          invalid(query, :custom_sort, message)
      end
    end)
  end

  defp apply_sort(query, _sort, _defs) do
    invalid(query, :custom_sort, "must be a comma-separated string of custom field names")
  end

  # --- typed expressions --------------------------------------------------------

  # Sort by the jsonb value for the same reason `jsonb_condition` compares by
  # it: numbers order numerically, ISO strings lexically, and a row carrying
  # an off-type value reorders instead of raising.
  defp sort_expr(%{name: name}) do
    Ash.Sort.expr_sort(fragment("(? -> ?::text)", ^ref(:custom_fields), ^name))
  end

  # The Ash type the *input* value is cast with before being JSON-encoded into
  # the predicate. `datetime` values are stored as offset-less ISO-8601 (see
  # ApplyCustomFields), hence :naive_datetime. nil means "treat as text" —
  # right for strings and the safe default for plugin-contributed types.
  defp ash_type(%{field_type: :integer}), do: :integer
  defp ash_type(%{field_type: :float}), do: :float
  defp ash_type(%{field_type: :boolean}), do: :boolean
  defp ash_type(%{field_type: :date}), do: :date
  defp ash_type(%{field_type: :datetime}), do: :naive_datetime
  defp ash_type(_definition), do: nil

  # --- value casting -------------------------------------------------------------

  defp cast_value(raw, nil, name) do
    if is_binary(raw) or is_number(raw) or is_boolean(raw) do
      {:ok, to_string(raw)}
    else
      {:error, "invalid value for custom field #{inspect(name)}"}
    end
  end

  defp cast_value(raw, type, name) do
    case Ash.Type.cast_input(type, raw) do
      {:ok, value} when not is_nil(value) ->
        {:ok, value}

      _ ->
        {:error, "invalid #{type} value for custom field #{inspect(name)}: #{inspect(raw)}"}
    end
  end

  defp cast_list(raw, type, name, build) do
    raw = List.wrap(raw)

    raw
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case cast_value(item, type, name) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, build.(Enum.reverse(values))}
      error -> error
    end
  end

  defp invalid(query, argument, message) do
    Ash.Query.add_error(
      query,
      InvalidArgument.exception(field: argument, message: message)
    )
  end
end
