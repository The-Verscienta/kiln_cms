defmodule KilnCMS.CMS.TaskBlockPerformanceTest do
  @moduledoc """
  The two cost claims block discussions rest on, asserted rather than assumed.

  1. **Per-block counts cost nothing per block.** The editor reads a
     document's comments once and its open tasks once, then groups in memory.
     Twenty blocks with threads must cost the same two queries as one.
  2. **A single block's reload uses the composite index.** `:for_block` is the
     read a `{:block_thread_changed, _}` handler would use to refresh one
     block; it must be served by the index on
     `(org_id, content_type, content_id, block_id)`, not by a sequential scan
     of every task in the org.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "perf-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

  # Counts the SELECTs a function issues, via Ecto's telemetry rather than a
  # log-scraping proxy for it.
  defp count_queries(fun) do
    handler = "perf-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measure, meta, _config ->
        if meta[:source] in ["comments", "tasks"], do: send(parent, {:query, meta[:source]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain_queries([])
  end

  defp drain_queries(acc) do
    receive do
      {:query, source} -> drain_queries([source | acc])
    after
      0 -> Enum.frequencies(acc)
    end
  end

  test "reading a document's discussions costs two queries, whatever the block count" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()

    for _ <- 1..20 do
      block_id = Ecto.UUID.generate()

      CMS.add_comment!(
        %{
          content_type: "page",
          content_id: content_id,
          block_id: block_id,
          body: "Needs a look"
        },
        actor: editor
      )

      CMS.assign_task!(
        %{
          content_type: "page",
          content_id: content_id,
          block_id: block_id,
          assignee_id: editor.id
        },
        actor: editor
      )
    end

    drain()

    counts =
      count_queries(fn ->
        comments = CMS.list_comments_for!("page", content_id, actor: editor)
        tasks = CMS.list_open_tasks_for!("page", content_id, actor: editor)

        # This is what the editor does with them: group in memory, once.
        assert length(comments) == 20
        assert length(tasks) == 20
      end)

    assert counts == %{"comments" => 1, "tasks" => 1},
           "expected one read of each table regardless of block count, got #{inspect(counts)}"
  end

  # Enough tasks in the org that the planner's choice is not a coin toss. At
  # fixture scale an index scan and a scan of the org's whole task table cost
  # the same to within the planner's fuzz factor, so which index it reaches for
  # is arbitrary — and asserting a specific one there made this case flake. At
  # this many rows the composite index costs ~8 against ~79 for a sequential
  # scan; nothing else is close. 200 documents with 10 blocks apiece, one org
  # and one assignee, which is the shape a busy site's `tasks` actually has.
  @documents 200
  @blocks_per_document 10

  # `pg_get_indexdef/3`'s per-column form, so this reads the index's real key
  # rather than pattern-matching a `CREATE INDEX` string. An index that is
  # missing (or renamed) yields no rows rather than raising.
  defp index_columns(name) do
    KilnCMS.Repo.query!(
      """
      SELECT pg_get_indexdef(c.oid, k.ord::int, true)
      FROM pg_class c
      JOIN pg_index i ON i.indexrelid = c.oid
      JOIN LATERAL generate_series(1, i.indnatts) AS k(ord) ON true
      WHERE c.relname = $1
      ORDER BY k.ord
      """,
      [name]
    ).rows
    |> List.flatten()
  end

  # The SQL Ash issues for a read, so the plan below is the plan for the real
  # query rather than for a hand-written stand-in that may have drifted from it.
  defp capture_query(fun) do
    handler = "perf-sql-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measure, meta, _config ->
        if meta[:source] == "tasks", do: send(parent, {:sql, meta[:query], meta[:params]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain_sql([])
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql, params} -> drain_sql([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp seed_org_tasks(editor) do
    KilnCMS.Repo.query!(
      """
      INSERT INTO tasks
        (id, org_id, content_type, content_id, block_id, assignee_id,
         status, kind, inserted_at, updated_at)
      SELECT gen_random_uuid(), $1, 'page', d.content_id, gen_random_uuid(), $2,
             'open', 'manual', now(), now()
      FROM (SELECT gen_random_uuid() AS content_id FROM generate_series(1, $3)) d,
           generate_series(1, $4)
      """,
      [
        Ecto.UUID.dump!(KilnCMS.Accounts.default_org_id()),
        Ecto.UUID.dump!(editor.id),
        @documents,
        @blocks_per_document
      ]
    )
  end

  test "the columns for_block filters on have one index, in that order" do
    # The structural half of the claim, and the half that survives whatever the
    # planner is feeling: the index `:for_block` needs exists and its key is the
    # four columns in the order that lets `:for_content` match on the prefix.
    # Deleting it from the migration fails here even on an empty table.
    columns = index_columns("tasks_content_lookup_index")

    assert columns == ~w(org_id content_type content_id block_id),
           "expected tasks_content_lookup_index to key (org_id, content_type, " <>
             "content_id, block_id) in that order, got: #{inspect(columns)}"
  end

  test "for_block reads one block's tasks through that index rather than scanning the org" do
    editor = user(:editor)
    org = KilnCMS.Accounts.default_org_id()
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()

    CMS.assign_task!(
      %{
        content_type: "page",
        content_id: content_id,
        block_id: block_id,
        assignee_id: editor.id
      },
      actor: editor
    )

    seed_org_tasks(editor)
    drain()

    # The planner is asked at scale and at its own default settings. The
    # earlier form of this case set `enable_seqscan = off` instead, which at
    # fixture scale proves only that *some* index is loadable — and lets the
    # degenerate answer through, since reading the whole org through
    # `tasks_assignee_lookup_index` and filtering is still "an index scan".
    # Volume is what makes the answer stable; an `ANALYZE` here was tried and
    # dropped, because it changed no plan (statistics faked both ways — a
    # near-empty `pg_class` and a stale skewed `pg_statistic` — still give the
    # index) while writing row counts that outlive the sandbox rollback.

    # `tenant:` is what puts `org_id` in the predicate, and `org_id` leads the
    # index — an unscoped read has nothing to match the first key column with.
    [{sql, params}] =
      capture_query(fn ->
        assert [_one] =
                 CMS.list_tasks_for_block!("page", content_id, block_id,
                   actor: editor,
                   tenant: org
                 )
      end)

    plan =
      KilnCMS.Repo.query!("EXPLAIN (FORMAT TEXT) " <> sql, params).rows
      |> List.flatten()
      |> Enum.join("\n")

    refute plan =~ "Seq Scan on tasks",
           "expected one block's tasks to be found by index, not by reading " <>
             "every task in the org, got:\n#{plan}"

    assert plan =~ "tasks_content_lookup_index",
           "expected the composite index to serve for_block's predicate, got:\n#{plan}"

    # Named but only partly used would still be a read of the whole org: all
    # four columns have to be index conditions, not rechecked as a filter.
    index_cond =
      plan |> String.split("\n") |> Enum.find("", &(String.trim(&1) =~ ~r/^Index Cond:/))

    for column <- ~w(org_id content_type content_id block_id) do
      assert index_cond =~ column,
             "expected #{column} to be matched by the index rather than filtered, got:\n#{plan}"
    end
  end
end
