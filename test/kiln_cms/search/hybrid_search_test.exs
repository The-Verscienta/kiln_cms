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

      # "alpha" is the whole title, so the title leg names it, and the fuzzy
      # leg (which joins when the keyword leg finds fewer than three) returns
      # it as well: all four legs.
      assert Search.hit_legs(both_hit) == [:keyword, :semantic, :title, :fuzzy]
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

  describe "the title leg: a record the query names enters fusion" do
    # `plainto_tsquery` ANDs every query lexeme, so "huang qi dang shen"
    # matched neither "Huang Qi" nor "Dang Shen" — only a decoy that happened
    # to mention all four words — and the fuzzy leg, which would have found
    # the titles, stayed out because the decoy counted as a keyword hit
    # ("Why Shen Beat Huang Qi", P2). The title leg runs on every query and
    # outweighs keyword + semantic together, so each named record ranks above
    # the decoy; a single-entity query is untouched, because the record it
    # names collects the title leg on top of the legs it already led.

    defp materia_medica(admin) do
      huang_qi =
        CMS.create_page!(
          %{title: "Huang Qi", slug: slug(), seo_description: "Astragalus root, a tonic"},
          actor: admin
        )

      dang_shen =
        CMS.create_page!(
          %{title: "Dang Shen", slug: slug(), seo_description: "Codonopsis root"},
          actor: admin
        )

      # Every query word, in its body — the only thing the AND-only keyword
      # leg finds for the pair, and what stood alone at rank 1 before.
      decoy =
        CMS.create_page!(
          %{
            title: "Materia medica index",
            slug: slug(),
            seo_description: "Huang Qi and Dang Shen compared with Ren Shen"
          },
          actor: admin
        )

      KilnCMS.DataCase.drain_oban()
      {huang_qi, dang_shen, decoy}
    end

    defp rank_of(results, record), do: Enum.find_index(results, &(&1.id == record.id))

    test "two titled records outrank a decoy that contains every query word" do
      admin = admin()
      {huang_qi, dang_shen, decoy} = materia_medica(admin)

      results = Search.hybrid(:page, "huang qi dang shen", actor: admin)

      decoy_rank = rank_of(results, decoy)
      assert decoy_rank, "the decoy is a keyword hit and must still be returned"
      assert :keyword in Search.hit_legs(Enum.at(results, decoy_rank))
      refute :title in Search.hit_legs(Enum.at(results, decoy_rank))

      for named <- [huang_qi, dang_shen] do
        rank = rank_of(results, named)
        assert rank, "#{named.title} must enter fusion"
        assert rank < decoy_rank, "#{named.title} ranked below the decoy"
        assert :title in Search.hit_legs(Enum.at(results, rank))
      end
    end

    test "a single-entity query keeps its rank 1 and gains the leg on top" do
      admin = admin()
      {huang_qi, dang_shen, _decoy} = materia_medica(admin)

      [first | _] = results = Search.hybrid(:page, "huang qi", actor: admin)

      assert first.id == huang_qi.id
      assert :keyword in Search.hit_legs(first)
      assert :title in Search.hit_legs(first)

      # Not named by "huang qi": whatever else found it, the title leg didn't.
      case rank_of(results, dang_shen) do
        nil -> :ok
        rank -> refute :title in Search.hit_legs(Enum.at(results, rank))
      end
    end

    test "matches whole words through the locale's stemmer, never inside a word" do
      admin = admin()
      put_search_env(semantic: false)
      # "databases" stems to the same lexeme as the title, so it is named.
      stemmed = CMS.create_page!(%{title: "Database", slug: slug()}, actor: admin)
      # "data" is only a prefix of "database" — no word boundary, no match.
      prefix = CMS.create_page!(%{title: "Data", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(:page, "our databases guide", actor: admin)

      assert :title in Search.hit_legs(Enum.at(results, rank_of(results, stemmed)))
      refute prefix.id in ids(results)
    end

    test "a title of nothing but stop words names nothing" do
      admin = admin()
      put_search_env(semantic: false)
      page = CMS.create_page!(%{title: "About", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      # "about" is in the query, but it is a stop word under the locale's
      # config, so the title has no lexemes to find — and nothing else finds
      # the page either.
      refute page.id in (Search.hybrid(:page, "about databases", actor: admin) |> ids())
    end

    test "respects :filters like the other legs" do
      admin = admin()
      put_search_env(semantic: false)
      cat = CMS.create_category!(%{name: "Tonics #{slug()}", slug: slug()}, actor: admin)

      inside =
        CMS.create_page!(%{title: "Huang Qi", slug: slug(), category_id: cat.id}, actor: admin)

      outside = CMS.create_page!(%{title: "Dang Shen", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      results =
        Search.hybrid(:page, "huang qi dang shen",
          actor: admin,
          filters: %{category_id: cat.id}
        )

      assert ids(results) == [inside.id]
      assert :title in Search.hit_legs(hd(results))
      refute outside.id in ids(results)
    end
  end

  describe "the any-term fallback (:keyword_any)" do
    # The keyword leg is `plainto_tsquery` — an AND of every lexeme. The "Why
    # Shen Beat Huang Qi" report's D3/D4: a query naming two records ("huang
    # qi dang shen") matched neither, because no document contains all four
    # words, and a question form ANDed eight lexemes into nothing — at which
    # point the empty keyword leg un-suppressed the fuzzy title leg, so the
    # vaguer question beat the precise name list by accident. When the AND
    # comes up short on a multi-word query, the same lexemes ORed join the
    # fusion at half weight. The safety net beneath the title leg above (P2):
    # a record the query names by its whole title enters through that leg;
    # one it names by a word of its title, or a question form, through this
    # one. Keyword-only throughout, so every hit's legs are exactly the
    # keyword and title legs that found it.

    setup do
      put_search_env(semantic: false)
      admin = admin()
      huang_qi = CMS.create_page!(%{title: "Huang Qi", slug: slug()}, actor: admin)
      dang_shen = CMS.create_page!(%{title: "Dang Shen", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      %{admin: admin, huang_qi: huang_qi, dang_shen: dang_shen}
    end

    test "a query naming two records surfaces both, above a record naming one word", ctx do
      # Carries one of the four words in its title (and a word the query
      # does not, so the title leg does not name it): the OR finds it,
      # ranked below the two records that carry two each — `ts_rank` grows
      # with the terms matched. Created after them, so a tie would put it
      # FIRST (`inserted_at desc` breaks ties) — the order is the rank's
      # doing.
      shen = CMS.create_page!(%{title: "Shen notes", slug: slug()}, actor: ctx.admin)

      # One word again, in the B-weighted description rather than the
      # A-weighted title, and created last. Ranked by the OR query it sits
      # below `shen`; ranked by the AND query (`search_rank`, which scores
      # a lone term at zero however it is weighted) the two would tie and
      # this one would come first. Pins that the action orders by its own
      # rank, not the every-term one.
      described =
        CMS.create_page!(%{title: "Unrelated", slug: slug(), seo_description: "About dang"},
          actor: ctx.admin
        )

      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(:page, "huang qi dang shen", actor: ctx.admin)
      result_ids = ids(results)
      position = fn id -> Enum.find_index(result_ids, &(&1 == id)) end

      assert ctx.huang_qi.id in result_ids
      assert ctx.dang_shen.id in result_ids
      assert position.(shen.id) > position.(ctx.huang_qi.id)
      assert position.(shen.id) > position.(ctx.dang_shen.id)
      assert position.(described.id) > position.(shen.id)

      # Found by the relaxation and by the title leg (the query names each
      # whole title): the AND leg has no hit to contribute, and the fuzzy
      # leg's word similarity does not reach a two-word title from a
      # four-word prefix.
      for hit <- results, hit.id in [ctx.huang_qi.id, ctx.dang_shen.id] do
        assert Search.hit_legs(hit) == [:keyword_any, :title]
        # Fused at a real (if reduced) weight — a relaxed hit still scores.
        assert Search.hit_score(hit) > 0
      end
    end

    test "a question form no longer returns nothing", ctx do
      result_ids =
        Search.hybrid(:page, "How is Huang Qi different from Dang Shen?", actor: ctx.admin)
        |> ids()

      assert ctx.huang_qi.id in result_ids
      assert ctx.dang_shen.id in result_ids
    end

    test "a precise query with enough full matches never runs the relaxation", ctx do
      for n <- 1..3 do
        CMS.create_page!(%{title: "alpha beta #{n}", slug: slug()}, actor: ctx.admin)
      end

      # Matches "alpha" but not "beta" — reachable only through the OR leg,
      # which the three full matches keep switched off. (Not "alpha only":
      # "only" is a stop word, so that title reduces to "alpha" and the
      # title leg would name it.)
      partial = CMS.create_page!(%{title: "alpha gamma", slug: slug()}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(:page, "alpha beta", actor: ctx.admin)

      assert length(results) == 3
      refute partial.id in ids(results)
      assert Enum.all?(results, &(Search.hit_legs(&1) == [:keyword]))
    end

    test "a one-word query is never relaxed, however sparse the full match", ctx do
      # One hit — under the threshold — but OR and AND are the same query
      # for one word, so the relaxation would only re-count this hit. The
      # legs are the full match and the fuzzy title leg, nothing more.
      assert [hit] = Search.hybrid(:page, "huang", actor: ctx.admin)
      assert hit.id == ctx.huang_qi.id
      assert Search.hit_legs(hit) == [:keyword, :fuzzy]
    end

    test "the relaxation narrows by :filters like the full match does", ctx do
      cat =
        CMS.create_category!(
          %{name: "Cat #{System.unique_integer([:positive])}", slug: slug()},
          actor: ctx.admin
        )

      inside =
        CMS.create_page!(%{title: "Huang Qi inside", slug: slug(), category_id: cat.id},
          actor: ctx.admin
        )

      KilnCMS.DataCase.drain_oban()

      results =
        Search.hybrid(:page, "huang qi dang shen",
          actor: ctx.admin,
          filters: %{category_id: cat.id}
        )

      # The two uncategorised records match the OR too; the filter keeps
      # them out, exactly as it would on the AND leg.
      assert ids(results) == [inside.id]
    end

    test "the :search_any_published twin pins state; the base answers the actor", ctx do
      CMS.publish_page!(ctx.dang_shen, %{}, actor: ctx.admin)

      read = fn action ->
        KilnCMS.CMS.Page
        |> Ash.Query.for_read(action, %{query: "huang qi dang shen"})
        |> Ash.read!(actor: ctx.admin)
        |> ids()
      end

      # An admin reads drafts through the base action …
      assert ctx.huang_qi.id in read.(:search_any)
      assert ctx.dang_shen.id in read.(:search_any)
      # … and only published content through the delivery twin, like
      # `:search_published`.
      assert read.(:search_any_published) == [ctx.dang_shen.id]
    end
  end
end
