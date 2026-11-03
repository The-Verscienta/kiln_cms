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

  Hermetic like `KilnCMS.Search.RankingFixtureTest`: the corpus lives in an
  org of its own, so no other test's rows or per-org embedding budget can
  reach it, and vector reads are exact (`KilnCMS.Search.VectorScan`'s
  measurement mode, scoped to the test's transaction). On approximate scans
  the ML job's search suite, run alone and in its own order, missed every
  page's block, which left the far post the block leg's only candidate and
  so its rank 1.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Search
  alias KilnCMS.Search.VectorScan

  # The query (matched as a substring, so a configured `query_prefix` does
  # not move it) and anything marked `nearmark` embed near one axis, anything
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
        text =~ "exactmark" or text =~ "heat interior" -> {:ok, axis(0, 0.0, text)}
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

    # `SET LOCAL`: the sandbox's transaction scopes it to this test, and the
    # shared sandbox hands this connection to every process the sweep spawns.
    for statement <- VectorScan.statements(:exact) do
      Repo.query!(String.replace_prefix(statement, "SET ", "SET LOCAL "))
    end

    %{org: org(), admin: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: "global rank",
      slug: "global-rank-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp seed(%{org: org, admin: admin}, post_marker) do
    for n <- 1..40 do
      %{
        title: "Pattern #{n}",
        slug: "gr-pattern-#{n}",
        body_markdown: "Heat lodged in the interior, case #{n}. nearmark"
      }
      |> CMS.create_page!(actor: admin, tenant: org)
      |> then(&CMS.publish_page!(&1, %{}, actor: admin, tenant: org))
    end

    %{
      title: "Ginseng root",
      slug: "gr-ginseng",
      body_markdown: "A measured look at the root and its heat. #{post_marker}"
    }
    |> CMS.create_post!(actor: admin, tenant: org)
    |> then(&CMS.publish_post!(&1, %{}, actor: admin, tenant: org))

    KilnCMS.DataCase.drain_oban()
    assert unembedded(org) == [], "every record and its blocks should be embedded"
  end

  # Slugs of the org's records missing a document or block embedding —
  # empty when the embedding jobs all ran.
  defp unembedded(org) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT slug FROM pages p WHERE org_id = $1 AND (embedding IS NULL OR NOT EXISTS
          (SELECT 1 FROM block_embeddings b WHERE b.document_id = p.id))
        UNION ALL
        SELECT slug FROM posts p WHERE org_id = $1 AND (embedding IS NULL OR NOT EXISTS
          (SELECT 1 FROM block_embeddings b WHERE b.document_id = p.id))
        """,
        [Ecto.UUID.dump!(org.id)]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp sweep(%{org: org}) do
    results =
      Search.global("heat interior", sections: [:pages, :posts], limit: 50, tenant: org)

    {results.pages, results.posts}
  end

  test "a lone far record does not outrank full matches from a large section", ctx do
    seed(ctx, "farmark")
    {pages, [post]} = sweep(ctx)

    assert length(pages) == 40
    assert Enum.all?(pages, &(:keyword in Search.hit_legs(&1)))
    assert :keyword_any in Search.hit_legs(post)

    weakest_page = pages |> Enum.map(&Search.hit_score/1) |> Enum.min()
    assert Search.hit_score(post) < weakest_page
  end

  test "a lone record that is the nearest still outranks weaker matches", ctx do
    seed(ctx, "exactmark")
    {pages, [post]} = sweep(ctx)

    weakest_page = pages |> Enum.map(&Search.hit_score/1) |> Enum.min()
    assert Search.hit_score(post) > weakest_page
  end

  test "a sweep of one section ranks as hybrid/3 does", %{org: org, admin: admin} = ctx do
    seed(ctx, "farmark")
    opts = [limit: 50, actor: admin, tenant: org]

    swept = Search.global("heat interior", [sections: [:pages]] ++ opts).pages
    direct = Search.hybrid(:page, "heat interior", opts)

    assert Enum.map(swept, & &1.id) == Enum.map(direct, & &1.id)
    assert Enum.map(swept, &Search.hit_score/1) == Enum.map(direct, &Search.hit_score/1)
  end

  test "documents sharing a tag keep the tag leg's order instead of all taking rank 1",
       %{org: org, admin: admin} do
    tag = CMS.create_tag!(%{name: "immunity", slug: "gr-immunity"}, actor: admin, tenant: org)

    for n <- 1..3 do
      CMS.create_page!(%{title: "Remedy #{n}", slug: "gr-remedy-#{n}", tag_ids: [tag.id]},
        actor: admin,
        tenant: org
      )
    end

    CMS.create_post!(%{title: "Tonic", slug: "gr-tonic", tag_ids: [tag.id]},
      actor: admin,
      tenant: org
    )

    KilnCMS.DataCase.drain_oban()

    results =
      Search.global("immunity",
        sections: [:pages, :posts],
        explain: true,
        actor: admin,
        tenant: org
      )

    tag_rank = fn hit -> Search.hit_explain(hit).legs.tag.rank end

    assert results.pages |> Enum.map(tag_rank) |> Enum.sort() == [1, 3, 4]
    assert Enum.map(results.posts, tag_rank) == [1]
  end

  describe "global_ranks/1" do
    defp collected(leg, keyed) do
      %{
        legs: [{leg, Enum.map(keyed, fn {id, _key} -> %{id: id} end), 1.0}],
        keys: %{leg => Map.new(keyed)}
      }
    end

    test "ranks one leg over every section, ties sharing the better rank" do
      ranks =
        Search.global_ranks(%{
          pages: collected(:semantic, [{"p1", 0.1}, {"p2", 0.3}, {"p3", 0.5}]),
          posts: collected(:semantic, [{"q1", 0.1}, {"q2", 0.3}])
        })

      assert ranks.pages.semantic == %{"p1" => 1, "p2" => 3, "p3" => 5}
      assert ranks.posts.semantic == %{"q1" => 1, "q2" => 3}
      assert ranks.posts.keyword == %{}
    end

    test "records tied within a section keep their leg's order" do
      ranks =
        Search.global_ranks(%{
          pages: collected(:tag, [{"p1", 0.2}, {"p2", 0.2}, {"p3", 0.2}]),
          posts: collected(:tag, [{"q1", 0.2}])
        })

      assert ranks.pages.tag == %{"p1" => 1, "p2" => 3, "p3" => 4}
      assert ranks.posts.tag == %{"q1" => 1}
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

      assert ranks.pages.semantic == %{"keyed" => 1, "unkeyed" => 3}
      assert ranks.posts.semantic == %{"q1" => 2}
    end
  end
end
