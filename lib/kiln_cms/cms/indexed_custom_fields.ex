defmodule KilnCMS.CMS.IndexedCustomFields do
  @moduledoc """
  The custom fields a site has asked to be **range-filterable and sortable at
  index speed** (#2359, tier 2 of #2291; ADR 0025).

  `custom_fields` is one JSONB map and the global GIN index of #2291 only
  serves containment (`eq`, `in`, list membership). Range (`gt`/`gte`/`lt`/
  `lte`) and `custom_sort` need a btree per field, and field names are
  per-site runtime data. D4/D17 forbid runtime DDL and migrations are written
  by `mix ash.codegen`, so the names are declared in **config**, read at
  compile time:

      config :kiln_cms, :indexed_custom_fields, ["price", "rating"]

  `KilnCMS.CMS.Content` turns each name into two expression btrees on every
  content table (`pages`, `posts`, `entries`), `ASC NULLS LAST` and
  `DESC NULLS LAST`, and `mix ash.codegen` writes the migration. Adding a
  name is an additive `CREATE INDEX CONCURRENTLY`; removing one is a `DROP
  INDEX`; neither touches data. The default is `[]`: core ships no such
  index.

  The indexed expression is `sort_sql/1`, the very expression
  `KilnCMS.CMS.Preparations.CustomFieldQuery` orders by, so one index serves
  `custom_sort=price` and `custom_sort=-price` (with a `LIMIT`) and the range
  operators. The query inlines the field name as a SQL **literal** for a
  listed name only: with a bound name Postgres switches to a generic plan
  after five executions and stops matching the index. That is why `valid?/2`
  gates both the config and the query.

  Eligible field types are integer, float, boolean, date and datetime
  (`eligible_types/0`); a string btree can exceed the ~2.7 KB index row limit.
  `mix kiln.custom_fields.index --check` reports drift in both directions.
  """

  @config Application.compile_env(:kiln_cms, :indexed_custom_fields, [])
  @core_tables ~w(pages posts entries)

  # Test seam: a test sets this application key (a map of table => names) to
  # exercise the query and the drift check without declaring indexes in the
  # compiled resources. The test environment must not declare any: CI's
  # `mix ash.codegen --check` runs there, and a declared index is pending
  # codegen until a migration carries it.
  @override_key :indexed_custom_fields_override

  @name_format ~r/\A[a-z][a-z0-9_]*\z/
  @max_length 24
  @eligible_types [:integer, :float, :date, :datetime]

  # `config :kiln_cms, :indexed_custom_fields` is a list (every content table
  # gets the indexes) or a map of table name to list (`%{"entries" => ["price"]}`):
  # each name costs two btrees per table it is listed for, so a site that
  # sorts a compiled type's field has no reason to index `entries` too.
  @by_table (case @config do
               list when is_list(list) -> Map.new(@core_tables, &{&1, list})
               map when is_map(map) -> map
             end)

  # Fail the build, not the migration: a bad entry would otherwise surface as
  # an unusable index name or, worse, SQL built from a stray string.
  for {table, names} <- @by_table do
    if length(names) != length(Enum.uniq(names)) do
      raise ArgumentError,
            "config :kiln_cms, :indexed_custom_fields lists a name twice for #{table}"
    end

    for name <- names do
      unless is_binary(name) and name =~ @name_format and byte_size(name) <= @max_length do
        raise ArgumentError,
              "config :kiln_cms, :indexed_custom_fields entry #{inspect(name)} must be a " <>
                "custom field name (lowercase letters, digits and underscores, starting with a " <>
                "letter, at most #{@max_length} characters)"
      end

      for direction <- [:asc, :desc] do
        index = "#{table}_cf_#{name}_#{direction}_index"

        if byte_size(index) > 63 do
          raise ArgumentError,
                "index name #{index} is over PostgreSQL's 63-byte limit; use a shorter field name"
        end
      end
    end
  end

  @doc "The configured field names per table (compile-time)."
  @spec by_table() :: %{String.t() => [String.t()]}
  def by_table, do: Application.get_env(:kiln_cms, @override_key) || @by_table

  @doc "The names declared for `table`."
  @spec names(String.t()) :: [String.t()]
  def names(table), do: Map.get(by_table(), table, [])

  @doc "Is `name` safe to inline as a SQL literal and backed by a declared index on `table`?"
  @spec valid?(String.t() | nil, term()) :: boolean()
  def valid?(table, name) when is_binary(table) and is_binary(name), do: name in names(table)
  def valid?(_table, _name), do: false

  @doc "Is `name` a well-formed indexable field name (format and length)?"
  @spec well_formed?(term()) :: boolean()
  def well_formed?(name),
    do: is_binary(name) and name =~ @name_format and byte_size(name) <= @max_length

  @doc "The field types an index may be declared for."
  @spec eligible_types() :: [atom()]
  def eligible_types, do: @eligible_types

  @doc """
  The sort/range expression for `name` as SQL text over a `?` placeholder for
  the `custom_fields` column. A stored JSON `null`, array or object reads as
  SQL `NULL` (last in either direction), so it neither leads the order nor
  matches a range. `name` must satisfy `valid?/2`.
  """
  @spec sort_sql(String.t()) :: String.t()
  def sort_sql(name) when is_binary(name) do
    "(CASE WHEN jsonb_typeof(? -> '#{name}') IN ('null', 'array', 'object') " <>
      "THEN NULL ELSE (? -> '#{name}') END)"
  end

  @doc """
  The same expression with the field name as a **bound** parameter, for a
  field that has no declared index. Same rows, no index.
  """
  @spec bound_sql() :: String.t()
  def bound_sql do
    "(CASE WHEN jsonb_typeof(? -> ?::text) IN ('null', 'array', 'object') " <>
      "THEN NULL ELSE (? -> ?::text) END)"
  end

  @doc "The same expression over the bare column, as written in an index."
  @spec index_sql(String.t()) :: String.t()
  def index_sql(name), do: String.replace(sort_sql(name), "?", "custom_fields")

  @doc "The index name for `table`, `name` and direction (`:asc` / `:desc`)."
  @spec index_name(String.t(), String.t(), :asc | :desc) :: String.t()
  def index_name(table, name, direction), do: "#{table}_cf_#{name}_#{direction}_index"

  @doc """
  The `index` entries (as quoted DSL calls) for `table`, spliced into a
  `custom_indexes` section by `KilnCMS.CMS.Content`.
  """
  @spec index_entries(String.t()) :: [Macro.t()]
  def index_entries(table) do
    for %{expr: expr, name: name} <- index_specs(table) do
      quote do
        index [unquote(expr)], name: unquote(name), concurrently: true
      end
    end
  end

  @doc "The index definitions for `table`: `%{name: index_name, expr: column_sql}`."
  @spec index_specs(String.t()) :: [%{name: String.t(), expr: String.t()}]
  def index_specs(table) do
    for name <- names(table),
        {direction, suffix} <- [asc: "ASC NULLS LAST", desc: "DESC NULLS LAST"] do
      %{name: index_name(table, name, direction), expr: index_sql(name) <> " " <> suffix}
    end
  end

  @doc """
  Compares the declared indexes with the database and the field registry, in
  both directions, and returns the problems found as `{kind, message}` pairs
  (an empty list is clean). Read-only: it writes nothing and runs no DDL.

    * `:missing_index` — a listed name has no index on a table yet (the
      migration was not generated or applied); queries still answer, from the
      heap;
    * `:invalid_index` — a `CREATE INDEX CONCURRENTLY` failed and left an
      invalid index; drop it and rebuild;
    * `:unlisted_index` — an `_cf_` index exists for a name no longer listed;
      it costs every write and nothing reads it;
    * `:unused_name` — no field definition has that name, so the index serves
      nothing (a rename or a delete leaves this behind);
    * `:ineligible_type` — a definition of that name has a type an index is
      not declared for (`eligible_types/0`), or the name is declared with
      different types.
  """
  @spec check(module()) :: [{atom(), String.t()}]
  def check(repo \\ KilnCMS.Repo) do
    by_table = by_table()
    tables = Enum.uniq(Map.keys(by_table) ++ @core_tables)

    %{rows: indexes} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT c.relname, t.relname, i.indisvalid
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_class t ON t.oid = i.indrelid
        WHERE t.relname = ANY($1) AND c.relname ~ '_cf_.+_(asc|desc)_index$'
        """,
        [tables]
      )

    present = Map.new(indexes, fn [name, _table, valid] -> {name, valid} end)

    expected =
      for {table, names} <- by_table, name <- names, direction <- [:asc, :desc] do
        index_name(table, name, direction)
      end

    missing =
      for name <- expected, not is_map_key(present, name), do: {:missing_index, name}

    invalid = for {name, false} <- present, do: {:invalid_index, name}

    unlisted =
      for {name, _valid} <- present, name not in expected, do: {:unlisted_index, name}

    listed = by_table |> Map.values() |> List.flatten() |> Enum.uniq()

    %{rows: definitions} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT name, array_agg(DISTINCT field_type::text) FROM field_definitions " <>
          "WHERE name = ANY($1) GROUP BY name",
        [listed]
      )

    types = Map.new(definitions, fn [name, types] -> {name, types} end)
    eligible = Enum.map(@eligible_types, &Atom.to_string/1)

    unused = for name <- listed, not is_map_key(types, name), do: {:unused_name, name}

    ineligible =
      for {name, found} <- types, Enum.any?(found, &(&1 not in eligible)) or length(found) > 1 do
        {:ineligible_type, "#{name} (#{Enum.join(found, ", ")})"}
      end

    Enum.sort(missing ++ invalid ++ unlisted ++ unused ++ ineligible)
  end
end
