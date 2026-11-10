defmodule KilnCMS.CMS.CustomFieldRangeIndexTest do
  @moduledoc """
  Range filters and `custom_sort` on a field listed in
  `config :kiln_cms, :indexed_custom_fields` are answered from that field's
  btrees (#2359, ADR 0025). The test environment declares none (CI's
  `mix ash.codegen --check` would call them pending), so a setup block lists
  `idx_price` and `idx_rating` through the module's test seam.

  Tagged `:table_lock`: it creates indexes on `pages` and `entries`, and a
  `CREATE INDEX` inside the sandbox holds a lock on the shared table until the
  rollback. Run it with `mix test --only table_lock`.

  The indexes are not in the migrations (core ships none, the way a site that
  has not opted in has none), so setup builds them from the very definitions
  the Content macro would declare (`IndexedCustomFields.index_specs/1`),
  org-leading as codegen would. The plan assertions then run against 20,000
  rows after `ANALYZE`, at default planner settings, replaying the SQL Ash
  issued with its real parameters eight times and once as a forced generic
  plan: a literal field name is what keeps the index in use after the fifth
  execution.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :table_lock

  alias KilnCMS.CMS
  alias KilnCMS.CMS.IndexedCustomFields
  alias KilnCMS.Repo

  @rows 20_000

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  @names ["idx_price", "idx_rating"]

  setup do
    previous = Application.get_env(:kiln_cms, :indexed_custom_fields_override)

    Application.put_env(
      :kiln_cms,
      :indexed_custom_fields_override,
      Map.new(~w(pages posts entries), &{&1, @names})
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :indexed_custom_fields_override, previous),
        else: Application.delete_env(:kiln_cms, :indexed_custom_fields_override)
    end)
  end

  describe "the declared indexes" do
    test "the test environment declares none; a listed name yields an asc and a desc btree" do
      for resource <- [CMS.Page, CMS.Post, CMS.Entry] do
        refute Enum.any?(
                 AshPostgres.DataLayer.Info.custom_indexes(resource),
                 &String.contains?(&1.name, "_cf_")
               )
      end

      for table <- ~w(pages posts entries) do
        assert IndexedCustomFields.names(table) == @names
        specs = Map.new(IndexedCustomFields.index_specs(table), &{&1.name, &1.expr})
        assert map_size(specs) == 4

        for name <- @names, direction <- [:asc, :desc] do
          expr = Map.fetch!(specs, IndexedCustomFields.index_name(table, name, direction))
          assert expr =~ IndexedCustomFields.index_sql(name)
          assert expr =~ if(direction == :asc, do: "ASC NULLS LAST", else: "DESC NULLS LAST")
        end

        assert length(IndexedCustomFields.index_entries(table)) == 4
      end
    end

    test "the SQL is injection-proof by construction" do
      refute IndexedCustomFields.valid?("pages", "price'; drop table pages; --")
      refute IndexedCustomFields.valid?("pages", "not_listed")
      refute IndexedCustomFields.valid?("unknown_table", "idx_price")
      refute IndexedCustomFields.sort_sql("idx_price") =~ ~r/\?.*\?.*\?/
    end
  end

  describe "plans on a realistic table" do
    setup do
      admin = admin()
      org_id = KilnCMS.Accounts.default_org_id()
      org = Ecto.UUID.dump!(org_id)

      # `idx_price` is unique per row (so a sort has an order to follow), 5% of
      # rows have no key and 1% hold a JSON null. `plain` is the same without
      # an index.
      Repo.query!(
        """
        INSERT INTO pages (id, title, slug, org_id, locale, state, custom_fields)
        SELECT gen_random_uuid(), 'cfr ' || i, 'cfr-' || i, $1, 'en', 'published',
               CASE WHEN i % 20 = 0 THEN '{}'::jsonb
                    WHEN i % 100 = 1 THEN jsonb_build_object('idx_price', null, 'plain', null)
                    ELSE jsonb_build_object('idx_price', i, 'plain', i) END
        FROM generate_series(1, $2) AS i
        """,
        [org, @rows]
      )

      for {name, type} <- [{"idx_price", :integer}, {"plain", :integer}] do
        CMS.create_field_definition!(
          %{content_type: :page, label: name, name: name, field_type: type},
          actor: admin
        )
      end

      dyn =
        CMS.create_type_definition!(
          %{name: "cfr#{System.unique_integer([:positive])}", label: "Dyn"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{type_definition_id: dyn.id, label: "p", name: "idx_price", field_type: :integer},
        actor: admin
      )

      Repo.query!(
        """
        INSERT INTO entries (id, title, slug, org_id, locale, state, type_definition_id, custom_fields)
        SELECT gen_random_uuid(), 'cfr ' || i, 'cfr-' || i, $1, 'en', 'published', $3,
               jsonb_build_object('idx_price', i)
        FROM generate_series(1, $2) AS i
        """,
        [org, @rows, Ecto.UUID.dump!(dyn.id)]
      )

      for table <- ~w(pages posts entries), spec <- IndexedCustomFields.index_specs(table) do
        Repo.query!("CREATE INDEX #{spec.name} ON #{table} (org_id, #{spec.expr})")
      end

      Repo.query!("ANALYZE pages")
      Repo.query!("ANALYZE entries")
      Repo.query!("ANALYZE type_definitions")

      %{admin: admin, org_id: org_id, type: dyn}
    end

    defp pages(args, admin, org_id),
      do: fn -> CMS.list_pages!(args, actor: admin, tenant: org_id, page: [limit: 20]) end

    defp entries(args, type, admin, org_id) do
      fn ->
        CMS.list_entries!(args,
          query: [filter: [type_name: type.name]],
          actor: admin,
          tenant: org_id,
          page: [limit: 20]
        )
      end
    end

    # The SQL of the one read against `source` that orders or filters by the
    # indexed expression.
    defp capture(source, fun),
      do: capture_query(source, fun, ~r/FROM "#{source}"/)

    defp assert_btree(source, fun, index_name, opts \\ []) do
      {sql, params} = capture(source, fun)

      # As a prepared statement is executed: Postgres plans the first five
      # runs against the values and then compares a value-blind generic plan.
      name = "cfr_#{System.unique_integer([:positive])}"
      Repo.query!("PREPARE #{name} AS " <> sql)

      # `generic: true` skips the five custom runs. Only a query whose
      # parameters are not the selective part (a sort: tenant, name, limit) can
      # hold its index there; a range's bound value is what a generic plan
      # cannot see.
      if opts[:generic], do: Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")

      try do
        for run <- 1..10 do
          plan =
            Repo.query!("EXPLAIN EXECUTE #{name}(#{Enum.map_join(params, ", ", &literal/1)})").rows
            |> Enum.map_join("\n", &hd/1)

          assert plan =~ index_name, "run #{run}: #{plan}"
          refute plan =~ "Seq Scan on #{source}", "run #{run}: #{plan}"
        end
      after
        Repo.query!("DEALLOCATE #{name}")
      end
    end

    test "page range", %{admin: admin, org_id: org_id} do
      assert_btree(
        "pages",
        pages(%{custom_filter: %{"idx_price" => %{"gt" => "19900"}}}, admin, org_id),
        "pages_cf_idx_price_"
      )
    end

    test "page sort with a limit, ascending and descending", %{admin: admin, org_id: org_id} do
      assert_btree(
        "pages",
        pages(%{custom_sort: "idx_price"}, admin, org_id),
        "pages_cf_idx_price_asc_index"
      )

      # A value-blind generic plan is where a bound field name loses the index.
      assert_btree(
        "pages",
        pages(%{custom_sort: "-idx_price"}, admin, org_id),
        "pages_cf_idx_price_desc_index",
        generic: true
      )

      assert_btree(
        "pages",
        pages(%{custom_sort: "-idx_price"}, admin, org_id),
        "pages_cf_idx_price_desc_index"
      )
    end

    test "entry range and sort", %{admin: admin, org_id: org_id, type: type} do
      assert_btree(
        "entries",
        entries(%{custom_filter: %{"idx_price" => %{"lte" => "50"}}}, type, admin, org_id),
        "entries_cf_idx_price_"
      )

      assert_btree(
        "entries",
        entries(%{custom_sort: "-idx_price"}, type, admin, org_id),
        "entries_cf_idx_price_desc_index"
      )
    end

    test "the keyset page after the first one is indexed too", %{admin: admin, org_id: org_id} do
      first =
        CMS.list_pages!(%{custom_sort: "-idx_price"},
          actor: admin,
          tenant: org_id,
          page: [limit: 20]
        )

      cursor = List.last(first.results).__metadata__.keyset

      assert_btree(
        "pages",
        fn ->
          CMS.list_pages!(%{custom_sort: "-idx_price"},
            actor: admin,
            tenant: org_id,
            page: [limit: 20, after: cursor]
          )
        end,
        "pages_cf_idx_price_desc_index"
      )
    end

    test "an unlisted field is still answered, from the heap", %{admin: admin, org_id: org_id} do
      page = pages(%{custom_filter: %{"plain" => %{"gt" => "19900"}}}, admin, org_id).()
      assert page.results != []

      {sql, params} =
        capture("pages", pages(%{custom_filter: %{"plain" => %{"gt" => "19900"}}}, admin, org_id))

      refute explain(sql, params, nil) =~ "pages_cf_"
    end

    test "the rows are the same as the unindexed form", %{admin: admin, org_id: org_id} do
      listed =
        CMS.list_pages!(
          %{
            custom_filter: %{"idx_price" => %{"gte" => "19990", "lt" => "20000"}},
            custom_sort: "-idx_price"
          },
          actor: admin,
          tenant: org_id
        )

      plain =
        CMS.list_pages!(
          %{
            custom_filter: %{"plain" => %{"gte" => "19990", "lt" => "20000"}},
            custom_sort: "-plain"
          },
          actor: admin,
          tenant: org_id
        )

      assert Enum.map(listed, & &1.custom_fields["idx_price"]) ==
               Enum.map(plain, & &1.custom_fields["plain"])

      refute Enum.any?(listed, &is_nil(&1.custom_fields["idx_price"]))
    end

    test "--check reports drift in both directions and writes nothing", %{admin: admin} do
      # setup built every declared index; only `idx_rating` has no definition.
      assert IndexedCustomFields.check() == [{:unused_name, "idx_rating"}]

      Repo.query!("DROP INDEX pages_cf_idx_price_desc_index")
      Repo.query!("CREATE INDEX posts_cf_stale_asc_index ON posts (title)")

      Repo.query!(
        "UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'entries_cf_idx_price_asc_index'::regclass"
      )

      CMS.create_field_definition!(
        %{content_type: :post, label: "r", name: "idx_rating", field_type: :string},
        actor: admin
      )

      assert IndexedCustomFields.check() == [
               {:ineligible_type, "idx_rating (string)"},
               {:invalid_index, "entries_cf_idx_price_asc_index"},
               {:missing_index, "pages_cf_idx_price_desc_index"},
               {:unlisted_index, "posts_cf_stale_asc_index"}
             ]
    end

    test "a stored JSON null, array or object matches no range, indexed or not",
         %{admin: admin, org_id: org_id} do
      org = Ecto.UUID.dump!(org_id)

      Repo.query!(
        """
        INSERT INTO pages (id, title, slug, org_id, locale, state, custom_fields)
        VALUES (gen_random_uuid(), 'arr', 'cfr-arr', $1, 'en', 'published',
                '{"idx_price": [1], "plain": [1]}'),
               (gen_random_uuid(), 'obj', 'cfr-obj', $1, 'en', 'published',
                '{"idx_price": {"a": 1}, "plain": {"a": 1}}')
        """,
        [org]
      )

      for name <- ["idx_price", "plain"] do
        titles =
          CMS.list_pages!(%{custom_filter: %{name => %{"gt" => "0"}}},
            actor: admin,
            tenant: org_id
          )
          |> Enum.map(& &1.title)

        refute "arr" in titles
        refute "obj" in titles
      end
    end
  end

  # The SQL and parameters of the one query `fun` issues against `source`.
  defp capture_query(source, fun, pattern) do
    test = self()
    handler = "cfr-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta[:source] == source and Regex.match?(pattern, meta[:query]),
          do: send(test, {:captured, meta[:query], meta[:params]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    # The last match: the read itself, after any registry lookups.
    receive_last(nil)
  end

  defp receive_last(last) do
    receive do
      {:captured, sql, params} -> receive_last({sql, params})
    after
      0 -> last || flunk("no query captured")
    end
  end

  defp literal(value) when is_integer(value), do: "'#{value}'"
  defp literal(value) when is_boolean(value), do: to_string(value)
  defp literal(<<_::128>> = uuid), do: "'#{Ecto.UUID.load!(uuid)}'"
  defp literal(value) when is_binary(value), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp literal(value) when is_list(value), do: "'" <> Jason.encode!(value) <> "'"
  defp literal(value) when is_map(value), do: "'" <> Jason.encode!(value) <> "'"

  defp explain(sql, params, setup) do
    for stmt <- List.wrap(setup), stmt, do: Repo.query!(stmt)

    Repo.query!("EXPLAIN (FORMAT TEXT) " <> sql, params).rows
    |> Enum.map_join("\n", &hd/1)
  end
end
