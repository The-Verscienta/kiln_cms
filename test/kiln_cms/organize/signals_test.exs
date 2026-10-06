defmodule KilnCMS.Organize.SignalsTest do
  @moduledoc """
  The under-organized queue, taxonomy health and content gaps as
  organization signals (#1596).
  """
  # async: false — swaps the global KilnCMS.Search env.
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrganizeFixtures

  alias KilnCMS.Analytics
  alias KilnCMS.CMS
  alias KilnCMS.Organize.Gaps
  alias KilnCMS.Organize.Health
  alias KilnCMS.Organize.Queue
  alias KilnCMS.Organize.Terms

  @minute :timer.minutes(1)

  # Text naming a topic embeds on that topic's axis (+ a little noise), and
  # "colour" is spelt "color" first, so the two tag names are one vector.
  defmodule AxisEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @axes ~w(alpha beta gamma color sourdough)

    @impl true
    def embed(text) do
      text = String.replace(text, "colour", "color")
      axis = Enum.find_index(@axes, &(text =~ &1)) || 9
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
    semantic_on!(embedder: AxisEmbedder, suggest_tags_threshold: 0.35)
    %{org: org!(), admin: user!(:admin)}
  end

  defp ids(rows), do: MapSet.new(rows, & &1.id)

  describe "Queue.build/2" do
    test "lists untagged documents and those far from every tag", %{org: org, admin: admin} do
      alpha_tag = tag!(org, admin, "alpha")
      cat = category!(org, admin)

      covered = post!(org, admin, "alpha passage", tag_ids: [alpha_tag.id])
      untagged_draft = post!(org, admin, "alpha draft", publish?: false)
      untagged_with_cat = post!(org, admin, "alpha with category", category_id: cat.id)
      # Tagged, but about something no tag in the vocabulary describes.
      far_tagged = post!(org, admin, "gamma passage", tag_ids: [alpha_tag.id])

      {:ok, %{remaining: 0}} = Terms.index_tag_vectors(org, admin)

      queue = Queue.build(org, admin)

      untagged = Map.new(queue.untagged, &{&1.doc.id, &1.missing})
      assert untagged == %{untagged_draft.id => :none, untagged_with_cat.id => :no_tags}

      assert [%{doc: %{id: far_id}, nearest: {%{id: nearest_id}, distance}}] = queue.far
      assert far_id == far_tagged.id
      assert nearest_id == alpha_tag.id
      assert distance > 0.35
      refute covered.id in Enum.map(queue.far, & &1.doc.id)
      assert queue.vocabulary_indexed?
      assert queue.far_considered == 3
    end

    test "with no tag indexed, the far leg says so instead of flagging everything",
         %{org: org, admin: admin} do
      post!(org, admin, "gamma passage")
      assert %{far: [], vocabulary_indexed?: false} = Queue.build(org, admin)
    end
  end

  describe "Health.report/2" do
    test "unused, single-use and near-duplicate terms; documents nothing links to",
         %{org: org, admin: admin} do
      colour = tag!(org, admin, "colour")
      color = tag!(org, admin, "color")
      sourdough = tag!(org, admin, "sourdough")
      unused_cat = category!(org, admin)

      a = post!(org, admin, "alpha passage", tag_ids: [colour.id, sourdough.id])
      b = post!(org, admin, "beta passage", tag_ids: [sourdough.id])
      lonely = post!(org, admin, "gamma passage")

      # `b` links to `a` (a curated related link); a self-link on `lonely`
      # must not count as a way in.
      CMS.create_content_link!(%{source_id: b.id, target_id: a.id}, actor: admin, tenant: org)

      CMS.create_content_link!(%{source_id: lonely.id, target_id: lonely.id},
        actor: admin,
        tenant: org
      )

      # Another org's edge to `lonely`'s id must not count either.
      other = org!()
      other_doc = post!(other, admin, "other passage")

      CMS.create_content_link!(%{source_id: other_doc.id, target_id: lonely.id},
        actor: admin,
        tenant: other
      )

      {:ok, %{remaining: 0}} = Terms.index_tag_vectors(org, admin)

      report = Health.report(org, admin)

      assert MapSet.new(report.unused, & &1.id) == MapSet.new([color.id, unused_cat.id])
      assert MapSet.new(report.single_use, & &1.id) == MapSet.new([colour.id])

      assert [%{a: pa, b: pb, distance: d}] = report.near_duplicates
      assert MapSet.new([pa.id, pb.id]) == MapSet.new([colour.id, color.id])
      assert d <= 0.08

      assert ids(report.unlinked) == MapSet.new([b.id, lonely.id])
      assert report.unlinked_considered == 3
      assert report.missing_vectors == 0
    end
  end

  describe "Gaps.signals/2" do
    defp zero_result(org, query, times) do
      for _ <- 1..times do
        Analytics.record_search!(%{query: query, locale: "en", result_count: 0},
          authorize?: false,
          tenant: org
        )
      end
    end

    test "a gap near a tag is a missing hub page; one near none is a missing term",
         %{org: org, admin: admin} do
      sourdough = tag!(org, admin, "sourdough")
      {:ok, _} = Terms.index_tag_vectors(org, admin)
      zero_result(org, "sourdough starter #{uniq()}", 2)
      zero_result(org, "gamma rays #{uniq()}", 1)
      editor = user!(:admin)

      %{gaps: [hub, missing], skipped: nil} = Gaps.signals(org, editor)

      assert {:hub_missing, %{id: id}, _} = hub.signal
      assert id == sourdough.id
      assert hub.searches == 2
      assert missing.signal == :term_missing

      # The query embeddings were charged once, interactively: two units.
      assert spent("user", editor.id, @minute) == 2
      # A reload costs nothing — both queries are cached now.
      assert %{skipped: nil} = Gaps.signals(org, editor)
      assert spent("user", editor.id, @minute) == 2
    end

    test "no room for the query embeddings: the gaps still show, unclassified, uncharged",
         %{org: org, admin: admin} do
      tag!(org, admin, "sourdough")
      {:ok, _} = Terms.index_tag_vectors(org, admin)
      editor = user!(:admin)
      put_search_env(embedding_per_user_limit: {1, @minute})
      zero_result(org, "sourdough a #{uniq()}", 1)
      zero_result(org, "sourdough b #{uniq()}", 1)

      %{gaps: gaps, skipped: {:rate_limited, _}} = Gaps.signals(org, editor)

      assert length(gaps) == 2
      assert Enum.all?(gaps, &(&1.signal == :unclassified))
      assert spent("user", editor.id, @minute) == 0
    end
  end

  test "semantic off: every signal is empty and nothing is called", %{org: org, admin: admin} do
    tag!(org, admin, "sourdough")
    post!(org, admin, "alpha passage", publish?: false)
    put_search_env(semantic: false, embedder: RaisingEmbedder)

    assert %{untagged: [], far: []} = Queue.build(org, admin)

    assert %{unused: [], single_use: [], near_duplicates: [], unlinked: []} =
             Health.report(org, admin)

    assert Gaps.signals(org, admin) == %{gaps: [], skipped: nil, vocabulary_truncated?: false}
    assert spent("user", admin.id, @minute) == 0
  end
end
