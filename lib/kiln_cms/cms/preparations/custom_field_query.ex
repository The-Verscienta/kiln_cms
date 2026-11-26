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
      `gt`, `gte`, `lt`, `lte`, `in`, `ilike`, `contains`, `starts_with`,
      `null`; `is_nil` is a synonym of `null`). `contains` / `starts_with`
      match text case-insensitively and take their operand literally (`%`,
      `_` and `\\` are escaped), unlike `ilike`. Conditions are ANDed.
    * `custom_where` — the typed form of `custom_filter` (GraphQL
      `customWhere`, #2290): a list of `%{name: "price", float: %{gt: 10.0}}`,
      one kind key (`string`, `int`, `float`, `boolean`, `date`, `date_time`)
      per condition, which must be the kind of the field
      (`KilnCMS.CMS.FieldKind`). It is translated into `custom_filter`
      conditions here, once the definitions are resolved, so casting,
      privacy, tenant and Entry scoping are the same code as `custom_filter`'s
      (a private field is the same "unknown custom field"). Reference, media,
      group, geolocation, link and relationship fields keep using
      `custom_filter`. A list of scalars (#2289) is given the kind of its
      items and takes `eq` (contains), `notEq`, `in` (contains any) and
      `isNull`; its `has*` / `count` are `custom_filter`'s, and other
      `multiple` fields use `custom_filter` alone.
    * `custom_sort` — comma-separated field names, `-` prefix for descending
      (`"-price,title"`), appended to any explicit `sort` so it wins over an
      action's *default* order but not over a caller's.

  Each referenced field is resolved against the `FieldDefinition` registry —
  unknown names are rejected (400), and input values are cast to the
  definition's declared type, then compared/sorted **as jsonb** so numbers
  compare numerically without a SQL cast that could raise on off-type rows
  (see `jsonb_condition/3`). Rows without the key are `NULL`: excluded by
  comparisons, last in sorts (`*_nils_last`). A sort also reads a stored JSON
  `null`, array or object as `NULL` (last in either direction), so it neither
  leads the order nor breaks the keyset cursor of page 2.

  An equality operand (`eq`, `not_eq`, each item of `in`) on a field whose
  write tidies the value — a string or URL's spaces, a select's label, an
  email, color, telephone, time or slug — matches both as sent and as the
  write would have stored it (#2677, `KilnCMS.CMS.FieldValue.canonical/2`),
  so `#FFF` finds a stored `#ffffff` and a value stored before a retype is
  still found by its own spelling. Range operators and text matching take the
  operand as sent. An operand of a shape no operator takes — an object, or a
  list beside anything but `in` — is a 400 (#2739).

  A `datetime` operand is a wall-clock time (#2678): read as a write reads it
  (`DateTimes.cast/1`), so its UTC offset is dropped, in `custom_filter` and
  in `custom_where` alike, and its fractional seconds are kept. `eq`,
  `not_eq` and `in` match every spelling a write could have stored for it
  (`.25`, `.250`, …), and the range operators compare against the one
  spelling that orders them all (`DateTimes.bound/2`). One `custom_filter`,
  and one `custom_where`, takes at most 1000 `in` values in
  all, across its fields and groups.

  On the shared entry tier the definitions in scope depend on the dynamic
  type, which we recover from the query's own `type_definition_id`/`type_name`
  equality filter; unscoped queries fall back to *all* dynamic-type fields and
  reject names whose type differs across owners rather than guess.

  `custom_filter` also takes boolean groups (#2355): `_or` / `_and` (a list of
  conditions, or a position-keyed map) and `_not` (one condition), nesting up to
  four deep. A condition's keys are custom field names, nested groups, and
  `_native` — a map of built-in `filter[...]` conditions handed to
  `Ash.Filter.parse_input/2`, so only public fields. Every name resolves through
  the same privacy-filtered definitions as a top-level one. A `custom_sort` token
  `_native:<name>` sorts by a built-in column (#2356) so it can follow a custom
  key.

  `media`/`reference` fields filter by their snapshot's stable `id`
  (equality-shaped operators only). A **single-valued** one is also sortable
  (#2444, `Relations.sort_key/2`): the key is the target's *current* title (a
  media item's current filename), read from the target and not from the stored
  snapshot label, and it is `NULL` — last, like an unset field — where the
  caller may not read the target, so the order of unreadable targets is never
  revealed. A `multiple` one has no single key and is refused. On a `multiple` one
  (a gallery, a list of references) `eq` means "contains this id", `not_eq`
  "does not", and `in` "contains any of them".

  A `multiple` scalar field — a list of phrases, terms, numbers, dates,
  times, links, addresses, phone numbers, colors or slugs (#2289) — reads
  the same way for its items (`custom_filter[properties]=tonic`,
  `custom_filter[scores]=10`), and also takes `has` / `has_all` / `has_none`
  over values and `count` over its items; `has_none` matches a record with
  no value, `not_eq` does not. Items are cast as a single field of their
  type would be. Comparing items (`gt`…) and matching text in them are not
  supported yet, and a list is not sortable — see
  `KilnCMS.CMS.Preparations.CustomFieldQuery.Lists`. A plugin field type that
  takes lists (`c:Kiln.FieldType.multiple?/0`, #2680) reads the same way, its
  operands cast by its own `cast/2`; in `custom_where` its items take the kind
  its `graphql_kind/1` gives, and one with no such kind is `custom_filter`'s
  alone. A **held list** (`KilnCMS.CMS.FieldDefinition.held_list?/1`: its type
  no longer takes lists) is refused by every operator and by `custom_sort`
  (400), until an admin saves it as a single value.

  A
  reference also takes the
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
  these predicates unless the site declared the field in
  `config :kiln_cms, :indexed_custom_fields` (#2359, ADR 0025, which indexes
  its range operators and `custom_sort`) — otherwise promote a hot field to a
  compiled attribute when that starts to matter (D4/D17). A private field (#2044) is unknown to anyone
  below editor, here as everywhere else.
  """
  use Ash.Resource.Preparation

  import Ash.Expr

  require Ash.Sort

  alias Ash.Error.Query.InvalidArgument
  alias KilnCMS.CMS.FieldValue
  alias KilnCMS.CMS.IndexedCustomFields
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.DateTimes
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.Lists
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.Relations
  alias KilnCMS.CMS.ScalarLists

  @operators ~w(eq not_eq gt gte lt lte in ilike contains starts_with null is_nil)

  # The field types a record-level `multiple` field may hold a list of (#2289);
  # their operators are `Lists`'.
  @scalar_list_types ScalarLists.types()
  @typed_list_types ScalarLists.typed()

  # `custom_filter` groups (#2355).
  @max_group_depth 4
  @max_group_members 50
  @group_keys ~w(_or _and _not)

  # The `in` values one `custom_filter` or `custom_where` holds in all, across
  # its fields and groups (#2678). A date-time value is compared under up to
  # seven spellings, a list item under two containments each, so this keeps
  # the expanded predicate well inside Postgres' 65535 bind parameters.
  @max_in_values 1000

  # A built-in column in a `custom_sort` (#2356): `_native:title`, `-_native:title`.
  @native_sort_prefix "_native:"

  # `custom_where`: the condition's kind keys, and the operators of each.
  @kind_keys [:string, :int, :float, :boolean, :date, :date_time]
  @comparison_ops ~w(eq not_eq in gt gte lt lte is_null)
  @kind_ops %{
    string: ~w(eq not_eq in contains starts_with is_null),
    int: @comparison_ops,
    float: @comparison_ops,
    boolean: ~w(eq is_null),
    date: @comparison_ops,
    date_time: @comparison_ops
  }

  @impl true
  def prepare(query, _opts, context) do
    filter = Ash.Query.get_argument(query, :custom_filter) || %{}
    sort = Ash.Query.get_argument(query, :custom_sort) || ""
    where = Ash.Query.get_argument(query, :custom_where) || []

    if filter == %{} and sort == "" and where == [] do
      query
    else
      defs = query |> definitions() |> visible_to(query, context)

      # What the relationship operators gate targets with (`Relations`).
      ctx = %{
        resource: query.resource,
        table: AshPostgres.DataLayer.Info.table(query.resource),
        actor: Map.get(context, :actor),
        tenant: query.to_tenant || query.tenant,
        spelling: spelling(query)
      }

      query
      |> apply_filter(filter, defs, ctx)
      |> apply_where(where, defs, ctx)
      |> apply_sort(sort, defs, ctx)
    end
  end

  # How `custom_where`'s errors spell its keys (#2913): GraphQL's camelCase
  # (`dateTime`, `notEq`, `customFilter`) when the request came in over
  # GraphQL (`KilnCMSWeb.GraphqlSchema.context/1` marks it), otherwise the
  # snake_case JSON:API, MCP and the code interface take, so a caller that
  # follows the message sends a key its own surface accepts.
  defp spelling(query) do
    if query.context[:kiln_api_surface] == :graphql, do: :graphql, else: :snake
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

  # A private field (#2044) is not there for anyone below editor: filtering or
  # sorting on it would answer questions about a value they may not read, so
  # its name is an unknown field. Decided by the caller's own tier even on an
  # `authorize?: false` read — delivery reads run that way with no actor, and
  # are exactly the callers this keeps out.
  defp visible_to(defs, query, context) do
    case Map.get(context, :actor) do
      %KilnCMS.SystemActor{} ->
        defs

      actor ->
        case KilnCMS.Accounts.Scoping.effective_tier(actor, query) do
          :admin -> defs
          :editor -> reject_hidden(defs, actor, query, context)
          _below_editor -> Enum.reject(defs, &(Map.get(&1, :private) == true))
        end
    end
  end

  # An editor under a read restriction (#2281) cannot probe the private fields
  # it hides either: their names are unknown here, like a missing field.
  #
  # authorize?: false — a match on the read's own flag, not a bypass: such a
  # read is internal plumbing and keeps every definition.
  defp reject_hidden(defs, _actor, _query, %{authorize?: false}), do: defs

  defp reject_hidden(defs, actor, query, _context) do
    org_id = KilnCMS.Accounts.org_id(query.to_tenant || query.tenant)
    resource = query.resource

    # The definitions are one compiled type's, or — on the entry tier, with no
    # type named — several dynamic types'. A name hidden under any of them is
    # unknown here: a query across types would otherwise match the rows of the
    # type that hides it.
    hidden =
      defs
      |> Enum.map(&Map.get(&1, :type_definition_id))
      |> Enum.uniq()
      |> Enum.flat_map(fn
        nil ->
          scope = KilnCMS.CMS.ContentTypes.type_atom(resource)
          type = KilnCMS.CMS.ContentTypes.type_name(resource)
          KilnCMS.CMS.HiddenFields.names_for_scope(actor, org_id, scope, type)

        definition_id ->
          probe = struct(resource, type_definition_id: definition_id, org_id: org_id)
          type = KilnCMS.CMS.ContentTypes.type_name_for(probe)
          KilnCMS.CMS.HiddenFields.names_for_scope(actor, org_id, definition_id, type)
      end)

    Enum.reject(defs, &(Map.get(&1, :name) in hidden))
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
  # as every owner agrees on the value type (the SQL cast is the same) and,
  # for a typed list (#2289), on whether it is one: a list's operators are not
  # a single value's.
  #
  # A held list (#2680: its type no longer takes lists) is neither filtered nor
  # sorted, under any owner: its stored items no longer match what the type
  # casts an operand to, so any answer would be a guess.
  defp resolve(defs, name) do
    case Enum.filter(defs, &(&1.name == name)) do
      [] ->
        {:error, "unknown custom field #{inspect(name)}"}

      [definition | _] = matches ->
        held = Enum.find(matches, &KilnCMS.CMS.FieldDefinition.held_list?/1)

        cond do
          held ->
            {:error,
             "custom field #{inspect(name)} holds lists its field type (#{held.field_type}) " <>
               "no longer takes; it can't be filtered or sorted until an admin saves it as a " <>
               "single value or the plugin takes lists again"}

          matches |> Enum.map(&value_shape/1) |> Enum.uniq() |> length() == 1 ->
            {:ok, definition}

          true ->
            {:error,
             "custom field #{inspect(name)} has a different type per content type — " <>
               "scope the query with filter[type_name] (or type_definition_id)"}
        end
    end
  end

  defp value_shape(%{field_type: type} = definition) when type in @typed_list_types,
    do: {type, Map.get(definition, :multiple) == true}

  defp value_shape(%{field_type: type}), do: type

  # --- filtering ---------------------------------------------------------------

  defp apply_filter(query, filter, defs, ctx) when is_map(filter) do
    with :ok <- check_groups(filter),
         :ok <- check_in_values(filter_in_values(filter)),
         {:ok, exprs} <- filter_exprs(filter, defs, ctx) do
      Enum.reduce(exprs, query, &Ash.Query.do_filter(&2, &1))
    else
      {:error, message} -> invalid(query, :custom_filter, message)
    end
  end

  defp apply_filter(query, _filter, _defs, _ctx) do
    invalid(query, :custom_filter, "must be a map of custom field names to conditions")
  end

  # The expressions (to be ANDed) one condition map stands for: each key is a
  # custom field name, or one of the reserved group keys (#2355) — no field can
  # be named like them, since a name starts with a letter.
  defp filter_exprs(map, defs, ctx) do
    Enum.reduce_while(map, {:ok, []}, fn {name, condition}, {:ok, acc} ->
      case entry_exprs(to_string(name), condition, defs, ctx) do
        {:ok, exprs} -> {:cont, {:ok, exprs ++ acc}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp entry_exprs(group, condition, defs, ctx) when group in ~w(_or _and) do
    with {:ok, members} <- group_members(group, condition),
         {:ok, exprs} <- member_exprs(members, defs, ctx) do
      {:ok, [join_group(group, exprs)]}
    end
  end

  defp entry_exprs("_not", condition, defs, ctx) when is_map(condition) do
    with {:ok, exprs} <- filter_exprs(condition, defs, ctx) do
      {:ok, [expr(not (^and_all(exprs)))]}
    end
  end

  defp entry_exprs("_not", _condition, _defs, _ctx),
    do: {:error, "_not must hold a condition (a map of custom field names to conditions)"}

  defp entry_exprs("_native", condition, _defs, ctx), do: native_exprs(condition, ctx)

  defp entry_exprs(name, condition, defs, ctx) do
    with {:ok, target} <- resolve_target(defs, name, ctx) do
      conditions(target, condition, ctx)
    end
  end

  defp join_group("_or", exprs), do: Enum.reduce(exprs, &expr(^&2 or ^&1))
  defp join_group("_and", exprs), do: Enum.reduce(exprs, &expr(^&2 and ^&1))

  defp and_all([]), do: expr(true)
  defp and_all(exprs), do: Enum.reduce(exprs, &expr(^&2 and ^&1))

  defp member_exprs(members, defs, ctx) do
    members
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      case filter_exprs(member, defs, ctx) do
        {:ok, exprs} -> {:cont, {:ok, [and_all(exprs) | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, exprs} -> {:ok, Enum.reverse(exprs)}
      error -> error
    end
  end

  # A list of condition maps, or — as a query string spells a list — a map keyed
  # by position (`custom_filter[_or][0][price]=1`), as `Ash.Filter` reads it.
  defp group_members(group, members) when is_list(members) do
    if members != [] and Enum.all?(members, &is_map/1),
      do: {:ok, members},
      else: {:error, "#{group} must be a non-empty list of conditions"}
  end

  defp group_members(group, members) when is_map(members) and map_size(members) > 0 do
    ordered =
      Enum.map(members, fn {key, value} ->
        case Integer.parse(to_string(key)) do
          {position, ""} -> {position, value}
          _ -> :error
        end
      end)

    if :error in ordered do
      {:error, "#{group} must be a non-empty list of conditions"}
    else
      ordered
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> then(&group_members(group, &1))
    end
  end

  defp group_members(group, _members),
    do: {:error, "#{group} must be a non-empty list of conditions"}

  # Built-in columns inside a group, parsed by Ash exactly as `filter[...]` is:
  # public fields only, the same operators. A custom field is never named here.
  defp native_exprs(condition, ctx) when is_map(condition) do
    case Ash.Filter.parse_input(ctx.resource, condition) do
      {:ok, %Ash.Filter{expression: nil}} -> {:ok, []}
      {:ok, %Ash.Filter{expression: expression}} -> {:ok, [expression]}
      {:error, error} -> {:error, "invalid _native filter: " <> Exception.message(error)}
    end
  end

  defp native_exprs(_condition, _ctx),
    do: {:error, "_native must be a map of built-in field filters"}

  # Groups are bounded: they nest at most `@max_group_depth` deep and hold at
  # most `@max_group_members` members in all (a field list has no such cap).
  defp check_groups(filter), do: check_group_stats(group_stats(filter))

  defp check_group_stats({depth, members}) do
    cond do
      depth > @max_group_depth ->
        {:error, "_or / _and / _not nest at most #{@max_group_depth} deep"}

      members > @max_group_members ->
        {:error, "_or / _and hold at most #{@max_group_members} conditions in all"}

      true ->
        :ok
    end
  end

  defp group_stats(map) when is_map(map) do
    Enum.reduce(map, {0, 0}, fn
      # Atom keys too (`%{_or: […]}` from an Elixir or MCP caller): the filter
      # itself normalises keys with `to_string/1`, so the caps must as well.
      {key, value}, {depth, members} when key in [:_or, :_and, :_not] or key in ~w(_or _and _not) ->
        children =
          if is_map(value) and to_string(key) == "_not", do: [value], else: member_list(value)

        {d, m} = children |> Enum.map(&group_stats/1) |> Enum.reduce({0, 0}, &merge_stats/2)
        {max(depth, d + 1), members + length(children) + m}

      _other, acc ->
        acc
    end)
  end

  defp group_stats(_other), do: {0, 0}

  defp merge_stats({d1, m1}, {d2, m2}), do: {max(d1, d2), m1 + m2}

  defp member_list(list) when is_list(list), do: list
  defp member_list(map) when is_map(map), do: Map.values(map)
  defp member_list(_other), do: []

  # The `in` values of a whole `custom_filter` or `custom_where`, groups
  # included, are capped together (#2678): an MCP or JSON body is unbounded.
  defp check_in_values(count) when count > @max_in_values,
    do:
      {:error,
       "in takes at most #{@max_in_values} values in all, across every condition and " <>
         "group (got #{count})"}

  defp check_in_values(_count), do: :ok

  defp filter_in_values(map) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, 0, fn {key, value}, acc ->
      acc +
        case to_string(key) do
          group when group in ~w(_or _and) ->
            value |> member_list() |> Enum.map(&filter_in_values/1) |> Enum.sum()

          "_not" ->
            filter_in_values(value)

          "_native" ->
            0

          _field ->
            operand_in_values(value)
        end
    end)
  end

  defp filter_in_values(_other), do: 0

  # The `in` operand among one field's operators (or one `customWhere` kind's).
  defp operand_in_values(condition) when is_map(condition) and not is_struct(condition) do
    Enum.reduce(condition, 0, fn {op, value}, acc ->
      if to_string(op) == "in", do: acc + length(List.wrap(value)), else: acc
    end)
  end

  defp operand_in_values(_condition), do: 0

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

  # A list of scalars (#2289) takes the membership operators, `has*` and
  # `count` included; `null` is the same question as on any field.
  defp relation_or_condition(%{field_type: type, multiple: true} = definition, op, raw, _ctx)
       when type in @scalar_list_types do
    case normalize_op(op) do
      "null" -> condition(definition, "null", raw)
      op -> Lists.condition(definition, op, raw)
    end
  end

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

  # `:index_table` tells the range operators which table's declared indexes
  # apply (#2359); it rides on the definition because `condition/3` has no ctx.
  defp relation_or_condition(definition, op, raw, ctx),
    do: condition(Map.put(definition, :index_table, ctx.table), normalize_op(op), raw)

  # `is_nil` is the native `filter[x][is_nil]` spelling of `null`, accepted so
  # the same predicate reads the same on a custom field (#2292). Resolved
  # before the operator guards, so every clause below sees `null` only.
  defp normalize_op("is_nil"), do: "null"
  defp normalize_op(op), do: op

  defp link_conditions(parent, link, condition, ctx, targets) do
    label = "#{parent.name}.link.#{link.name}"

    Enum.reduce_while(condition, {:ok, []}, fn {op, raw}, {:ok, acc} ->
      case link_condition(link, normalize_op(op), raw, label) do
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

  defp link_condition(_link, op, _raw, label) when op in ~w(contains starts_with),
    do: {:error, "#{op} is not supported on link fields (#{inspect(label)})"}

  # The shapes no link operator takes (#2739), as on a field: an object, and a
  # list beside any operator but `in`.
  defp link_condition(_link, op, raw, label)
       when (is_map(raw) and not is_struct(raw)) or (is_list(raw) and op not in ~w(in null)),
       do: operand_shape(raw, op, "link field #{inspect(label)}")

  defp link_condition(%{name: name}, "null", raw, label) do
    path = expr(get_path(metadata, [^name]))

    case raw do
      t when t in [true, "true", "1"] -> {:ok, expr(is_nil(^path))}
      f when f in [false, "false", "0"] -> {:ok, expr(not is_nil(^path))}
      _ -> {:error, "null for link field #{inspect(label)} must be true or false"}
    end
  end

  defp link_condition(%{name: name} = link, "in", raw, label) do
    cast_list(
      raw,
      ash_type(link),
      label,
      fn
        [] ->
          expr(false)

        values ->
          values
          |> equal_values(raw, link)
          |> Enum.map(&jsonb_condition(:metadata, "eq", name, &1))
          |> Enum.reduce(&expr(^&2 or ^&1))
      end,
      "link field #{inspect(label)}"
    )
  end

  defp link_condition(%{name: name} = link, "ilike", raw, label) do
    if ash_type(link) do
      {:error, "ilike is only supported on text-like link fields (#{inspect(label)})"}
    else
      with {:ok, pattern} <- cast_value(raw, nil, label) do
        {:ok, expr(ilike(get_path(metadata, [^name]), ^pattern))}
      end
    end
  end

  defp link_condition(%{name: name} = link, op, raw, label) when op in ~w(eq not_eq) do
    with {:ok, value} <- cast_value(raw, ash_type(link), label) do
      {:ok, equality(op, [value], [raw], link, &jsonb_condition(:metadata, op, name, &1))}
    end
  end

  defp link_condition(%{name: name} = link, op, raw, label) do
    with {:ok, value} <- cast_value(raw, ash_type(link), label) do
      {:ok, jsonb_condition(:metadata, op, name, range_operand(link, op, value))}
    end
  end

  defp condition(%{name: name}, op, _raw) when op not in @operators do
    {:error, "unknown operator #{inspect(op)} for custom field #{inspect(name)}"}
  end

  # `custom_filter[name][eq][x]=1` parses to a map operand. No operator takes
  # one, and the clauses below `to_string/1` theirs — a raise, so a 500, on a
  # public read. Lists are refused below, after `null` and the composite types.
  # Not a struct: GraphQL hands a date operand over as a `%Date{}`.
  defp condition(%{name: name}, op, raw) when is_map(raw) and not is_struct(raw),
    do: operand_shape(raw, op, "custom field #{inspect(name)}")

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

  # A JSON field (#2278) holds an arbitrary object or array, so there is no
  # scalar to compare either: `null` above is the one question it answers.
  defp condition(%{field_type: :json, name: name}, _op, _raw),
    do: {:error, "custom field #{inspect(name)} (json) only supports null"}

  # A range, key/value list, link or address (#2278, #2279) is a composite
  # value with no scalar to compare, so `null` above is the one question it
  # answers.
  defp condition(%{field_type: type, name: name}, _op, _raw)
       when type in [:range, :key_value, :link, :address],
       do: {:error, "custom field #{inspect(name)} (#{type}) only supports null"}

  # A group is an object or a list of them, for the same reason: `null` above
  # is the one question its value answers as a whole.
  defp condition(%{field_type: type, name: name}, _op, _raw) when type in [:group, :flexible],
    do: {:error, "custom field #{inspect(name)} (#{type}) only supports null"}

  # A list is `in`'s operand only (#2739): beside `ilike` it was joined into
  # one pattern, beside a media id into one id.
  defp condition(%{name: name}, op, raw) when is_list(raw) and op != "in",
    do: operand_shape(raw, op, "custom field #{inspect(name)}")

  # A gallery (`multiple` media) or a list of references (`multiple`
  # reference) holds a list of snapshots, so `eq` asks whether the list
  # *contains* the id, `not_eq` whether it does not, and `in` whether it
  # contains any of them — jsonb containment against a one-snapshot array. The
  # probe is bound as text and cast in SQL: bound as `::jsonb` directly,
  # Postgrex would encode the JSON string as a JSON string.
  defp condition(%{field_type: type, multiple: true, name: name}, op, raw)
       when type in [:media, :reference] do
    probe = fn id -> Jason.encode!([%{"id" => id}]) end
    contains = fn id -> list_contains(name, probe.(id)) end

    case op do
      "eq" ->
        with {:ok, id} <- cast_value(raw, nil, name), do: {:ok, contains.(id)}

      "not_eq" ->
        with {:ok, id} <- cast_value(raw, nil, name),
             do: {:ok, expr(not (^absent_safe_contains(name, probe.(id))))}

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
      "eq" ->
        with {:ok, id} <- cast_value(raw, nil, name), do: {:ok, snapshot_id(name, id)}

      "not_eq" ->
        with {:ok, id} <- cast_value(raw, nil, name), do: {:ok, expr(^field != ^id)}

      "in" ->
        cast_list(raw, nil, name, fn
          [] -> expr(false)
          values -> values |> Enum.map(&snapshot_id(name, &1)) |> Enum.reduce(&expr(^&2 or ^&1))
        end)

      _ ->
        {:error, "custom field #{inspect(name)} (#{type}) only supports eq/not_eq/in/null"}
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
        |> equal_values(raw, definition)
        |> Enum.map(&jsonb_condition(:custom_fields, "eq", name, &1))
        |> Enum.reduce(&expr(^&2 or ^&1))
    end)
  end

  defp condition(%{name: name} = definition, op, raw) when op in ~w(contains starts_with) do
    if ash_type(definition) do
      {:error, "#{op} is only supported on text-like custom fields (#{inspect(name)})"}
    else
      with {:ok, text} <- cast_value(raw, nil, name) do
        {:ok, text_match(name, op, text)}
      end
    end
  end

  defp condition(%{name: name} = definition, "ilike", raw) do
    if ash_type(definition) do
      {:error, "ilike is only supported on text-like custom fields (#{inspect(name)})"}
    else
      with {:ok, pattern} <- cast_value(raw, nil, name) do
        {:ok, expr(ilike(get_path(custom_fields, [^name]), ^pattern))}
      end
    end
  end

  defp condition(%{name: name} = definition, op, raw) when op in ~w(eq not_eq) do
    with {:ok, value} <- cast_value(raw, ash_type(definition), name) do
      {:ok,
       equality(op, [value], [raw], definition, &jsonb_condition(:custom_fields, op, name, &1))}
    end
  end

  # The range operators compare the operand as sent (cast, never tidied): a
  # time's tidy drops its seconds, and an email's or a slug's would move it in
  # the order.
  defp condition(%{name: name} = definition, op, raw) do
    with {:ok, value} <- cast_value(raw, ash_type(definition), name) do
      value = range_operand(definition, op, value)
      {:ok, jsonb_condition(:custom_fields, op, name, value, Map.get(definition, :index_table))}
    end
  end

  # A date-time's range operand is the one stored spelling that orders every
  # other spelling correctly (#2678, `DateTimes.bound/2`).
  defp range_operand(%{field_type: :datetime}, op, %NaiveDateTime{} = value),
    do: DateTimes.bound(op, value)

  defp range_operand(_definition, _op, value), do: value

  # --- equality operands (#2677) -------------------------------------------------

  # `eq` / `not_eq` over every spelling of the operand: `eq` matches any of
  # them, `not_eq` none (an absent value still drops out of each `!=`).
  defp equality(op, values, raws, definition, compare) do
    join = if op == "eq", do: &expr(^&2 or ^&1), else: &expr(^&2 and ^&1)

    values
    |> equal_values(raws, definition)
    |> Enum.map(compare)
    |> Enum.reduce(join)
  end

  # The values an equality operand matches (#2677): each cast as sent — so a
  # value stored before the field was retyped (a `:string` holding `"#FFF"`,
  # now a color) is still found by its own spelling — and, where it differs,
  # as a write would have stored it (`FieldValue.canonical/2`): `#FFF` finds a
  # stored `#ffffff`, a select's label its option's value. `values` are the
  # cast operands of `raws`, item for item. A date-time matches every text a
  # write could have stored for it (#2678, `DateTimes.spellings/1`).
  defp equal_values(values, _raws, %{field_type: :datetime}),
    do: values |> Enum.flat_map(&DateTimes.spellings/1) |> Enum.uniq()

  defp equal_values(values, raws, definition) do
    values
    |> Enum.zip(List.wrap(raws))
    |> Enum.flat_map(fn {value, raw} ->
      case FieldValue.canonical(definition, raw) do
        {:ok, canonical} when canonical != value -> [value, canonical]
        _same_or_none -> [value]
      end
    end)
    |> Enum.uniq()
  end

  # Case-insensitive substring / prefix match on the field's text. The operand is
  # text, not a pattern: `\`, `%` and `_` are escaped before the wildcard goes on.
  defp text_match(name, op, text) do
    escaped = String.replace(text, ["\\", "%", "_"], &("\\" <> &1))
    pattern = if op == "contains", do: "%" <> escaped <> "%", else: escaped <> "%"

    expr(fragment("(? ->> ?::text) ILIKE ? ESCAPE '\\'", ^ref(:custom_fields), ^name, ^pattern))
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
  defp jsonb_condition(column, op, name, raw_value, table \\ nil) do
    field = comparison_field(column, op, name, table)
    value = expr(fragment("?::jsonb", ^raw_value))

    case op do
      "eq" when column == :custom_fields -> contains(column, name, raw_value)
      "eq" -> expr(^field == ^value)
      "not_eq" -> expr(^field != ^value)
      "gt" -> expr(^field > ^value)
      "gte" -> expr(^field >= ^value)
      "lt" -> expr(^field < ^value)
      "lte" -> expr(^field <= ^value)
    end
  end

  # A range operator compares the CASE expression the indexes are built on
  # (#2359), so a stored JSON null, array or object never matches, indexed or
  # not. A field the site declared in `:indexed_custom_fields` gets its name
  # inlined as a literal (a bound name defeats the btree under a generic plan);
  # any other keeps a bound name.
  defp comparison_field(:custom_fields, op, name, table) when op in ~w(gt gte lt lte),
    do: range_field(name, table)

  defp comparison_field(column, _op, name, _table),
    do: expr(fragment("(? -> ?::text)", ^ref(column), ^name))

  # `name` passed `IndexedCustomFields.valid?/2` where inlined: a configured,
  # pattern-checked field name, so it cannot carry SQL.
  defp range_field(name, table) do
    column = ref(:custom_fields)

    args =
      if IndexedCustomFields.valid?(table, name),
        do: [IndexedCustomFields.sort_sql(name), column, column],
        else: [IndexedCustomFields.bound_sql(), column, name, column, name]

    # `fragment/2` only takes a compile-time string; the SQL here is built from
    # a configured, pattern-checked name (or none), so it is built directly.
    {:ok, fragment} = Ash.Query.Function.Fragment.new(args)
    fragment
  end

  # --- containment (index-matchable equality) ---------------------------------

  @doc """
  Equality on one custom field as **containment**: `custom_fields @>
  jsonb_build_object(name, value)`, an `Ash.Expr` over the `column` (an atom).

  Unlike `(custom_fields -> name) = value`, a `@>` against a bound `jsonb`
  parameter can use a GIN index on the column under any plan (#2291), and one
  index covers every field name because the name sits inside the indexed
  value. `value` is the already-cast Elixir term (see `ash_type/1`); it is
  JSON-encoded by the `::jsonb` bind, so `10` matches a JSON number and `"10"`
  a JSON string.

  It selects the same rows as `(column -> name) = value::jsonb` for a scalar
  `value`: containment's "an array contains a scalar" shortcut applies only
  at the top level, never to a value nested under `name`. Only the positive
  match is rewritten. A negation (`not_eq`) must keep the old `->` form: an
  absent key is `NULL` there and is excluded, where `NOT (column @> ...)`
  would include it.
  """
  def contains(column, name, value) when is_atom(column) and is_binary(name) do
    expr(
      fragment(
        "? @> jsonb_build_object(?::text, ?::jsonb)",
        ^ref(column),
        ^name,
        ^value
      )
    )
  end

  @doc """
  The Ash type a custom field's *input* is cast with before being JSON-encoded
  into a predicate, by `FieldDefinition` field type: `:integer`, `:float`,
  `:boolean`, `:date`, `:naive_datetime` (datetimes are stored offset-less
  ISO-8601, see `ApplyCustomFields`), `:dynamic` for a `:computed` field (the
  formula decides, so the supplied value's own JSON type is kept), and `nil`
  for text-like and plugin-contributed types ("treat as text").
  """
  def ash_type(%{field_type: :integer}), do: :integer
  def ash_type(%{field_type: :float}), do: :float
  def ash_type(%{field_type: :boolean}), do: :boolean
  def ash_type(%{field_type: :date}), do: :date
  def ash_type(%{field_type: :datetime}), do: :naive_datetime
  # A `:computed` field (#429) has no static type — its formula decides, so
  # `{{ word_count(body) }}` stores a JSON number while `{{ slugify(title) }}`
  # stores a JSON string. Infer from the supplied predicate instead: text-casting
  # a number would compare a JSON string against a JSON number, which doesn't
  # merely miss — jsonb orders Number below String, so a range predicate
  # silently matches every row or none.
  def ash_type(%{field_type: :computed}), do: :dynamic
  def ash_type(_definition), do: nil

  # A list-valued field (`multiple` select/string/media/reference) holds the
  # probe: `custom_fields @> {name: [probe...]}`. Bound as text and cast in
  # SQL — bound as `::jsonb` directly, Postgrex would encode the JSON string
  # as a JSON string.
  defp list_contains(name, probe) do
    expr(
      fragment(
        "? @> jsonb_build_object(?::text, ?::text::jsonb)",
        ^ref(:custom_fields),
        ^name,
        ^probe
      )
    )
  end

  # The old `->` form, kept for negation: an absent key is NULL and drops out
  # of `NOT (...)` instead of matching it.
  defp absent_safe_contains(name, probe) do
    expr(fragment("(? -> ?::text) @> ?::text::jsonb", ^ref(:custom_fields), ^name, ^probe))
  end

  # A single media/reference field matched by its snapshot's stable id (text).
  defp snapshot_id(name, id) do
    expr(
      fragment(
        "? @> jsonb_build_object(?::text, jsonb_build_object('id', ?::text))",
        ^ref(:custom_fields),
        ^name,
        ^id
      )
    )
  end

  # --- typed conditions (`custom_where`) -----------------------------------------

  defp apply_where(query, where, defs, ctx) when is_list(where) do
    max = KilnCMSWeb.GraphqlLimits.max_custom_conditions()

    with :ok <- check_where_size(where, max),
         :ok <- check_group_stats(where_stats(where)),
         :ok <- check_in_values(where_in_values(where)),
         {:ok, exprs} <- where_exprs(where, defs, ctx) do
      Enum.reduce(exprs, query, &Ash.Query.do_filter(&2, &1))
    else
      {:error, message} -> invalid(query, :custom_where, message)
    end
  end

  defp apply_where(query, _where, _defs, _ctx),
    do: invalid(query, :custom_where, "must be a list of conditions")

  defp check_where_size(where, max) do
    if length(where) > max,
      do: {:error, "at most #{max} conditions are allowed"},
      else: :ok
  end

  defp where_exprs(nodes, defs, ctx) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case where_node(node, defs, ctx) do
        {:ok, exprs} -> {:cont, {:ok, acc ++ exprs}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  # One element of `customWhere`: a leaf condition on one custom field, or —
  # as `customFilter`'s `_or` / `_and` / `_not` (#2355, #2445) — a group of
  # such elements, nested within `@max_group_depth`.
  defp where_node(raw, defs, ctx) when is_map(raw) do
    node = Map.new(raw, fn {key, value} -> {to_string(key), value} end)

    case Enum.filter(@group_keys, &(node[&1] != nil)) do
      [] ->
        where_leaf(raw, defs, ctx)

      [group] ->
        where_group(group, node, defs, ctx)

      groups ->
        {:error, "a condition takes one of #{group_list()}, got #{Enum.join(groups, ", ")}"}
    end
  end

  defp where_node(_raw, _defs, _ctx), do: {:error, "every condition must be an object"}

  defp where_group(group, node, defs, ctx) do
    others = Map.keys(node) -- [group]
    stray = Enum.find(others, &(node[&1] != nil))

    cond do
      stray != nil ->
        {:error, "#{group} cannot be combined with #{inspect(stray)} in one condition"}

      group == "_not" and is_map(node[group]) ->
        with {:ok, exprs} <- where_node(node[group], defs, ctx) do
          {:ok, [expr(not (^and_all(exprs)))]}
        end

      group == "_not" ->
        {:error, "_not must hold one condition"}

      true ->
        with {:ok, members} <- group_members(group, node[group]),
             {:ok, exprs} <- member_nodes(members, defs, ctx) do
          {:ok, [join_group(group, exprs)]}
        end
    end
  end

  defp member_nodes(members, defs, ctx) do
    members
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      case where_node(member, defs, ctx) do
        {:ok, exprs} -> {:cont, {:ok, [and_all(exprs) | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, exprs} -> {:ok, Enum.reverse(exprs)}
      error -> error
    end
  end

  # Depth and member counts of a `customWhere` list, counted as `group_stats/1`
  # counts a `customFilter` map so the two share one pair of caps.
  defp where_stats(nodes) when is_list(nodes) do
    nodes |> Enum.map(&node_stats/1) |> Enum.reduce({0, 0}, &merge_stats/2)
  end

  defp node_stats(node) when is_map(node) do
    Enum.reduce(node, {0, 0}, fn {key, value}, acc ->
      merge_stats(acc, group_stat(to_string(key), value))
    end)
  end

  defp node_stats(_node), do: {0, 0}

  defp group_stat(group, value) when group in @group_keys and value != nil do
    children = if is_map(value) and group == "_not", do: [value], else: member_list(value)
    {depth, members} = where_stats(children)
    {depth + 1, length(children) + members}
  end

  defp group_stat(_key, _value), do: {0, 0}

  # The `in` values of a `customWhere` list, counted under `custom_filter`'s cap.
  defp where_in_values(nodes) when is_list(nodes),
    do: nodes |> Enum.map(&node_in_values/1) |> Enum.sum()

  defp where_in_values(_nodes), do: 0

  defp node_in_values(node) when is_map(node) do
    Enum.reduce(node, 0, fn {key, value}, acc ->
      acc +
        case to_string(key) do
          group when group in ~w(_or _and) -> value |> member_list() |> where_in_values()
          "_not" -> node_in_values(value)
          "name" -> 0
          _kind -> operand_in_values(value)
        end
    end)
  end

  defp node_in_values(_node), do: 0

  # The same `resolve/2` as `custom_filter`, over the same already
  # privacy-filtered `defs`: a missing and a private field answer alike.
  defp where_leaf(raw, defs, ctx) do
    spelling = ctx.spelling

    with {:ok, name, kind, ops} <- parse_condition(raw, spelling),
         {:ok, definition} <- resolve(defs, name),
         :ok <- check_kind(definition, kind, ops, spelling),
         {:ok, filter} <- translate_ops(kind, ops, name, spelling) do
      conditions(definition, filter, ctx)
    end
  end

  # `{:ok, name, kind, ops}`: exactly one kind key, its operators (string keys,
  # nil operands dropped, as GraphQL gives an explicit `null`).
  defp parse_condition(raw, spelling) when is_map(raw) do
    raw = Map.new(raw, fn {key, value} -> {to_string(key), value} end)
    kind_names = Enum.map(@kind_keys, &Atom.to_string/1)
    unknown = Map.keys(raw) -- ["name" | kind_names ++ @group_keys]
    given = Enum.filter(kind_names, &(raw[&1] != nil))
    name = raw["name"]

    cond do
      not is_binary(name) or name == "" ->
        {:error, "every condition needs a name"}

      unknown != [] ->
        {:error, "unknown key #{inspect(hd(unknown))} in the condition on #{inspect(name)}"}

      length(given) != 1 ->
        {:error,
         "the condition on #{inspect(name)} needs exactly one of #{kind_list(spelling)}, " <>
           "got #{if given == [], do: "none", else: Enum.map_join(given, ", ", &spell(&1, spelling))}"}

      true ->
        [key] = given
        operators(name, String.to_existing_atom(key), raw[key], spelling)
    end
  end

  defp operators(name, kind, ops, _spelling) when is_map(ops) do
    ops =
      ops
      |> Map.new(fn {op, value} -> {to_string(op), value} end)
      |> Map.reject(fn {_op, value} -> is_nil(value) end)

    if ops == %{},
      do: {:error, "the condition on #{inspect(name)} needs at least one operator"},
      else: {:ok, name, kind, ops}
  end

  defp operators(name, kind, _ops, spelling),
    do: {:error, "the #{spell(kind, spelling)} condition on #{inspect(name)} must be an object"}

  defp group_list, do: Enum.join(@group_keys, ", ")

  defp kind_list(spelling), do: Enum.map_join(@kind_keys, ", ", &spell(&1, spelling))

  # A key as the surface that received the request spells it (`spelling/1`).
  defp spell(key, :graphql), do: key |> to_string() |> Macro.camelize() |> lcfirst()
  defp spell(key, :snake), do: to_string(key)

  defp lcfirst(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest

  # "an int". GraphQL keeps the "a int" its clients may already match on.
  defp a(word, :graphql), do: "a " <> word
  defp a("int", :snake), do: "an int"
  defp a(word, :snake), do: "a " <> word

  # The kind given must be the field's own. A `multiple` field is a `:list`;
  # a list of scalars (#2289) takes the kind of its items, with the list's
  # meaning — `eq` contains, `not_eq` does not contain, `in` contains any —
  # and `isNull`. Its other operators (`has*`, `count`) are `customFilter`'s.
  defp check_kind(definition, kind, ops, spelling) do
    actual = KilnCMS.CMS.FieldKind.kind_for(definition)
    given = if kind == :date_time, do: :datetime, else: kind
    name = definition.name

    cond do
      actual == given ->
        :ok

      actual == :list and definition.field_type in @scalar_list_types ->
        list_kind(definition, kind, given, ops, spelling)

      actual in [:string, :int, :float, :boolean, :date, :datetime] ->
        actual = spell(actual_key(actual), spelling)

        {:error,
         "custom field #{inspect(name)} is #{a(actual, spelling)} field, " <>
           "not #{spell(kind, spelling)}; use the #{actual} condition"}

      true ->
        {:error,
         "custom field #{inspect(name)} has kind #{actual}, which " <>
           "#{spell(:custom_where, spelling)} does not support; " <>
           "use #{spell(:custom_filter, spelling)}"}
    end
  end

  defp list_kind(definition, kind, given, ops, spelling) do
    item = KilnCMS.CMS.FieldKind.item_kind_for(definition)
    name = definition.name

    cond do
      # A plugin type with no `graphql_kind/1` (#2680) has no typed condition.
      item == :json ->
        {:error,
         "custom field #{inspect(name)}: #{spell(:custom_where, spelling)} does not support " <>
           "a list of json values; use #{spell(:custom_filter, spelling)}"}

      item != given ->
        item = spell(actual_key(item), spelling)

        {:error,
         "custom field #{inspect(name)} is a list of #{item} values, " <>
           "not #{spell(kind, spelling)}; use the #{item} condition"}

      Map.keys(ops) -- ~w(eq not_eq in is_null) != [] ->
        {:error,
         "custom field #{inspect(name)} is a list: #{spell(:custom_where, spelling)} " <>
           "supports only eq, #{spell(:not_eq, spelling)}, in and #{spell(:is_null, spelling)} " <>
           "on it (#{spell(:custom_filter, spelling)} also takes has, has_all, has_none and count)"}

      true ->
        :ok
    end
  end

  defp actual_key(:datetime), do: :date_time
  defp actual_key(kind), do: kind

  # `custom_filter`'s own shape: `%{operator => operand}` with operands in the
  # types `cast_value/3` takes.
  defp translate_ops(kind, ops, name, spelling) do
    allowed = Map.fetch!(@kind_ops, kind)

    error =
      Enum.find_value(ops, fn {op, value} ->
        case check_operator(op, value, allowed, kind, name, spelling) do
          :ok -> nil
          {:error, _message} = error -> error
        end
      end)

    error ||
      {:ok,
       Map.new(ops, fn {op, value} ->
         {if(op == "is_null", do: "null", else: op), operand(value)}
       end)}
  end

  defp check_operator(op, value, allowed, kind, name, spelling) do
    max_in = KilnCMSWeb.GraphqlLimits.max_custom_in_values()

    cond do
      op not in allowed ->
        {:error,
         "unknown operator #{inspect(op)} for #{a(spell(kind, spelling), spelling)} condition " <>
           "on #{inspect(name)} " <>
           "(#{Enum.join(allowed, ", ")})"}

      op == "in" and not is_list(value) ->
        {:error, "in on #{inspect(name)} must be a list"}

      op == "in" and length(value) > max_in ->
        {:error, "in on #{inspect(name)} takes at most #{max_in} values"}

      true ->
        :ok
    end
  end

  # A date-time operand is cast as `custom_filter`'s are (`DateTimes.cast/1`):
  # its offset is dropped, as a write drops it (#2678).
  defp operand(values) when is_list(values), do: Enum.map(values, &operand/1)
  defp operand(value), do: value

  # --- sorting -----------------------------------------------------------------

  defp apply_sort(query, sort, defs, ctx) when is_binary(sort) do
    sort
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce(query, fn token, query ->
      {direction, name} =
        case token do
          "-" <> name -> {:desc_nils_last, name}
          name -> {:asc_nils_last, name}
        end

      case name do
        @native_sort_prefix <> builtin -> native_sort(query, builtin, direction)
        _ -> custom_sort(query, name, direction, defs, ctx)
      end
    end)
  end

  defp apply_sort(query, _sort, _defs, _ctx) do
    invalid(query, :custom_sort, "must be a comma-separated string of custom field names")
  end

  defp custom_sort(query, name, direction, defs, ctx) do
    case resolve(defs, name) do
      # A single reference or media field sorts by its target's current
      # title / filename, `NULL` where the caller cannot read the target
      # (#2444, `Relations.sort_key/2`). The stored snapshot's label is not
      # the key: it lags a rename and would order unreadable targets.
      {:ok, %{field_type: type, multiple: multiple} = definition}
      when type in [:reference, :media] and multiple != true ->
        target_sort(query, definition, direction, ctx)

      {:ok, %{field_type: type}} when type in [:reference, :media] ->
        invalid(
          query,
          :custom_sort,
          "custom field #{inspect(name)} (#{type}) holds a list and is not sortable: " <>
            "a list has no single key; sort by a single-valued field or a built-in"
        )

      # Composite values are jsonb objects. Sorting them orders by key count
      # then key/value text, which is meaningless for a coordinate or a
      # snapshot — refuse rather than return a 200 in nonsense order.
      {:ok, %{field_type: type}}
      when type in [:geolocation, :group, :flexible, :json, :range, :key_value, :link, :address] ->
        invalid(query, :custom_sort, "custom field #{inspect(name)} (#{type}) is not sortable")

      {:ok, %{field_type: type, multiple: true}} when type in @scalar_list_types ->
        invalid(query, :custom_sort, "custom field #{inspect(name)} (a list) is not sortable")

      {:ok, definition} ->
        Ash.Query.sort(query, [{sort_expr(definition, table_of(query)), direction}])

      {:error, message} ->
        invalid(query, :custom_sort, message)
    end
  end

  defp target_sort(query, definition, direction, ctx) do
    case Relations.sort_key(definition, ctx) do
      {:ok, key} -> Ash.Query.sort(query, [{Ash.Sort.expr_sort(^key), direction}])
      {:error, message} -> invalid(query, :custom_sort, message)
    end
  end

  # A built-in column inside a mixed order (#2356): `_native:title` sorts by the
  # public attribute, calculation or aggregate, parsed by Ash as `sort=` is, so
  # it keeps its place among the custom tokens.
  defp native_sort(query, name, direction) do
    statement = if direction == :desc_nils_last, do: "-" <> name, else: name

    case Ash.Sort.parse_input(query.resource, statement) do
      {:ok, sort} ->
        Ash.Query.sort(query, sort)

      {:error, error} ->
        invalid(
          query,
          :custom_sort,
          "cannot sort by #{inspect(name)}: " <> Exception.message(error)
        )
    end
  end

  # --- typed expressions --------------------------------------------------------

  # Sort by the jsonb value for the same reason `jsonb_condition` compares by
  # it: numbers order numerically, ISO strings lexically, and a row carrying
  # an off-type value reorders instead of raising.
  #
  # A stored JSON `null`, an array and an object read as *no value* (SQL
  # NULL, so last in either direction), like a missing key. They are not
  # SQL NULL as jsonb, so left alone a `null` would sort FIRST (jsonb orders
  # null lowest), and an array/object cursor value cannot be bound back into
  # the keyset filter (`jsonb > integer[]`), which fails the page-2 read.
  # Neither is a value a field of a sortable type holds unless it was retyped.
  #
  # Typed `JsonbSortKey` so the keyset filter compares in jsonb too (#3272).
  defp sort_expr(%{name: name}, table) do
    if IndexedCustomFields.valid?(table, name) do
      # The expression a declared btree is built on (#2359), name inlined.
      Ash.Sort.expr_sort(^range_field(name, table), KilnCMS.CMS.Types.JsonbSortKey)
    else
      bound_sort_expr(name)
    end
  end

  defp table_of(query), do: AshPostgres.DataLayer.Info.table(query.resource)

  defp bound_sort_expr(name) do
    Ash.Sort.expr_sort(
      fragment(
        "(CASE WHEN jsonb_typeof(? -> ?::text) IN ('null', 'array', 'object') THEN NULL ELSE (? -> ?::text) END)",
        ^ref(:custom_fields),
        ^name,
        ^ref(:custom_fields),
        ^name
      ),
      KilnCMS.CMS.Types.JsonbSortKey
    )
  end

  # --- value casting -------------------------------------------------------------

  # Preserve the caller's JSON-native type so the encoded predicate matches how
  # the value is actually stored. Public for the items of a scalar list
  # (`Lists`), which cast as a single field of their type does.
  @doc false
  def cast_value(raw, :dynamic, _name) when is_number(raw) or is_boolean(raw), do: {:ok, raw}

  def cast_value(raw, :dynamic, name) when is_binary(raw) do
    # `Kiln.FieldType.parse_float/1` — `Float.parse/1` raises on an overflow
    # literal under Elixir 1.19 (total only from 1.20), and this value comes
    # straight off a query string.
    case {Integer.parse(raw), Kiln.FieldType.parse_float(raw)} do
      {{integer, ""}, _} -> {:ok, integer}
      {_, {float, ""}} -> {:ok, float}
      _ -> cast_value(raw, nil, name)
    end
  end

  def cast_value(raw, :dynamic, name), do: cast_value(raw, nil, name)

  def cast_value(raw, nil, name) do
    if is_binary(raw) or is_number(raw) or is_boolean(raw) do
      {:ok, to_string(raw)}
    else
      {:error, "invalid value for custom field #{inspect(name)}"}
    end
  end

  # A date-time is read as a write reads it (#2678): the offset dropped, the
  # fractional seconds kept. Ecto's `:naive_datetime` cast truncates them.
  def cast_value(raw, :naive_datetime, name) do
    case DateTimes.cast(raw) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         "invalid naive_datetime value for custom field #{inspect(name)}: #{inspect(raw)}"}
    end
  end

  def cast_value(raw, type, name) do
    case Ash.Type.cast_input(type, raw) do
      {:ok, value} when not is_nil(value) ->
        {:ok, value}

      _ ->
        {:error, "invalid #{type} value for custom field #{inspect(name)}: #{inspect(raw)}"}
    end
  end

  @doc false
  # The error for an operand of a shape no operator takes it in (#2739): an
  # object (`custom_filter[x][eq][y]=1`, or JSON from GraphQL `customFilter` or
  # MCP), or a list where one value goes. `subject` names the field ("custom
  # field \"x\"", "link field \"a.link.b\""). Not a struct: GraphQL hands a
  # date operand over as a `%Date{}`. Shared with `Lists`.
  @spec operand_shape(term(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def operand_shape(raw, op, subject) when is_map(raw) and not is_struct(raw),
    do: {:error, "#{op} on #{subject} takes a value, not a nested filter"}

  def operand_shape(raw, op, subject) when is_list(raw),
    do: {:error, "#{op} on #{subject} takes one value, not a list"}

  def operand_shape(_raw, _op, _subject), do: :ok

  # `in`'s items are each one value: an object or a list among them is refused
  # before the cast (an Ecto date cast takes a `%{"year" => …}` map).
  # `subject` names the field in a shape error: "custom field …" by default, a
  # link's caller passes "link field …" so its errors read like the link's
  # other operators.
  defp cast_list(raw, type, name, build, subject \\ nil) do
    raw = List.wrap(raw)
    subject = subject || "custom field #{inspect(name)}"

    raw
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      with :ok <- operand_shape(item, "in", subject),
           {:ok, value} <- cast_value(item, type, name) do
        {:cont, {:ok, [value | acc]}}
      else
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
