defmodule KilnCMS.Search.SemanticSearchTest do
  @moduledoc """
  The `:search_semantic` action embeds the query and returns embedded content by
  cosine distance (nearest first), via the HNSW index. Uses a deterministic stub
  embedder — same text always yields the same vector — so an exact-text query
  retrieves its own record at distance 0, exercising the embed → sort plumbing
  without a model.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(semantic: true, embedder: StubEmbedder)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sem-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sem-#{System.unique_integer([:positive])}"

  defp embed_all, do: Oban.drain_queue(queue: :default, with_recursion: true)

  test "ranks the nearest embedded record first" do
    admin = admin()
    alpha = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
    beta = CMS.create_page!(%{title: "Beta", slug: slug()}, actor: admin)
    embed_all()

    # "Alpha" embeds to exactly the alpha page's vector (distance 0), so it wins.
    ids = "Alpha" |> CMS.semantic_search_pages!(actor: admin) |> Enum.map(& &1.id)

    assert hd(ids) == alpha.id
    assert beta.id in ids
  end

  test "excludes content that hasn't been embedded" do
    admin = admin()
    embedded = CMS.create_page!(%{title: "Embedded", slug: slug()}, actor: admin)
    embed_all()

    # Created after embedding ran and never drained, so it has no vector.
    _unembedded = CMS.create_page!(%{title: "Pending", slug: slug()}, actor: admin)

    ids = "Embedded" |> CMS.semantic_search_pages!(actor: admin) |> Enum.map(& &1.id)
    assert embedded.id in ids
    assert length(ids) == 1
  end

  test "returns nothing when semantic search is disabled" do
    admin = admin()
    CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
    embed_all()

    put_search_env(semantic: false)
    assert CMS.semantic_search_pages!("Alpha", actor: admin) == []
  end

  test "respects read visibility — anonymous matches published only" do
    admin = admin()
    draft = CMS.create_page!(%{title: "Secret", slug: slug()}, actor: admin)
    published = CMS.create_page!(%{title: "Public", slug: slug()}, actor: admin)
    published = CMS.publish_page!(published, %{}, actor: admin)
    embed_all()

    anon_ids = "Secret" |> CMS.semantic_search_pages!(authorize?: true) |> Enum.map(& &1.id)
    refute draft.id in anon_ids
    assert published.id in anon_ids
  end
end
