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

  describe "scoped to the ask path (the 2026-09-04 search-ranking report, P7)" do
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

  # A `BoostReranker` that also reports every call to the test process — the
  # docs it was handed. Sections may run in their own tasks
  # (`section_concurrency/0`), so `self()` inside `scores/2` is not the test;
  # the test's pid rides in app env instead (this file is async: false).
  defmodule RecordingReranker do
    @behaviour KilnCMS.Search.Reranker
    @impl true
    def scores(query, docs) do
      if pid = Application.get_env(:kiln_cms, :rerank_test_pid), do: send(pid, {:reranked, docs})
      BoostReranker.scores(query, docs)
    end
  end

  defp record_reranks do
    Application.put_env(:kiln_cms, :rerank_test_pid, self())
    on_exit(fn -> Application.delete_env(:kiln_cms, :rerank_test_pid) end)
    put_search_env(reranker: RecordingReranker)
  end

  # Every `{:reranked, docs}` already in the mailbox.
  defp reranker_calls(acc \\ []) do
    receive do
      {:reranked, docs} -> reranker_calls([docs | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the text the reranker reads (#1938)" do
    test "is the title and the record's search_text, not the title alone" do
      record_reranks()
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"

      # A page has no excerpt attribute at all: before #1938 the model saw
      # "<title>" and nothing else.
      page =
        CMS.create_page!(
          %{title: "#{term} alpha", slug: slug(), seo_description: "intensely bitter and cold"},
          actor: admin
        )

      KilnCMS.DataCase.drain_oban()

      Search.hybrid(:page, term, actor: admin, rerank: true)
      assert [[doc]] = reranker_calls()
      assert doc =~ ~r/^#{term} alpha — /
      assert doc =~ "intensely bitter and cold"
      refute Map.has_key?(page, :excerpt)
    end

    test "survives a caller's narrow :select — GET /api/search's", %{conn: conn} do
      # `/api/search` reads six fields (`@hit_fields`), none of them
      # `search_text`. With reranking on, `hybrid/3` widens the select to
      # what the reranker reads, or the model is back to the title alone.
      record_reranks()
      put_search_env(rerank: true)
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"

      page =
        CMS.create_page!(
          %{title: "#{term} alpha", slug: slug(), seo_description: "intensely bitter and cold"},
          actor: admin
        )

      CMS.publish_page!(page, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert %{"results" => %{"pages" => [_]}} =
               conn |> get("/api/search?q=#{term}") |> json_response(200)

      assert [[doc]] = reranker_calls() |> Enum.reject(&(&1 == []))
      assert doc =~ "intensely bitter and cold"
    end

    test "falls back to the passage, then the excerpt, then the title, and is capped" do
      assert Search.rerank_text(%{title: "T", search_text: "body", excerpt: "ex"}) == "T — body"

      assert Search.rerank_text(%{title: "T", search_text: nil, passage: "p", excerpt: "e"}) ==
               "T — p"

      assert Search.rerank_text(%{title: "T", search_text: "", excerpt: "ex"}) == "T — ex"
      assert Search.rerank_text(%{title: "T"}) == "T"

      long = String.duplicate("word ", 5_000)
      text = Search.rerank_text(%{title: "T", search_text: long})
      assert String.length(text) == Search.rerank_text_limit()
      assert Search.rerank_text_limit() == 4096
    end
  end

  describe "defaults (#1938, #1937)" do
    test "are what reranking always did" do
      # Whatever the test config sets, minus every key this PR added: the
      # setup's `on_exit` puts the original back.
      search = Application.get_env(:kiln_cms, KilnCMS.Search, [])
      added = [:rerank_mode, :rerank_batch_size, :rerank_sequence_length]
      Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.drop(search, added))
      Application.put_env(:kiln_cms, KilnCMS.Ask, rerank: false)

      assert Search.rerank_mode() == :replace
      assert Search.rerank_batch_size() == 8
      assert Search.rerank_sequence_length() == 512
      assert Ask.rerank_scope() == :section
      assert Ask.rerank_mode() == :replace
      refute Ask.rerank_pin?()
      assert Ask.rerank_union() == 30
    end
  end

  # Three published records in a fused order nothing random decides — the
  # describes below switch the stub-embedded semantic leg off, and three
  # keyword hits keep the fuzzy leg from running: "alpha" has the term in its
  # title and its SEO description, "gamma" in its title, and the "boost" page
  # (the stub reranker's favourite) only in its SEO description.
  defp seed_three_pages(admin, term) do
    pages =
      for {title, attrs} <- [
            {"#{term} alpha", %{seo_description: "All about #{term}"}},
            {"#{term} gamma", %{}},
            {"Notes on boost", %{seo_description: "About #{term}"}}
          ] do
        page = CMS.create_page!(Map.merge(%{title: title, slug: slug()}, attrs), actor: admin)
        CMS.publish_page!(page, %{}, actor: admin)
      end

    KilnCMS.DataCase.drain_oban()
    pages
  end

  describe "rerank_mode {:rrf, k} (#1938)" do
    setup do
      put_search_env(semantic: false)
      :ok
    end

    test "orders a section by RRF of the fused rank and the rerank rank" do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      [_alpha, _gamma, boost] = seed_three_pages(admin, term)

      fused = Search.hybrid(:page, term, actor: admin)
      assert [first, second, %{id: last}] = fused
      assert last == boost.id

      replaced = Search.hybrid(:page, term, actor: admin, rerank: true)
      assert hd(replaced).id == boost.id

      # Blended: boost is rerank 1 and fused 3 (1/63 + 1/61), the fused
      # second is fused 2 and rerank 3 (1/62 + 1/63) — boost passes it — and
      # the fused first is fused 1 and rerank 2, which holds.
      blended = Search.hybrid(:page, term, actor: admin, rerank: true, rerank_mode: {:rrf, 60})
      assert Enum.map(blended, & &1.id) == [first.id, boost.id, second.id]

      assert_in_delta Search.hit_score(hd(blended)), 1 / 61 + 1 / 62, 1.0e-12
      assert Search.hit_legs(hd(blended)) == Search.hit_legs(first)
    end

    test "follows the configured mode when the call names none" do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      [_alpha, _gamma, boost] = seed_three_pages(admin, term)

      put_search_env(rerank_mode: {:rrf, 60})
      assert [_, %{id: id}, _] = Search.hybrid(:page, term, actor: admin, rerank: true)
      assert id == boost.id
    end
  end

  describe "the union rerank for /api/ask (#1937)" do
    setup do
      # Semantic off: the stub embedder's vectors are hashes, and a fused
      # order they decide is a fused order no test can state.
      put_search_env(semantic: false, rerank: false, reranker: BoostReranker)
      put_ask_env(rerank: true, rerank_scope: :union)
      :ok
    end

    test "reranks every content type's candidates in ONE reranker call per question" do
      record_reranks()
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {_alpha, boost, _post} = seed_across_types(admin, term)

      assert [first | _] = Ask.answer(term).sources
      assert {first.title, first.score} == {boost.title, 1.0}

      # One call, over the union of the page and post sections.
      assert [docs] = reranker_calls()
      assert length(docs) == 3

      # The per-section scope, for contrast: one call per non-empty section.
      put_ask_env(rerank_scope: :section)
      Ask.answer(term)
      assert length(reranker_calls()) == 2
    end

    test "the union is the fused merge's top rerank_union/0, and the rest follows in fused order" do
      record_reranks()
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {_alpha, boost, _post} = seed_across_types(admin, term)
      put_ask_env(rerank: false)
      fused = Ask.answer(term).sources

      put_ask_env(rerank: true, rerank_union: 2)
      reranked = Ask.answer(term).sources

      # Boost was fused last, outside a union of two: never reranked, still last.
      assert [[_, _]] = reranker_calls()
      assert List.last(reranked).title == boost.title
      assert List.last(reranked) == List.last(fused)
    end

    test "a failed union rerank keeps the fused order and the fused scores" do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      seed_across_types(admin, term)

      put_ask_env(rerank: false)
      fused = Ask.answer(term).sources

      put_search_env(reranker: FailReranker)
      put_ask_env(rerank: true)
      assert Ask.answer(term).sources == fused
      assert Enum.all?(fused, &(&1.score < 0.1))
    end

    test "{:rrf, k} blends the global fused rank with the union rerank rank" do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {_alpha, boost, _post} = seed_across_types(admin, term)

      put_ask_env(rerank: false)
      # The alpha page and the post tie on fused score (keyword and fuzzy
      # rank 1 each in their own section); the merge's stable sort orders
      # them by registry, and that position is the fused rank the blend reads.
      assert [f1, f2, %{title: last}] = Ask.answer(term).sources
      assert last == boost.title

      put_ask_env(rerank: true, rerank_mode: {:rrf, 60})
      assert [b1, b2, b3] = Ask.answer(term).sources
      # As in the section test: boost (fused 3, rerank 1) passes the fused
      # second (fused 2, rerank 3) but not the fused first (fused 1, rerank 2)
      # — across a page and a post this time.
      assert Enum.map([b1, b2, b3], & &1.title) == [f1.title, boost.title, f2.title]
      assert_in_delta b1.score, 1 / 61 + 1 / 62, 1.0e-12
      assert_in_delta b2.score, 1 / 63 + 1 / 61, 1.0e-12
    end

    test "the pin holds a source the question names by title at its fused rank" do
      admin = admin()
      term = "common#{System.unique_integer([:positive])}"
      {_alpha, boost, _post} = seed_across_types(admin, term)

      # A page whose whole title is the question: the title leg names it.
      named = CMS.create_page!(%{title: term, slug: slug()}, actor: admin)
      named = CMS.publish_page!(named, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      put_ask_env(rerank: false)
      fused = Ask.answer(term).sources
      named_at = Enum.find_index(fused, &(&1.title == named.title))
      assert :title in Enum.at(fused, named_at).legs

      # Unpinned, the reranker (which scores only "boost") moves it.
      put_ask_env(rerank: true, rerank_mode: :replace)
      unpinned = Ask.answer(term).sources
      assert hd(unpinned).title == boost.title
      refute Enum.find_index(unpinned, &(&1.title == named.title)) == named_at

      # Pinned: exactly its fused rank, and the boost page still rises
      # among the rest.
      put_ask_env(rerank_pin: true)
      pinned = Ask.answer(term).sources
      assert Enum.find_index(pinned, &(&1.title == named.title)) == named_at

      assert pinned |> Enum.reject(&(&1.title == named.title)) |> hd() |> Map.get(:title) ==
               boost.title
    end
  end
end
