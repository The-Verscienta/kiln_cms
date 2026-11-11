defmodule KilnCMS.CMS.CustomFieldIndexTest do
  @moduledoc """
  `custom_filter` equality, `in` and list-has are answered from the
  `<table>_custom_fields_gin_index` GIN index (`jsonb_path_ops`) rather than a
  sequential scan (#2291).

  The plan assertions run against 20,000 seeded rows after an explicit
  `ANALYZE`, at default planner settings (no `enable_seqscan = off`): at
  fixture scale a scan is the cheaper plan and the question has no answer.
  They EXPLAIN the SQL Ash actually issues, captured off the repo's telemetry
  and replayed with its real bound parameters, so a predicate that stops
  matching the index fails here. The replay runs repeatedly, because Postgres
  plans a prepared statement's first executions against the actual values and
  then may switch to a value-blind generic plan; a forced generic plan is
  checked too.
  """
  # Not async (the plan assertions cost a table other tests also write and
  # roll back, and dead tuples skew its size).
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo

  @rows 20_000
  # Distinct values per field: each value is carried by @rows / @distinct = 10
  # rows, 0.05% of the table.
  @distinct 2_000

  # The setup writes @rows rows into each of two indexed tables, then merges
  # the GIN pending lists and analyzes. Under load from another suite on the
  # same host, these statements can take longer than the repo's default 15 s
  # query `:timeout` (#2334: the `entries` INSERT was cut off at 15 s while
  # the plan assertions themselves held), so they get their own bound, and
  # ExUnit's 60 s test timeout (which covers `setup`) is raised to match.
  # Both stay under the SQL sandbox's 120 s ownership timeout
  # (`KilnCMS.DataCase.setup_sandbox/1` sets none, so DBConnection's default
  # applies): past it the owner's connection is dropped whatever these say.
  @seed_timeout :timer.seconds(45)
  @moduletag timeout: :timer.seconds(110)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfi-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  describe "the index" do
    test "every content table carries it, GIN, jsonb_path_ops, valid" do
      for table <- ["pages", "posts", "entries"] do
        %{rows: rows} =
          Repo.query!(
            """
            SELECT pg_get_indexdef(i.indexrelid), i.indisvalid
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            WHERE c.relname = $1
            """,
            ["#{table}_custom_fields_gin_index"]
          )

        assert [[indexdef, true]] = rows, "#{table} has no valid custom fields index"
        assert indexdef =~ "USING gin"
        assert indexdef =~ "(custom_fields jsonb_path_ops)"
        # No tenant column: a GIN over a plain uuid needs btree_gin, and the
        # query's `org_id = ?` rides along as a filter.
        refute indexdef =~ "org_id"
      end
    end

    test "the version tables do not" do
      for table <- ["pages_versions", "posts_versions", "entries_versions"] do
        %{rows: rows} =
          Repo.query!("SELECT 1 FROM pg_indexes WHERE tablename = $1 AND indexdef ~ $2", [
            table,
            "custom_fields"
          ])

        assert rows == [], "#{table} should not index custom_fields"
      end
    end
  end

  describe "plans on a realistic table" do
    setup do
      admin = admin()
      org_id = KilnCMS.Accounts.default_org_id()
      org = Ecto.UUID.dump!(org_id)

      # Fields hold an integer (`price`), a string (`color`) and a multiple
      # select (`tags`); every one takes @distinct values over @rows rows.
      Repo.query!(
        """
        INSERT INTO pages (id, title, slug, org_id, locale, state, custom_fields)
        SELECT gen_random_uuid(), 'cfi ' || i, 'cfi-' || i, $1, 'en', 'published',
               jsonb_build_object('price', i % $2, 'color', 'c' || (i % $2),
                                  'tags', jsonb_build_array('t' || (i % $2), 'common'))
        FROM generate_series(1, $3) AS i
        """,
        [org, @distinct, @rows],
        timeout: @seed_timeout
      )

      for {name, type} <- [{"price", :integer}, {"color", :string}] do
        CMS.create_field_definition!(
          %{content_type: :page, label: name, name: name, field_type: type},
          actor: admin
        )
      end

      CMS.create_field_definition!(
        %{
          content_type: :page,
          label: "tags",
          name: "tags",
          field_type: :select,
          multiple: true,
          options: ["t7", "t8", "t9", "common"]
        },
        actor: admin
      )

      type =
        CMS.create_type_definition!(
          %{name: "cfi#{System.unique_integer([:positive])}", label: "Dyn"},
          actor: admin
        )

      for {name, ftype} <- [{"price", :integer}, {"color", :string}] do
        CMS.create_field_definition!(
          %{type_definition_id: type.id, label: name, name: name, field_type: ftype},
          actor: admin
        )
      end

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          label: "tags",
          name: "tags",
          field_type: :select,
          multiple: true,
          options: ["t7", "t8", "t9", "common"]
        },
        actor: admin
      )

      Repo.query!(
        """
        INSERT INTO entries (id, title, slug, org_id, locale, state, type_definition_id, custom_fields)
        SELECT gen_random_uuid(), 'cfi ' || i, 'cfi-' || i, $1, 'en', 'published', $4,
               jsonb_build_object('price', i % $2, 'color', 'c' || (i % $2),
                                  'tags', jsonb_build_array('t' || (i % $2), 'common'))
        FROM generate_series(1, $3) AS i
        """,
        [org, @distinct, @rows, Ecto.UUID.dump!(type.id)],
        timeout: @seed_timeout
      )

      # Statistics for the rows just written, so the planner costs the table it
      # has rather than the near-empty one it last sampled. Its `pg_statistic`
      # rows roll back with the sandbox.
      #
      # A GIN index takes new rows into a pending list first (`fastupdate`),
      # and the planner costs every scan of it by that list's size. Rows that
      # earlier tests inserted and rolled back stay in the list until a vacuum
      # merges it, so its size, and with it the `in` plan, depended on what
      # ran before this module (#2333 CI: a Bitmap Index Scan on
      # entries_unique_slug_index won). Merge it now so the plan is costed on
      # this table alone. `type_definitions` is the other side of the entries
      # join; analyze it too rather than plan against whatever autovacuum
      # last sampled.
      Repo.query!("SELECT gin_clean_pending_list('pages_custom_fields_gin_index')", [],
        timeout: @seed_timeout
      )

      Repo.query!("SELECT gin_clean_pending_list('entries_custom_fields_gin_index')", [],
        timeout: @seed_timeout
      )

      Repo.query!("ANALYZE pages", [], timeout: @seed_timeout)
      Repo.query!("ANALYZE entries", [], timeout: @seed_timeout)
      Repo.query!("ANALYZE type_definitions", [], timeout: @seed_timeout)

      %{admin: admin, org_id: org_id, type: type}
    end

    defp read_page(filter, admin) do
      fn -> CMS.list_pages!(%{custom_filter: filter}, actor: admin) end
    end

    defp read_entry(filter, type, admin) do
      fn ->
        CMS.list_entries!(%{custom_filter: filter},
          query: [filter: [type_name: type.name]],
          actor: admin
        )
      end
    end

    # `seqscan: :off` is for `in`: a bitmap OR of GIN scans carries a fixed cost per
    # value, so at fixture scale the planner may rightly prefer a Seq Scan (the
    # 100k benchmark in docs/benchmarks.md covers its real choice). It still proves
    # the predicate is index-matchable, which is what the rewrite is for.
    defp assert_indexed(source, fun, index, opts \\ []) do
      pre = if opts[:seqscan] == :off, do: "SET LOCAL enable_seqscan = off"

      {sql, params} = capture_query(source, fun)

      # Every execution: the first ones are planned against the real values,
      # later ones may be a generic plan.
      for run <- 1..8 do
        plan = explain(sql, params, pre)

        assert plan =~ index, "run #{run}: #{plan}"

        assert Enum.any?(
                 String.split(plan, "\n"),
                 &(&1 =~ "Index Cond:" and &1 =~ "custom_fields @>")
               ),
               "run #{run}: #{plan}"

        refute plan =~ "Seq Scan on #{source}", "run #{run}: #{plan}"
      end

      # And a plan that never sees the values at all.
      plan = explain(sql, params, [pre, "SET LOCAL plan_cache_mode = force_generic_plan"])
      assert plan =~ index, plan
      assert plan =~ "Index Cond:", plan
      refute plan =~ "Seq Scan on #{source}", plan
    end

    test "page equality", %{admin: admin} do
      assert_indexed(
        "pages",
        read_page(%{"price" => %{"eq" => "7"}}, admin),
        "pages_custom_fields_gin_index"
      )

      assert_indexed(
        "pages",
        read_page(%{"color" => "c7"}, admin),
        "pages_custom_fields_gin_index"
      )
    end

    test "page in", %{admin: admin} do
      assert_indexed(
        "pages",
        read_page(%{"price" => %{"in" => ["7", "8", "9"]}}, admin),
        "pages_custom_fields_gin_index",
        seqscan: :off
      )
    end

    test "page list-has", %{admin: admin} do
      assert_indexed(
        "pages",
        read_page(%{"tags" => "t7"}, admin),
        "pages_custom_fields_gin_index"
      )
    end

    test "entry equality", %{admin: admin, type: type} do
      assert_indexed(
        "entries",
        read_entry(%{"price" => %{"eq" => "7"}}, type, admin),
        "entries_custom_fields_gin_index"
      )
    end

    test "entry in", %{admin: admin, type: type} do
      assert_indexed(
        "entries",
        read_entry(%{"color" => %{"in" => ["c7", "c8", "c9"]}}, type, admin),
        "entries_custom_fields_gin_index",
        seqscan: :off
      )
    end

    test "entry list-has", %{admin: admin, type: type} do
      assert_indexed(
        "entries",
        read_entry(%{"tags" => "t7"}, type, admin),
        "entries_custom_fields_gin_index"
      )
    end

    test "the answers are the rows the filter names", %{admin: admin, type: type} do
      pages = CMS.list_pages!(%{custom_filter: %{"price" => "7"}}, actor: admin)
      assert length(pages) == div(@rows, @distinct)
      assert Enum.all?(pages, &(&1.custom_fields["price"] == 7))

      entries =
        CMS.list_entries!(%{custom_filter: %{"tags" => "t7"}},
          query: [filter: [type_name: type.name]],
          actor: admin
        )

      assert length(entries) == div(@rows, @distinct)

      in_pages =
        CMS.list_pages!(%{custom_filter: %{"price" => %{"in" => ["7", "8"]}}}, actor: admin)

      assert length(in_pages) == 2 * div(@rows, @distinct)
    end

    test "the public JSON:API path is planned through it", %{conn: conn} do
      fun = fn ->
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/json/pages?custom_filter[price]=7")
        |> json_response(200)
      end

      body = fun.()
      assert length(body["data"]) == div(@rows, @distinct)

      assert_indexed("pages", fun, "pages_custom_fields_gin_index")
    end

    test "range stays unindexed, as documented", %{admin: admin} do
      {sql, params} =
        capture_query(
          "pages",
          read_page(%{"price" => %{"gt" => "1990"}}, admin),
          ~r/FROM "pages"/
        )

      refute explain(sql, params) =~ "pages_custom_fields_gin_index"
    end

    test "a tenant-scoped read returns no other tenant's rows", %{admin: admin, org_id: org_id} do
      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org cfi",
          slug: "cfi-#{System.unique_integer([:positive])}",
          status: :active
        })

      Ash.Seed.seed!(CMS.Page, %{
        title: "other tenant",
        slug: "cfi-other",
        org_id: other.id,
        state: :published,
        custom_fields: %{"price" => 7}
      })

      CMS.create_field_definition!(
        %{content_type: :page, label: "price", name: "price", field_type: :integer},
        actor: admin,
        tenant: other.id
      )

      mine = CMS.list_pages!(%{custom_filter: %{"price" => "7"}}, actor: admin, tenant: org_id)

      theirs =
        CMS.list_pages!(%{custom_filter: %{"price" => "7"}}, actor: admin, tenant: other.id)

      assert length(mine) == div(@rows, @distinct)
      refute Enum.any?(mine, &(&1.org_id == other.id))
      assert Enum.map(theirs, & &1.title) == ["other tenant"]
    end
  end

  # The SQL and parameters of the one `custom_fields @>` query `fun` issues
  # against `source`.
  def capture_query(source, fun, pattern \\ ~r/"custom_fields"(::jsonb)? @>/) do
    test = self()
    handler = "cfi-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta[:source] == source and
             Regex.match?(pattern, meta[:query]),
           do: send(test, {:captured, meta[:query], meta[:params]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    assert_received {:captured, sql, params}
    {sql, params}
  end

  def explain(sql, params, setup \\ nil) do
    for stmt <- List.wrap(setup), stmt, do: Repo.query!(stmt)

    Repo.query!("EXPLAIN (FORMAT TEXT) " <> sql, params).rows
    |> Enum.map_join("\n", &hd/1)
  end
end
