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
  # depends on which dynamic type the query is scoped to (see moduledoc). All
  # definition reads run under the query's org (epic #336) so a filter/sort only
  # ever resolves against the requesting site's field schema.
  defp definitions(%{resource: resource} = query) do
    tenant = query.to_tenant

    if function_exported?(resource, :__kiln_dynamic_entry__, 0) do
      entry_definitions(query, tenant)
    else
      KilnCMS.CMS.field_definitions_for!(resource.__kiln_content_type__(),
        authorize?: false,
        tenant: tenant
      )
    end
  end

  defp entry_definitions(query, tenant) do
    cond do
      id = equality_filter_value(query, :type_definition_id) ->
        KilnCMS.CMS.field_definitions_for_definition!(id, authorize?: false, tenant: tenant)

      name = equality_filter_value(query, :type_name) ->
        case KilnCMS.CMS.get_type_definition_by_name(name, authorize?: false, tenant: tenant) do
          {:ok, definition} ->
            KilnCMS.CMS.field_definitions_for_definition!(definition.id,
              authorize?: false,
              tenant: tenant
            )

          _ ->
            []
        end

      true ->
        KilnCMS.CMS.list_field_definitions!(
          query: [filter: [type_definition_id: [is_nil: false]]],
          authorize?: false,
          tenant: tenant
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

  defp apply_filter(query, filter, defs) when is_map(filter) do
    Enum.reduce(filter, query, fn {name, condition}, query ->
      name = to_string(name)

      with {:ok, definition} <- resolve(defs, name),
           {:ok, exprs} <- conditions(definition, condition) do
        Enum.reduce(exprs, query, &Ash.Query.do_filter(&2, &1))
      else
        {:error, message} -> invalid(query, :custom_filter, message)
      end
    end)
  end

  defp apply_filter(query, _filter, _defs) do
    invalid(query, :custom_filter, "must be a map of custom field names to conditions")
  end

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
