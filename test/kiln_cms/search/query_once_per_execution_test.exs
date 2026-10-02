defmodule KilnCMS.Search.QueryOncePerExecutionTest do
  @moduledoc """
  #1725: the expressions every search leg builds from the query text alone
  (`plainto_tsquery(...)`, `to_tsvector(..., query)`) must be computed once
  per statement, not once per row.

  Postgres runs a prepared statement on a *generic* plan after five
  executions on a connection, and on a generic plan the query is a
  parameter, not a constant — so a bare `plainto_tsquery(kiln_regconfig($2),
  $3)` in a filter's recheck or an `ORDER BY ts_rank(...)` parses and stems
  the query text again for every matching row. Wrapped in a scalar
  `(SELECT …)` it is an InitPlan, run once.

  Structural, so it holds at any scale: the SQL Ash really issues is captured
  off the repo's telemetry and planned with `EXPLAIN (GENERIC_PLAN)`; the
  query-side expressions must appear only inside InitPlans, which a text
  plan never prints, so they must not appear in it at all.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Search

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(original, :semantic, false))
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "once-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Every statement `fun` issues against `pages`, as `{sql, params}`.
  defp capture_page_queries(fun) do
    test_pid = self()
    handler = "query-once-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta[:source] == "pages", do: send(test_pid, {:page_sql, {meta[:query], meta[:params]}})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect([])
  end

  defp collect(acc) do
    receive do
      {:page_sql, sql} -> collect([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # GENERIC_PLAN ignores the values, but the protocol still binds them.
  defp generic_plan({sql, params}) do
    %{rows: rows} = Repo.query!("EXPLAIN (GENERIC_PLAN) " <> sql, params)
    Enum.map_join(rows, "\n", &hd/1)
  end

  test "no leg recomputes the query per row on a generic plan" do
    admin = admin()

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "other_name",
        label: "Other name",
        field_type: :string,
        names_record: true
      },
      actor: admin
    )

    CMS.create_page!(
      %{
        title: "Saffron Rice",
        slug: "once-saffron",
        body_markdown: "Saffron threads in warm stock.",
        custom_fields: %{"other_name" => "Zafferano"}
      },
      actor: admin
    )

    query = "saffron rice zafferano"

    statements =
      capture_page_queries(fn ->
        # Keyword (AND and, sparse, the OR relaxation), title, alias, fuzzy,
        # and the hydrating read with the highlight snippet.
        Search.hybrid(:page, query, actor: admin, load: [highlight: %{query: query, locale: "en"}])
        # The grounding passage `KilnCMS.Ask` loads.
        Search.global(query, actor: admin, sections: [:pages], passage: true)
      end)

    searching = Enum.filter(statements, fn {sql, _} -> sql =~ "tsquery" or sql =~ "to_tsvector" end)

    # keyword, keyword_any, title, alias, two hydrating reads
    assert length(searching) >= 6, "captured: #{inspect(statements, pretty: true)}"

    for {sql, _params} = statement <- searching do
      plan = generic_plan(statement)

      refute plan =~ "plainto_tsquery(",
             "the query is parsed per row:\n#{sql}\n\n#{plan}"

      # The query's own tsvector (title and alias legs): a parameter as the
      # text argument. A row's tsvector reads a column instead.
      refute plan =~ ~r/to_tsvector\(CASE [^\n]*? END, \$\d+\)/,
             "the query's tsvector is built per row:\n#{sql}\n\n#{plan}"
    end
  end
end
