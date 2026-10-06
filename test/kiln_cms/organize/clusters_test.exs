defmodule KilnCMS.Organize.ClustersTest do
  @moduledoc "Semantic clusters as a library browse axis (#1596)."
  # async: false — swaps the global KilnCMS.Search env.
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrganizeFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Organize.Clusters
  alias KilnCMS.Organize.Terms
  alias KilnCMS.Organize.Vectors

  # Text naming a topic embeds close to that topic's axis, plus a little
  # per-text noise, so three topics are three real, separable clusters — the
  # hash stub alone puts unrelated texts at arbitrary distances.
  defmodule TopicEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @topics %{"alpha" => 0, "beta" => 1, "gamma" => 2}

    @impl true
    def embed(text) do
      axis = Enum.find_value(@topics, 3, fn {word, i} -> if text =~ word, do: i end)
      seed = :erlang.phash2(text)

      {:ok,
       for i <- 0..383 do
         noise = :math.sin(seed * 1.0e-3 + i) * 0.01
         if i == axis, do: 1.0 + noise, else: noise
       end}
    end
  end

  defmodule RaisingEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(_text), do: raise("the embedder must not be called with semantic search off")
  end

  setup do
    semantic_on!(embedder: TopicEmbedder, suggest_tags_threshold: 0.35)
    %{org: org!(), admin: user!(:admin)}
  end

  defp topic_posts(org, admin, topic, n) do
    for i <- 1..n, do: post!(org, admin, "#{topic} passage #{i}", title: "#{topic} #{i}")
  end

  defp ids(docs), do: MapSet.new(docs, & &1.id)

  test "k follows √(n/2), between 2 and 12" do
    assert Clusters.k(0) == 0
    assert Clusters.k(1) == 1
    assert Clusters.k(2) == 2
    assert Clusters.k(18) == 3
    assert Clusters.k(300) == 12
    assert Clusters.k(10_000) == 12
  end

  test "groups documents by topic, labels covered clusters, flags the uncovered one",
       %{org: org, admin: admin} do
    alpha = topic_posts(org, admin, "alpha", 6)
    beta = topic_posts(org, admin, "beta", 6)
    gamma = topic_posts(org, admin, "gamma", 6)

    alpha_tag = tag!(org, admin, "alpha")
    beta_tag = tag!(org, admin, "beta")
    {:ok, _} = Terms.index_tag_vectors(org, admin)

    %{clusters: clusters, unindexed: 0} = Clusters.browse(org, admin)

    assert length(clusters) == 3

    by_members = Map.new(clusters, &{MapSet.new(&1.members, fn m -> m.id end), &1.label})

    assert {:tag, %{id: a}, _} = Map.fetch!(by_members, ids(alpha))
    assert a == alpha_tag.id
    assert {:tag, %{id: b}, _} = Map.fetch!(by_members, ids(beta))
    assert b == beta_tag.id
    # No tag is near "gamma": a group the vocabulary has no word for.
    assert :uncovered == Map.fetch!(by_members, ids(gamma))
  end

  test "drafts are not clustered, an unindexed published document is counted, other orgs never appear",
       %{org: org, admin: admin} do
    alpha = topic_posts(org, admin, "alpha", 2)
    _draft = post!(org, admin, "alpha draft", publish?: false)

    unindexed =
      org
      |> then(
        &CMS.create_post!(%{title: "alpha late", slug: "late-#{uniq()}"},
          actor: admin,
          tenant: &1
        )
      )
      |> CMS.publish_post!(%{}, actor: admin, tenant: org)

    other = org!()
    _foreign = topic_posts(other, admin, "alpha", 2)

    %{clusters: clusters, unindexed: 1} = Clusters.browse(org, admin)

    members = clusters |> Enum.flat_map(& &1.members) |> ids()
    assert members == ids(alpha)
    refute MapSet.member?(members, unindexed.id)
  end

  test "deterministic: the same library clusters the same way twice", %{org: org, admin: admin} do
    topic_posts(org, admin, "alpha", 4)
    topic_posts(org, admin, "beta", 4)
    topic_posts(org, admin, "gamma", 4)

    shape = fn ->
      org
      |> Clusters.browse(admin)
      |> Map.fetch!(:clusters)
      |> Enum.map(&Enum.map(&1.members, fn m -> m.id end))
    end

    assert shape.() == shape.()
  end

  test "semantic off: empty, and the embedder is never called", %{org: org, admin: admin} do
    topic_posts(org, admin, "alpha", 2)
    put_search_env(semantic: false, embedder: RaisingEmbedder)

    assert Clusters.browse(org, admin) == %{clusters: [], unindexed: 0}
  end

  describe "Vectors.kmeans/2" do
    test "separates well-separated points and orders members nearest-first" do
      a = Vectors.normalize([1.0, 0.0, 0.0])
      a2 = Vectors.normalize([0.9, 0.1, 0.0])
      b = Vectors.normalize([0.0, 1.0, 0.0])

      far = Vectors.normalize([0.5, 0.5, 0.0])
      assert [{_, first}, {_, [:b]}] = Vectors.kmeans([{:b, b}, {:a2, a2}, {:a, a}], 2)
      assert MapSet.new(first) == MapSet.new([:a, :a2])

      # Nearest-first within a group: the outlier comes last.
      assert [{_, [_, _, :far]}] = Vectors.kmeans([{:far, far}, {:a2, a2}, {:a, a}], 1)
    end

    test "never asks for more groups than points" do
      assert [{_, [:only]}] = Vectors.kmeans([{:only, [1.0, 0.0]}], 5)
      assert [] = Vectors.kmeans([], 3)
    end
  end
end
