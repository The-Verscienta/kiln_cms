defmodule KilnCMS.Search.ExplainTest do
  @moduledoc """
  `explain: true` on `KilnCMS.Search.hybrid/3` and `global/2` (A2): each hit
  reports the rank every leg gave it — the rank fusion used — with the raw
  number that leg ranked by, and which query terms it matched, so a caller
  can sort by coverage and then score without reading snippets. Off by
  default. Semantic is off in the test env, so the keyword legs carry it.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "explain-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp token, do: "xpl#{System.unique_integer([:positive])}"

  # One page matching both query words, one matching only the first: the
  # every-term leg finds one record, so the any-term relaxation joins.
  defp seed do
    admin = admin()
    {first, second} = {token(), token()}

    publish = fn attrs ->
      attrs
      |> Map.put(:slug, "explain-#{System.unique_integer([:positive])}")
      |> CMS.create_page!(actor: admin)
      |> then(&CMS.publish_page!(&1, %{}, actor: admin))
    end

    full = publish.(%{title: "Full", body_markdown: "Both #{first} and #{second} here."})
    partial = publish.(%{title: "Partial", body_markdown: "Only #{first} here."})
    KilnCMS.DataCase.drain_oban()

    %{admin: admin, query: "#{first} #{second}", first: first, full: full, partial: partial}
  end

  test "each hit explains its legs, matched terms and coverage" do
    %{admin: admin, query: query, first: first, full: full, partial: partial} = seed()

    hits = Search.hybrid(:page, query, actor: admin, explain: true)
    by_id = Map.new(hits, &{&1.id, Search.hit_explain(&1)})

    full_explain = Map.fetch!(by_id, full.id)
    partial_explain = Map.fetch!(by_id, partial.id)

    assert full_explain.coverage == 1.0
    assert partial_explain.coverage == 0.5
    assert partial_explain.matched_terms == [first]

    assert [%{term: ^first, matched: true}, %{matched: false}] = partial_explain.terms
    assert Enum.all?(partial_explain.terms, &is_binary(&1.lexeme))

    # The full match came through the every-term leg, the partial one only
    # through the any-term relaxation.
    assert %{rank: 1, measure: :ts_rank, score: score} = full_explain.legs.keyword
    assert is_float(score) and score > 0
    refute Map.has_key?(partial_explain.legs, :keyword)
    assert %{measure: :ts_rank, rank: rank} = partial_explain.legs.keyword_any
    assert is_integer(rank)

    for hit <- hits do
      explain = Search.hit_explain(hit)
      # One entry per leg that returned the hit, and the contributions are
      # the fused score, term by term.
      assert explain.legs |> Map.keys() |> Enum.sort() == Enum.sort(Search.hit_legs(hit))

      assert_in_delta explain.legs |> Map.values() |> Enum.map(& &1.contribution) |> Enum.sum(),
                      Search.hit_score(hit),
                      1.0e-9
    end

    # Sorting by coverage, then score, puts the full match first.
    assert [%{id: id} | _] =
             Enum.sort_by(hits, &{-Search.hit_explain(&1).coverage, -Search.hit_score(&1)})

    assert id == full.id
  end

  test "a match-or-not leg reports no raw score" do
    %{admin: admin, full: full} = seed()

    [hit] = Search.hybrid(:page, "Full", actor: admin, explain: true, filters: %{})
    assert hit.id == full.id
    assert %{rank: 1, score: nil, measure: nil} = Search.hit_explain(hit).legs.title
  end

  test "a fuzzy hit reports the trigram similarity it was ranked by" do
    admin = admin()
    word = "zymurgicon#{System.unique_integer([:positive])}"

    page =
      %{title: "#{word} guide", slug: "explain-fz-#{System.unique_integer([:positive])}"}
      |> CMS.create_page!(actor: admin)
      |> then(&CMS.publish_page!(&1, %{}, actor: admin))

    # A dropped letter: no lexeme matches, so only the trigram leg finds it.
    typo = String.replace(word, "zymurg", "zymrg")
    [hit] = Search.hybrid(:page, typo, actor: admin, explain: true)

    assert hit.id == page.id

    assert %{fuzzy: %{measure: :trigram_similarity, score: similarity}} =
             Search.hit_explain(hit).legs

    assert similarity > 0 and similarity <= 1
    assert Search.hit_explain(hit).coverage == 0.0
  end

  test "explain is off by default" do
    %{admin: admin, query: query} = seed()

    hits = Search.hybrid(:page, query, actor: admin)
    assert hits != []
    assert Enum.all?(hits, &is_nil(Search.hit_explain(&1)))

    %{pages: pages} = Search.global(query, sections: [:pages])
    assert pages != []
    assert Enum.all?(pages, &is_nil(Search.hit_explain(&1)))
  end

  test "global/2 passes explain through to every content section" do
    %{query: query, full: full} = seed()

    %{pages: pages} = Search.global(query, sections: [:pages], explain: true)

    assert %{coverage: 1.0, legs: %{keyword: %{rank: 1}}} =
             pages |> Enum.find(&(&1.id == full.id)) |> Search.hit_explain()
  end
end
