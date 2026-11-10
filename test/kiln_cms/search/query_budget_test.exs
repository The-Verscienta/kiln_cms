defmodule KilnCMS.Search.QueryBudgetTest do
  @moduledoc """
  `global/2` inside `query_budget/0` (#2166): a slow embedding or reranker
  costs its own legs, not the request, and `global_report/2` says what was
  cut. The scheduler's own cases are in `KilnCMS.Search.BudgetTest`.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Test.SearchHold

  defmodule SlowEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      SearchHold.hold(:budget_test_delay)
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  defmodule SlowReranker do
    @behaviour KilnCMS.Search.Reranker

    @impl true
    def scores(_query, docs) do
      SearchHold.hold(:budget_test_rerank_delay)
      {:ok, docs |> Enum.with_index() |> Enum.map(fn {_doc, i} -> i * 1.0 end)}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "qb-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, original)
      Application.delete_env(:kiln_cms, :budget_test_delay)
      Application.delete_env(:kiln_cms, :budget_test_rerank_delay)
    end)

    # A separate callback, so a slow call that never lets go cannot stop
    # the config above from being put back.
    SearchHold.release_on_exit()

    put_search_env(semantic: true, embedder: SlowEmbedder)
    admin = admin()

    page = CMS.create_page!(%{title: "budgeted alpha", slug: "qb-page"}, actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    %{admin: admin, page: page}
  end

  test "an embedding that misses its half of the budget costs only the vector legs",
       %{admin: admin, page: page} do
    Application.put_env(:kiln_cms, :budget_test_delay, 30_000)

    # Core's own sections, not `Search.content_sections/0`: every section
    # must finish its keyword legs inside the half of the budget the
    # embedding leaves, one at a time at concurrency 1. An overlay that
    # registers a dozen more content types makes that a test of its section
    # count on a slow runner, not of how an embedding miss is charged.
    #
    # A budget of seconds, not milliseconds (#2553): a keyword leg still
    # querying at the deadline is killed mid-query, and in the SQL sandbox
    # that takes down the test's shared connection, so every later read
    # fails with an `OwnershipError`. Under a loaded suite 400 ms cut the
    # keyword legs as well as the embedding.
    sections = [:pages, :posts, :entries]

    for concurrency <- [1, 2] do
      put_search_env(section_concurrency: concurrency, query_budget: 3_000)

      {micros, report} =
        :timer.tc(fn -> Search.global_report("alpha", actor: admin, sections: sections) end)

      # The keyword legs answered...
      assert Enum.map(report.sections.pages, & &1.id) == [page.id]
      # ...the request did not wait for the embedder's thirty seconds...
      assert micros < 6_000_000, "took #{div(micros, 1000)} ms at concurrency #{concurrency}"
      # ...the embedding was given up at half the budget, not all of it...
      embed = report.timings[:embed]
      assert embed >= 1_400_000 and embed < 3_000_000, "embed took #{div(embed, 1000)} ms"
      # ...and every swept content section says which legs it went without.
      for section <- sections do
        assert report.partial[section] == [:semantic, :block, :tag]
      end

      refute Map.has_key?(report.partial, :media)
    end
  end

  test "a budget already spent answers every section empty, and says so", %{admin: admin} do
    for concurrency <- [1, 2] do
      put_search_env(section_concurrency: concurrency)

      report = Search.global_report("alpha", actor: admin, budget: 0)

      assert Enum.all?(report.sections, fn {_section, hits} -> hits == [] end)

      for section <- Search.content_sections() do
        assert report.partial[section] == [
                 :keyword,
                 :title,
                 :alias,
                 :compound,
                 :synonym,
                 :fuzzy,
                 :semantic,
                 :block,
                 :tag
               ]
      end

      for {section, _resource} <- KilnCMS.CMS.Taxonomy.searchable() do
        assert report.partial[section] == [:section]
      end

      assert report.partial[:media] == [:section]
    end
  end

  test "a reranker slower than the budget leaves the fused order", %{admin: admin, page: page} do
    # Seconds, for the reason the embedding-miss test above gives (#2553).
    put_search_env(reranker: SlowReranker, query_budget: 3_000)
    Application.put_env(:kiln_cms, :budget_test_rerank_delay, 30_000)

    # Core's sections only, for the reason the embedding-miss test above
    # gives: an overlay's extra content types make this a test of the
    # section count on a slow runner.
    {micros, report} =
      :timer.tc(fn ->
        Search.global_report("alpha",
          actor: admin,
          rerank: true,
          sections: [:pages, :posts, :entries]
        )
      end)

    assert Enum.map(report.sections.pages, & &1.id) == [page.id]
    assert micros < 6_000_000
    assert report.partial == %{pages: [:rerank]}
  end

  test "a sweep that finishes is not partial, and accounts for its time", %{admin: admin} do
    report = Search.global_report("alpha", actor: admin)

    assert report.partial == %{}

    assert report.sections ==
             Search.global("alpha", actor: admin)
             |> then(&Map.take(&1, Map.keys(report.sections)))

    names = Keyword.keys(report.timings)
    assert List.first(names) == :embed
    assert List.last(names) == :total
    assert :keyword in names and :semantic in names and :fuse in names
    assert Enum.all?(report.timings, fn {_name, micros} -> is_integer(micros) and micros >= 0 end)
  end

  test "budget: :infinity waits for a slow embedding", %{admin: admin} do
    Application.put_env(:kiln_cms, :budget_test_delay, 300)
    put_search_env(query_budget: 50)

    report = Search.global_report("alpha", actor: admin, budget: :infinity)

    assert report.partial == %{}
  end
end
