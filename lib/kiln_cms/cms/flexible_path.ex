defmodule KilnCMS.CMS.FlexiblePath do
  @moduledoc """
  Where the values of a flexible field's item tree live (#2282,
  `docs/flexible-content-plan.md` section 8), and the SQL that reaches them.

  A flexible field (`sections`) stores a list of items under its key of
  `custom_fields`; an item is an object keyed by its sub-fields, tagged with
  its `_type`; an item's sub-field may itself be a flexible field, down to
  `FieldDefinition.max_flexible_depth/0` levels:

      custom_fields -> sections [ {_type: hero, headline, rows [ {_type: row, ...} ]} ]

  A definition in that tree (an item type, or a sub-field of one) therefore
  reaches its values through a **path** of `{field, item_type}` steps from the
  top-level flexible field of a content type or dynamic type:
  `[{"sections", "hero"}, {"rows", "row"}]`. Item type names are unique only
  within one flexible field, so every statement here is qualified by the whole
  path — a name is never matched by position-blind descent (`$.**`).

  `item_path/2` finds the path by walking `flex_of_id` and `group_of_id`
  upward. `update_sql/4` builds the one statement that rewrites every item the
  path reaches, and `items_exist?/2` asks whether any such item exists.

  All names and values reach the database as bound parameters; the only
  interpolations are the table name (a resource's own `postgres do table`) and
  the `$n` placeholders this module generates.
  """

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.Validations.FlexibleField

  @typedoc "`{flexible field name, item type name}`, outermost first."
  @type steps :: [{String.t(), String.t()}]

  @doc """
  The path to the items of `item_type` (a row with `flex_of_id`): the
  top-level flexible field that owns the tree, and the steps from it down to
  that item type. `:error` when a link of the chain no longer resolves (the
  owner went first and took its rows with it) or is deeper than the cap.
  """
  @spec item_path(map(), term()) :: {:ok, FieldDefinition.t(), steps()} | :error
  def item_path(item_type, tenant) do
    case item_path_detailed(item_type, tenant) do
      {:ok, _top, _steps} = found -> found
      {:error, _reason} -> :error
    end
  end

  @doc """
  `item_path/2` with the reason it failed: `:gone` (a link of the chain no
  longer resolves, so the owner took its rows with it), `:too_deep` (past the
  depth cap) or `:unreadable` (the registry read itself failed).
  """
  @spec item_path_detailed(map(), term()) ::
          {:ok, FieldDefinition.t(), steps()} | {:error, :gone | :too_deep | :unreadable}
  def item_path_detailed(item_type, tenant), do: climb(item_type, tenant, [], 0)

  # One level per flexible field: past the cap the chain is malformed, and the
  # walk gives up rather than loop.
  defp climb(%{flex_of_id: flex_id} = item_type, tenant, steps, levels)
       when not is_nil(flex_id) do
    if levels < FieldDefinition.max_flexible_depth() do
      with {:ok, flexible} <- fetch(flex_id, tenant),
           do: up(flexible, [{flexible.name, item_type.name} | steps], tenant, levels)
    else
      {:error, :too_deep}
    end
  end

  defp climb(_not_an_item_type, _tenant, _steps, _levels), do: {:error, :gone}

  defp up(%{group_of_id: nil} = flexible, steps, _tenant, _levels), do: {:ok, flexible, steps}

  defp up(%{group_of_id: owner_id}, steps, tenant, levels) do
    with {:ok, owner} <- fetch(owner_id, tenant), do: climb(owner, tenant, steps, levels + 1)
  end

  # Like `FlexibleField.parent/2`, but tells a row that is not there from a
  # read that failed.
  defp fetch(id, tenant) do
    case KilnCMS.CMS.get_field_definition(id,
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           tenant: tenant
         ) do
      {:ok, %{} = definition} -> {:ok, definition}
      {:ok, nil} -> {:error, :gone}
      {:error, error} -> if not_found?(error), do: {:error, :gone}, else: {:error, :unreadable}
    end
  end

  defp not_found?(%{errors: errors}) when is_list(errors),
    do: errors != [] and Enum.all?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

  defp not_found?(_error), do: false

  @doc """
  The top-level definition (of a content type or a dynamic type) whose values
  hold `definition`'s: itself for a top-level field, the owning flexible field
  for an item type or a sub-field of one, and the first top-level ancestor
  found by walking `link_of_id`, `group_of_id` and `flex_of_id` for anything
  else. `nil` when the chain is broken.
  """
  @spec owner(map(), term()) :: FieldDefinition.t() | map() | nil
  def owner(definition, tenant), do: owner(definition, tenant, 0)

  defp owner(_definition, _tenant, hops) when hops > 16, do: nil

  defp owner(definition, tenant, hops) do
    if FieldDefinition.top_level?(definition) do
      definition
    else
      with id when not is_nil(id) <- FieldDefinition.parent_id(definition),
           %{} = parent <- FlexibleField.parent(id, tenant) do
        owner(parent, tenant, hops + 1)
      else
        _broken -> nil
      end
    end
  end

  @doc """
  The type name (a content type's atom as a string, or a dynamic type's name) a
  top-level definition belongs to, or `nil`.
  """
  @spec type_name(map(), term()) :: String.t() | nil
  def type_name(%{type_definition_id: id}, tenant) when not is_nil(id) do
    case KilnCMS.CMS.get_type_definition(id,
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           authorize_with: :error,
           tenant: tenant
         ) do
      {:ok, type_def} -> type_def.name
      _error -> nil
    end
  end

  def type_name(%{content_type: type}, _tenant) when is_atom(type) and not is_nil(type),
    do: to_string(type)

  def type_name(_definition, _tenant), do: nil

  # --- SQL ---------------------------------------------------------------------

  @doc """
  The `UPDATE` rewriting every item `steps` reach, and its parameters, for one
  of:

    * `{:rename_field, from, to, setting?}` — move a sub-field's key inside each
      item of the last step's type (under `_settings` for a setting);
    * `{:purge_field, name, setting?}` — remove it; an item left with nothing
      but its meta keys is dropped, as a write drops a blank item (a setting
      leaves its item whole);
    * `{:rename_type, to}` — rewrite `_type` of the last step's items;
    * `:purge_type` — remove the last step's items, and so everything below.

  A list a purge empties loses its key (a write stores no empty list).
  `filter` is the `WHERE` tail builder `SyncFieldValues.target/1` returns, with
  its `filter_params`, which follow the parameters bound here. The statement
  is `map_sql/3` over the `custom_fields` column.
  """
  @spec update_sql(String.t(), steps(), tuple() | atom(), {function(), list()}) ::
          {String.t(), list()}
  def update_sql(table, steps, op, {filter, filter_params}) do
    {new, carries, bound} = map_sql(steps, op, "custom_fields")

    sql = """
    UPDATE #{table}
       SET custom_fields = #{new}
     WHERE #{carries}#{filter.(length(bound))}
    """

    {sql, bound ++ filter_params}
  end

  @doc """
  `update_sql/4`'s rewrite as SQL over any map expression `m` (a column, or
  the held copy `(working_fields -> 'custom_fields')`): `{new, carries,
  params}`, where `new` is the rewritten map, `carries` the predicate saying
  `m` holds something the rewrite changes (`new` is only meaningful where it
  holds), and `params` the values bound to `$1…$n`, which any further
  parameters follow. `m` may appear several times; it is read, never written.
  """
  @spec map_sql(steps(), tuple() | atom(), String.t()) :: {String.t(), String.t(), list()}
  def map_sql(steps, op, m) do
    n = length(steps)
    {op_params, jsonpath} = op_params(op, steps)
    base = 2 * n + 1
    bound = step_params(steps) ++ op_params
    path_index = length(bound) + 1
    top = "#{m} -> #{field(0)}"

    new = """
    (SELECT CASE WHEN a = '[]'::jsonb THEN #{m} - #{field(0)}
                 ELSE jsonb_set(#{m}, ARRAY[#{field(0)}], a) END
       FROM (SELECT #{items(0, top, n, op, base)} AS a) AS s)
    """

    carries =
      "(jsonb_typeof(#{top}) = 'array' AND " <>
        "jsonb_path_exists(#{m}, $#{path_index}::text::jsonpath, #{vars(n)}))"

    {new, carries, bound ++ [jsonpath]}
  end

  @doc """
  Whether any stored item of the last step's type exists in `table` (under the
  `filter` tail), reached through `steps`.
  """
  @spec items_exist?(String.t(), steps(), {function(), list()}) :: boolean()
  # `table` is a resource's own `postgres do table` (never user input); the
  # other interpolations are generated `$n` placeholders and integer indexes.
  # Every name and value reaches the database as a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def items_exist?(table, steps, {filter, filter_params}) do
    {_params, jsonpath} = op_params(:purge_type, steps)
    bound = step_params(steps)
    path_index = length(bound) + 1

    sql = """
    SELECT EXISTS (SELECT 1 FROM #{table}
                    WHERE jsonb_path_exists(custom_fields, $#{path_index}::text::jsonpath, #{vars(length(steps))})#{filter.(path_index)})
    """

    case KilnCMS.Repo.query(sql, bound ++ [jsonpath] ++ filter_params) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      # Fail closed: an unreadable answer must not read as "no items".
      _error -> true
    end
  end

  @doc """
  How many stored items of the last step's type exist in `table` (under the
  `filter` tail), reached through `steps`: the number `items_exist?/3` tests
  for being non-zero. `:error` when the count cannot be read (it must not read
  as "none").
  """
  @spec count_items(String.t(), steps(), {function(), list()}) ::
          {:ok, non_neg_integer()} | :error
  # As `items_exist?/3`: `table` is a resource's own table, everything else a
  # generated `$n` placeholder or a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def count_items(table, steps, {filter, filter_params}) do
    {_params, jsonpath} = op_params(:purge_type, steps)
    bound = step_params(steps)
    path_index = length(bound) + 1

    sql = """
    SELECT count(*) FROM #{table} AS t,
           LATERAL jsonb_path_query(t.custom_fields, $#{path_index}::text::jsonpath, #{vars(length(steps))}) AS item
     WHERE true#{filter.(path_index)}
    """

    case KilnCMS.Repo.query(sql, bound ++ [jsonpath] ++ filter_params) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> {:ok, count}
      _error -> :error
    end
  end

  @doc """
  How many stored items deleting `definition` would remove, for the fields
  screen to show before it asks: the items of an **item type**, or, for a
  **flexible field** (top-level or nested), the items of each of its item types
  (what sits inside an item goes with it and is not counted again).
  `{:ok, 0}` for any other definition; `:error` when a link of the chain does
  not resolve or the count cannot be read, which a caller must treat as
  "unknown", not "none".
  """
  @spec count_stored(map(), term()) :: {:ok, non_neg_integer()} | :error
  def count_stored(%{flex_of_id: id} = item_type, tenant) when not is_nil(id) do
    with {:ok, top, steps} <- item_path(item_type, tenant),
         {:ok, table, filter, params} <- KilnCMS.CMS.Changes.SyncFieldValues.target(top) do
      count_items(table, steps, {filter, params})
    else
      _unresolved -> :error
    end
  end

  def count_stored(%{field_type: :flexible, id: id}, tenant) do
    with {:ok, item_types} <- item_types_of(id, tenant) do
      Enum.reduce_while(item_types, {:ok, 0}, &add_count(&1, &2, tenant))
    end
  end

  def count_stored(_definition, _tenant), do: {:ok, 0}

  defp add_count(item_type, {:ok, total}, tenant) do
    case count_stored(item_type, tenant) do
      {:ok, count} -> {:cont, {:ok, total + count}}
      :error -> {:halt, :error}
    end
  end

  defp item_types_of(flexible_id, tenant) do
    case KilnCMS.CMS.list_field_definitions(
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           tenant: tenant,
           query: [filter: [flex_of_id: flexible_id]]
         ) do
      {:ok, item_types} -> {:ok, item_types}
      {:error, _error} -> :error
    end
  end

  defp field(i), do: "$#{2 * i + 1}::text"
  defp type(i), do: "$#{2 * i + 2}::text"

  defp step_params(steps), do: Enum.flat_map(steps, fn {field, type} -> [field, type] end)

  defp vars(m) do
    # Every field is bound too, though only the update reads it as a key: a
    # parameter no expression mentions has no type for Postgres to infer.
    pairs =
      Enum.map_join(0..(m - 1), ", ", fn i -> "'t#{i}', #{type(i)}, 'f#{i}', #{field(i)}" end)

    "jsonb_build_object(#{pairs})"
  end

  # The jsonpath reaching the items (or the sub-field in them), the steps
  # spelled as literals: a path cannot take a member name from a variable. They
  # are field and type names (`[a-z][a-z0-9_]*`, validated), quoted anyway. Item
  # types compare through the `t<i>` variables.
  defp op_params(op, steps) do
    path =
      steps
      |> Enum.with_index()
      |> Enum.map_join(fn {{field, _type}, i} ->
        "." <> quote_member(field) <> "[*] ? (@.\"_type\" == $t#{i})"
      end)

    {params, tail} =
      case op do
        {:rename_field, from, to, setting?} -> {[from, to], member_path(from, setting?)}
        {:purge_field, name, setting?} -> {[name], member_path(name, setting?)}
        {:rename_type, to} -> {[to], ""}
        :purge_type -> {[], ""}
      end

    {params, "lax $" <> path <> tail}
  end

  defp member_path(name, true), do: ".\"_settings\"." <> quote_member(name)
  defp member_path(name, false), do: ".#{quote_member(name)}"

  defp quote_member(name) do
    ~s("#{name |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))}")
  end

  # The rewritten array of the items at level `i` (`arr` is its SQL, known to
  # be an array). The last level applies `op`; the levels above descend into
  # their items' next flexible field.
  defp items(i, arr, m, op, base) do
    last? = i == m - 1
    e = "e#{i}"

    inner = if last?, do: leaf(op, e, base), else: descend(i, e, m, op, base)

    pre =
      case {last?, op} do
        {true, :purge_type} ->
          "WHERE NOT (jsonb_typeof(#{e}) = 'object' AND #{e} ->> '_type' = #{type(i)})"

        _ ->
          ""
      end

    post =
      case {last?, op} do
        {true, {:purge_field, _name, false}} ->
          "WHERE NOT (jsonb_typeof(r#{i}) = 'object' AND (r#{i} - '_id' - '_type' - '_settings') = '{}'::jsonb)"

        _ ->
          ""
      end

    # `purge_type` removes rather than rewrites, so its CASE keeps what is left.
    body =
      if last? and op == :purge_type,
        do: e,
        else:
          "CASE WHEN jsonb_typeof(#{e}) = 'object' AND #{e} ->> '_type' = #{type(i)} THEN #{inner} ELSE #{e} END"

    """
    (SELECT COALESCE(jsonb_agg(r#{i} ORDER BY n#{i}), '[]'::jsonb)
       FROM (SELECT #{body} AS r#{i}, n#{i}
               FROM jsonb_array_elements(#{arr}) WITH ORDINALITY AS x#{i}(#{e}, n#{i}) #{pre}) AS k#{i}
       #{post})
    """
  end

  defp descend(i, e, m, op, base) do
    next = "#{e} -> #{field(i + 1)}"

    """
    CASE WHEN jsonb_typeof(#{next}) = 'array'
         THEN (SELECT CASE WHEN a#{i} = '[]'::jsonb THEN #{e} - #{field(i + 1)}
                           ELSE jsonb_set(#{e}, ARRAY[#{field(i + 1)}], a#{i}) END
                 FROM (SELECT #{items(i + 1, next, m, op, base)} AS a#{i}) AS s#{i})
         ELSE #{e} END
    """
  end

  defp leaf({:rename_type, _to}, e, base),
    do: "jsonb_set(#{e}, '{_type}', to_jsonb($#{base}::text))"

  defp leaf({:rename_field, _from, _to, false}, e, base) do
    """
    CASE WHEN #{e} ? $#{base}::text
         THEN (#{e} - $#{base}::text) || jsonb_build_object($#{base + 1}::text, #{e} -> $#{base}::text)
         ELSE #{e} END
    """
  end

  defp leaf({:rename_field, _from, _to, true}, e, base) do
    s = "(#{e} -> '_settings')"

    """
    CASE WHEN jsonb_typeof(#{s}) = 'object' AND #{s} ? $#{base}::text
         THEN jsonb_set(#{e}, '{_settings}',
                        (#{s} - $#{base}::text) || jsonb_build_object($#{base + 1}::text, #{s} -> $#{base}::text))
         ELSE #{e} END
    """
  end

  defp leaf({:purge_field, _name, false}, e, base), do: "(#{e} - $#{base}::text)"

  defp leaf({:purge_field, _name, true}, e, base) do
    s = "(#{e} -> '_settings')"

    """
    CASE WHEN jsonb_typeof(#{s}) = 'object' AND #{s} ? $#{base}::text
         THEN (CASE WHEN (#{s} - $#{base}::text) = '{}'::jsonb THEN #{e} - '_settings'
                    ELSE jsonb_set(#{e}, '{_settings}', #{s} - $#{base}::text) END)
         ELSE #{e} END
    """
  end

  # Unused by `purge_type`, which filters instead of rewriting.
  defp leaf(:purge_type, e, _base), do: e
end
