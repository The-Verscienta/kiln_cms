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
  (equality-shaped operators only) and are not sortable. On a `multiple` one
  (a gallery, a list of references) `eq` means "contains this id", `not_eq`
  "does not", and `in` "contains any of them". A reference also takes the
  relationship operators `has` / `has_all` / `has_none` / `count`, which
  read its `content_links` edges rather than the snapshot, and so do the
  built-in `tags` and `related_<type>s` (the set operators only) — see
  `KilnCMS.CMS.Preparations.CustomFieldQuery.Relations`. A reference's link
  fields (R3) filter under `<field>.link.<name>` —
  `custom_filter[ingredients.link.role]=main` — with the scalar operators:
  a record matches when **some** connection of that field carries a
  matching value, read from the edges' `metadata` under the same both-ends
  gate as the relationship operators. A `target` beside the operators
  (`custom_filter[credits.link.role][eq]=photo&custom_filter[credits.link.role][target]=<id>`)
  narrows that to the connections pointing at those ids (#2044). Definitions are read
  as the system (`KilnCMS.CMS.Housekeeping`, #1659): registry metadata, not
  user data, and the public API's anonymous callers filter too. The read fails
  closed — a refused registry read raises rather than resolving to "no
  fields" (which would already 400, never widen the result). No index backs
  these predicates — promote a hot field to a compiled attribute when that
  starts to matter (D4/D17).
  """
  use Ash.Resource.Preparation

  import Ash.Expr

  require Ash.Sort

  alias Ash.Error.Query.InvalidArgument
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.Relations

  @operators ~w(eq not_eq gt gte lt lte in ilike null)

  @impl true
  def prepare(query, _opts, context) do
    filter = Ash.Query.get_argument(query, :custom_filter) || %{}
    sort = Ash.Query.get_argument(query, :custom_sort) || ""

    if filter == %{} and sort == "" do
      query
    else
      defs = definitions(query)

      # What the relationship operators gate targets with (`Relations`).
      ctx = %{
        resource: query.resource,
        actor: Map.get(context, :actor),
        tenant: query.to_tenant || query.tenant
      }

      query
      |> apply_filter(filter, defs, ctx)
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
      KilnCMS.CMS.field_definitions_for!(resource.__kiln_content_type__(), registry_opts(tenant))
    end
  end

  # As the system, with `authorize_with: :error`: a refusal is an error, never
  # an empty registry. See the moduledoc.
  defp registry_opts(tenant) do
    [
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: tenant
    ]
  end

  defp entry_definitions(query, tenant) do
    cond do
      id = equality_filter_value(query, :type_definition_id) ->
        KilnCMS.CMS.field_definitions_for_definition!(id, registry_opts(tenant))

      name = equality_filter_value(query, :type_name) ->
        case KilnCMS.CMS.get_type_definition_by_name(name, registry_opts(tenant)) do
          {:ok, definition} ->
            KilnCMS.CMS.field_definitions_for_definition!(definition.id, registry_opts(tenant))

          {:error, %Ash.Error.Forbidden{} = error} ->
            raise error

          _ ->
            []
        end

      true ->
        KilnCMS.CMS.list_field_definitions!(
          [query: [filter: [type_definition_id: [is_nil: false]]]] ++ registry_opts(tenant)
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

  defp apply_filter(query, filter, defs, ctx) when is_map(filter) do
    Enum.reduce(filter, query, fn {name, condition}, query ->
      name = to_string(name)

      with {:ok, target} <- resolve_target(defs, name, ctx),
           {:ok, exprs} <- conditions(target, condition, ctx) do
        Enum.reduce(exprs, query, &Ash.Query.do_filter(&2, &1))
      else
        {:error, message} -> invalid(query, :custom_filter, message)
      end
    end)
  end

  defp apply_filter(query, _filter, _defs, _ctx) do
    invalid(query, :custom_filter, "must be a map of custom field names to conditions")
  end

  # A custom field wins a name it shares with a built-in relationship, so a
  # site's existing `custom_filter[tags]` keeps its meaning; otherwise
  # `tags` and `related_<type>s` take the relationship operators (R6).
  defp resolve_target(defs, name, ctx) do
    case Regex.run(~r/\A(.+)\.link\.([^.]+)\z/, name) do
      [_, parent, link] -> resolve_link(defs, parent, link, ctx)
      nil -> resolve_field(defs, name, ctx)
    end
  end

  # `<reference field>.link.<link field>` (R3).
  defp resolve_link(defs, parent_name, link_name, ctx) do
    with {:ok, parent} <- resolve(defs, parent_name),
         :ok <- reference_parent(parent) do
      links = link_fields(parent, ctx)

      case Enum.find(links, &(&1.name == link_name)) do
        nil ->
          names = links |> Enum.map(& &1.name) |> Enum.sort()

          {:error,
           "custom field #{inspect(parent_name)} has no link field #{inspect(link_name)}" <>
             if(names == [], do: "", else: " (link fields: #{Enum.join(names, ", ")})")}

        link ->
          {:ok, {:link, parent, link}}
      end
    end
  end

  defp reference_parent(%{field_type: :reference}), do: :ok

  defp reference_parent(%{name: name, field_type: type}),
    do:
      {:error,
       "custom field #{inspect(name)} (#{type}) is not a reference, so it has no link fields"}

  # `for_type`/`for_definition` load them; the unscoped entry read does not.
  defp link_fields(%{link_fields: %Ash.NotLoaded{}} = parent, ctx) do
    parent
    |> Ash.load!(:link_fields, registry_opts(ctx.tenant))
    |> KilnCMS.CMS.FieldDefinition.link_fields()
  end

  defp link_fields(parent, _ctx), do: KilnCMS.CMS.FieldDefinition.link_fields(parent)

  defp resolve_field(defs, name, ctx) do
    case {resolve(defs, name), Relations.builtin(ctx.resource, name)} do
      {{:error, "unknown" <> _}, {_, _} = builtin} -> {:ok, {:builtin, builtin}}
      {result, _builtin} -> result
    end
  end

  # A bare value is an equality match; a map is `%{operator => value}`.
  defp conditions(target, condition, ctx) when not is_map(condition) do
    conditions(target, %{"eq" => condition}, ctx)
  end

  # A link filter's `target` (#2044) is not an operator: it narrows the
  # edges every operator beside it reads to those pointing at the given ids,
  # so `[eq]=photographer&[target]=<id>` asks whether *that* record is the
  # photographer. Taken out before the operators are read.
  defp conditions({:link, parent, link}, condition, ctx) when is_map(condition) do
    label = "#{parent.name}.link.#{link.name}"

    case Map.pop(stringify_keys(condition), "target") do
      {nil, rest} ->
        link_conditions(parent, link, rest, ctx, nil)

      {_raw, rest} when map_size(rest) == 0 ->
        {:error, "target for link field #{inspect(label)} needs a condition beside it"}

      {raw, rest} ->
        with {:ok, ids} <- Relations.link_targets(raw, label) do
          link_conditions(parent, link, rest, ctx, ids)
        end
    end
  end

  defp conditions(target, condition, ctx) do
    Enum.reduce_while(condition, {:ok, []}, fn {op, raw}, {:ok, acc} ->
      case relation_or_condition(target, to_string(op), raw, ctx) do
        {:ok, expr} -> {:cont, {:ok, [expr | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp relation_or_condition({:builtin, builtin}, op, raw, ctx),
    do: Relations.builtin_condition(builtin, op, raw, ctx)

  # The relationship operators run over the reference's `content_links`
  # edges, single or `multiple` alike (R6).
  defp relation_or_condition(%{field_type: :reference} = definition, op, raw, ctx)
       when op in ~w(has has_all has_none count),
       do: Relations.reference(definition, op, raw, ctx)

  defp relation_or_condition(%{field_type: type, name: name}, op, _raw, _ctx)
       when op in ~w(has has_all has_none count) do
    {:error,
     "#{op} is a relationship operator: custom field #{inspect(name)} (#{type}) " <>
       "is not a reference"}
  end

  defp relation_or_condition(definition, op, raw, _ctx), do: condition(definition, op, raw)

  defp link_conditions(parent, link, condition, ctx, targets) do
    label = "#{parent.name}.link.#{link.name}"

    Enum.reduce_while(condition, {:ok, []}, fn {op, raw}, {:ok, acc} ->
      case link_condition(link, op, raw, label) do
        {:ok, condition} ->
          {:cont, {:ok, [Relations.link(parent, condition, ctx, targets) | acc]}}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # One link field's value on an edge's `metadata` (R3) — the condition
  # `Relations.link/3` wraps in the edge `exists`. Link fields are scalar
  # (`FieldDefinition.link_field_types/0`), so these are the scalar rules of
  # `condition/3` on another jsonb column.
  defp link_condition(_link, op, _raw, label) when op not in @operators,
    do: {:error, "unknown operator #{inspect(op)} for link field #{inspect(label)}"}

  defp link_condition(%{name: name}, "null", raw, label) do
    path = expr(get_path(metadata, [^name]))

    case raw do
      t when t in [true, "true", "1"] -> {:ok, expr(is_nil(^path))}
      f when f in [false, "false", "0"] -> {:ok, expr(not is_nil(^path))}
      _ -> {:error, "null for link field #{inspect(label)} must be true or false"}
    end
  end

  defp link_condition(%{name: name} = link, "in", raw, label) do
    cast_list(raw, ash_type(link), label, fn
      [] ->
        expr(false)

      values ->
        values
        |> Enum.map(&jsonb_condition(:metadata, "eq", name, &1))
        |> Enum.reduce(&expr(^&2 or ^&1))
    end)
  end

  defp link_condition(%{name: name} = link, "ilike", raw, label) do
    if ash_type(link) do
      {:error, "ilike is only supported on text-like link fields (#{inspect(label)})"}
    else
      {:ok, expr(ilike(get_path(metadata, [^name]), ^to_string(raw)))}
    end
  end

  defp link_condition(%{name: name} = link, op, raw, label) do
    with {:ok, value} <- cast_value(raw, ash_type(link), label) do
      {:ok, jsonb_condition(:metadata, op, name, value)}
    end
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

  # A geolocation (#428) is a composite jsonb object with no stable scalar to
  # match on — comparing it as text silently returns wrong rows (a JSON string
  # never equals a JSON object), so refuse the predicate outright the way the
  # sort path does.
  defp condition(%{field_type: :geolocation, name: name}, _op, _raw),
    do: {:error, "custom field #{inspect(name)} (geolocation) is not filterable"}

  # A group is an object or a list of them, for the same reason: `null` above
  # is the one question its value answers as a whole.
  defp condition(%{field_type: :group, name: name}, _op, _raw),
    do: {:error, "custom field #{inspect(name)} (group) only supports null"}

  # A gallery (`multiple` media) or a list of references (`multiple`
  # reference) holds a list of snapshots, so `eq` asks whether the list
  # *contains* the id, `not_eq` whether it does not, and `in` whether it
  # contains any of them — jsonb containment against a one-snapshot array. The
  # probe is bound as text and cast in SQL: bound as `::jsonb` directly,
  # Postgrex would encode the JSON string as a JSON string.
  defp condition(%{field_type: type, multiple: true, name: name}, op, raw)
       when type in [:media, :reference] do
    contains = fn id ->
      probe = Jason.encode!([%{"id" => to_string(id)}])
      expr(fragment("(? -> ?::text) @> ?::text::jsonb", ^ref(:custom_fields), ^name, ^probe))
    end

    case op do
      "eq" ->
        {:ok, contains.(raw)}

      "not_eq" ->
        {:ok, expr(not (^contains.(raw)))}

      "in" ->
        cast_list(raw, nil, name, fn
          [] -> expr(false)
          values -> values |> Enum.map(contains) |> Enum.reduce(&expr(^&2 or ^&1))
        end)

      _ ->
        {:error,
         "custom field #{inspect(name)} (#{list_label(type)}) only supports eq/not_eq/in/null"}
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
        |> Enum.map(&jsonb_condition(:custom_fields, "eq", name, &1))
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
      {:ok, jsonb_condition(:custom_fields, op, name, value)}
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
  #
  # `column` is `:custom_fields` for a field on the record, `:metadata` for a
  # link field on an edge (R3).
  defp jsonb_condition(column, op, name, raw_value) do
    field = expr(fragment("(? -> ?::text)", ^ref(column), ^name))
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
        # Composite values are jsonb objects. Sorting them orders by key count
        # then key/value text, which is meaningless for a coordinate or a
        # snapshot — refuse rather than return a 200 in nonsense order.
        {:ok, %{field_type: type}} when type in [:media, :reference, :geolocation, :group] ->
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
  # A `:computed` field (#429) has no static type — its formula decides, so
  # `{{ word_count(body) }}` stores a JSON number while `{{ slugify(title) }}`
  # stores a JSON string. Infer from the supplied predicate instead: text-casting
  # a number would compare a JSON string against a JSON number, which doesn't
  # merely miss — jsonb orders Number below String, so a range predicate
  # silently matches every row or none.
  defp ash_type(%{field_type: :computed}), do: :dynamic
  defp ash_type(_definition), do: nil

  # --- value casting -------------------------------------------------------------

  # Preserve the caller's JSON-native type so the encoded predicate matches how
  # the value is actually stored.
  defp cast_value(raw, :dynamic, _name) when is_number(raw) or is_boolean(raw), do: {:ok, raw}

  defp cast_value(raw, :dynamic, name) when is_binary(raw) do
    # `Kiln.FieldType.parse_float/1` — `Float.parse/1` raises on an overflow
    # literal under Elixir 1.19 (total only from 1.20), and this value comes
    # straight off a query string.
    case {Integer.parse(raw), Kiln.FieldType.parse_float(raw)} do
      {{integer, ""}, _} -> {:ok, integer}
      {_, {float, ""}} -> {:ok, float}
      _ -> cast_value(raw, nil, name)
    end
  end

  defp cast_value(raw, :dynamic, name), do: cast_value(raw, nil, name)

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

  defp list_label(:media), do: "media gallery"
  defp list_label(:reference), do: "list of references"
end
