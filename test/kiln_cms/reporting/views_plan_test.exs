defmodule KilnCMS.Reporting.ViewsPlanTest do
  @moduledoc """
  The reporting views' query plans at scale (#2295). At a handful of rows
  Postgres seq-scans anything, so the plan only means something once the
  tables are big enough that a missing index or a failed pushdown shows: 20k
  published pages and 1.5k field definitions. A lookup by record through the
  `security_barrier` view must still seek the page by key (the id predicate
  is pushed in because `uuid =` is leakproof), and the allowlist must find
  its definitions by index rather than scan them per row.
  """
  # Not async: each test creates a role and GRANTs on the shared schema, which
  # lock the same catalog rows; two open sandbox transactions doing so deadlock.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.ReportingRole

  @pages 20_000
  @definitions 1_500

  defp bulk_copy!(table, template_id, overrides, count) do
    %{rows: rows} =
      KilnCMS.Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 AND is_generated = 'NEVER' " <>
          "AND column_name <> ALL($2)",
        [table, ["id" | Map.keys(overrides)]]
      )

    cols = Enum.map_join(List.flatten(rows), ", ", &~s("#{&1}"))
    names = Enum.map_join(overrides, ", ", fn {col, _} -> ~s("#{col}") end)
    exprs = Enum.map_join(overrides, ", ", fn {_, expr} -> expr end)

    KilnCMS.Repo.query!(
      "INSERT INTO #{table} (id, #{names}, #{cols}) " <>
        "SELECT gen_random_uuid(), #{exprs}, #{cols} FROM #{table}, generate_series(1, #{count}) g " <>
        "WHERE id = $1",
      [Ecto.UUID.dump!(template_id)]
    )
  end

  defp plan(role, sql, params) do
    ReportingRole.as(role, fn ->
      %{rows: [[json]]} =
        KilnCMS.Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)

      json
    end)
  end

  defp nodes(%{"Plan" => root}), do: nodes(root)

  defp nodes(%{} = node),
    do: [node | Enum.flat_map(Map.get(node, "Plans", []), &nodes/1)]

  defp seq_scans(json, relation) do
    json
    |> List.first()
    |> nodes()
    |> Enum.filter(&(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == relation))
  end

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "rpt-plan-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    definition =
      CMS.create_field_definition!(
        %{content_type: :page, name: "motto", label: "Motto", field_type: :string},
        actor: admin
      )

    page =
      %{
        title: "Template",
        slug: "tpl-#{System.unique_integer([:positive])}",
        custom_fields: %{"motto" => "x"}
      }
      |> CMS.create_page!(actor: admin)
      |> CMS.publish_page!(actor: admin)

    # Every row gets its own values (and keys that name a definition), so the
    # executor cannot memoize the allowlist work away.
    custom =
      "jsonb_build_object('motto', 'v' || g, 'f' || (g % #{@definitions} + 1), g, " <>
        "'stray' || g, 'x')"

    bulk_copy!("pages", page.id, %{"slug" => "'bulk-' || g", "custom_fields" => custom}, @pages)
    bulk_copy!("field_definitions", definition.id, %{"name" => "'f' || g"}, @definitions)

    KilnCMS.Repo.query!("ANALYZE pages")
    KilnCMS.Repo.query!("ANALYZE field_definitions")

    %{role: ReportingRole.create!(), page: page}
  end

  @queries [
    {"a record by id, wide", "SELECT * FROM kiln_reporting_v1.pages WHERE id = $1", :id},
    {"a record by id, long",
     "SELECT * FROM kiln_reporting_v1.pages_field_values WHERE record_id = $1", :id},
    {"every record, wide", "SELECT count(custom_fields) FROM kiln_reporting_v1.pages", :none},
    {"every value of one field, long",
     "SELECT count(*) FROM kiln_reporting_v1.pages_field_values WHERE field_name = 'motto'",
     :none}
  ]

  for {name, sql, args} <- @queries do
    test "#{name}: the definitions are never scanned once per row", %{role: role, page: page} do
      params = if unquote(args) == :id, do: [Ecto.UUID.dump!(page.id)], else: []
      [%{"Execution Time" => ms}] = json = plan(role, unquote(sql), params)

      # Informational timing for the report; the assertions are structural.
      if System.get_env("KILN_REPORTING_PLAN_DEBUG") do
        IO.puts("#{unquote(name)}: #{ms} ms, " <> inspect(summary(json)))
      end

      # A definitions scan that repeats per record is the shape that costs
      # seconds at 20k rows; a once-only scan (a hash build) or an index probe
      # is fine.
      repeated =
        json
        |> List.first()
        |> nodes()
        |> Enum.filter(
          &(&1["Relation Name"] == "field_definitions" and &1["Node Type"] == "Seq Scan" and
              &1["Actual Loops"] > 1)
        )

      assert [] == repeated
      if unquote(args) == :id, do: assert([] == seq_scans(json, "pages"))
    end
  end

  defp summary(json) do
    json
    |> List.first()
    |> nodes()
    |> Enum.map(
      &{&1["Node Type"], &1["Relation Name"], &1["Actual Loops"], &1["Actual Total Time"]}
    )
  end
end
