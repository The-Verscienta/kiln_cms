defmodule KilnCMS.Search.RankingStabilityTest do
  @moduledoc """
  A fixed corpus, a fixed set of queries, and the exact ranked output of
  `KilnCMS.Search.global/2` pinned: section, title, fused score and legs, in
  order, plus the highlight each hit carries.

  This is the guard for #1712, which rebuilt *how* a search runs — one
  pooled connection per request instead of four, the legs reading ids rather
  than whole rows, an index-backed title leg — under the promise that *what*
  it returns does not move. Every expected list below was recorded against
  the code before that change. A diff here is a ranking change: it needs a
  reason of its own, not a re-pin to make the test pass.

  Runs twice: keyword-only (the default build) and with the deterministic
  stub embedder, so the semantic, block and tag legs take part too.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defmodule StubEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  @queries [
    # One rare word: the keyword and title legs.
    "saffron",
    # A title the query names whole, plus a keyword crowd around it.
    "saffron rice",
    # A word on most documents: ranking a crowd.
    "kitchen",
    # Two records named in one query: the AND fails closed, the title leg and
    # the any-term fallback carry it.
    "pad thai tom yum",
    # A typo: the fuzzy leg.
    "saffon",
    # A question: eight lexemes ANDed match nothing, the OR relaxation does.
    "how do I cook a green curry at home",
    # A tag's name.
    "weeknight"
  ]

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rank-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # The corpus. Created in this order every run, so `inserted_at` — the
  # tiebreaker of every keyword leg — orders it the same way each time.
  defp seed_corpus do
    admin = admin()
    tag = CMS.create_tag!(%{name: "weeknight", slug: "rank-weeknight"}, actor: admin)

    pages = [
      {"Pad Thai", "Rice noodles, tamarind and peanuts from the kitchen.", []},
      {"Tom Yum", "A hot and sour soup; lemongrass, galangal, kitchen staple.", [tag.id]},
      {"Green Curry", "Cook a green curry at home with coconut milk.", [tag.id]},
      {"Saffron Rice", "Saffron threads bloom in warm stock in the kitchen.", []},
      {"About the kitchen", "Everything we cook, and how we cook it at home.", []},
      {"Thai Street Food", "Pad thai and tom yum are the two dishes everybody asks about.", []}
    ]

    posts = [
      {"Saffron, the costly spice", "Why saffron costs more than gold, gram for gram.", []},
      {"Kitchen notes", "A kitchen diary: curry, rice, soup, noodles.", [tag.id]},
      {"Weeknight dinners", "Fast meals for a weeknight kitchen.", [tag.id]},
      {"How to cook rice", "Rinse, soak, simmer. Home cooking basics.", []},
      {"Yum", "A single word post about food.", []}
    ]

    for {title, body, tag_ids} <- pages do
      title
      |> then(
        &CMS.create_page!(
          %{title: &1, slug: slug(&1), body_markdown: body, tag_ids: tag_ids},
          actor: admin
        )
      )
      |> then(&CMS.publish_page!(&1, %{}, actor: admin))
    end

    for {title, body, tag_ids} <- posts do
      title
      |> then(
        &CMS.create_post!(
          %{title: &1, slug: slug(&1), body_markdown: body, tag_ids: tag_ids},
          actor: admin
        )
      )
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))
    end

    # A draft matching every query: anonymous search must never see it, so it
    # must not appear below — nor move anything that does.
    CMS.create_page!(
      %{
        title: "Saffron kitchen draft",
        slug: "rank-draft",
        body_markdown: "saffron kitchen pad thai tom yum weeknight curry"
      },
      actor: admin
    )

    KilnCMS.DataCase.drain_oban()
  end

  defp slug(title) do
    "rank-" <> (title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"))
  end

  # What a caller sees, reduced to what must not move: per content section,
  # each hit's title, score (rounded past float noise) and legs, in order,
  # and whether it carries a highlight.
  defp ranked(query) do
    query
    |> Search.global(authorize?: true, highlight: true, limit: 10)
    |> Map.take([:pages, :posts, :entries])
    |> Enum.sort()
    |> Enum.map(fn {section, hits} ->
      {section,
       Enum.map(hits, fn hit ->
         {hit.title, Float.round(Search.hit_score(hit), 8), Search.hit_legs(hit),
          is_binary(hit.highlight) and hit.highlight != ""}
       end)}
    end)
  end

  defp snapshot, do: Map.new(@queries, &{&1, ranked(&1)})

  test "keyword-only ranking is unchanged on a fixed corpus" do
    put_search_env(semantic: false)
    seed_corpus()
    assert snapshot() == keyword_only_expected()
  end

  test "hybrid ranking (semantic, block and tag legs on) is unchanged on a fixed corpus" do
    put_search_env(semantic: true, embedder: StubEmbedder)
    seed_corpus()
    assert snapshot() == hybrid_expected()
  end

  defp keyword_only_expected do
    %{
      "how do I cook a green curry at home" => [
        entries: [],
        pages: [
          {"Green Curry", 0.07377049, [:keyword, :keyword_any, :title], true},
          {"About the kitchen", 0.00806452, [:keyword_any], true}
        ],
        posts: [
          {"How to cook rice", 0.00819672, [:keyword_any], true},
          {"Kitchen notes", 0.00806452, [:keyword_any], true}
        ]
      ],
      "kitchen" => [
        entries: [],
        pages: [
          {"About the kitchen", 0.06557377, [:keyword, :title], true},
          {"Saffron Rice", 0.01612903, [:keyword], true},
          {"Tom Yum", 0.01587302, [:keyword], true},
          {"Pad Thai", 0.015625, [:keyword], true}
        ],
        posts: [
          {"Kitchen notes", 0.02459016, [:keyword, :fuzzy], true},
          {"Weeknight dinners", 0.01612903, [:keyword], true}
        ]
      ],
      "pad thai tom yum" => [
        entries: [],
        pages: [
          {"Pad Thai", 0.05711684, [:keyword_any, :title], true},
          {"Tom Yum", 0.05645161, [:keyword_any, :title], true},
          {"Thai Street Food", 0.02459016, [:keyword, :keyword_any], true}
        ],
        posts: [{"Yum", 0.05737705, [:keyword_any, :title], true}]
      ],
      "saffon" => [entries: [], pages: [], posts: []],
      "saffron" => [
        entries: [],
        pages: [{"Saffron Rice", 0.02459016, [:keyword, :fuzzy], true}],
        posts: [{"Saffron, the costly spice", 0.02459016, [:keyword, :fuzzy], true}]
      ],
      "saffron rice" => [
        entries: [],
        pages: [
          {"Saffron Rice", 0.08196721, [:keyword, :keyword_any, :title, :fuzzy], true},
          {"Pad Thai", 0.00806452, [:keyword_any], true}
        ],
        posts: [
          {"Saffron, the costly spice", 0.01639344, [:keyword_any, :fuzzy], true},
          {"How to cook rice", 0.00806452, [:keyword_any], true},
          {"Kitchen notes", 0.00793651, [:keyword_any], true}
        ]
      ],
      "weeknight" => [
        entries: [],
        pages: [],
        posts: [{"Weeknight dinners", 0.02459016, [:keyword, :fuzzy], true}]
      ]
    }
  end

  defp hybrid_expected do
    %{
      "how do I cook a green curry at home" => [
        entries: [],
        pages: [
          {"Green Curry", 0.10454701, [:keyword, :keyword_any, :semantic, :block, :title], true},
          {"About the kitchen", 0.04033097, [:keyword_any, :semantic, :block], true},
          {"Tom Yum", 0.03252247, [:semantic, :block], true},
          {"Saffron Rice", 0.03200205, [:semantic, :block], true},
          {"Pad Thai", 0.03077652, [:semantic, :block], true},
          {"Thai Street Food", 0.03076923, [:semantic, :block], true}
        ],
        posts: [
          {"Kitchen notes", 0.04008296, [:keyword_any, :semantic, :block], true},
          {"How to cook rice", 0.03971037, [:keyword_any, :semantic, :block], true},
          {"Yum", 0.03201844, [:semantic, :block], true},
          {"Weeknight dinners", 0.03174603, [:semantic, :block], true},
          {"Saffron, the costly spice", 0.03151365, [:semantic, :block], true}
        ]
      ],
      "kitchen" => [
        entries: [],
        pages: [
          {"About the kitchen", 0.09759221, [:keyword, :semantic, :block, :title], true},
          {"Saffron Rice", 0.04713865, [:keyword, :semantic, :block], true},
          {"Pad Thai", 0.04713865, [:keyword, :semantic, :block], true},
          {"Tom Yum", 0.04617605, [:keyword, :semantic, :block], true},
          {"Green Curry", 0.03252247, [:semantic, :block], true},
          {"Thai Street Food", 0.03174603, [:semantic, :block], true}
        ],
        posts: [
          {"Kitchen notes", 0.05559978, [:keyword, :semantic, :block, :fuzzy], true},
          {"Weeknight dinners", 0.04865151, [:keyword, :semantic, :block], true},
          {"Saffron, the costly spice", 0.03200205, [:semantic, :block], true},
          {"Yum", 0.03177806, [:semantic, :block], true},
          {"How to cook rice", 0.03149802, [:semantic, :block], true}
        ]
      ],
      "pad thai tom yum" => [
        entries: [],
        pages: [
          {"Tom Yum", 0.08819764, [:keyword_any, :semantic, :block, :title], true},
          {"Pad Thai", 0.08789335, [:keyword_any, :semantic, :block, :title], true},
          {"Thai Street Food", 0.05535939, [:keyword, :keyword_any, :semantic, :block], true},
          {"About the kitchen", 0.03252247, [:semantic, :block], true},
          {"Green Curry", 0.03201844, [:semantic, :block], true},
          {"Saffron Rice", 0.03128055, [:semantic, :block], true}
        ],
        posts: [
          {"Yum", 0.0893791, [:keyword_any, :semantic, :block, :title], true},
          {"Weeknight dinners", 0.03278689, [:semantic, :block], true},
          {"Saffron, the costly spice", 0.03151365, [:semantic, :block], true},
          {"How to cook rice", 0.03149802, [:semantic, :block], true},
          {"Kitchen notes", 0.03100962, [:semantic, :block], true}
        ]
      ],
      "saffon" => [
        entries: [],
        pages: [
          {"Green Curry", 0.03226646, [:semantic, :block], true},
          {"Pad Thai", 0.03226646, [:semantic, :block], true},
          {"Thai Street Food", 0.03225806, [:semantic, :block], true},
          {"Saffron Rice", 0.03100962, [:semantic, :block], true},
          {"About the kitchen", 0.03077652, [:semantic, :block], true},
          {"Tom Yum", 0.03053613, [:semantic, :block], true}
        ],
        posts: [
          {"Saffron, the costly spice", 0.03201844, [:semantic, :block], true},
          {"How to cook rice", 0.03201844, [:semantic, :block], true},
          {"Weeknight dinners", 0.03174603, [:semantic, :block], true},
          {"Yum", 0.03151365, [:semantic, :block], true},
          {"Kitchen notes", 0.03151365, [:semantic, :block], true}
        ]
      ],
      "saffron" => [
        entries: [],
        pages: [
          {"Saffron Rice", 0.05559978, [:keyword, :semantic, :block, :fuzzy], true},
          {"Green Curry", 0.03252247, [:semantic, :block], true},
          {"About the kitchen", 0.03177806, [:semantic, :block], true},
          {"Pad Thai", 0.03175403, [:semantic, :block], true},
          {"Thai Street Food", 0.03174603, [:semantic, :block], true},
          {"Tom Yum", 0.03030303, [:semantic, :block], true}
        ],
        posts: [
          {"Saffron, the costly spice", 0.0563442, [:keyword, :semantic, :block, :fuzzy], true},
          {"How to cook rice", 0.03201844, [:semantic, :block], true},
          {"Weeknight dinners", 0.03200205, [:semantic, :block], true},
          {"Yum", 0.03177806, [:semantic, :block], true},
          {"Kitchen notes", 0.03125763, [:semantic, :block], true}
        ]
      ],
      "saffron rice" => [
        entries: [],
        pages: [
          {"Saffron Rice", 0.11374527,
           [:keyword, :keyword_any, :semantic, :block, :title, :fuzzy], true},
          {"Pad Thai", 0.04008296, [:keyword_any, :semantic, :block], true},
          {"Tom Yum", 0.03981855, [:semantic, :block, :tag], true},
          {"Green Curry", 0.03922125, [:semantic, :block, :tag], true},
          {"Thai Street Food", 0.03200205, [:semantic, :block], true},
          {"About the kitchen", 0.03053613, [:semantic, :block], true}
        ],
        posts: [
          {"Kitchen notes", 0.04878791, [:keyword_any, :semantic, :block, :tag], true},
          {"Saffron, the costly spice", 0.04814747, [:keyword_any, :semantic, :block, :fuzzy],
           true},
          {"How to cook rice", 0.04006656, [:keyword_any, :semantic, :block], true},
          {"Weeknight dinners", 0.03920634, [:semantic, :block, :tag], true},
          {"Yum", 0.03125763, [:semantic, :block], true}
        ]
      ],
      "weeknight" => [
        entries: [],
        pages: [
          {"Tom Yum", 0.03981855, [:semantic, :block, :tag], true},
          {"Green Curry", 0.03922125, [:semantic, :block, :tag], true},
          {"Pad Thai", 0.03201844, [:semantic, :block], true},
          {"Thai Street Food", 0.03200205, [:semantic, :block], true},
          {"Saffron Rice", 0.03177806, [:semantic, :block], true},
          {"About the kitchen", 0.03053613, [:semantic, :block], true}
        ],
        posts: [
          {"Weeknight dinners", 0.0637965, [:keyword, :semantic, :block, :fuzzy, :tag], true},
          {"Kitchen notes", 0.0408514, [:semantic, :block, :tag], true},
          {"How to cook rice", 0.03200205, [:semantic, :block], true},
          {"Saffron, the costly spice", 0.03175403, [:semantic, :block], true},
          {"Yum", 0.03125763, [:semantic, :block], true}
        ]
      ]
    }
  end
end
