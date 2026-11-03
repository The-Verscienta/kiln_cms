defmodule KilnCMS.Search.TermGateTest do
  @moduledoc """
  The term-evidence gate (`KilnCMS.Search.term_gate/0`, A6): junk queries —
  most of their words nowhere in the corpus — come back empty even with the
  semantic legs answering every query, while typo queries one edit from a
  record's name still find it. The corpus is a small materia medica, the
  shape of the deployment whose held-out set motivated the gate: short
  romanised names, prose bodies.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  import KilnCMS.TypedFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Search.TermEvidence

  # Every text embeds near every other, so the semantic legs answer every
  # query with the whole corpus: a deployment with no floor, the worst case
  # the gate has to hold against.
  defmodule NearEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      jitter = :erlang.phash2(text, 1000) * 1.0e-6
      {:ok, for(i <- 1..384, do: 1.0 + if(i == 1, do: jitter, else: 0.0))}
    end
  end

  @corpus [
    {"Gui Zhi Tang",
     "Cinnamon twig decoction releases the exterior and harmonises the nutritive level."},
    {"Ban Xia", "Pinellia rhizome dries dampness, transforms phlegm and stops vomiting."},
    {"Huang Qi", "Astragalus root tonifies the spleen and lifts the yang."},
    {"Huang Lian", "Coptis rhizome, intensely bitter and cold, clears heat and drains fire."},
    {"Ma Huang Tang", "Ephedra decoction induces sweating for wind cold with no sweating."},
    {"Xiao Chai Hu Tang", "Minor bupleurum decoction harmonises the lesser yang stage."},
    {"Dang Gui", "Angelica root nourishes the blood and regulates menstruation."},
    {"Bai Zhu", "White atractylodes strengthens the spleen and dries dampness."},
    # "zi" and "gui" are name words on their own here, as on a real
    # materia medica: the typo in "gui zi tang" is a name word too.
    {"Wu Wei Zi", "Schisandra berry astringes the lung and calms the spirit."}
  ]

  @junk [
    "taylor swift tour dates",
    "cheap flights to paris",
    "bitcoin price today",
    "best pizza near me",
    "how to fix a flat tire",
    "iphone release date",
    "football world cup schedule",
    "asdfghjkl zzqqxx",
    "xylophone quasar",
    "weather tomorrow london",
    "netflix new movies"
  ]

  @typos [
    {"gui zi tang", "Gui Zhi Tang"},
    {"ban xa", "Ban Xia"},
    {"huang qui", "Huang Qi"},
    {"huang lain", "Huang Lian"},
    {"xiao chai hu tan", "Xiao Chai Hu Tang"},
    {"dang guy", "Dang Gui"}
  ]

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    # The corpus lives in an organisation of its own: embedding it is charged
    # to that org's `search_embedding` budget, not the default org's, which
    # every other suite in the window shares. Spent there, other suites' corpora
    # go part-embedded and their pinned rankings move. The generous limit keeps
    # this one's corpus whole across the file's tests.
    put_search_env(
      semantic: true,
      embedder: NearEmbedder,
      embedding_per_org_limit: {1_000_000, :timer.hours(1)}
    )

    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "gate",
        slug: "gate-#{System.unique_integer([:positive])}",
        status: :active
      })

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "gate-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    pages =
      Map.new(@corpus, fn {title, body} ->
        page =
          CMS.create_page!(
            %{
              title: title,
              slug: "gate-#{System.unique_integer([:positive])}",
              blocks: typed_blocks([%{type: :rich_text, content: "<p>#{body}</p>", order: 0}])
            },
            actor: admin,
            tenant: org
          )

        {title, page}
      end)

    KilnCMS.DataCase.drain_oban()
    %{admin: admin, pages: pages, opts: [actor: admin, tenant: org]}
  end

  defp titles(results), do: Enum.map(results, & &1.title)

  describe "junk" do
    test "comes back empty with the gate on, though the semantic legs answer it", %{opts: opts} do
      for query <- @junk do
        assert Search.hybrid(:page, query, opts) == [], "#{query} returned hits"
      end
    end

    test "is what the semantic legs answer with the gate off", %{opts: opts} do
      put_search_env(term_gate: false)

      returned = Enum.count(@junk, &(Search.hybrid(:page, &1, opts) != []))
      assert returned == length(@junk)
    end

    test "comes back empty from every section of a global search", %{opts: opts} do
      results = Search.global("taylor swift tour dates", opts)

      for {section, hits} <- results, is_list(hits) do
        assert hits == [], "#{section} returned #{length(hits)} hits"
      end
    end

    test "comes back empty with semantic search off too", %{opts: opts} do
      put_search_env(semantic: false)

      returned = Enum.reject(@junk, &(Search.hybrid(:page, &1, opts) == []))
      assert returned == []
    end

    test "is judged junk on its terms", %{opts: opts} do
      evidence = Search.term_evidence(:page, "taylor swift tour dates", opts)

      assert evidence.verdict == :junk
      assert evidence.terms == ~w(taylor swift tour dates)
      assert evidence.share < 0.6
    end
  end

  describe "typos" do
    test "find the record they misspell in the top five", %{opts: opts} do
      for {query, title} <- @typos do
        top = opts |> then(&Search.hybrid(:page, query, &1)) |> Enum.take(5) |> titles()
        assert title in top, "#{query}: #{title} not in #{inspect(top)}"
      end
    end

    test "carry the correction to the nearest name word", %{opts: opts} do
      assert %TermEvidence{verdict: :typo, corrections: %{"zi" => "zhi"}} =
               Search.term_evidence(:page, "gui zi tang", opts)

      assert %TermEvidence{verdict: :typo, corrections: %{"xa" => "xia"}} =
               Search.term_evidence(:page, "ban xa", opts)

      assert %TermEvidence{verdict: :typo, corrections: %{"qui" => "qi"}} =
               Search.term_evidence(:page, "huang qui", opts)
    end

    test "find their record with semantic search off", %{opts: opts} do
      put_search_env(semantic: false)

      for {query, title} <- @typos do
        top = opts |> then(&Search.hybrid(:page, query, &1)) |> Enum.take(5) |> titles()
        assert title in top, "#{query}: #{title} not in #{inspect(top)}"
      end
    end

    test "leave a query of correctly spelled names alone", %{opts: opts} do
      assert %TermEvidence{verdict: :ok, corrections: corrections} =
               Search.term_evidence(:page, "wu wei zi tang", opts)

      assert corrections == %{}
    end

    # Lexical legs only: `NearEmbedder` puts every text a hair's breadth from
    # every other, so the semantic ranks are arbitrary and a record sharing
    # one word ("Dang Gui") can take semantic rank 1. The top-five test above
    # holds with them on.
    test "rank the corrected record first", %{opts: opts} do
      put_search_env(semantic: false)

      assert [%{title: "Gui Zhi Tang"} | _] = Search.hybrid(:page, "gui zi tang", opts)
      assert [%{title: "Ban Xia"} | _] = Search.hybrid(:page, "ban xa", opts)
    end
  end

  describe "real queries" do
    test "a paraphrase in the corpus's words is not gated", %{opts: opts} do
      assert %TermEvidence{verdict: :ok} =
               Search.term_evidence(:page, "bitter herb that clears heat", opts)

      assert "Huang Lian" in titles(Search.hybrid(:page, "bitter herb that clears heat", opts))
    end

    test "the documented cost: a query in none of the corpus's words is gated", %{opts: opts} do
      # "licorice" is no word of the corpus, and the semantic legs alone would
      # have answered it. `term_gate/0` says so; turning the gate off is the
      # remedy for a site whose users search that way.
      assert Search.hybrid(:page, "licorice", opts) == []

      put_search_env(term_gate: false)
      assert Search.hybrid(:page, "licorice", opts) != []
    end

    test "a record named on one word survives a stray word", %{opts: opts} do
      evidence = Search.term_evidence(:page, "ban qwerty", opts)

      assert evidence.named?
      assert evidence.verdict != :junk
    end

    test "a query of stop words alone has no terms and is not gated", %{opts: opts} do
      assert %TermEvidence{terms: [], verdict: :ok} =
               Search.term_evidence(:page, "the of and", opts)
    end

    test "is not consulted when the keyword leg matched", %{opts: opts} do
      [hit | _] = Search.hybrid(:page, "astragalus", opts)
      assert hit.title == "Huang Qi"
    end
  end

  describe "the vocabulary" do
    test "is the caller's organisation's alone", %{admin: admin} do
      org = fn name ->
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: name,
          slug: "gate-#{name}-#{System.unique_integer([:positive])}",
          status: :active
        })
      end

      herbs = org.("herbs")
      music = org.("music")
      CMS.create_page!(%{title: "Ban Xia", slug: "gate-bx"}, actor: admin, tenant: herbs)

      CMS.create_page!(%{title: "Taylor Swift Tour Dates", slug: "gate-ts"},
        actor: admin,
        tenant: music
      )

      query = "taylor swift tour dates"
      assert Search.term_evidence(:page, query, actor: admin, tenant: herbs).verdict == :junk
      assert Search.term_evidence(:page, query, actor: admin, tenant: music).verdict == :ok
    end
  end

  describe "term_gate/0" do
    test "defaults on with the documented settings" do
      put_search_env(term_gate: true)

      assert Search.term_gate() == %{
               min_share: 0.6,
               min_share_named: 0.5,
               one_typo_length: 2,
               two_typo_length: 8
             }
    end

    test "is nil when off, merges partial settings, and raises on nonsense" do
      put_search_env(term_gate: false)
      assert Search.term_gate() == nil

      put_search_env(term_gate: [min_share: 0.75])
      assert Search.term_gate().min_share == 0.75

      for bad <- [:on, "true", [min_share: 0], [min_share: 1.5], [one_typo_length: 0], [bogus: 1]] do
        put_search_env(term_gate: bad)
        assert_raise ArgumentError, fn -> Search.term_gate() end
      end
    end

    test "the boot-time keys override without replacing an overlay's settings" do
      put_search_env(term_gate: [min_share_named: 0.4], term_gate_enabled: false)
      assert Search.term_gate() == nil

      put_search_env(term_gate_enabled: true, term_gate_min_share: 0.8)
      assert %{min_share: 0.8, min_share_named: 0.4} = Search.term_gate()

      put_search_env(term_gate: false, term_gate_enabled: true)
      assert %{min_share: 0.8} = Search.term_gate()
    end
  end

  describe "across/2" do
    @gate %{min_share: 0.6, min_share_named: 0.5, one_typo_length: 2, two_typo_length: 8}

    defp junk(evidenced, names \\ []) do
      %TermEvidence{
        terms: ~w(heat interior),
        verdict: :junk,
        evidenced: MapSet.new(evidenced),
        names: MapSet.new(names)
      }
    end

    test "is junk only when every section is and their evidence together falls short" do
      assert TermEvidence.across([junk([]), junk([])], @gate)
      assert TermEvidence.across([junk(~w(heat)), junk(~w(heat))], @gate)
    end

    test "is not junk when the sections' evidence together clears the bar" do
      # "heat" in one section, "interior" in the other.
      refute TermEvidence.across([junk(~w(heat)), junk(~w(interior))], @gate)
    end

    test "is not junk when any section matched or passed" do
      refute TermEvidence.across([junk([]), nil], @gate)
      refute TermEvidence.across([junk([]), %TermEvidence{verdict: :ok}], @gate)
      refute TermEvidence.across([], @gate)
    end
  end

  describe "edits/2 and levenshtein/2" do
    @gate %{min_share: 0.6, min_share_named: 0.5, one_typo_length: 2, two_typo_length: 8}

    test "budget by length" do
      assert TermEvidence.edits(1, @gate) == 0
      assert TermEvidence.edits(2, @gate) == 1
      assert TermEvidence.edits(7, @gate) == 1
      assert TermEvidence.edits(8, @gate) == 2
      assert TermEvidence.edits(65, @gate) == 0
    end

    test "counts inserts, deletes and substitutions" do
      assert TermEvidence.levenshtein("zi", "zhi") == 1
      assert TermEvidence.levenshtein("qui", "qi") == 1
      assert TermEvidence.levenshtein("lain", "lian") == 2
      assert TermEvidence.levenshtein("kitten", "sitting") == 3
      assert TermEvidence.levenshtein("", "abc") == 3
      assert TermEvidence.levenshtein("same", "same") == 0
    end
  end
end
