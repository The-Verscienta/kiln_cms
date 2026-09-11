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
    # `plainto_tsquery` ANDs every query lexeme, so "pad thai tom yum"
    # matched neither "Pad Thai" nor "Tom Yum" — only a decoy that happened
    # to mention all four words — and the fuzzy leg, which would have found
    # the titles, stayed out because the decoy counted as a keyword hit
    # (the 2026-09-04 search-ranking report, P2). The title leg runs on every query and
    # outweighs keyword + semantic together, so each named record ranks above
    # the decoy; a single-entity query is untouched, because the record it
    # names collects the title leg on top of the legs it already led.

    defp thai_menu(admin) do
      pad_thai =
        CMS.create_page!(
          %{title: "Pad Thai", slug: slug(), seo_description: "Rice noodles, stir-fried"},
          actor: admin
        )

      tom_yum =
        CMS.create_page!(
          %{title: "Tom Yum", slug: slug(), seo_description: "Hot and sour soup"},
          actor: admin
        )

      # Every query word, in its body — the only thing the AND-only keyword
      # leg finds for the pair, and what stood alone at rank 1 before.
      decoy =
        CMS.create_page!(
          %{
            title: "Street food index",
            slug: slug(),
            seo_description: "Pad Thai and Tom Yum compared with Tom Kha"
          },
          actor: admin
        )

      KilnCMS.DataCase.drain_oban()
      {pad_thai, tom_yum, decoy}
    end

    defp rank_of(results, record), do: Enum.find_index(results, &(&1.id == record.id))

    test "two titled records outrank a decoy that contains every query word" do
      admin = admin()
      {pad_thai, tom_yum, decoy} = thai_menu(admin)

      results = Search.hybrid(:page, "pad thai tom yum", actor: admin)

      decoy_rank = rank_of(results, decoy)
      assert decoy_rank, "the decoy is a keyword hit and must still be returned"
      assert :keyword in Search.hit_legs(Enum.at(results, decoy_rank))
      refute :title in Search.hit_legs(Enum.at(results, decoy_rank))

      for named <- [pad_thai, tom_yum] do
        rank = rank_of(results, named)
        assert rank, "#{named.title} must enter fusion"
        assert rank < decoy_rank, "#{named.title} ranked below the decoy"
        assert :title in Search.hit_legs(Enum.at(results, rank))
      end
    end

    test "a single-entity query keeps its rank 1 and gains the leg on top" do
      admin = admin()
      {pad_thai, tom_yum, _decoy} = thai_menu(admin)

      [first | _] = results = Search.hybrid(:page, "pad thai", actor: admin)

      assert first.id == pad_thai.id
      assert :keyword in Search.hit_legs(first)
      assert :title in Search.hit_legs(first)

      # Not named by "pad thai": whatever else found it, the title leg didn't.
      case rank_of(results, tom_yum) do
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
      cat = CMS.create_category!(%{name: "Noodles #{slug()}", slug: slug()}, actor: admin)

      inside =
        CMS.create_page!(%{title: "Pad Thai", slug: slug(), category_id: cat.id}, actor: admin)

      outside = CMS.create_page!(%{title: "Tom Yum", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      results =
        Search.hybrid(:page, "pad thai tom yum",
          actor: admin,
          filters: %{category_id: cat.id}
        )

      assert ids(results) == [inside.id]
      assert :title in Search.hit_legs(hd(results))
      refute outside.id in ids(results)
    end
  end

  describe "the any-term fallback (:keyword_any)" do
    # The keyword leg is `plainto_tsquery` — an AND of every lexeme. The
    # 2026-09-04 search-ranking report's D3/D4: a query naming two records ("pad
    # thai tom yum") matched neither, because no document contains all four
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
      pad_thai = CMS.create_page!(%{title: "Pad Thai", slug: slug()}, actor: admin)
      tom_yum = CMS.create_page!(%{title: "Tom Yum", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      %{admin: admin, pad_thai: pad_thai, tom_yum: tom_yum}
    end

    test "a query naming two records surfaces both, above a record naming one word", ctx do
      # Carries one of the four words in its title (and a word the query
      # does not, so the title leg does not name it): the OR finds it,
      # ranked below the two records that carry two each — `ts_rank` grows
      # with the terms matched. Created after them, so a tie would put it
      # FIRST (`inserted_at desc` breaks ties) — the order is the rank's
      # doing.
      yum = CMS.create_page!(%{title: "Yum notes", slug: slug()}, actor: ctx.admin)

      # One word again, in the B-weighted description rather than the
      # A-weighted title, and created last. Ranked by the OR query it sits
      # below `yum`; ranked by the AND query (`search_rank`, which scores
      # a lone term at zero however it is weighted) the two would tie and
      # this one would come first. Pins that the action orders by its own
      # rank, not the every-term one.
      described =
        CMS.create_page!(%{title: "Unrelated", slug: slug(), seo_description: "About tom"},
          actor: ctx.admin
        )

      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(:page, "pad thai tom yum", actor: ctx.admin)
      result_ids = ids(results)
      position = fn id -> Enum.find_index(result_ids, &(&1 == id)) end

      assert ctx.pad_thai.id in result_ids
      assert ctx.tom_yum.id in result_ids
      assert position.(yum.id) > position.(ctx.pad_thai.id)
      assert position.(yum.id) > position.(ctx.tom_yum.id)
      assert position.(described.id) > position.(yum.id)

      # Found by the relaxation and by the title leg (the query names each
      # whole title): the AND leg has no hit to contribute, and the fuzzy
      # leg's word similarity does not reach a two-word title from a
      # four-word prefix.
      for hit <- results, hit.id in [ctx.pad_thai.id, ctx.tom_yum.id] do
        assert Search.hit_legs(hit) == [:keyword_any, :title]
        # Fused at a real (if reduced) weight — a relaxed hit still scores.
        assert Search.hit_score(hit) > 0
      end
    end

    test "a question form no longer returns nothing", ctx do
      result_ids =
        Search.hybrid(:page, "How is Pad Thai different from Tom Yum?", actor: ctx.admin)
        |> ids()

      assert ctx.pad_thai.id in result_ids
      assert ctx.tom_yum.id in result_ids
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
      assert [hit] = Search.hybrid(:page, "pad", actor: ctx.admin)
      assert hit.id == ctx.pad_thai.id
      assert Search.hit_legs(hit) == [:keyword, :fuzzy]
    end

    test "the relaxation narrows by :filters like the full match does", ctx do
      cat =
        CMS.create_category!(
          %{name: "Cat #{System.unique_integer([:positive])}", slug: slug()},
          actor: ctx.admin
        )

      inside =
        CMS.create_page!(%{title: "Pad Thai inside", slug: slug(), category_id: cat.id},
          actor: ctx.admin
        )

      KilnCMS.DataCase.drain_oban()

      results =
        Search.hybrid(:page, "pad thai tom yum",
          actor: ctx.admin,
          filters: %{category_id: cat.id}
        )

      # The two uncategorised records match the OR too; the filter keeps
      # them out, exactly as it would on the AND leg.
      assert ids(results) == [inside.id]
    end

    test "the :search_any_published twin pins state; the base answers the actor", ctx do
      CMS.publish_page!(ctx.tom_yum, %{}, actor: ctx.admin)

      read = fn action ->
        KilnCMS.CMS.Page
        |> Ash.Query.for_read(action, %{query: "pad thai tom yum"})
        |> Ash.read!(actor: ctx.admin)
        |> ids()
      end

      # An admin reads drafts through the base action …
      assert ctx.pad_thai.id in read.(:search_any)
      assert ctx.tom_yum.id in read.(:search_any)
      # … and only published content through the delivery twin, like
      # `:search_published`.
      assert read.(:search_any_published) == [ctx.tom_yum.id]
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

    test "a non-numeric floor raises rather than flooring nothing" do
      # Erlang orders `number < atom < bitstring`: a string here compared as
      # greater than every distance, so hybrid search admitted every
      # semantic-only hit — junk included — while the per-type action cast
      # the value in SQL and kept working. Loud beats that.
      admin = admin()
      CMS.create_page!(%{title: "alpha beta", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      for bad <- ["0.35", :none, false] do
        put_search_env(semantic_max_distance: bad)

        assert_raise ArgumentError, ~r/semantic_max_distance: must be a number or nil/, fn ->
          Search.hybrid(:page, "nothing like this exists", actor: admin)
        end
      end

      put_search_env(semantic_max_distance: nil)
      assert is_list(Search.hybrid(:page, "alpha", actor: admin))
    end

    test "the per-type semantic action floors the leg, exempting rows the title leg vouches for" do
      # The `semantic-search` API routes have no fusion to leave the floor
      # to, so they apply it themselves — with the one exemption the title
      # leg gives hybrid search: a row whose title the query names is kept
      # whatever its distance. A row vouched only by the keyword legs is not:
      # those legs are fusion's, not this action's.
      admin = admin()
      query = "tell me about alpha beta"
      named = CMS.create_page!(%{title: "alpha beta", slug: slug()}, actor: admin)
      # "alpha beta" only in the SEO description: the keyword legs' find, not
      # the title leg's.
      keyword_only =
        CMS.create_page!(
          %{title: "unrelated words", slug: slug(), seo_description: "alpha beta"},
          actor: admin
        )

      semantic_only = CMS.create_page!(%{title: "gamma", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      records = [named, keyword_only, semantic_only]
      by_distance = records |> Enum.sort_by(&distance_of(&1, query, admin)) |> ids()

      put_search_env(semantic_max_distance: 0.0)

      assert CMS.semantic_search_pages!(query, actor: admin) |> ids() == [named.id]
      # Junk still returns nothing: nothing names it, and nothing is within 0.
      assert CMS.semantic_search_pages!("nothing like this exists", actor: admin) == []
      # Hybrid keeps the keyword-vouched record too, as before.
      hybrid_ids = Search.hybrid(:page, query, actor: admin) |> ids()
      assert named.id in hybrid_ids and keyword_only.id in hybrid_ids
      refute semantic_only.id in hybrid_ids

      # Sorted by distance still, and paginated and countable still: the
      # exemption is part of the same query, not a list fused afterwards.
      put_search_env(
        semantic_max_distance: Enum.max(Enum.map(records, &distance_of(&1, query, admin)))
      )

      page =
        KilnCMS.CMS.Page
        |> Ash.Query.for_read(:search_semantic, %{query: query})
        |> Ash.Query.page(limit: 2, count: true)
        |> Ash.read!(actor: admin)

      assert page.count == 3
      assert ids(page.results) == Enum.take(by_distance, 2)
    end
  end

  describe "the block leg: a document reached through its nearest section (D16)" do
    # The per-block embeddings the fire pipeline writes describe each
    # section; the leg ranks documents by their nearest block. Under the
    # stub embedder a block whose text is the query sits at distance 0 from
    # it (its ancestor context aside), while the document's own vector — over
    # the whole text — sits somewhere else, which is exactly the long-document
    # case the leg exists for.

    alias KilnCMS.Search.BlockIndexer

    defp indexed_page(admin, title, blocks) do
      page = CMS.create_page!(%{title: title, slug: slug(), blocks: blocks}, actor: admin)
      {:ok, _count} = BlockIndexer.reindex(page)
      page
    end

    defp block_distance(page, query) do
      {:ok, vector} = Search.embed_query(query)

      KilnCMS.Search.BlockEmbedding
      |> Ash.Query.for_read(:nearest_to_vector, %{vector: vector, document_type: :page, limit: 50})
      |> Ash.Query.load(semantic_distance: %{query_vector: vector})
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.document_id == page.id))
      |> Map.fetch!(:semantic_distance)
    end

    test "a record is reached through its nearest block, and carries :block" do
      admin = admin()
      section = "quiet rivers and cold streams"

      deep =
        indexed_page(admin, "Unrelated opening", [
          %{
            type: :rich_text,
            content: "<p>An opening about something else entirely.</p>",
            order: 0
          },
          %{type: :rich_text, content: "<p>#{section}</p>", order: 1}
        ])

      other =
        indexed_page(admin, "Other", [%{type: :rich_text, content: "<p>mountains</p>", order: 0}])

      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(:page, section, actor: admin)
      hit = Enum.find(results, &(&1.id == deep.id))
      assert hit, "expected the page with the matching section among the results"
      assert :block in Search.hit_legs(hit)
      # The leg's order is the nearest block's: the section that is the query
      # beats a block about mountains.
      assert block_distance(deep, section) < block_distance(other, section)

      put_search_env(block_leg: false)

      refute Search.hybrid(:page, section, actor: admin)
             |> Enum.any?(&(:block in Search.hit_legs(&1)))
    end

    test "the floor judges a semantic-only hit by its nearest distance, block included" do
      admin = admin()
      # Stop words only: no keyword, any-term, title or fuzzy leg can return
      # this page — only the two semantic legs, at two grains.
      query = "the and of"

      page =
        indexed_page(admin, "gamma", [%{type: :rich_text, content: "<p>#{query}</p>", order: 0}])

      KilnCMS.DataCase.drain_oban()

      block = block_distance(page, query)
      document = distance_of(page, query, admin)
      assert block < document, "premise: the section is nearer than the whole document"

      # A floor the document fails and the block passes: kept, through the block.
      put_search_env(semantic_max_distance: (block + document) / 2)
      [hit] = Search.hybrid(:page, query, actor: admin)
      assert hit.id == page.id
      assert Search.hit_legs(hit) == [:semantic, :block]

      # Without the block leg the same floor drops it: the document alone is beyond it.
      put_search_env(block_leg: false)
      assert Search.hybrid(:page, query, actor: admin) == []

      # And a floor both fail drops it with the leg on.
      put_search_env(block_leg: true, semantic_max_distance: block / 2)
      assert Search.hybrid(:page, query, actor: admin) == []
    end

    test "reaches the entry tier: a dynamic type's entry is filed under :entry" do
      # `Entry` declares itself with `__kiln_dynamic_entry__/0`, not a content
      # type — the leg must still know its block rows are filed as `:entry`.
      admin = admin()

      definition =
        CMS.create_type_definition!(
          %{name: "bl#{System.unique_integer([:positive])}", label: "Bl"},
          actor: admin
        )

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          definition.name,
          %{
            title: "Opening",
            slug: slug(),
            blocks: [
              %{type: :rich_text, content: "<p>quiet rivers and cold streams</p>", order: 0}
            ]
          },
          actor: admin
        )

      {:ok, 1} = BlockIndexer.reindex(entry)
      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(definition.name, "quiet rivers and cold streams", actor: admin)
      hit = Enum.find(results, &(&1.id == entry.id))
      assert hit, "expected the entry among the results"
      assert :block in Search.hit_legs(hit)
    end

    test "sits out under facet filters, and a document with no block rows is reached by the other legs" do
      admin = admin()

      page =
        indexed_page(admin, "alpha beta", [%{type: :rich_text, content: "<p>alpha</p>", order: 0}])

      # Created and never indexed at block grain (a draft that was never fired).
      draft = CMS.create_page!(%{title: "alpha draft", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(:page, "alpha", actor: admin)
      assert :block in Search.hit_legs(Enum.find(results, &(&1.id == page.id)))
      refute :block in Search.hit_legs(Enum.find(results, &(&1.id == draft.id)))

      filtered = Search.hybrid(:page, "alpha", actor: admin, filters: %{author_id: admin.id})
      assert page.id in ids(filtered)
      refute Enum.any?(filtered, &(:block in Search.hit_legs(&1)))
    end
  end

  describe "the alias leg: a record the query names by a flagged field" do
    # A title is not the only name a record answers to. A custom field
    # flagged `names_record` is phrase-matched against the query the way
    # the title is (`KilnCMS.CMS.NameFields`, `:search_alias`), at the title
    # leg's weight.

    defp name_field(admin, content_type, name) do
      CMS.create_field_definition!(
        %{
          content_type: content_type,
          name: name,
          label: name,
          field_type: :string,
          names_record: true
        },
        actor: admin
      )
    end

    test "a query containing a flagged field's value finds the record, as :alias" do
      admin = admin()
      name_field(admin, :page, "latin_name")

      huang_qi =
        CMS.create_page!(
          %{
            title: "Huang Qi",
            slug: slug(),
            custom_fields: %{"latin_name" => "Astragalus membranaceus"}
          },
          actor: admin
        )

      dang_shen =
        CMS.create_page!(
          %{
            title: "Dang Shen",
            slug: slug(),
            custom_fields: %{"latin_name" => "Codonopsis pilosula"}
          },
          actor: admin
        )

      KilnCMS.DataCase.drain_oban()

      # The query names neither title; it names Huang Qi's Latin binomial.
      results = Search.hybrid(:page, "what is astragalus membranaceus used for", actor: admin)
      assert hd(results).id == huang_qi.id
      assert :alias in Search.hit_legs(hd(results))
      refute :title in Search.hit_legs(hd(results))

      case Enum.find(results, &(&1.id == dang_shen.id)) do
        nil -> :ok
        other -> refute :alias in Search.hit_legs(other)
      end
    end

    test "a field that is not flagged names nothing, and a flag takes effect at once" do
      admin = admin()

      definition =
        CMS.create_field_definition!(
          %{content_type: :page, name: "trade_name", label: "Trade name", field_type: :string},
          actor: admin
        )

      page =
        CMS.create_page!(
          %{title: "Widget", slug: slug(), custom_fields: %{"trade_name" => "Zorptastic"}},
          actor: admin
        )

      KilnCMS.DataCase.drain_oban()

      refute Enum.any?(
               Search.hybrid(:page, "zorptastic", actor: admin),
               &(:alias in Search.hit_legs(&1))
             )

      CMS.update_field_definition!(definition, %{names_record: true}, actor: admin)

      [hit] = Search.hybrid(:page, "zorptastic", actor: admin) |> Enum.filter(&(&1.id == page.id))
      assert :alias in Search.hit_legs(hit)
    end

    test "a dynamic type's flagged field names its entries" do
      admin = admin()

      herb =
        CMS.create_type_definition!(
          %{name: "herb#{System.unique_integer([:positive])}", label: "Herb"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: herb.id,
          name: "pinyin",
          label: "Pinyin",
          field_type: :string,
          names_record: true
        },
        actor: admin
      )

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          herb.name,
          %{title: "Astragalus", slug: slug(), custom_fields: %{"pinyin" => "huang qi"}},
          actor: admin
        )

      KilnCMS.DataCase.drain_oban()

      results = Search.hybrid(herb.name, "huang qi dang shen", actor: admin)
      hit = Enum.find(results, &(&1.id == entry.id))
      assert hit, "expected the entry named by its pinyin"
      assert :alias in Search.hit_legs(hit)
    end
  end

  describe "the tag leg: a record carrying a tag the query names" do
    # Tag-name vectors are written on tag create (`EnqueueTagEmbedding` →
    # `TagEmbeddingWorker`); the leg finds tags within the threshold of the
    # query and every document carrying one joins fusion at half weight.
    # Under the stub embedder a tag whose name IS the query sits at distance
    # 0, within any threshold.

    defp tagged_page(admin, title, tag) do
      CMS.create_page!(%{title: title, slug: slug(), tag_ids: [tag.id]}, actor: admin)
    end

    test "a tag named by the query brings its documents in as :tag, at half weight" do
      admin = admin()
      tag = CMS.create_tag!(%{name: "immunity", slug: slug()}, actor: admin)
      tagged = tagged_page(admin, "Some remedy", tag)
      untagged = CMS.create_page!(%{title: "Another remedy", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      # The tag's vector was written by the worker, not by a panel.
      assert [%{name: "immunity"}] =
               KilnCMS.SearchIndex.tag_embeddings_for!([tag.id], authorize?: false)

      results = Search.hybrid(:page, "immunity", actor: admin)
      hit = Enum.find(results, &(&1.id == tagged.id))
      assert hit, "expected the tagged page"
      assert :tag in Search.hit_legs(hit)
      refute :tag in Search.hit_legs(Enum.find(results, &(&1.id == untagged.id)) || %{})

      put_search_env(tag_leg: false)

      refute Enum.any?(
               Search.hybrid(:page, "immunity", actor: admin),
               &(:tag in Search.hit_legs(&1))
             )
    end

    test "a tag beyond the threshold names nothing; the floor judges a tag-only hit by its tag" do
      admin = admin()
      tag = CMS.create_tag!(%{name: "the and of", slug: slug()}, actor: admin)
      # No lexical leg can return this page for the stop-word query; only the
      # semantic legs and the tag can.
      page = tagged_page(admin, "gamma", tag)
      KilnCMS.DataCase.drain_oban()

      query = "the and of"
      document = distance_of(page, query, admin)
      assert document > 0.0

      # Tag at distance 0 (its name is the query): a floor the document fails
      # keeps the page, through the tag.
      put_search_env(semantic_max_distance: document / 2)
      [hit] = Search.hybrid(:page, query, actor: admin)
      assert hit.id == page.id
      assert :tag in Search.hit_legs(hit)

      # A threshold below the tag's distance (0) is impossible; a threshold
      # of 0 still admits it (`<=`), so tighten by renaming the tag away from
      # the query: the leg then has no tag within the threshold, and the
      # floor drops the page on its document distance alone.
      CMS.update_tag!(tag, %{name: "something else entirely"}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      put_search_env(tag_leg_threshold: 0.0)
      assert Search.hybrid(:page, query, actor: admin) == []

      # A tag within the threshold but beyond the floor is no alibi either:
      # the tag leg is semantic, and a tag-only hit is judged by the nearer
      # of its distances, not waved through as a lexical match. Admit every
      # tag (threshold 2.0) and lift the floor: the page is back, through the
      # tag. Then set the floor below both distances: gone again.
      put_search_env(tag_leg_threshold: 2.0, semantic_max_distance: 2.0)
      assert [hit] = Search.hybrid(:page, query, actor: admin)
      assert :tag in Search.hit_legs(hit)
      put_search_env(semantic_max_distance: 0.0)
      assert Search.hybrid(:page, query, actor: admin) == []
    end

    test "sits out under facet filters" do
      admin = admin()
      tag = CMS.create_tag!(%{name: "immunity", slug: slug()}, actor: admin)
      # The title carries the query too, so the keyword leg returns the page
      # under the facet; the tag (its name IS the query, distance 0) would as
      # well, and must not.
      tagged = tagged_page(admin, "immunity remedy", tag)
      KilnCMS.DataCase.drain_oban()

      unfiltered = Search.hybrid(:page, "immunity", actor: admin)
      assert :tag in Search.hit_legs(Enum.find(unfiltered, &(&1.id == tagged.id)))

      filtered = Search.hybrid(:page, "immunity", actor: admin, filters: %{author_id: admin.id})
      assert tagged.id in ids(filtered)
      refute Enum.any?(filtered, &(:tag in Search.hit_legs(&1)))
    end
  end
end
