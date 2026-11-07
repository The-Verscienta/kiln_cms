defmodule KilnCMS.Reporting.ViewSql do
  @moduledoc """
  The SQL behind the read-only reporting views in the `kiln_reporting_v1`
  schema (#2295).

  Every content table gets two plain `security_barrier` views, created by a
  `custom_statements` entry of the `KilnCMS.CMS.Content` macro (so the SQL
  reaches the database through `mix ash.codegen`, never at runtime):

    * `kiln_reporting_v1.<table>`: the core columns plus `custom_fields`
      narrowed to an **allowlist** of keys;
    * `kiln_reporting_v1.<table>_field_values`: the same values, one row per
      record and field (`org_id, record_id, type_name, field_name, field_type,
      multiple, value_text, value_json`).

  ## What a view carries

  A key reaches a view only while a live `field_definitions` row of the
  record's own site and type names it and that row is neither `private` nor a
  `user` field, and neither a link field nor a group sub-field. The allowlist
  is read live, so a flip to private, a rename, a retype or a delete takes
  effect on the next query. Undefined and orphaned keys are dropped (a
  denylist would leak them). `search_text`, `embedding`, `working_*` and
  `access_password_hash` are not in any column list.

  What is guaranteed for the values of the allowed keys:

    * **Reference fields** are projected to `{"id", "type"}` (a list of them
      for a `multiple` field). The stored snapshot's `slug` and `title` are
      never exposed, because they were taken whatever state the target was in
      and can name a draft (`KilnCMS.CMS.ReferenceSnapshots`). The projection
      keys on the field's type and also on the snapshot's shape, so a snapshot
      left under a field that was retyped is cut down too. The target ids are
      still visible; a view does not check whether the target is public.
    * **Media fields** pass through as stored: the `KilnCMS.Media.Snapshot`
      shape (`id`, `url`, `alt`, `width`, `height`, `mime_type`, `focal`,
      `variants` with their urls), which is the same data a published page
      links to.
    * Every other allowed value is exposed as stored, including an
      off-type value a retype left behind.

  A row is visible while it is `published`, not archived, without an access
  password, and for the `public` audience.

  The views are a public SQL contract, additive-only in 1.x. A new view must
  be a `CREATE OR REPLACE` (a statement here carries no destructive verb);
  `down` removes only the views.
  """

  @schema "kiln_reporting_v1"

  # Every column pins a base column (Postgres refuses to alter or drop one a
  # view references): `kiln.migrations.check` reads this list.
  @core_columns ~w(id org_id title slug locale audience state published_at inserted_at updated_at)

  @doc "The schema the views live in."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The base-table columns the views reference."
  @spec core_columns() :: [String.t()]
  def core_columns, do: @core_columns ++ ~w(custom_fields archived_at access_password_hash)

  @doc """
  Every content-table column any view references. `mix kiln.migrations.check`
  keeps its own copy (it reads migrations with the standard library alone);
  a test keeps the two equal.
  """
  @spec pinned_columns() :: [String.t()]
  def pinned_columns, do: core_columns() ++ ["type_definition_id"]

  @doc """
  The columns the views read from tables that are not content tables, keyed by
  table. Postgres refuses to alter or drop these too while a view reads them.
  """
  @spec pinned_other_columns() :: %{String.t() => [String.t()]}
  def pinned_other_columns do
    %{
      "field_definitions" =>
        ~w(name org_id type_definition_id content_type private field_type multiple link_of_id group_of_id),
      "type_definitions" => ~w(id org_id name path_segment)
    }
  end

  @doc "Creates the schema (idempotent)."
  @spec create_schema() :: String.t()
  def create_schema, do: "CREATE SCHEMA IF NOT EXISTS #{@schema}"

  @doc "The no-op `down` of the schema statement: the views are removed one by one."
  @spec keep_schema() :: String.t()
  def keep_schema, do: "SELECT 1"

  @doc "The wide view of `table`: core columns plus allowlisted `custom_fields`."
  @spec records_view(String.t(), String.t(), boolean()) :: String.t()
  def records_view(table, type, dynamic?) do
    {extra_cols, extra_join} = entry_parts(dynamic?, type)

    core = Enum.map_join(@core_columns, ", ", &"t.#{&1}")

    "CREATE OR REPLACE VIEW #{@schema}.#{table} WITH (security_barrier = true) AS " <>
      "SELECT #{core}#{extra_cols}, COALESCE(cf.allowed, '{}'::jsonb) AS custom_fields " <>
      "FROM #{table} t#{extra_join} " <>
      "LEFT JOIN LATERAL (" <>
      "SELECT jsonb_object_agg(fd.name, #{projected()}) AS allowed " <>
      "FROM field_definitions fd#{value_join()} " <>
      "WHERE #{keys_in_record()} AND #{allowed_definition(type, dynamic?)}" <>
      ") cf ON true " <>
      "WHERE #{row_filter()}"
  end

  @doc "The long view of `table`: one row per record and allowlisted field."
  @spec field_values_view(String.t(), String.t(), boolean()) :: String.t()
  def field_values_view(table, type, dynamic?) do
    {_cols, extra_join} = entry_parts(dynamic?, type)

    type_name = if dynamic?, do: "td.name", else: "'#{type}'::text"

    "CREATE OR REPLACE VIEW #{@schema}.#{table}_field_values WITH (security_barrier = true) AS " <>
      "SELECT t.org_id, t.id AS record_id, #{type_name} AS type_name, " <>
      "f.name AS field_name, f.field_type, f.multiple, #{value_text()} AS value_text, " <>
      "f.value AS value_json " <>
      "FROM #{table} t#{extra_join} " <>
      "CROSS JOIN LATERAL (" <>
      "SELECT fd.name, fd.field_type::text AS field_type, fd.multiple, " <>
      "#{projected()} AS value " <>
      "FROM field_definitions fd#{value_join()} " <>
      "WHERE #{keys_in_record()} AND #{allowed_definition(type, dynamic?)}" <>
      ") f " <>
      "WHERE #{row_filter()}"
  end

  @doc "`down` for `records_view/3`."
  @spec drop_records_view(String.t()) :: String.t()
  def drop_records_view(table), do: "DROP VIEW IF EXISTS #{@schema}.#{table}"

  @doc "`down` for `field_values_view/3`."
  @spec drop_field_values_view(String.t()) :: String.t()
  def drop_field_values_view(table), do: "DROP VIEW IF EXISTS #{@schema}.#{table}_field_values"

  # The stored value of the field a definition names, as `val.v`.
  defp value_join,
    do: " CROSS JOIN LATERAL (SELECT t.custom_fields -> fd.name AS v) val"

  @snapshot_keys "ARRAY['id', 'type', 'slug', 'title']"

  # The stored `:reference` snapshot is `{id, type, slug, title}`, taken
  # whatever state the target was in: its slug and title can name a draft. A
  # view keeps `{id, type}` only. A reference field's objects are cut down
  # whatever their shape; for any other field only a value shaped like a
  # snapshot is (the leftover of a retype), and a media snapshot, which has
  # a `url`, is not one. Every branch is guarded by `jsonb_typeof`, so a value
  # of the wrong type passes through instead of raising.
  defp projected do
    ref = "fd.field_type::text = 'reference'"

    "CASE " <>
      "WHEN jsonb_typeof(val.v) = 'object' THEN #{id_and_type("val.v", ref)} " <>
      "WHEN jsonb_typeof(val.v) = 'array' AND (#{ref} OR val.v @? '$[*].slug') THEN " <>
      "COALESCE((SELECT jsonb_agg(#{id_and_type("e.x", ref)} ORDER BY e.n) " <>
      "FROM jsonb_array_elements(val.v) WITH ORDINALITY AS e(x, n)), '[]'::jsonb) " <>
      "ELSE val.v END"
  end

  defp id_and_type(x, ref) do
    "CASE WHEN jsonb_typeof(#{x}) = 'object' AND (#{ref} OR " <>
      "(#{x} ?& #{@snapshot_keys} AND NOT #{x} ? 'url')) " <>
      "THEN jsonb_build_object('id', #{x} -> 'id', 'type', #{x} -> 'type') ELSE #{x} END"
  end

  # A single reference reads as its id; everything else as the plain text of
  # its JSON (a string without quotes, a number, a list as JSON).
  defp value_text do
    "CASE WHEN f.field_type = 'reference' AND f.multiple IS NOT TRUE " <>
      "AND jsonb_typeof(f.value) = 'object' THEN f.value ->> 'id' " <>
      "ELSE f.value #>> '{}' END"
  end

  # Entries carry their type in a row of `type_definitions`; the row's own site
  # must match, or a foreign type's name would label the record.
  defp entry_parts(true, _type) do
    {", t.type_definition_id, td.name AS type_name, td.path_segment AS type_slug",
     " LEFT JOIN type_definitions td ON td.id = t.type_definition_id AND td.org_id = t.org_id"}
  end

  defp entry_parts(false, _type), do: {"", ""}

  # The definitions are probed by name from the record's own keys, so the
  # planner takes the index of the definitions rather than scanning them for
  # every record (20k records over 1.5k definitions: 8 s the other way round).
  defp keys_in_record,
    do: "fd.name = ANY (ARRAY(SELECT jsonb_object_keys(#{object_of("t.custom_fields")})))"

  defp object_of(column),
    do: "CASE WHEN jsonb_typeof(#{column}) = 'object' THEN #{column} ELSE '{}'::jsonb END"

  # The definitions a key may name: the record's own site and type, a plain
  # top-level field, neither private nor a console account. Link fields and
  # group sub-fields are marked by `link_of_id` / `group_of_id`.
  defp allowed_definition(type, dynamic?) do
    scope =
      if dynamic?,
        do: "fd.type_definition_id = t.type_definition_id",
        else: "fd.type_definition_id IS NULL AND fd.content_type = '#{type}'"

    "fd.org_id = t.org_id AND #{scope} AND fd.private = false " <>
      "AND fd.field_type <> 'user' AND fd.link_of_id IS NULL AND fd.group_of_id IS NULL"
  end

  defp row_filter do
    "t.state = 'published' AND t.archived_at IS NULL " <>
      "AND t.access_password_hash IS NULL AND t.audience = 'public'"
  end
end
