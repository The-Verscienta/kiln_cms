defmodule KilnCMS.Organize.FoundationsTest do
  @moduledoc """
  The pieces every derived-organization surface stands on (#1596): SQL
  centroids, chunked tag-vector indexing, the term seam's usage counts and
  tag application, and the actor-first candidate set.
  """
  # async: false — swaps the global KilnCMS.Search env (stub embedder).
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrganizeFixtures

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Organize.Candidates
  alias KilnCMS.Organize.Terms
  alias KilnCMS.Search.Related
  alias KilnCMS.SearchIndex

  setup do
    semantic_on!()
    %{org: org!(), admin: user!(:admin)}
  end

  defp search_actor, do: KilnCMS.SystemActor.new(:search)

  describe "document_centroids" do
    test "averages a document's block vectors in SQL", %{org: org, admin: admin} do
      post = post!(org, admin, ["first centroid passage", "second centroid passage"])

      [row] = SearchIndex.document_centroids!([post.id], actor: search_actor(), tenant: org.id)

      blocks =
        SearchIndex.block_embeddings_for!(:post, post.id, actor: search_actor(), tenant: org.id)

      assert length(blocks) == 2
      expected = blocks |> Enum.map(& &1.embedding) |> Enum.zip_with(&(Enum.sum(&1) / 2))

      assert row.document_id == post.id
      assert row.document_type == :post
      assert length(row.centroid) == 384

      # pgvector stores float4, so compare at its precision.
      Enum.zip_with(row.centroid, expected, fn got, want -> assert_in_delta got, want, 1.0e-5 end)
    end

    test "the tenant clause is the isolation: another org's ids answer nothing",
         %{org: org, admin: admin} do
      post = post!(org, admin, "isolated centroid passage")
      other = org!()

      assert [_] =
               SearchIndex.document_centroids!([post.id], actor: search_actor(), tenant: org.id)

      assert [] =
               SearchIndex.document_centroids!([post.id], actor: search_actor(), tenant: other.id)

      # No tenant must never mean "every org".
      assert [] = KilnCMS.Search.DocumentCentroids.for_documents(nil, [post.id])
    end

    test "an unindexed draft has no centroid", %{org: org, admin: admin} do
      draft = post!(org, admin, "never indexed", publish?: false)

      assert [] =
               SearchIndex.document_centroids!([draft.id], actor: search_actor(), tenant: org.id)
    end

    test "a viewer may not read centroids", %{org: org, admin: admin} do
      post = post!(org, admin, "viewer centroid passage")

      assert {:error, %Ash.Error.Forbidden{}} =
               SearchIndex.document_centroids([post.id], actor: user!(:viewer), tenant: org.id)
    end
  end

  describe "Related.ensure_tag_vectors/3 — chunked indexing" do
    test "fills a taxonomy larger than the per-user window, one window at a time",
         %{org: org, admin: admin} do
      put_search_env(
        embedding_per_user_limit: {3, :timer.minutes(1)},
        embedding_per_org_limit: {100, :timer.hours(1)}
      )

      tags = for i <- 1..7, do: tag!(org, admin, "chunk tag #{i} #{uniq()}")
      tag_maps = Enum.map(tags, &Map.take(&1, [:id, :name]))
      assert length(Related.missing_tag_vectors(org.id, tag_maps)) == 7

      user = "chunk-user-#{uniq()}"

      assert {:ok, %{indexed: 3, remaining: 4}} =
               Related.ensure_tag_vectors(org.id, tag_maps, max: 3, user_id: user)

      assert spent("user", user, :timer.minutes(1)) == 3

      # Same window, same user: refused, and nothing more embedded.
      assert {:error, {:rate_limited, _}} =
               Related.ensure_tag_vectors(org.id, tag_maps, max: 3, user_id: user)

      assert length(Related.missing_tag_vectors(org.id, tag_maps)) == 4

      # A fresh window (another identity standing in for "a minute later").
      user2 = "chunk-user-#{uniq()}"

      assert {:ok, %{indexed: 3, remaining: 1}} =
               Related.ensure_tag_vectors(org.id, tag_maps, max: 3, user_id: user2)

      user3 = "chunk-user-#{uniq()}"

      assert {:ok, %{indexed: 1, remaining: 0}} =
               Related.ensure_tag_vectors(org.id, tag_maps, max: 3, user_id: user3)

      assert spent("user", user3, :timer.minutes(1)) == 1
      assert Related.missing_tag_vectors(org.id, tag_maps) == []

      # Nothing left: a further call is free.
      assert {:ok, %{indexed: 0, remaining: 0}} =
               Related.ensure_tag_vectors(org.id, tag_maps, max: 3, user_id: user3)

      assert spent("user", user3, :timer.minutes(1)) == 1
    end

    test "semantic off: a no-op that never touches the budget", %{org: org, admin: admin} do
      tag = tag!(org, admin)
      put_search_env(semantic: false, embedding_per_user_limit: {1, :timer.minutes(1)})
      user = "off-user-#{uniq()}"

      assert {:ok, %{indexed: 0, remaining: 0}} =
               Related.ensure_tag_vectors(org.id, [Map.take(tag, [:id, :name])], user_id: user)

      assert Related.missing_tag_vectors(org.id, [Map.take(tag, [:id, :name])]) == []
      assert spent("user", user, :timer.minutes(1)) == 0
    end

    test "Terms.index_tag_vectors sizes the chunk to the room LEFT in the window",
         %{org: org, admin: admin} do
      # The editor already spent 2 of 3 this minute (the per-document panel,
      # say). A full-window chunk of 3 would be refused AND counted — leaving
      # the counter at 5 and the panel blocked. Sized to the room left, it
      # indexes 1 and the counter lands exactly on the limit.
      put_search_env(
        embedding_per_user_limit: {3, :timer.minutes(1)},
        embedding_per_org_limit: {100, :timer.hours(1)}
      )

      editor = user!(:admin)
      for _ <- 1..3, do: tag!(org, admin, "room tag #{uniq()}")

      :ok =
        KilnCMS.LLM.Budget.check(
          "search_embedding",
          nil,
          editor.id,
          KilnCMS.Search.embedding_budget_limits(false, 2)
        )

      assert spent("user", editor.id, :timer.minutes(1)) == 2

      assert {:ok, %{indexed: 1, remaining: 2}} = Terms.index_tag_vectors(org, editor)
      assert spent("user", editor.id, :timer.minutes(1)) == 3

      # No room left: refused without charging anything further.
      assert {:error, {:rate_limited, _}} = Terms.index_tag_vectors(org, editor)
      assert spent("user", editor.id, :timer.minutes(1)) == 3
      assert Terms.missing_tag_vectors(org, editor) == 2
    end

    test "a name the embedder cannot answer for is reported, and the next chunk moves on",
         %{org: org, admin: admin} do
      put_search_env(embedder: KilnCMS.Organize.FoundationsTest.PickyEmbedder)
      bad = tag!(org, admin, "aaa unembeddable #{uniq()}")
      good = tag!(org, admin, "bbb fine #{uniq()}")
      tags = Enum.map([bad, good], &Map.take(&1, [:id, :name]))

      assert {:ok, %{indexed: 0, failed: [failed_id], remaining: 1}} =
               Related.ensure_tag_vectors(org.id, tags, max: 1)

      assert failed_id == bad.id

      # Without `:exclude`, the same unembeddable name would head every chunk.
      assert {:ok, %{indexed: 1, failed: [], remaining: 0}} =
               Related.ensure_tag_vectors(org.id, tags, max: 1, exclude: [failed_id])

      assert Enum.map(Related.missing_tag_vectors(org.id, tags), & &1.id) == [bad.id]
    end
  end

  defmodule PickyEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text) do
      if String.contains?(text, "unembeddable"),
        do: {:error, :no_vector},
        else: KilnCMS.StubEmbedder.embed(text)
    end
  end

  describe "Terms.usage/2" do
    test "counts live content only, per org", %{org: org, admin: admin} do
      used_twice = tag!(org, admin)
      single = tag!(org, admin)
      trashed_only = tag!(org, admin)
      unused = tag!(org, admin)
      cat = category!(org, admin)

      post!(org, admin, "usage a", tag_ids: [used_twice.id, single.id], category_id: cat.id)
      post!(org, admin, "usage b", tag_ids: [used_twice.id], publish?: false)

      # A trashed post: its tagging survives (a restore brings it back), but
      # it is not a use anyone can see.
      trashed = post!(org, admin, "usage c", tag_ids: [trashed_only.id, single.id])
      CMS.destroy_post!(trashed, actor: admin, tenant: org)

      # Another org's identically-shaped content must not move these counts.
      other = org!()
      other_tag = tag!(other, admin)
      post!(other, admin, "other usage", tag_ids: [other_tag.id])

      counts = org |> Terms.usage(admin) |> Map.new(fn {t, n} -> {t.id, n} end)

      assert counts[used_twice.id] == 2
      assert counts[single.id] == 1
      assert counts[trashed_only.id] == 0
      assert counts[unused.id] == 0
      assert counts[cat.id] == 1
      refute Map.has_key?(counts, other_tag.id)
    end
  end

  describe "Terms.apply_tags/4" do
    test "a draft takes the tags on :update, merged with what it has", %{org: org, admin: admin} do
      a = tag!(org, admin)
      b = tag!(org, admin)
      draft = post!(org, admin, "apply draft", tag_ids: [a.id], publish?: false)

      assert {:ok, _} = Terms.apply_tags("post", draft, [b.id], admin)

      tags = CMS.get_post!(draft.id, actor: admin, tenant: org, load: [:tags]).tags
      assert MapSet.new(tags, & &1.id) == MapSet.new([a.id, b.id])
    end

    test "a live document holds them in its working copy, merged with the HELD set",
         %{org: org, admin: admin} do
      a = tag!(org, admin)
      b = tag!(org, admin)
      c = tag!(org, admin)
      live = post!(org, admin, "apply live", tag_ids: [a.id, b.id])

      # The editor already removed B in the working copy: held [A], live [A, B].
      {:ok, live} =
        ContentTypes.save_working_copy("post", live, %{fields: %{"tag_ids" => [a.id]}},
          actor: admin,
          tenant: org
        )

      assert Terms.applied_tag_ids(live) == [a.id]

      assert {:ok, after_apply} = Terms.apply_tags("post", live, [c.id], admin)

      # C joins the held set; B stays removed there; readers still see A, B.
      assert MapSet.new(Terms.applied_tag_ids(after_apply)) == MapSet.new([a.id, c.id])

      live_tags = CMS.get_post!(live.id, actor: admin, tenant: org, load: [:tags]).tags
      assert MapSet.new(live_tags, & &1.id) == MapSet.new([a.id, b.id])
    end
  end

  describe "Candidates.list/3" do
    test "newest first, bounded, filtered, and read as the actor", %{org: org, admin: admin} do
      tag = tag!(org, admin)
      tagged = post!(org, admin, "cand tagged", tag_ids: [tag.id])
      bare = post!(org, admin, "cand bare")
      draft = post!(org, admin, "cand draft", publish?: false)

      ids = org |> Candidates.list(admin, limit: 10) |> Enum.map(& &1.id)
      assert ids == [draft.id, bare.id, tagged.id]

      assert [%{id: id}] = Candidates.list(org, admin, limit: 1)
      assert id == draft.id

      published = org |> Candidates.list(admin, limit: 10, state: :published) |> Enum.map(& &1.id)
      assert MapSet.new(published) == MapSet.new([bare.id, tagged.id])

      untermed =
        org
        |> Candidates.list(admin, limit: 10, filter: Terms.untermed_filter())
        |> Enum.map(& &1.id)

      assert MapSet.new(untermed) == MapSet.new([bare.id, draft.id])

      # Granular RBAC (#332): drafts in "page" only — the post draft is gone.
      restricted = user!(:editor, %{readable_types: ["page"]})
      seen = org |> Candidates.list(restricted, limit: 10) |> Enum.map(& &1.id)
      refute draft.id in seen
      assert bare.id in seen
    end
  end
end
