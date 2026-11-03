defmodule KilnCMS.Search.GlobalRankTest do
  @moduledoc """
  #2175: `global/2` ranks the distance and `ts_rank` legs over every
  section's candidates together, so a section holding one record no longer
  hands it rank 1 in every leg that returns it.

  The corpus is the production report in miniature: forty pages that match
  both query terms and sit near the query, and one post that matches one
  term. Ranked per section, the post's semantic and block rank 1 outscored
  the pages from about the fourteenth down. Ranked globally it outranks a
  page only when it is the nearer one.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search

  # The query and anything marked `nearmark` embed near one axis, anything
  # marked `exactmark` exactly on it, and everything else near an orthogonal
  # one. A little hashed noise keeps the near distances distinct, so they
  # rank rather than tie.
  defmodule AxisEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder

    @dim 384

    @impl true
    def embed(text) do
      cond do
        text =~ "exactmark" or String.trim(text) == "heat interior" -> {:ok, axis(0, 0.0, text)}
        text =~ "nearmark" -> {:ok, axis(0, 0.05, text)}
        true -> {:ok, axis(1, 0.05, text)}
      end
    end

    defp axis(index, noise, text) do
      seed = :erlang.phash2(text)

      for i <- 0..(@dim - 1) do
        if(i == index, do: 1.0, else: 0.0) + noise * :math.sin(seed * 1.0e-4 + i)
      end
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(semantic: true, embedder: AxisEmbedder)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp seed(post_marker) do
    admin = admin()

    for n <- 1..40 do
      %{
        title: "Pattern #{n}",
        slug: "gr-pattern-#{n}",
        body_markdown: "Heat lodged in the interior, case #{n}. nearmark"
      }
      |> CMS.create_page!(actor: admin)
      |> then(&CMS.publish_page!(&1, %{}, actor: admin))
    end

    %{
      title: "Ginseng root",
      slug: "gr-ginseng",
      body_markdown: "A measured look at the root and its heat. #{post_marker}"
    }
    |> CMS.create_post!(actor: admin)
    |> then(&CMS.publish_post!(&1, %{}, actor: admin))

    KilnCMS.DataCase.drain_oban()
  end

  defp sweep do
    results = Search.global("heat interior", sections: [:pages, :posts], limit: 50)
    {results.pages, results.posts}
  end

  test "a lone far record does not outrank full matches from a large section" do
    seed("farmark")
    {pages, [post]} = sweep()

    assert length(pages) == 40
    assert Enum.all?(pages, &(:keyword in Search.hit_legs(&1)))
    assert :keyword_any in Search.hit_legs(post)

    weakest_page = pages |> Enum.map(&Search.hit_score/1) |> Enum.min()
    assert Search.hit_score(post) < weakest_page
  end

  test "a lone record that is the nearest still outranks weaker matches" do
    seed("exactmark")
    {pages, [post]} = sweep()

    weakest_page = pages |> Enum.map(&Search.hit_score/1) |> Enum.min()
    assert Search.hit_score(post) > weakest_page
  end

  describe "global_ranks/1" do
    defp collected(leg, keyed) do
      %{
        legs: [{leg, Enum.map(keyed, fn {id, _key} -> %{id: id} end), 1.0}],
        keys: %{leg => Map.new(keyed)}
      }
    end

    test "ranks one leg over every section, ties sharing the average position" do
      ranks =
        Search.global_ranks(%{
          pages: collected(:semantic, [{"p1", 0.1}, {"p2", 0.3}, {"p3", 0.5}]),
          posts: collected(:semantic, [{"q1", 0.3}])
        })

      assert ranks.pages.semantic === %{"p1" => 1, "p2" => 2.5, "p3" => 4}
      assert ranks.posts.semantic === %{"q1" => 2.5}
      assert ranks.posts.keyword == %{}
    end

    # The tag leg ties by design: every document carrying a tag sits at
    # that tag's distance. Best-rank ties handed all of them rank 1, which
    # multiplied the weakest leg's weight by the size of the group.
    test "a tag's documents split its positions rather than all taking rank 1" do
      ranks =
        Search.global_ranks(%{
          pages: collected(:tag, for(n <- 1..30, do: {"page-#{n}", 0.2})),
          posts: collected(:tag, [{"post", 0.2}, {"far", 0.4}])
        })

      assert ranks.pages.tag["page-1"] === 16
      assert ranks.posts.tag === %{"post" => 16, "far" => 32}
    end

    test "a candidate with no key ranks after every keyed one" do
      ranks =
        Search.global_ranks(%{
          pages: %{
            legs: [{:semantic, [%{id: "unkeyed"}, %{id: "keyed"}], 1.0}],
            keys: %{semantic: %{"unkeyed" => %Ash.NotLoaded{}, "keyed" => 0.9}}
          },
          posts: collected(:semantic, [{"q1", 0.95}])
        })

      assert ranks.pages.semantic === %{"keyed" => 1, "unkeyed" => 3}
      assert ranks.posts.semantic === %{"q1" => 2}
    end
  end
end
