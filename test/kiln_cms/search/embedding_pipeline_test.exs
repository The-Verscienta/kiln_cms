defmodule KilnCMS.Search.EmbeddingPipelineTest do
  @moduledoc """
  The semantic-embedding pipeline: a content create/update enqueues a background
  `EmbeddingWorker` (via `Changes.EnqueueEmbedding`) which embeds `search_text`
  and stores the vector through the `:set_embedding` action — but only when
  semantic search is enabled. Uses a deterministic stub embedder, so no model is
  loaded.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

  # Deterministic fake embedder: same text always yields the same 384-d vector,
  # and it never touches Bumblebee/Nx.
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
      email: "embed-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "embed-#{System.unique_integer([:positive])}"

  test "creating content enqueues a job that embeds and stores the vector" do
    admin = admin()
    page = CMS.create_page!(%{title: "Otters and rivers", slug: slug()}, actor: admin)

    # Computed in the background, so nothing is stored synchronously.
    assert is_nil(CMS.get_page!(page.id, authorize?: false).embedding)

    assert %{success: 1} = KilnCMS.DataCase.drain_oban()

    embedding = CMS.get_page!(page.id, authorize?: false).embedding
    assert is_list(embedding)
    assert length(embedding) == 384
  end

  test "updating content re-embeds from the new text" do
    admin = admin()
    page = CMS.create_page!(%{title: "First", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    first = CMS.get_page!(page.id, authorize?: false).embedding

    CMS.update_page!(page, %{title: "Completely different subject matter"}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    second = CMS.get_page!(page.id, authorize?: false).embedding

    assert is_list(second)
    refute first == second
  end

  test "embedding writes don't create PaperTrail versions" do
    admin = admin()
    page = CMS.create_page!(%{title: "Versioned", slug: slug()}, actor: admin)
    before = length(CMS.list_page_versions!(authorize?: false))

    KilnCMS.DataCase.drain_oban()

    assert CMS.get_page!(page.id, authorize?: false).embedding
    assert length(CMS.list_page_versions!(authorize?: false)) == before
  end

  test "with semantic search disabled, no job is enqueued and no embedding stored" do
    put_search_env(semantic: false)
    admin = admin()
    page = CMS.create_page!(%{title: "No embed", slug: slug()}, actor: admin)

    assert %{success: 0, failure: 0} = KilnCMS.DataCase.drain_oban()
    assert is_nil(CMS.get_page!(page.id, authorize?: false).embedding)
  end
end
