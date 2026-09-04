defmodule KilnCMS.Search.RerankTest do
  @moduledoc """
  Phase D (#8): `hybrid/3` with `rerank: true` reorders the fused results by a
  reranker's scores, and falls back to the fused order when reranking is off or
  the reranker errors. Uses deterministic stubs (no models).

  The second half is the report's P7: reranking scoped to the ask path by
  `KilnCMS.Ask`'s own switch, with every other surface — `GET /api/search`
  here — keeping the global one. The ConnCase is for that endpoint.
  """
  # async: false — toggles the global `KilnCMS.Search` and `KilnCMS.Ask` app env.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Ask
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

  # Not an error the fallback absorbs — a call is the failure. `rerank/2` does
  # not rescue, so a sweep that reaches this stub raises out of the test.
  defmodule RaisingReranker do
    @behaviour KilnCMS.Search.Reranker
    @impl true
    def scores(_query, _docs), do: raise("the reranker ran")
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  defp put_ask_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Ask, [])
    Application.put_env(:kiln_cms, KilnCMS.Ask, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    original_ask = Application.get_env(:kiln_cms, KilnCMS.Ask, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, original)
      Application.put_env(:kiln_cms, KilnCMS.Ask, original_ask)
    end)

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
    KilnCMS.DataCase.drain_oban()
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

  test "a reranked hit carries the reranker's score, not its fused one" do
    # `hit_score/1` promises "the number this order came from". A caller
    # sorting reranked sections against each other by their RRF scores would
    # otherwise quietly undo the reranking.
    admin = admin()
    term = "common#{System.unique_integer([:positive])}"
    {plain, boosted} = seed_pair(admin, term)

    results = Search.hybrid(:page, term, actor: admin, rerank: true)

    assert Search.hit_score(Enum.find(results, &(&1.id == boosted.id))) == 1.0
    assert Search.hit_score(Enum.find(results, &(&1.id == plain.id))) == 0.0
    # Provenance is fusion's, and reranking leaves it alone.
    assert Search.hit_legs(Enum.find(results, &(&1.id == boosted.id))) != []
  end

  describe "scoped to the ask path (the Shen-beat-Huang-Qi report, P7)" do
    # The report's deployment had this reranker wired and never running: the
    # only switch reranked every surface on every query, CPU inference its
    # host could not afford. `KilnCMS.Ask`'s own switch reranks the bounded
    # candidate set behind one question and nothing else. Every case here
    # starts with the global switch OFF and the ask switch ON.
    setup do
      put_search_env(rerank: false, reranker: BoostReranker)
      put_ask_env(rerank: true)
      :ok
    end

    # Three published records the two orders disagree on. The term is in two
    # titles, so the fuzzy title leg returns those as well as the keyword leg
    # and fusion ranks them first; the "boost" page carries the term only in
    # its SEO description — one leg, the lowest fused score — and "boost" in
    # its title is the one thing the stub reranker scores. Fused order puts
    # it last; reranked order puts it first, across both content types.
    defp seed_across_types(admin, term) do
      alpha = CMS.create_page!(%{title: "#{term} alpha", slug: slug()}, actor: admin)
      alpha = CMS.publish_page!(alpha, %{}, actor: admin)

      boost =
        CMS.create_page!(
          %{title: "Notes on boost", slug: slug(), seo_description: "About #{term}"},
          actor: admin
        )

      boost = CMS.publish_page!(boost, %{}, actor: admin)
      post = CMS.create_post!(%{title: "The #{term} handbook", slug: slug()}, actor: admin)
      post = CMS.publish_post!(post, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      {alpha, boost, post}
    end

    test "ask's sources are reranked across content types while every other surface is not" do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {_alpha, boost, _post} = seed_across_types(admin, term)

      refute Search.rerank?()
      assert Ask.rerank?()

      # The control: with ask's switch off too, fusion cites the boost page
      # last — it is the weakest match, on one leg.
      put_ask_env(rerank: false)
      fused = Ask.answer(term).sources
      assert List.last(fused).title == boost.title
      assert Enum.all?(fused, &(&1.score < 1.0))

      put_ask_env(rerank: true)
      assert [first, second, third | _] = Ask.answer(term).sources

      # The reranker's order, across a page and a post — and its scores, so
      # the number a client reads is the one this order came from.
      assert {first.type, first.title, first.score} == {"page", boost.title, 1.0}
      assert Enum.sort([second.type, third.type]) == ["page", "post"]
      assert second.score == 0.0 and third.score == 0.0
      # Provenance is fusion's, and reranking leaves it alone: the boost page
      # never came through the fuzzy title leg, the others did.
      refute :fuzzy in first.legs
      assert :keyword in first.legs
    end

    test "GET /api/search stays in fused order under the same switches", %{conn: conn} do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {alpha, boost, post} = seed_across_types(admin, term)

      body = conn |> get("/api/search?q=#{term}") |> json_response(200)

      # Fused order — the term-in-title page first, the boost page last —
      # with fused scores, none of them the stub's 1.0 / 0.0.
      assert [
               %{"id" => first_id, "score" => first_score},
               %{"id" => last_id, "score" => last_score}
             ] =
               body["results"]["pages"]

      assert {first_id, last_id} == {alpha.id, boost.id}
      assert first_score > last_score and last_score > 0.0 and first_score < 1.0
      assert [%{"id" => post_id, "score" => post_score}] = body["results"]["posts"]
      assert post_id == post.id and post_score < 1.0

      # And exactly the order an explicitly unreranked sweep produces.
      fused = Search.global(term, rerank: false, sections: [:pages], authorize?: true)
      assert Enum.map(fused.pages, & &1.id) == [alpha.id, boost.id]
    end

    test "with both switches off, nothing calls the reranker", %{conn: conn} do
      put_search_env(reranker: RaisingReranker)
      put_ask_env(rerank: false)
      refute Ask.rerank?()

      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {alpha, _boost, _post} = seed_across_types(admin, term)

      assert [_, _, _ | _] = Ask.answer(term).sources
      alpha_id = alpha.id
      body = conn |> get("/api/search?q=#{term}") |> json_response(200)
      assert [%{"id" => ^alpha_id} | _] = body["results"]["pages"]
    end

    test "Search.global/2's :rerank option overrides the switch in both directions" do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {alpha, boost, _post} = seed_across_types(admin, term)
      pages = fn opts -> Search.global(term, [sections: [:pages], actor: admin] ++ opts).pages end

      # Switch off, option on: reranked.
      assert hd(pages.(rerank: true)).id == boost.id
      # Omitted: the switch decides — off.
      assert hd(pages.([])).id == alpha.id

      put_search_env(rerank: true)
      # Switch on, option off: fused.
      assert hd(pages.(rerank: false)).id == alpha.id
      # Omitted: the switch decides — on.
      assert hd(pages.([])).id == boost.id
    end

    test "the global switch covers the ask path too" do
      put_ask_env(rerank: false)
      refute Ask.rerank?()
      put_search_env(rerank: true)
      assert Ask.rerank?()
    end
  end
end
