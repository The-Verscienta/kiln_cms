defmodule KilnCMS.CMS.JoinGraduation do
  @moduledoc """
  Graduating a `:reference` custom field to a typed Ash join resource (R10 in
  `docs/relationships-plan.md`, decision D22).

  A UI-defined relationship lives in the shared `content_links` table. A
  project that needs a table of its own for one relationship — typed columns
  for its link data, its own indexes, SQL that joins it directly — graduates
  the field, the same promotion path D17 gives dynamic types. Three steps, in
  this order, each its own command:

    1. `mix kiln.gen.join <type>.<field>` writes the join resource and its
       code interfaces (`Mix.Tasks.Kiln.Gen.Join`), then `mix ash.codegen`
       and `mix ash.migrate` create its table.
    2. `mix kiln.gen.join <type>.<field> --data-migration` writes a migration
       that copies the field's edges into that table (`copy_sql/1`). It is a
       second run because it must sort after step 1's table migration.
    3. `mix kiln.join.retire <type>.<field>`, once the copy is verified,
       deletes the field definition and its stored values (`retire/2`), so
       there are never two sources of truth.

  This module holds what the three share: resolving a field into a `spec/0`
  (`resolve/2`), the SQL that copies and compares edges, and the retirement.

  ## What graduates

  The field's `:reference` edges (`kind: :reference`, its `field`, its source
  and target types) whose source and target rows still exist. An edge to a
  purged record is a broken reference, and a foreign key cannot point at
  nothing, so it is not copied; `verify/2` counts it apart. Edges follow the
  **live** value only, so a reference held in a working copy is not an edge:
  retirement refuses while one is pending.

  Graduation is project-wide. The schema (the link fields, their types) is
  read from one organization's definition, `--org` or the default org, and
  the copy and the retirement cover the field in every organization that
  defines it.

  ## What does not

  A field that allows **several target types** (R2) is refused. A typed join
  table has one foreign key per end, and each target type is its own table,
  so a polymorphic field has no single resource to point at. Split the field
  into one field per target type first and graduate each.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition

  @domain_namespace KilnCMS.CMS

  # Names the generated resource uses for its own columns and relationships.
  # A link field with one of them would collide.
  @reserved ~w(id org_id source_id target_id position inserted_at updated_at
               source target organization)

  @typedoc "The column type a link field becomes."
  @type kind :: :string | :integer | :float | :boolean | :date | :naive_datetime

  @typedoc "One link field as a typed column."
  @type column :: %{
          name: String.t(),
          kind: kind(),
          field_type: atom(),
          required: boolean(),
          default: term(),
          options: [String.t()],
          label: String.t()
        }

  @typedoc "One end of the relationship."
  @type side :: %{type: String.t(), resource: module(), table: String.t(), dynamic?: boolean()}

  @typedoc "A field resolved for graduation."
  @type spec :: %{
          field: String.t(),
          label: String.t(),
          source: side(),
          target: side(),
          columns: [column()],
          module: module(),
          table: String.t(),
          base: String.t(),
          org_id: Ash.UUID.t()
        }

  @doc """
  Split `"<type>.<field>"` into its two names.

      iex> KilnCMS.CMS.JoinGraduation.parse_field("recipe.ingredients")
      {:ok, {"recipe", "ingredients"}}

      iex> KilnCMS.CMS.JoinGraduation.parse_field("ingredients")
      :error
  """
  @spec parse_field(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_field(string) when is_binary(string) do
    case String.split(string, ".") do
      [type, field] when type != "" and field != "" -> {:ok, {type, field}}
      _other -> :error
    end
  end

  @doc """
  Resolve `"<type>.<field>"` into a `spec/0`, reading the field's definition
  in one organization.

  ## Options

    * `:org_id` — the organization whose definition gives the schema (default:
      the default org).
    * `:module` — the join resource module (default
      `KilnCMS.CMS.<Type><Field>Link`).
  """
  @spec resolve(String.t(), keyword()) :: {:ok, spec()} | {:error, String.t()}
  def resolve(string, opts \\ []) do
    org_id = opts[:org_id] || KilnCMS.Accounts.default_org_id()

    with {:ok, {type, name}} <- parse(string),
         {:ok, source} <- side(type, org_id),
         {:ok, definition} <- definition(source, name, org_id),
         {:ok, target} <- target(definition, org_id),
         {:ok, columns} <- columns(definition) do
      module = opts[:module] || default_module(type, name)

      {:ok,
       %{
         field: name,
         label: definition.label,
         source: source,
         target: target,
         columns: columns,
         module: module,
         table: "#{type}_#{name}_links",
         base: "#{type}_#{name}_link",
         org_id: org_id
       }}
    end
  end

  defp parse(string) do
    case parse_field(string) do
      {:ok, names} ->
        {:ok, names}

      :error ->
        {:error, "expected <type>.<field>, e.g. recipe.ingredients; got #{inspect(string)}"}
    end
  end

  @doc """
  The join resource module a field graduates to by default.

      iex> KilnCMS.CMS.JoinGraduation.default_module("recipe", "ingredients")
      KilnCMS.CMS.RecipeIngredientsLink
  """
  @spec default_module(String.t(), String.t()) :: module()
  def default_module(type, field),
    do: Module.concat(@domain_namespace, Macro.camelize("#{type}_#{field}_link"))

  defp side(type, org_id) do
    case ContentTypes.get(type, org_id) do
      %{source: :dynamic} ->
        {:ok, side_of(type, CMS.Entry, true)}

      %{resource: resource} when not is_nil(resource) ->
        {:ok, side_of(type, resource, false)}

      nil ->
        {:error, "no content type named #{inspect(type)} in this organization"}
    end
  end

  defp side_of(type, resource, dynamic?) do
    %{
      type: to_string(type),
      resource: resource,
      table: AshPostgres.DataLayer.Info.table(resource),
      dynamic?: dynamic?
    }
  end

  # Registry metadata, read as the cms registry (FieldDefinition admits it for
  # reads), always with a tenant: definitions are per-org.
  defp definition(source, name, org_id) do
    opts = [actor: registry_actor(), authorize_with: :error, tenant: org_id]

    definitions =
      if source.dynamic? do
        case type_definition(source.type, org_id) do
          nil -> []
          type_definition -> CMS.field_definitions_for_definition!(type_definition.id, opts)
        end
      else
        CMS.field_definitions_for!(String.to_existing_atom(source.type), opts)
      end

    case Enum.find(definitions, &(&1.name == name)) do
      nil ->
        {:error, "#{source.type} has no field named #{inspect(name)}"}

      %{field_type: :reference} = definition ->
        {:ok, definition}

      %{field_type: type} ->
        {:error,
         "#{source.type}.#{name} is a #{type} field; only a reference field can graduate to a join resource"}
    end
  end

  defp type_definition(name, org_id) do
    case CMS.get_type_definition_by_name(name,
           actor: KilnCMS.SystemActor.new(:operator),
           tenant: org_id
         ) do
      {:ok, definition} -> definition
      {:error, _not_found} -> nil
    end
  end

  defp target(definition, org_id) do
    case FieldDefinition.reference_targets(definition) do
      [type] ->
        side(type, org_id)

      [] ->
        {:error, "#{definition.name} names no target type"}

      types ->
        {:error,
         "#{definition.name} links to several types (#{Enum.join(types, ", ")}). " <>
           "A typed join resource has one foreign key per end, so it can point at one " <>
           "table only. Split the field into one reference field per target type, " <>
           "then graduate each."}
    end
  end

  defp columns(definition) do
    link_fields = FieldDefinition.link_fields(definition)

    case Enum.filter(link_fields, &(&1.name in @reserved)) do
      [] ->
        {:ok, Enum.map(link_fields, &column/1)}

      clashes ->
        {:error,
         "link field(s) #{Enum.map_join(clashes, ", ", & &1.name)} would collide with the " <>
           "join resource's own columns; rename them in the fields admin first"}
    end
  end

  defp column(link_field) do
    kind = kind(link_field.field_type)

    %{
      name: link_field.name,
      kind: kind,
      field_type: link_field.field_type,
      required: link_field.required,
      default: cast_default(kind, link_field.default),
      options: if(link_field.field_type == :select, do: link_field.options, else: []),
      label: link_field.label
    }
  end

  @doc """
  The column kind (and Ash type) a link field's type becomes.

  `:text`, `:url` and `:select` are strings — a select's choices become a
  `one_of` validation on the resource. A datetime link value is stored
  without an offset (`ApplyCustomFields` normalizes to a naive ISO string),
  so it becomes a `:naive_datetime`.
  """
  @spec kind(atom()) :: kind()
  def kind(type) when type in [:string, :text, :url, :select], do: :string
  def kind(:integer), do: :integer
  def kind(:float), do: :float
  def kind(:boolean), do: :boolean
  def kind(:date), do: :date
  def kind(:datetime), do: :naive_datetime

  # A link field's default is a string in the definition; on the resource it
  # is the column's type. One that does not cast is dropped, never guessed.
  defp cast_default(_kind, nil), do: nil
  defp cast_default(_kind, ""), do: nil

  defp cast_default(kind, value) do
    case Ash.Type.cast_input(kind, value, []) do
      {:ok, cast} -> cast
      _error -> nil
    end
  end

  # --- SQL -----------------------------------------------------------------

  @doc """
  The `INSERT … SELECT` that copies the field's edges into the join table.

  One row per edge whose source and target rows still exist, with its org,
  ends, position and each link value cast to its column. A value of the wrong
  JSON type reads as `NULL` (then the column default, if the link field has
  one) rather than aborting the copy, and `ON CONFLICT DO NOTHING` makes the
  statement safe to run twice.

  Every interpolated name comes from code or from a validated identifier (a
  content type name, a field name); `literal/1` quotes them anyway.
  """
  @spec copy_sql(spec()) :: String.t()
  def copy_sql(spec) do
    names = Enum.map_join(spec.columns, "", &", #{ident(&1.name)}")
    values = Enum.map_join(spec.columns, "", &",\n       #{value_sql(&1)}")

    """
    INSERT INTO #{ident(spec.table)} (org_id, source_id, target_id, position#{names})
    SELECT cl.org_id, cl.source_id, cl.target_id, cl.position#{values}
      FROM content_links cl
     WHERE #{edge_filter(spec)}
       AND #{ends_exist(spec)}
    ON CONFLICT DO NOTHING
    """
  end

  # The field's edges, by kind, field and both ends' types.
  defp edge_filter(spec) do
    "cl.kind = 'reference' AND cl.field = #{literal(spec.field)}\n" <>
      "       AND cl.source_type = #{literal(spec.source.type)}" <>
      " AND cl.target_type = #{literal(spec.target.type)}"
  end

  defp ends_exist(spec) do
    "EXISTS (SELECT 1 FROM #{ident(spec.source.table)} s WHERE s.id = cl.source_id)\n" <>
      "       AND EXISTS (SELECT 1 FROM #{ident(spec.target.table)} t WHERE t.id = cl.target_id)"
  end

  defp value_sql(%{default: nil} = column), do: cast_sql(column)

  defp value_sql(column),
    do: "COALESCE(#{cast_sql(column)}, #{default_sql(column)})"

  # Guarded by the JSON type, so a stray value becomes NULL, not an error.
  defp cast_sql(%{name: name, kind: kind}) do
    key = literal(name)
    raw = "cl.metadata->>#{key}"
    json = "jsonb_typeof(cl.metadata->#{key})"

    case kind do
      :string ->
        "CASE WHEN #{json} = 'string' THEN #{raw} END"

      :integer ->
        "CASE WHEN #{json} = 'number' AND #{raw} ~ '^-?[0-9]+$' THEN (#{raw})::bigint END"

      :float ->
        "CASE WHEN #{json} = 'number' THEN (#{raw})::float8 END"

      :boolean ->
        "CASE WHEN #{json} = 'boolean' THEN (#{raw})::boolean END"

      :date ->
        "CASE WHEN #{json} = 'string' AND #{raw} ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' " <>
          "THEN (#{raw})::date END"

      :naive_datetime ->
        "CASE WHEN #{json} = 'string' AND #{raw} ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}' " <>
          "THEN (#{raw})::timestamp(0) END"
    end
  end

  defp default_sql(%{kind: :string, default: value}), do: literal(value)
  defp default_sql(%{kind: :integer, default: value}), do: "#{value}::bigint"
  defp default_sql(%{kind: :float, default: value}), do: "#{value / 1}::float8"
  defp default_sql(%{kind: :boolean, default: value}), do: to_string(value)
  defp default_sql(%{kind: :date, default: value}), do: "#{literal(Date.to_iso8601(value))}::date"

  defp default_sql(%{kind: :naive_datetime, default: value}),
    do: "#{literal(NaiveDateTime.to_iso8601(value))}::timestamp(0)"

  @doc false
  @spec literal(String.t()) :: String.t()
  def literal(value) when is_binary(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  # --- verification and retirement ---------------------------------------

  @typedoc "What stands between a field and its retirement, per count."
  @type report :: %{
          edges: non_neg_integer(),
          copied: non_neg_integer(),
          missing: non_neg_integer(),
          broken: non_neg_integer(),
          unmirrored: non_neg_integer(),
          pending: non_neg_integer()
        }

  @doc """
  Compare the field's edges in one organization with the join table.

    * `edges` — the field's edges whose two ends exist (what the copy takes);
    * `copied` — those with a join row of the same ends, position and link
      values;
    * `missing` — those without one: a connection made after the copy ran,
      or a link value that differs;
    * `broken` — edges to or from a record that no longer exists (not copied,
      and dropped by the retirement);
    * `unmirrored` — records holding a value for the field with no edge at
      all (written before edges existed; `mix kiln.links.backfill` writes
      them);
    * `pending` — records whose working copy holds a value for the field, not
      yet published, so not an edge.

  A field may retire when `missing`, `unmirrored` and `pending` are all zero.
  """
  @spec verify(spec(), Ash.UUID.t()) :: report()
  def verify(spec, org_id) do
    org = literal(org_id)
    in_org = "cl.org_id = #{org}::uuid AND #{edge_filter(spec)}"

    matches =
      [
        "j.org_id = cl.org_id",
        "j.source_id = cl.source_id",
        "j.target_id = cl.target_id",
        "j.position = cl.position"
      ] ++
        Enum.map(spec.columns, &"j.#{ident(&1.name)} IS NOT DISTINCT FROM #{value_sql(&1)}")

    %{
      edges:
        count("SELECT count(*) FROM content_links cl WHERE #{in_org} AND #{ends_exist(spec)}"),
      copied:
        count("""
        SELECT count(*) FROM content_links cl
         WHERE #{in_org} AND #{ends_exist(spec)}
           AND EXISTS (SELECT 1 FROM #{ident(spec.table)} j WHERE #{Enum.join(matches, " AND ")})
        """),
      broken:
        count(
          "SELECT count(*) FROM content_links cl WHERE #{in_org} AND NOT (#{ends_exist(spec)})"
        ),
      unmirrored: count(unmirrored_sql(spec, org)),
      pending: count(pending_sql(spec, org))
    }
    |> then(&Map.put(&1, :missing, &1.edges - &1.copied))
  end

  # A record of the source type holding a non-empty value with no edge.
  defp unmirrored_sql(spec, org) do
    key = literal(spec.field)
    value = "s.custom_fields->#{key}"

    """
    SELECT count(*) FROM #{ident(spec.source.table)} s
     WHERE s.org_id = #{org}::uuid#{source_type_filter(spec, org)}
       AND (jsonb_typeof(#{value}) = 'object'
            OR (jsonb_typeof(#{value}) = 'array' AND jsonb_array_length(#{value}) > 0))
       AND NOT EXISTS (SELECT 1 FROM content_links cl
                        WHERE cl.source_id = s.id AND cl.kind = 'reference' AND cl.field = #{key})
    """
  end

  # A working copy holds the whole `custom_fields` map under one key
  # (`WorkingCopy`); it is pending for this field when its value there differs
  # from the live one.
  defp pending_sql(spec, org) do
    key = literal(spec.field)

    """
    SELECT count(*) FROM #{ident(spec.source.table)} s
     WHERE s.org_id = #{org}::uuid#{source_type_filter(spec, org)}
       AND s.working_fields ? 'custom_fields'
       AND (s.working_fields->'custom_fields'->#{key}) IS DISTINCT FROM (s.custom_fields->#{key})
    """
  end

  # Dynamic types share the entries table; their rows are told apart by type
  # definition.
  defp source_type_filter(%{source: %{dynamic?: true, type: type}}, org) do
    " AND s.type_definition_id IN (SELECT id FROM type_definitions " <>
      "WHERE org_id = #{org}::uuid AND name = #{literal(type)})"
  end

  defp source_type_filter(_spec, _org), do: ""

  # sobelow_skip ["SQL.Query"]
  defp count(sql) do
    %{rows: [[count]]} = KilnCMS.Repo.query!(sql)
    count
  end

  @doc """
  Retire a graduated field: in every organization that defines it, verify the
  copy and delete the definition, which deletes its stored values and edges
  (`Changes.SyncFieldValues`).

  Refuses — `{:error, reports}`, nothing deleted — unless the join resource
  is compiled with a column for every link field, and every organization's
  `verify/2` report has no `missing`, `unmirrored` or `pending` edge. The
  check and the deletes run in one transaction that holds `content_links` in
  `SHARE` mode, so a connection made while it runs waits, and lands after the
  field is gone (then refused as an unknown field) rather than between the
  check and the delete.

  `dry_run: true` stops after the check: `{:ok, :dry_run, reports}`.
  """
  @spec retire(spec(), keyword()) ::
          {:ok, :retired | :dry_run, %{Ash.UUID.t() => report()}}
          | {:error, String.t() | %{Ash.UUID.t() => report()}}
  def retire(spec, opts \\ []) do
    with :ok <- check_resource(spec) do
      # The table the resource declares, which a project may have renamed
      # since it was generated.
      spec = %{spec | table: AshPostgres.DataLayer.Info.table(spec.module)}

      KilnCMS.Repo.transaction(fn -> retire_locked(spec, opts) end, timeout: :infinity)
      |> case do
        {:ok, {:ok, :retired, reports} = result} ->
          # The destroy busted each org's type registry before this commit,
          # so a read in between could have cached the field again.
          Enum.each(Map.keys(reports), &KilnCMS.Cache.bust_type_registry/1)
          result

        {:ok, result} ->
          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp retire_locked(spec, opts) do
    KilnCMS.Repo.query!("LOCK TABLE content_links IN SHARE MODE")

    definitions = definitions_by_org(spec)
    reports = Map.new(definitions, fn {org_id, _definition} -> {org_id, verify(spec, org_id)} end)

    cond do
      definitions == [] ->
        KilnCMS.Repo.rollback("no organization defines #{spec.source.type}.#{spec.field}")

      not Enum.all?(Map.values(reports), &retirable?/1) ->
        KilnCMS.Repo.rollback(reports)

      opts[:dry_run] ->
        {:ok, :dry_run, reports}

      true ->
        Enum.each(definitions, fn {org_id, definition} ->
          # authorize?: false — the last step of an operator's graduation, at
          # the host's shell with no actor, as `Promotion` archives a type.
          # Granting a system actor `destroy` here would let every system
          # caller delete a site's fields.
          #
          # Its `after_transaction` hooks — the value purge
          # (`SyncFieldValues`) above all — run inside this transaction on
          # purpose: the purge must commit or roll back with the check.
          CMS.destroy_field_definition!(definition,
            authorize?: false,
            tenant: org_id,
            context: %{warn_on_transaction_hooks?: false}
          )
        end)

        {:ok, :retired, reports}
    end
  end

  defp retirable?(report),
    do: report.missing == 0 and report.unmirrored == 0 and report.pending == 0

  defp check_resource(%{module: module, columns: columns}) do
    if Code.ensure_loaded?(module) and Ash.Resource.Info.resource?(module) do
      names = module |> Ash.Resource.Info.attributes() |> MapSet.new(&to_string(&1.name))

      case Enum.reject(columns, &MapSet.member?(names, &1.name)) do
        [] ->
          :ok

        missing ->
          {:error,
           "#{inspect(module)} has no column for link field(s) " <>
             "#{Enum.map_join(missing, ", ", & &1.name)}; its copy cannot be verified"}
      end
    else
      {:error,
       "#{inspect(module)} is not compiled; generate it and run its migrations first " <>
         "(mix kiln.gen.join, mix ash.codegen, mix ash.migrate)"}
    end
  end

  # Each organization's definition of the field, in every org that has one.
  defp definitions_by_org(spec) do
    KilnCMS.Accounts.list_org_ids()
    |> Enum.flat_map(fn org_id ->
      with {:ok, source} <- side(spec.source.type, org_id),
           {:ok, definition} <- definition(source, spec.field, org_id) do
        [{org_id, definition}]
      else
        _none -> []
      end
    end)
  end

  defp registry_actor, do: KilnCMS.CMS.Housekeeping.system(:cms_registry)
end
