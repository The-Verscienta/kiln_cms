defmodule KilnCMS.CMS.TaskBlockPerformanceTest do
  @moduledoc """
  The two cost claims block discussions rest on, asserted rather than assumed.

  1. **Per-block counts cost nothing per block.** The editor reads a
     document's comments once and its open tasks once, then groups in memory.
     Twenty blocks with threads must cost the same two queries as one.
  2. **A single block's reload uses the composite index.** `:for_block` is the
     read a `{:block_thread_changed, _}` handler would use to refresh one
     block; it must be an index scan on
     `(org_id, content_type, content_id, block_id)`, not a sequential scan of
     every task in the org.
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

  test "for_block hits the composite index rather than scanning the table" do
    editor = user(:editor)
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

    drain()

    # Postgres will happily scan a tiny table whatever the indexes say, so the
    # planner is asked with sequential scans disabled: the question is whether
    # an index *can* serve this predicate, not which one the planner prefers
    # at fixture scale.
    # Two statements, two calls: Postgres refuses multiple commands in one
    # prepared statement, and `SET LOCAL` needs the sandbox's transaction —
    # which is why this case is `async: false`.
    KilnCMS.Repo.query!("SET LOCAL enable_seqscan = off", [])

    plan =
      KilnCMS.Repo.query!(
        """
        EXPLAIN (FORMAT TEXT)
        SELECT id FROM tasks
        WHERE org_id = $1 AND content_type = $2 AND content_id = $3 AND block_id = $4
        """,
        [
          Ecto.UUID.dump!(KilnCMS.Accounts.default_org_id()),
          "page",
          Ecto.UUID.dump!(content_id),
          Ecto.UUID.dump!(block_id)
        ]
      )

    text = plan.rows |> List.flatten() |> Enum.join("\n")

    assert text =~ "tasks_content_lookup_index",
           "expected the composite index to serve for_block's predicate, got:\n#{text}"
  end
end
