defmodule KilnCMS.Search.RerankTest do
  @moduledoc """
  Phase D (#8): `hybrid/3` with `rerank: true` reorders the fused results by a
  reranker's scores, and falls back to the fused order when reranking is off or
  the reranker errors. Uses deterministic stubs (no models).
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  # Scores any doc containing "boost" highest, everything else 0.
  defmodule BoostReranker do
    @behaviour KilnCMS.Search.Reranker
    @impl true
    def scores(_query, docs) do
      {:ok, Enum.map(docs, &if(String.contains?(&1, "boost"), do: 1.0, else: 0.0))}
    end
  end

  defmodule FailReranker do
    @behaviour KilnCMS.Search.Reranker
    @impl true
    def scores(_query, _docs), do: {:error, :boom}
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(semantic: true, embedder: StubEmbedder, rerank: true, reranker: BoostReranker)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rr-#{System.unique_integer([:positive])}"

  defp seed_pair(admin, term) do
    plain = CMS.create_page!(%{title: "#{term} alpha", slug: slug()}, actor: admin)
    boosted = CMS.create_page!(%{title: "#{term} beta boost", slug: slug()}, actor: admin)
    Oban.drain_queue(queue: :default, with_recursion: true)
    {plain, boosted}
  end

  test "rerank: true reorders by the reranker's scores" do
    admin = admin()
    term = "common#{System.unique_integer([:positive])}"
    {_plain, boosted} = seed_pair(admin, term)

    ids = Search.hybrid(:page, term, actor: admin, rerank: true) |> Enum.map(& &1.id)
    assert hd(ids) == boosted.id
  end

  test "reranking is skipped without rerank: true" do
    admin = admin()
    term = "common#{System.unique_integer([:positive])}"
    {_plain, boosted} = seed_pair(admin, term)

    # Both present, but the boosted doc isn't forced first (RRF order stands).
    no_rerank = Search.hybrid(:page, term, actor: admin) |> Enum.map(& &1.id)
    with_rerank = Search.hybrid(:page, term, actor: admin, rerank: true) |> Enum.map(& &1.id)

    assert Enum.sort(no_rerank) == Enum.sort(with_rerank)
    assert hd(with_rerank) == boosted.id
  end

  test "falls back to fused order when the reranker errors" do
    admin = admin()
    put_search_env(reranker: FailReranker)
    term = "common#{System.unique_integer([:positive])}"
    {_plain, _boosted} = seed_pair(admin, term)

    reranked = Search.hybrid(:page, term, actor: admin, rerank: true) |> Enum.map(& &1.id)
    fused = Search.hybrid(:page, term, actor: admin) |> Enum.map(& &1.id)
    assert reranked == fused
  end
end
