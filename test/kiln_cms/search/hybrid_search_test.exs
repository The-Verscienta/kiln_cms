defmodule KilnCMS.Search.HybridTest do
  @moduledoc """
  `KilnCMS.Search.hybrid/3` fuses the keyword (`ts_rank`) and semantic (cosine)
  legs by Reciprocal Rank Fusion: a record matched by both legs outranks one
  matched by a single leg, results are deduplicated, and with semantic search
  disabled it degrades to keyword-only. Uses a deterministic stub embedder.
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
      email: "hyb-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "hyb-#{System.unique_integer([:positive])}"

  defp ids(records), do: Enum.map(records, & &1.id)

  test "a record matched by both legs ranks above a semantic-only match" do
    admin = admin()
    # Matches the keyword query "alpha" and embeds to the query's exact vector.
    both = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
    # Doesn't contain "alpha" (no keyword hit), but is still an embedded
    # candidate in the semantic leg.
    semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    results = Search.hybrid(:page, "alpha", actor: admin)
    result_ids = ids(results)

    assert hd(result_ids) == both.id
    assert semantic_only.id in result_ids
    # Deduplicated even though `both` appears in both legs.
    assert Enum.count(result_ids, &(&1 == both.id)) == 1
  end

  test "degrades to keyword-only when semantic search is disabled" do
    admin = admin()
    both = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
    semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    put_search_env(semantic: false)
    result_ids = Search.hybrid(:page, "alpha", actor: admin) |> ids()

    # Only the keyword match survives; the semantic-only candidate is gone.
    assert both.id in result_ids
    refute semantic_only.id in result_ids
  end

  test "respects the :limit option" do
    admin = admin()

    for n <- 1..5 do
      CMS.create_page!(%{title: "alpha #{n}", slug: slug()}, actor: admin)
    end

    KilnCMS.DataCase.drain_oban()

    assert length(Search.hybrid(:page, "alpha", actor: admin, limit: 3)) == 3
  end

  test "resolves dynamic types and the entry tier (not just :page/:post)" do
    admin = admin()

    definition =
      CMS.create_type_definition!(
        %{name: "hy#{System.unique_integer([:positive])}", label: "Hy"},
        actor: admin
      )

    entry =
      KilnCMS.CMS.ContentTypes.create!(definition.name, %{title: "alpha", slug: slug()},
        actor: admin
      )

    KilnCMS.DataCase.drain_oban()

    # By dynamic type name string and by the entry resource itself.
    assert entry.id in (Search.hybrid(definition.name, "alpha", actor: admin) |> ids())
    assert entry.id in (Search.hybrid(KilnCMS.CMS.Entry, "alpha", actor: admin) |> ids())
  end

  test "a typo is rescued by the fuzzy leg when the keyword leg comes up short" do
    admin = admin()
    # "fermentaton" survives stemming as its own token (no tsquery match) but
    # is trigram-close to "fermentation" — the keyword leg is empty, so the
    # fuzzy fallback fires and rescues the hit.
    page = CMS.create_page!(%{title: "Fermentation Guide", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    put_search_env(semantic: false)

    assert page.id in (Search.hybrid(:page, "fermentaton", actor: admin) |> ids())
  end

  test "the fuzzy leg stays out when the keyword leg has enough hits" do
    admin = admin()

    for n <- 1..3 do
      CMS.create_page!(%{title: "alpha #{n}", slug: slug()}, actor: admin)
    end

    # Matches the fuzzy leg (title ILIKE "alpha%") but not the keyword leg
    # ("alphaa" doesn't stem to "alpha") — it can only surface if the fallback
    # runs, which the three keyword hits keep switched off.
    near_miss = CMS.create_page!(%{title: "alphaa", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    put_search_env(semantic: false)

    refute near_miss.id in (Search.hybrid(:page, "alpha", actor: admin) |> ids())
  end

  test "global/2 sections are hybrid: semantic-only matches surface" do
    admin = admin()
    keyword_hit = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
    # No keyword overlap with the query — reachable only through the
    # semantic leg, which the old keyword-only global/2 never ran.
    semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    sections = Search.global("alpha", actor: admin)
    page_ids = ids(sections.pages)

    assert keyword_hit.id in page_ids
    assert semantic_only.id in page_ids
  end

  describe "score and leg provenance on every hit" do
    # The fused score used to be computed inside RRF and thrown away, leaving
    # `global/2`'s callers nothing to interleave sections on but registry
    # order. It now rides on the record's metadata, with the legs that found
    # it, and the list itself is still plain records.

    test "each hit carries the score it was ranked by and the legs that found it" do
      admin = admin()
      both = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
      semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(:page, "alpha", actor: admin)
      both_hit = Enum.find(results, &(&1.id == both.id))
      semantic_hit = Enum.find(results, &(&1.id == semantic_only.id))

      # "alpha" is a title word, so the fuzzy leg (which joins when the
      # keyword leg finds fewer than three) returns it as well: three legs.
      assert Search.hit_legs(both_hit) == [:keyword, :semantic, :fuzzy]
      assert Search.hit_legs(semantic_hit) == [:semantic]
      assert Search.hit_score(both_hit) > Search.hit_score(semantic_hit)

      # The order IS the score order — nothing else decides it.
      scores = Enum.map(results, &Search.hit_score/1)
      assert Enum.all?(scores, &is_float/1)
      assert scores == Enum.sort(scores, :desc)

      # A record that never went through fusion has neither.
      assert Search.hit_score(both) == nil
      assert Search.hit_legs(both) == []
    end

    test "the score survives loading calculations onto the hits" do
      admin = admin()
      page = CMS.create_page!(%{title: "alpha", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      locale = KilnCMS.I18n.default_locale()

      [hit | _] =
        Search.hybrid(:page, "alpha",
          actor: admin,
          load: [highlight: %{query: "alpha", locale: locale}]
        )

      assert hit.id == page.id
      assert hit.highlight =~ "<mark>alpha</mark>"
      assert is_float(Search.hit_score(hit))
      assert Search.hit_legs(hit) != []
    end

    test "ties keep a deterministic order: the legs' order, then the leg's own" do
      admin = admin()
      put_search_env(semantic: false)

      for n <- 1..4 do
        CMS.create_page!(%{title: "alpha #{n}", slug: slug()}, actor: admin)
      end

      KilnCMS.DataCase.drain_oban()

      # Keyword-only (four hits, so the fuzzy leg sits out): every hit was
      # found by one leg, and the fused scores fall off with rank, so this is
      # a fixed order — asserting the run twice pins that it is not a
      # `Map.values/1` accident.
      first = Search.hybrid(:page, "alpha", actor: admin) |> ids()
      assert length(first) == 4
      assert first == Search.hybrid(:page, "alpha", actor: admin) |> ids()
    end
  end

  describe "the relevance floor judges semantic-only hits, after fusion" do
    # `semantic_max_distance` used to be a WHERE on the semantic leg, so it
    # judged every row by distance alone — including rows the keyword leg was
    # about to vouch for. Now the leg runs unfloored and fusion drops only the
    # hits nobody else returned. Distances come from the stub embedder, so each
    # test measures the corpus and places the floor relative to what it found.

    defp distance_of(page, query, admin) do
      {:ok, rows} = Search.semantic_neighbours(:page, query, actor: admin, limit: 50)
      %{distance: distance} = Enum.find(rows, &(&1.id == page.id))
      distance
    end

    test "a record the keyword leg also found survives a floor its distance fails" do
      admin = admin()
      # "alpha" is a title word (keyword hit) but the page's text is not the
      # query, so its embedding sits at a real distance from the query's.
      page = CMS.create_page!(%{title: "alpha beta", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      distance = distance_of(page, "alpha", admin)
      assert distance > 0.0
      put_search_env(semantic_max_distance: distance / 2)

      [hit] = Search.hybrid(:page, "alpha", actor: admin)

      assert hit.id == page.id
      # The floor was not applied to the leg: the semantic leg still returned
      # the record, so it kept its semantic contribution to the fused score.
      assert :semantic in Search.hit_legs(hit)
      assert :keyword in Search.hit_legs(hit)
    end

    test "a semantic-only hit beyond the floor is dropped; one within it is kept" do
      admin = admin()
      keyword = CMS.create_page!(%{title: "alpha beta", slug: slug()}, actor: admin)
      # No "alpha" anywhere: only the semantic leg can return it.
      semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      distance = distance_of(semantic_only, "alpha", admin)

      put_search_env(semantic_max_distance: distance * 0.99)
      result_ids = Search.hybrid(:page, "alpha", actor: admin) |> ids()
      assert keyword.id in result_ids
      refute semantic_only.id in result_ids

      put_search_env(semantic_max_distance: distance * 1.01)
      results = Search.hybrid(:page, "alpha", actor: admin)
      assert semantic_only.id in ids(results)
      assert Search.hit_legs(Enum.find(results, &(&1.id == semantic_only.id))) == [:semantic]
    end

    test "a floored hit does not hold a slot against the limit" do
      admin = admin()
      semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      # Created after the drain, so it has no embedding: the semantic leg
      # cannot return it, and a typo query reaches it through the fuzzy leg
      # alone. Fuzzy-only at half weight scores below semantic-only at rank
      # one, so the fused list is led by the hit the floor is about to drop.
      fuzzy_only = CMS.create_page!(%{title: "Database Guide", slug: slug()}, actor: admin)

      put_search_env(semantic_max_distance: 0.0)
      results = Search.hybrid(:page, "databse", actor: admin, limit: 1)

      # Were the floor applied after `limit`, the one slot would go to the
      # semantic-only hit and come back empty once floored.
      assert ids(results) == [fuzzy_only.id]
      assert Search.hit_legs(hd(results)) == [:fuzzy]
      refute semantic_only.id in ids(results)
    end

    test "a query unlike anything indexed still returns nothing (#871)" do
      admin = admin()
      CMS.create_page!(%{title: "alpha beta", slug: slug()}, actor: admin)
      CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      put_search_env(semantic_max_distance: 0.0)

      assert Search.hybrid(:page, "nothing like this exists", actor: admin) == []
    end

    test "the per-type semantic action still floors the leg itself" do
      # The `semantic-search` API routes have no other leg to corroborate a
      # hit, so a record beyond the floor stays out of them even though hybrid
      # search — where the keyword leg vouches for it — returns it.
      admin = admin()
      page = CMS.create_page!(%{title: "alpha beta", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      put_search_env(semantic_max_distance: distance_of(page, "alpha", admin) / 2)

      assert CMS.semantic_search_pages!("alpha", actor: admin) == []
      assert Search.hybrid(:page, "alpha", actor: admin) |> ids() == [page.id]
    end
  end
end
