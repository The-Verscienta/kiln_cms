defmodule KilnCMS.Search.VectorScanTest do
  @moduledoc """
  The vector-scan knob for measurement runs: validation, the statements each
  mode sends, that the repo wires them into `after_connect` with the default
  byte-identical to what it always sent, what a live connection reports, and —
  the property the whole thing exists for — that exact mode really takes the
  HNSW index out of the plan while leaving btree indexes usable.

  The plan assertions use `EXPLAIN`, not a recall comparison: a test that
  shows default ef_search dropping a row is a test about pgvector's graph on a
  given insert order, and would flake; the plan is what decides exactness.
  """
  # Sandboxed, so every `SET` below dies with the test's transaction.
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Search.VectorScan

  doctest VectorScan

  describe "normalize!/1" do
    test "accepts the three modes" do
      assert VectorScan.normalize!(nil) == :default
      assert VectorScan.normalize!([]) == :default
      assert VectorScan.normalize!(exact: false) == :default
      assert VectorScan.normalize!(exact: true) == :exact
      assert VectorScan.normalize!(ef_search: 1) == {:ef_search, 1}
      assert VectorScan.normalize!(ef_search: 1000) == {:ef_search, 1000}
      assert VectorScan.normalize!(ef_search: 200, exact: false) == {:ef_search, 200}
    end

    test "refuses pgvector's out-of-range values, garbage, and both at once" do
      for bad <- [0, -1, 1001, "200", 200.0] do
        assert_raise ArgumentError, ~r/ef_search: must be an integer in 1\.\.1000/, fn ->
          VectorScan.normalize!(ef_search: bad)
        end
      end

      assert_raise ArgumentError, ~r/exact: must be a boolean/, fn ->
        VectorScan.normalize!(exact: "true")
      end

      assert_raise ArgumentError, ~r/sets both ef_search and exact/, fn ->
        VectorScan.normalize!(ef_search: 200, exact: true)
      end

      assert_raise ArgumentError, ~r/unknown vector_scan option/, fn ->
        VectorScan.normalize!(ef: 200)
      end

      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        VectorScan.normalize!(%{ef_search: 200})
      end
    end

    test "from_flags!/1 reads OptionParser output by the same rules" do
      assert VectorScan.from_flags!([]) == :default
      assert VectorScan.from_flags!(ef_search: 200) == {:ef_search, 200}
      assert VectorScan.from_flags!(exact: true) == :exact
      assert_raise ArgumentError, fn -> VectorScan.from_flags!(ef_search: 0) end
      assert_raise ArgumentError, fn -> VectorScan.from_flags!(ef_search: 200, exact: true) end
    end
  end

  describe "the repo's after_connect" do
    # Built through the real `init/2`, so this is the MFA the pool would get.
    defp after_connect(vector_scan) do
      config =
        KilnCMS.Repo.config()
        |> Keyword.delete(:after_connect)
        |> Keyword.put(:vector_scan, vector_scan)

      {:ok, config} = KilnCMS.Repo.init(:runtime, config)
      config[:after_connect]
    end

    test "unset sends exactly the one statement every earlier release sent" do
      assert after_connect(nil) ==
               {KilnCMS.Repo, :configure_vector_scan,
                [["SET hnsw.iterative_scan = strict_order"]]}
    end

    test "ef_search and exact add their one statement each" do
      assert {_, _, [["SET hnsw.iterative_scan = strict_order", "SET hnsw.ef_search = 200"]]} =
               after_connect(ef_search: 200)

      assert {_, _, [["SET hnsw.iterative_scan = strict_order", "SET enable_indexscan = off"]]} =
               after_connect(exact: true)
    end

    test "an unusable setting stops the repo from starting rather than defaulting" do
      assert_raise ArgumentError, fn -> after_connect(ef_search: 5000) end
    end
  end

  describe "effective/1 and the report header" do
    test "this suite's connections run the default: strict_order, ef_search 40" do
      scan = VectorScan.effective()

      assert scan == %{
               exact: false,
               ef_search: 40,
               ef_search_set: false,
               iterative_scan: "strict_order"
             }

      refute VectorScan.measurement_grade?(scan)
      header = VectorScan.header(scan)
      assert header =~ "vector scan: approximate HNSW, hnsw.ef_search = 40 (pgvector default)"
      assert header =~ "WARNING: approximate vector recall (ef_search 40)"
      assert header =~ "--ef-search 200 or --exact"

      assert %{mode: "approximate", ef_search: 40, measurement_grade: false} =
               VectorScan.to_json(scan)
    end

    test "reads back an ef_search the connection was given" do
      apply_mode({:ef_search, 200})
      scan = VectorScan.effective()

      assert %{exact: false, ef_search: 200, ef_search_set: true} = scan
      assert VectorScan.check!({:ef_search, 200}, scan) == :ok

      assert VectorScan.header(scan) ==
               "vector scan: approximate HNSW, hnsw.ef_search = 200, iterative_scan = strict_order"

      assert_raise ArgumentError, ~r/did not reach the connection pool/, fn ->
        VectorScan.check!(:exact, scan)
      end
    end

    test "reads back exact mode" do
      apply_mode(:exact)
      scan = VectorScan.effective()

      assert %{exact: true} = scan
      assert VectorScan.check!(:exact, scan) == :ok
      assert VectorScan.header(scan) =~ ~r/^vector scan: exact \(enable_indexscan = off/
      refute VectorScan.header(scan) =~ "WARNING"
      assert %{mode: "exact", ef_search: nil, measurement_grade: true} = VectorScan.to_json(scan)
    end

    test "a --url run says the mode is the server's" do
      assert VectorScan.header(:remote) =~ "the server's own"
      assert VectorScan.header(:remote) =~ "KILN_HNSW_EF_SEARCH=200"
      assert VectorScan.to_json(:remote) == %{mode: "server", known: false}
    end
  end

  describe "exact mode's plan" do
    defp plan(sql) do
      %{rows: rows} = Repo.query!("EXPLAIN (COSTS OFF) " <> sql, [])
      Enum.map_join(rows, "\n", &hd/1)
    end

    defp nearest_sql do
      vector = "[" <> Enum.join(List.duplicate("0.1", 384), ",") <> "]"
      "SELECT id FROM plan_probe ORDER BY embedding <=> '#{vector}'::vector LIMIT 10"
    end

    # Planned against a TEMP copy of `block_embeddings` — the same columns and
    # the same indexes, the HNSW one included (`INCLUDING INDEXES`) — rather
    # than the table itself, because the table's plan depends on statistics
    # this test does not own. Rows a rolled-back test inserted leave pages
    # behind; an autovacuum ANALYZE then records them as zero live tuples, and
    # the planner, now sure the table is empty, picks a sequential scan for
    # everything, which made "exact mode has no HNSW in its plan" pass for the
    # wrong reason and "the default walks HNSW" fail at random. Autovacuum
    # never touches a temp table, so it is planned from its pages alone.
    #
    # 2 000 rows make the HNSW walk the default plan's own choice (asserted on
    # the same data), so the exact assertion is not vacuous. Their embeddings
    # are NULL: the index skips NULLs, so inserting them costs milliseconds
    # where real vectors cost seconds of graph building, and the planner sizes
    # the table from its pages either way. The temp table dies with the
    # sandbox's transaction.
    setup do
      Repo.query!("CREATE TEMP TABLE plan_probe (LIKE block_embeddings INCLUDING ALL)", [])

      Repo.query!(
        """
        INSERT INTO plan_probe
          (document_type, document_id, block_key, block_type, content_hash, org_id)
        SELECT 'page', gen_random_uuid(), 'k' || g, 'paragraph', 'h', gen_random_uuid()
        FROM generate_series(1, 2000) AS g
        """,
        []
      )

      :ok
    end

    test "the default plan walks the HNSW index; exact mode sorts a sequential scan" do
      # The copied index is the production one: HNSW, cosine.
      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'plan_probe_embedding_idx'",
          []
        )

      assert indexdef =~ "USING hnsw (embedding vector_cosine_ops)"

      assert plan(nearest_sql()) =~ "Index Scan using plan_probe_embedding_idx on plan_probe"

      apply_mode(:exact)
      exact = plan(nearest_sql())

      refute exact =~ "plan_probe_embedding_idx"
      assert exact =~ "Seq Scan on plan_probe"
      assert exact =~ "Sort"
    end

    test "ef_search alone leaves the plan on the HNSW index" do
      apply_mode({:ef_search, 200})

      assert plan(nearest_sql()) =~ "Index Scan using plan_probe_embedding_idx on plan_probe"
    end

    test "exact mode leaves btree indexes usable, through a bitmap scan" do
      apply_mode(:exact)

      lookup =
        plan("SELECT id FROM plan_probe WHERE id = '00000000-0000-0000-0000-000000000000'")

      assert lookup =~ ~r/Bitmap Index Scan on plan_probe_pkey/
    end
  end

  # The same statements the pool's `after_connect` would run, on the test's
  # sandboxed connection — rolled back with it.
  defp apply_mode(mode) do
    mode
    |> VectorScan.statements()
    |> Enum.each(&Repo.query!(&1, []))
  end
end
