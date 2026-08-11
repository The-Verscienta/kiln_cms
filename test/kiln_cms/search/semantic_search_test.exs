defmodule KilnCMS.Search.SemanticSearchTest do
  @moduledoc """
  The `:search_semantic` action embeds the query and returns embedded content by
  cosine distance (nearest first), via the HNSW index. Uses a deterministic stub
  embedder — same text always yields the same vector — so an exact-text query
  retrieves its own record at distance 0, exercising the embed → sort plumbing
  without a model.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

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
      email: "sem-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sem-#{System.unique_integer([:positive])}"

  defp embed_all, do: KilnCMS.DataCase.drain_oban()

  # Drain the embedding jobs, then prove they landed (#617).
  #
  # `:search_semantic` filters `not is_nil(embedding)`, so a record whose job
  # never completed is silently absent from every semantic read — and
  # `Oban.drain_queue/1` runs only what is *available*. A job that failed once
  # goes `retryable`, and nothing promotes it back: `with_scheduled` defaults to
  # false, and the Stager that would otherwise stage it does not run in tests.
  # So it is not merely that a future `scheduled_at` is skipped — ANY retryable
  # job is left behind, permanently, for the rest of the test.
  #
  # Checking it here is what separates the two failures #617 could not tell
  # apart. A missing embedding fails on this line, named as a timing problem;
  # the visibility assertions downstream are then left meaning only what they
  # say, so a draft reaching an anonymous caller is unambiguously a policy leak
  # — a different severity entirely.
  defp embed_all!(records) do
    embed_all()

    for %resource{id: id} = record <- List.wrap(records) do
      reloaded = Ash.get!(resource, id, authorize?: false)

      # `flunk/1` inside an `unless`, not `refute/2`: `refute` is a function,
      # so its message — including the query below — is built on every passing
      # call. This one only runs when it is going to be read.
      unless reloaded.embedding do
        flunk(
          "#{inspect(resource)} #{id} (#{record.title}) has no embedding after " <>
            "embed_all/0. The embedding job did not complete, so this run says " <>
            "nothing about read visibility. Embedding jobs left in the queue: " <>
            inspect(leftover_jobs())
        )
      end

      reloaded
    end
  end

  # What the drain left behind, for the message above. A `retryable` row with an
  # attempt count is the signature of a job that failed and was rescheduled out
  # of the drain's reach; an empty list means the job never got enqueued at all,
  # which is a different bug again.
  #
  # `errors` and `scheduled_at` are the two that actually name the cause —
  # `errors` carries the exception and stacktrace Oban recorded on the failed
  # attempt, which is the thing #617 says is currently impossible to get at.
  # Scoped to the search queue: the other queues' jobs are noise in a message
  # about embeddings.
  defp leftover_jobs do
    KilnCMS.Repo.all(
      from(j in "oban_jobs",
        where: j.queue == "search",
        select: %{
          worker: j.worker,
          state: j.state,
          attempt: j.attempt,
          scheduled_at: j.scheduled_at,
          errors: j.errors
        }
      )
    )
  end

  test "ranks the nearest embedded record first" do
    admin = admin()
    alpha = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
    beta = CMS.create_page!(%{title: "Beta", slug: slug()}, actor: admin)
    embed_all()

    # "Alpha" embeds to exactly the alpha page's vector (distance 0), so it wins.
    ids = "Alpha" |> CMS.semantic_search_pages!(actor: admin) |> Enum.map(& &1.id)

    assert hd(ids) == alpha.id
    assert beta.id in ids
  end

  test "excludes content that hasn't been embedded" do
    admin = admin()
    embedded = CMS.create_page!(%{title: "Embedded", slug: slug()}, actor: admin)
    embed_all()

    # Created after embedding ran and never drained, so it has no vector.
    _unembedded = CMS.create_page!(%{title: "Pending", slug: slug()}, actor: admin)

    ids = "Embedded" |> CMS.semantic_search_pages!(actor: admin) |> Enum.map(& &1.id)
    assert embedded.id in ids
    assert length(ids) == 1
  end

  test "returns nothing when semantic search is disabled" do
    admin = admin()
    CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
    embed_all()

    put_search_env(semantic: false)
    assert CMS.semantic_search_pages!("Alpha", actor: admin) == []
  end

  test "respects read visibility — anonymous matches published only" do
    admin = admin()
    draft = CMS.create_page!(%{title: "Secret", slug: slug()}, actor: admin)
    published = CMS.create_page!(%{title: "Public", slug: slug()}, actor: admin)
    published = CMS.publish_page!(published, %{}, actor: admin)

    # Both must be embedded for this test to mean anything: the draft has to be
    # *reachable* by the search for its absence to prove the policy excluded it,
    # rather than proving only that it had no vector (#617).
    embed_all!([draft, published])

    anon_ids = "Secret" |> CMS.semantic_search_pages!(authorize?: true) |> Enum.map(& &1.id)

    refute draft.id in anon_ids,
           "an anonymous semantic search returned a DRAFT page. This is a read-policy " <>
             "leak, not a timing flake — the embedding precondition above passed."

    assert published.id in anon_ids,
           "the published page is embedded but an anonymous semantic search did not " <>
             "return it."
  end

  describe "semantic_distances/3" do
    test "reports each neighbour's raw cosine distance, nearest first" do
      admin = admin()
      CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
      CMS.create_page!(%{title: "Beta", slug: slug()}, actor: admin)
      embed_all()

      assert {:ok, [{"Alpha", nearest} | rest]} =
               KilnCMS.Search.semantic_distances(:page, "Alpha", actor: admin)

      # "Alpha" embeds to exactly the Alpha page's vector.
      assert_in_delta nearest, 0.0, 1.0e-6
      assert Enum.all?(rest, fn {_title, d} -> d > nearest end)
    end

    test "ignores a configured floor, so a cutoff can be measured against it" do
      admin = admin()
      CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
      CMS.create_page!(%{title: "Beta", slug: slug()}, actor: admin)
      embed_all()

      put_search_env(semantic_max_distance: 0.0)

      assert {:ok, measured} = KilnCMS.Search.semantic_distances(:page, "Alpha", actor: admin)
      assert length(measured) == 2
    end
  end

  describe "the relevance floor" do
    # Distances come from the stub embedder, so rather than hardcode a cutoff
    # the tests measure the corpus and place the floor between two known
    # neighbours — the same procedure the docs prescribe for a real model.
    defp distances(admin) do
      {:ok, measured} = KilnCMS.Search.semantic_distances(:page, "Alpha", actor: admin)
      measured
    end

    defp two_pages(admin) do
      alpha = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
      beta = CMS.create_page!(%{title: "Beta", slug: slug()}, actor: admin)
      embed_all()
      {alpha, beta}
    end

    test "unset (the default), every neighbour is returned however distant" do
      admin = admin()
      {alpha, beta} = two_pages(admin)

      ids = "Alpha" |> CMS.semantic_search_pages!(actor: admin) |> Enum.map(& &1.id)

      assert alpha.id in ids
      assert beta.id in ids
    end

    test "drops neighbours beyond the cutoff" do
      admin = admin()
      {alpha, beta} = two_pages(admin)

      [{_, nearest}, {_, furthest}] = distances(admin)
      put_search_env(semantic_max_distance: (nearest + furthest) / 2)

      ids = "Alpha" |> CMS.semantic_search_pages!(actor: admin) |> Enum.map(& &1.id)

      assert ids == [alpha.id]
      refute beta.id in ids
    end

    test "a query unlike anything indexed returns nothing at all" do
      # The point of the whole change: nearest-neighbour search always has a
      # nearest, so without a floor "no results" is unreachable.
      admin = admin()
      two_pages(admin)

      put_search_env(semantic_max_distance: 0.0)

      assert CMS.semantic_search_pages!("nothing like this exists", actor: admin) == []
    end

    test "keeps an exact match at a cutoff of zero" do
      # Boundary: the comparison is inclusive, so distance 0 survives a 0 floor.
      admin = admin()
      {alpha, _beta} = two_pages(admin)

      put_search_env(semantic_max_distance: 0.0)

      ids = "Alpha" |> CMS.semantic_search_pages!(actor: admin) |> Enum.map(& &1.id)
      assert ids == [alpha.id]
    end

    test "the floor reaches the hybrid search's semantic leg" do
      # hybrid/3 fuses keyword + semantic; with the floor on, a query matching
      # no keyword and nothing semantically near must come back empty rather
      # than fused-from-noise.
      admin = admin()
      two_pages(admin)

      put_search_env(semantic_max_distance: 0.0)

      assert KilnCMS.Search.hybrid(:page, "nothing like this exists", actor: admin) == []
    end
  end
end
