defmodule KilnCMSWeb.EditorLiveViewsExplainTest do
  @moduledoc """
  The content list's three orders are served by an index, not a sort of the
  whole site (#1593).

  Before the `*_console_*_index` indexes, every page of the list sorted every
  row of the site's content table to keep 51 (a top-N heap sort: ~7 ms at
  30,000 posts and linear after; measured 0.03 ms with the index). Each
  assertion EXPLAINs the SQL the list actually issues, captured off the repo's
  telemetry, and checks the named index serves the order with `org_id` in its
  `Index Cond` and no `Sort` node.

  The question asked is "does an index provide this order", so the plan is
  taken with `enable_sort = off`: without a matching index the planner has no
  choice but a Sort, and the test fails. Relying on cost alone instead would
  need fresh statistics, and an `ANALYZE` inside the sandbox writes
  `pg_class` row counts in place, outliving the rollback of the rows they
  describe.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Repo
  alias KilnCMSWeb.EditorLive.Filters

  @rows 1_000

  setup do
    org = KilnCMS.Accounts.default_org_id()

    Repo.query!(
      """
      INSERT INTO posts (title, slug, locale, state, org_id, updated_at, published_at)
      SELECT 'Explain ' || g, 'explain-' || g || '-' || $2::text, 'en',
             CASE WHEN g % 10 = 0 THEN 'draft' ELSE 'published' END,
             $1, now() - (g || ' minutes')::interval,
             CASE WHEN g % 10 = 0 THEN NULL ELSE now() - (g || ' minutes')::interval END
      FROM generate_series(1, $3::int) g
      """,
      [Ecto.UUID.dump!(org), to_string(System.unique_integer([:positive])), @rows]
    )

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "explain-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x",
        role: :admin
      })

    %{org: org, admin: admin}
  end

  # The SQL a read issued against `posts`, with its parameters.
  defp captured_sql(fun) do
    handler = "explain-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measure, meta, _config ->
        if meta[:source] == "posts", do: send(parent, {:sql, meta[:query], meta[:params]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    assert_received {:sql, sql, params}
    {sql, params}
  end

  defp plan(org, admin, params) do
    filters = Filters.parse(params, %{types: ["post"], locales: ["en"]})

    query =
      Filters.query_filters(filters, admin.id) ++
        [select: [:id, :title, :updated_at, :published_at], sort: Filters.sort(filters)]

    {sql, sql_params} =
      captured_sql(fn ->
        ContentTypes.list!(:post, actor: admin, tenant: org, query: query, page: [limit: 50])
      end)

    Repo.query!("SET LOCAL enable_sort = off")
    %{rows: rows} = Repo.query!("EXPLAIN " <> sql, sql_params)
    Enum.map_join(rows, "\n", &hd/1)
  end

  for {sort, index} <- [
        {"updated", "posts_console_updated_index"},
        {"title", "posts_console_title_index"},
        {"published", "posts_console_published_index"}
      ] do
    test "sorting by #{sort} reads #{index}", %{org: org, admin: admin} do
      plan = plan(org, admin, %{"sort" => unquote(sort)})

      assert plan =~ "using #{unquote(index)} on posts", plan
      assert plan =~ "Index Cond: (org_id = ", plan
      refute plan =~ "Sort Key", plan
    end
  end

  test "a status filter rides the order's index rather than sorting", %{org: org, admin: admin} do
    plan = plan(org, admin, %{"status" => "draft"})

    assert plan =~ "using posts_console_updated_index on posts", plan
    refute plan =~ "Sort Key", plan
  end

  test "the published index keeps never-published rows last" do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_indexdef(c.oid) FROM pg_class c WHERE c.relname = 'posts_console_published_index'"
      )

    assert definition =~ "(org_id, published_at DESC NULLS LAST, id DESC)"
  end
end
