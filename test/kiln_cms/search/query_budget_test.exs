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

  defmodule SlowEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      Process.sleep(Application.get_env(:kiln_cms, :budget_test_delay, 0))
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  defmodule SlowReranker do
    @behaviour KilnCMS.Search.Reranker

    @impl true
    def scores(_query, docs) do
      Process.sleep(Application.get_env(:kiln_cms, :budget_test_rerank_delay, 0))
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

    put_search_env(semantic: true, embedder: SlowEmbedder)
    admin = admin()

    page = CMS.create_page!(%{title: "budgeted alpha", slug: "qb-page"}, actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    %{admin: admin, page: page}
  end

  test "an embedding that misses its half of the budget costs only the vector legs",
       %{admin: admin, page: page} do
    Application.put_env(:kiln_cms, :budget_test_delay, 3_000)

    for concurrency <- [1, 2] do
      put_search_env(section_concurrency: concurrency, query_budget: 400)

      {micros, report} =
        :timer.tc(fn -> Search.global_report("alpha", actor: admin) end)

      # The keyword legs answered...
      assert Enum.map(report.sections.pages, & &1.id) == [page.id]
      # ...the request did not wait for the embedder's three seconds...
      assert micros < 1_500_000, "took #{div(micros, 1000)} ms at concurrency #{concurrency}"
      # ...and every content section says which legs it went without.
      for section <- Search.content_sections() do
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
    put_search_env(reranker: SlowReranker, query_budget: 400)
    Application.put_env(:kiln_cms, :budget_test_rerank_delay, 3_000)

    {micros, report} =
      :timer.tc(fn -> Search.global_report("alpha", actor: admin, rerank: true) end)

    assert Enum.map(report.sections.pages, & &1.id) == [page.id]
    assert micros < 1_500_000
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
