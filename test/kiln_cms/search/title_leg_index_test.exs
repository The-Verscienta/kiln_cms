defmodule KilnCMS.Search.TitleLegIndexTest do
  @moduledoc """
  The title leg (`:search_title`) is answered from the
  `<table>_title_lexemes_index` GIN index rather than a sequential scan of
  every title (#1712), and the prefilter that lets it do so returns exactly
  the rows the phrase match alone would.

  The plan assertion runs against a table of a few thousand rows, where the
  index wins on cost at default planner settings — at fixture scale a scan is
  the cheaper plan and the question has no answer. It EXPLAINs the SQL Ash
  actually issues, captured off the repo's telemetry, so a filter that stops
  matching the index expression fails here.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.CMS.Page
  alias KilnCMS.Repo

  @expression "tsvector_to_array(to_tsvector(kiln_regconfig(locale), title))"

  describe "the index" do
    test "every content table carries it, GIN, on the leg's exact expression" do
      for table <- ["pages", "posts", "entries"] do
        %{rows: rows} =
          Repo.query!(
            "SELECT indexdef FROM pg_indexes WHERE tablename = $1 AND indexname = $2",
            [table, "#{table}_title_lexemes_index"]
          )

        assert [[indexdef]] = rows, "#{table} has no title lexemes index"
        assert indexdef =~ "USING gin"
        assert indexdef =~ @expression
      end
    end

    test "the title leg's query is planned through it on a realistic table" do
      org_id = KilnCMS.Accounts.default_org_id()

      # 4,000 titles of distinct lexemes, none of which the query contains.
      Repo.query!(
        """
        INSERT INTO pages (id, title, slug, org_id, locale)
        SELECT gen_random_uuid(), 'topic' || i || ' field notes', 'tli-' || i, $1, 'en'
        FROM generate_series(1, 4000) AS i
        """,
        [Ecto.UUID.dump!(org_id)]
      )

      # Statistics for the rows just written, so the planner costs the table
      # it has rather than the near-empty one it last sampled — without them
      # it believes `org_id = ? AND locale = ?` finds one row and walks the
      # slug index. ANALYZE counts this transaction's own inserts as live;
      # its `pg_statistic` rows roll back with the sandbox, `reltuples` does
      # not (written in place), which moves no other test's results.
      Repo.query!("ANALYZE pages")

      {sql, params} =
        capture_query("pages", fn ->
          Page
          |> Ash.Query.for_read(:search_title, %{query: "saffron rice pilaf", locale: "en"})
          |> Ash.read!(authorize?: false, tenant: org_id)
        end)

      plan =
        Repo.query!("EXPLAIN (FORMAT TEXT) " <> sql, params).rows
        |> Enum.map_join("\n", &hd/1)

      assert plan =~ "pages_title_lexemes_index", plan

      # The overlap is the index condition — the part read from the index —
      # not a filter applied to rows found some other way.
      assert [index_cond] =
               plan
               |> String.split("\n")
               |> Enum.filter(&(&1 =~ "Index Cond:" and &1 =~ "&&")),
             plan

      assert index_cond =~ "tsvector_to_array"
      refute plan =~ "Seq Scan on pages", plan
    end
  end

  describe "the prefilter" do
    # The phrase match is the leg's meaning; the prefilter only narrows which
    # rows it reads. Titles picked for the ways the two could come apart: a
    # hyphenated compound (the parser emits the whole word and its parts),
    # stop words only, an apostrophe, digits, repeated words, and another
    # locale's stemming.
    @titles [
      {"E-mail marketing", "en"},
      {"Mail", "en"},
      {"About", "en"},
      {"The Who", "en"},
      {"Chef's Kitchen", "en"},
      {"2026 Guide", "en"},
      {"Twenty-one Pilots", "en"},
      {"Rice rice baby", "en"},
      {"Pad Thai", "en"},
      {"Les Misérables", "fr"},
      {"Cuisine française", "fr"}
    ]

    @queries [
      {"e-mail marketing tips", "en"},
      {"the mail", "en"},
      {"about the who", "en"},
      {"chef kitchen", "en"},
      {"chefs kitchen 2026 guide", "en"},
      {"twenty-one pilots live", "en"},
      {"one pilot", "en"},
      {"rice baby rice rice", "en"},
      {"pad thai tom yum", "en"},
      {"les misérables", "fr"},
      {"la cuisine française classique", "fr"},
      {"a an the", "en"}
    ]

    test "returns exactly what the phrase match alone returns" do
      admin = admin()

      for {title, locale} <- @titles do
        KilnCMS.CMS.create_page!(
          %{title: title, slug: "tli-#{System.unique_integer([:positive])}", locale: locale},
          actor: admin
        )
      end

      org_id = KilnCMS.Accounts.default_org_id()

      matched =
        for {query, locale} <- @queries do
          leg =
            Page
            |> Ash.Query.for_read(:search_title, %{query: query, locale: locale})
            |> Ash.Query.filter(contains(slug, "tli-"))
            |> Ash.read!(authorize?: false, tenant: org_id)
            |> Enum.map(& &1.title)
            |> Enum.sort()

          %{rows: rows} =
            Repo.query!(
              """
              SELECT title FROM pages
              WHERE org_id = $1 AND locale = $2 AND slug LIKE 'tli-%'
                AND to_tsvector(kiln_regconfig($2), $3) @@ phraseto_tsquery(kiln_regconfig($2), title)
              """,
              [Ecto.UUID.dump!(org_id), locale, query]
            )

          assert leg == rows |> List.flatten() |> Enum.sort(), "query #{inspect(query)}"
          leg
        end

      # Not a comparison of empty lists: most of these queries name a title.
      assert matched |> Enum.reject(&(&1 == [])) |> length() >= 7
      assert ["Mail"] in matched
      assert ["Les Misérables"] in matched
    end
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "tli-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # The SQL and parameters of the one query `fun` issues against `source`.
  defp capture_query(source, fun) do
    test = self()
    handler = "tli-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta[:source] == source,
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
end
