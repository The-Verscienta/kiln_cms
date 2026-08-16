defmodule KilnCMS.Search.RelatedTest do
  @moduledoc "Embedding-driven content intelligence (#339 phase 2)."
  # async: false — toggles the global KilnCMS.Search app env (stub embedder).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Search.BlockIndexer
  alias KilnCMS.Search.Related
  alias KilnCMS.Search.VectorCache

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, semantic: true, embedder: KilnCMS.StubEmbedder)
    )

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rel-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rel-#{System.unique_integer([:positive])}"

  defp indexed_post(actor, text, opts \\ []) do
    post =
      CMS.create_post!(
        %{
          title: Keyword.get(opts, :title, "Doc"),
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]
        },
        actor: actor
      )

    post =
      if Keyword.get(opts, :publish?, true),
        do: CMS.publish_post!(post, %{}, actor: actor),
        else: post

    {:ok, _} = BlockIndexer.reindex(post)
    post
  end

  test "related_documents ranks the identical-content sibling first, published only" do
    actor = admin()

    anchor = indexed_post(actor, "brewing herbal tea slowly", title: "Same")
    twin = indexed_post(actor, "brewing herbal tea slowly", title: "Same")
    _other = indexed_post(actor, "carburetor maintenance schedules", title: "Other")

    draft_twin =
      indexed_post(actor, "brewing herbal tea slowly", title: "Same", publish?: false)

    related = Related.related_documents(anchor)

    assert [%{slug: first_slug} | _] = related
    assert first_slug == twin.slug
    # The identical draft never appears in the public related list.
    refute Enum.any?(related, &(&1.id == draft_twin.id))
    # Never the anchor itself.
    refute Enum.any?(related, &(&1.id == anchor.id))
  end

  test "near_duplicates flags identical content in ANY state, not distant content" do
    actor = admin()

    # Identical title AND body: the hierarchical embedding folds ancestor
    # context (title) into the block text, and the stub embedder only matches
    # exact strings.
    anchor = indexed_post(actor, "unique passage about kiln firing", title: "Same")

    draft_dup =
      indexed_post(actor, "unique passage about kiln firing", title: "Same", publish?: false)

    _distant = indexed_post(actor, "entirely unrelated botany notes", title: "Far")

    dups = Related.near_duplicates(anchor)

    assert Enum.any?(dups, &(&1.id == draft_dup.id))
    refute Enum.any?(dups, &(&1.title == "Far"))
  end

  # A never-indexed draft: created, never published, and never handed to
  # `BlockIndexer.reindex/1` — so it has no rows in `block_embeddings`, which is
  # the state every real never-published document is in.
  defp unindexed_draft(actor, text, opts \\ []) do
    CMS.create_post!(
      %{
        title: Keyword.get(opts, :title, "Doc"),
        slug: slug(),
        blocks: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]
      },
      actor: actor
    )
  end

  describe "a never-published anchor (#852)" do
    test "near_duplicates works before the document has ever been indexed" do
      # The inversion #852 is about: near-duplicate detection is a PRE-publication
      # check — "someone already wrote this, do not publish a second copy" — and
      # it used to become available only once the thing it exists to prevent had
      # happened.
      actor = admin()

      published_twin =
        indexed_post(actor, "unique passage about kiln firing", title: "Same")

      _distant = indexed_post(actor, "entirely unrelated botany notes", title: "Far")

      draft = unindexed_draft(actor, "unique passage about kiln firing", title: "Same")

      # Precondition: the anchor genuinely has nothing in the index.
      assert [] =
               KilnCMS.SearchIndex.block_embeddings_for!(:post, draft.id,
                 authorize?: false,
                 tenant: draft.org_id
               )

      dups = Related.near_duplicates(draft)

      assert Enum.any?(dups, &(&1.id == published_twin.id)),
             "a never-published draft could not see its published duplicate"

      refute Enum.any?(dups, &(&1.title == "Far"))
    end

    test "computing the anchor's centroid writes nothing to the index" do
      # The reason this is computed rather than indexed: `block_embeddings` rows
      # carry block text with no state or audience column to filter on, so a
      # draft's rows would be visible to every other consumer of that table with
      # nothing to exclude them by.
      actor = admin()
      _twin = indexed_post(actor, "unique passage about kiln firing", title: "Same")
      draft = unindexed_draft(actor, "unique passage about kiln firing", title: "Same")

      assert Related.near_duplicates(draft) != []

      assert [] =
               KilnCMS.SearchIndex.block_embeddings_for!(:post, draft.id,
                 authorize?: false,
                 tenant: draft.org_id
               ),
             "the draft's vectors were persisted; they must stay in memory"
    end

    test "a draft anchor still only sees published neighbours on the public surface" do
      # `related_documents/2` is the reader-facing one. Giving the anchor a
      # centroid must not change which NEIGHBOURS are allowed through.
      actor = admin()

      published_twin =
        indexed_post(actor, "unique passage about kiln firing", title: "Same")

      draft_twin =
        indexed_post(actor, "unique passage about kiln firing",
          title: "Same",
          publish?: false
        )

      draft = unindexed_draft(actor, "unique passage about kiln firing", title: "Same")

      related = Related.related_documents(draft)

      assert Enum.any?(related, &(&1.id == published_twin.id))
      refute Enum.any?(related, &(&1.id == draft_twin.id))
    end

    test "a PUBLISHED anchor with no stored vectors is not computed on demand" do
      # The guard that keeps the public surface cheap. `/api/related` resolves
      # its anchor through `Delivery.published/4`, so a published document is
      # the only anchor a stranger can name — and an operator who turns on
      # semantic search without re-firing puts EVERY published page in the
      # no-stored-vectors state. Without this gate an anonymous crawler would
      # drive one model inference per block, per request, through one serving.
      actor = admin()
      _twin = indexed_post(actor, "unique passage about kiln firing", title: "Same")

      # Published, and deliberately never handed to `BlockIndexer.reindex/1`.
      unindexed =
        CMS.create_post!(
          %{
            title: "Same",
            slug: slug(),
            blocks: [
              %{type: :rich_text, content: "<p>unique passage about kiln firing</p>", order: 0}
            ]
          },
          actor: actor
        )
        |> CMS.publish_post!(%{}, actor: actor)

      assert [] =
               KilnCMS.SearchIndex.block_embeddings_for!(:post, unindexed.id,
                 authorize?: false,
                 tenant: unindexed.org_id
               )

      assert Related.near_duplicates(unindexed) == [],
             "a published anchor must not fall back to computing its centroid"
    end

    test "an anchor with no block text still resolves to no neighbours" do
      # An empty document has nothing to embed, so there is no centroid to
      # compute — the fallback must answer "nothing", not crash or compare
      # against a zero vector.
      actor = admin()
      _twin = indexed_post(actor, "unique passage about kiln firing", title: "Same")

      empty = CMS.create_post!(%{title: "Empty", slug: slug(), blocks: []}, actor: actor)

      assert Related.near_duplicates(empty) == []
    end
  end

  test "suggest_tags returns scored suggestions and skips applied tags" do
    actor = admin()
    uniq = System.unique_integer([:positive])

    tea = CMS.create_tag!(%{name: "herbal tea", slug: "tea-#{uniq}"}, actor: actor)
    cars = CMS.create_tag!(%{name: "carburetors", slug: "cars-#{uniq}"}, actor: actor)

    post = indexed_post(actor, "brewing herbal tea slowly")

    # `threshold: 2.0` ranks without filtering — cosine distance is `1 - cos θ`,
    # so 2 is its ceiling — which is what this asserted before #851 added one.
    # Kept that way on purpose: the stub embedder can't attest semantic
    # ordering, so "which of these two is closer" is a model property, not a
    # code property, and pinning it would be pinning `:erlang.phash2/1`.
    suggestions = Related.suggest_tags(post, threshold: 2.0)
    suggested_ids = Enum.map(suggestions, & &1.tag.id)
    assert tea.id in suggested_ids
    assert cars.id in suggested_ids
    assert Enum.all?(suggestions, &is_float(&1.distance))

    # Once applied, a tag is no longer suggested.
    post = CMS.update_post!(post, %{tag_ids: [tea.id]}, actor: actor)
    post = KilnCMS.CMS.get_post!(post.id, authorize?: false, load: [:tags])
    refute Enum.any?(Related.suggest_tags(post, threshold: 2.0), &(&1.tag.id == tea.id))
  end

  # #1085: the tag-name vector is persisted, so the ceiling and the ranking are
  # one pgvector query instead of N lookups + N cosine computations per call.
  describe "suggest_tags persists tag-name vectors (#1085)" do
    alias KilnCMS.SearchIndex

    defp stored_rows(tags) do
      SearchIndex.tag_embeddings_for!(Enum.map(tags, & &1.id), authorize?: false)
    end

    test "the first call stores one row per candidate; a second call reads them back" do
      actor = admin()
      uniq = System.unique_integer([:positive])
      tea = CMS.create_tag!(%{name: "persist tea #{uniq}", slug: "pt-#{uniq}"}, actor: actor)
      cars = CMS.create_tag!(%{name: "persist cars #{uniq}", slug: "pc-#{uniq}"}, actor: actor)
      post = indexed_post(actor, "brewing herbal tea slowly")

      assert stored_rows([tea, cars]) == []

      first = Related.suggest_tags(post, threshold: 2.0)
      assert Enum.map(first, & &1.tag.id) |> Enum.sort() == Enum.sort([tea.id, cars.id])

      rows = stored_rows([tea, cars])
      assert length(rows) == 2
      assert Enum.all?(rows, &(is_list(&1.embedding) and length(&1.embedding) == 384))
      assert Enum.map(rows, & &1.name) |> Enum.sort() == Enum.sort([tea.name, cars.name])

      # Same answer, same distances, from the table — and it is the TABLE, not
      # the ETS cache, that answers: wipe the cache and nothing changes.
      Cachex.clear(VectorCache.cache_name())
      refute VectorCache.cached?(tea.name)
      assert Related.suggest_tags(post, threshold: 2.0) == first
      # …and no inference ran to produce it (a cache miss would have re-filled it).
      refute VectorCache.cached?(tea.name)
    end

    test "the winners come back as full tag rows, not the id/name projection" do
      actor = admin()
      uniq = System.unique_integer([:positive])
      tag = CMS.create_tag!(%{name: "full row #{uniq}", slug: "fr-#{uniq}"}, actor: actor)
      post = indexed_post(actor, "brewing herbal tea slowly")

      [%{tag: suggested}] =
        Related.suggest_tags(post, threshold: 2.0, limit: 1)
        |> Enum.filter(&(&1.tag.id == tag.id))

      assert suggested.slug == tag.slug
      refute match?(%Ash.NotLoaded{}, suggested.slug)
    end

    test "a renamed tag is re-embedded — the stored name is the freshness check" do
      actor = admin()
      uniq = System.unique_integer([:positive])
      tag = CMS.create_tag!(%{name: "before rename #{uniq}", slug: "rn-#{uniq}"}, actor: actor)
      post = indexed_post(actor, "brewing herbal tea slowly")

      Related.suggest_tags(post, threshold: 2.0)
      [%{name: stored_name, embedding: before}] = stored_rows([tag])
      assert stored_name == tag.name

      tag = CMS.update_tag!(tag, %{name: "after rename #{uniq}"}, actor: actor)
      Related.suggest_tags(post, threshold: 2.0)

      [%{name: stored_name, embedding: after_vec}] = stored_rows([tag])
      assert stored_name == "after rename #{uniq}"
      # The stub is deterministic per text, so a different name is a different vector.
      refute after_vec == before
    end

    test "deleting the tag takes its vector with it" do
      actor = admin()
      uniq = System.unique_integer([:positive])
      tag = CMS.create_tag!(%{name: "doomed #{uniq}", slug: "dm-#{uniq}"}, actor: actor)
      post = indexed_post(actor, "brewing herbal tea slowly")

      Related.suggest_tags(post, threshold: 2.0)
      assert [_row] = stored_rows([tag])

      CMS.destroy_tag!(tag, actor: actor)
      assert stored_rows([tag]) == []
    end

    test "the ceiling is applied in the query: a tight one answers [] with rows stored" do
      actor = admin()
      uniq = System.unique_integer([:positive])
      tag = CMS.create_tag!(%{name: "far away #{uniq}", slug: "fa-#{uniq}"}, actor: actor)
      post = indexed_post(actor, "brewing herbal tea slowly")

      # Cosine distance is never negative, so a negative ceiling admits nothing —
      # and the fill still happened, so the next call is a pure query.
      assert Related.suggest_tags(post, threshold: -1.0) == []
      assert [_row] = stored_rows([tag])
    end

    test "nearest_to_vector only ranks the ids it is given (the authorized candidate set)" do
      actor = admin()
      uniq = System.unique_integer([:positive])
      a = CMS.create_tag!(%{name: "given a #{uniq}", slug: "ga-#{uniq}"}, actor: actor)
      b = CMS.create_tag!(%{name: "not given b #{uniq}", slug: "gb-#{uniq}"}, actor: actor)
      post = indexed_post(actor, "brewing herbal tea slowly")
      Related.suggest_tags(post, threshold: 2.0)

      {:ok, vector} = KilnCMS.StubEmbedder.embed("anything")

      ids =
        SearchIndex.nearest_tag_embeddings!(
          %{vector: vector, tag_ids: [a.id], threshold: 2.0, limit: 10},
          authorize?: false
        )
        |> Enum.map(& &1.tag_id)

      assert ids == [a.id]
      refute b.id in ids
    end
  end

  # #851: ranking alone always suggests something, because the candidate set is
  # the site's whole tag list. On a five-tag site the top five were all five.
  describe "suggest_tags relevance ceiling (#851)" do
    setup do
      actor = admin()
      uniq = System.unique_integer([:positive])

      CMS.create_tag!(%{name: "herbal tea", slug: "tea-#{uniq}"}, actor: actor)
      CMS.create_tag!(%{name: "carburetors", slug: "cars-#{uniq}"}, actor: actor)

      %{post: indexed_post(actor, "brewing herbal tea slowly")}
    end

    # The file `setup` already owns the app-env swap and its restore; this only
    # layers a threshold on top. No `on_exit` — `setup`'s restores it.
    defp put_threshold(value) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Search,
        Application.get_env(:kiln_cms, KilnCMS.Search, [])
        |> Keyword.put(:suggest_tags_threshold, value)
      )
    end

    test "the configured ceiling decides, and an explicit one overrides it", %{post: post} do
      # Nothing here is an exact text match, so under the stub every candidate
      # sits at some positive distance: a zero ceiling admits none and a
      # maximal one admits all. That is the mechanism — the *value* of the
      # shipped default is a model property and is deliberately not asserted.
      put_threshold(0.0)
      assert Related.suggest_tags(post) == []

      put_threshold(2.0)
      refute Related.suggest_tags(post) == []

      # The option wins over config, which is what makes the measuring recipe
      # in `KilnCMS.Search.suggest_tags_threshold/0` work on a tuned install.
      put_threshold(0.0)
      refute Related.suggest_tags(post, threshold: 2.0) == []
    end

    # #851's whole value is in the shipped default, and every test above and
    # below overrides it — so without this, `config/config.exs` could carry
    # `nil`, a string, or nothing at all and the suite would stay green while
    # the ceiling silently admitted everything in production.
    test "the shipped default is a number in the range cosine distance can produce" do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Search,
        Keyword.delete(
          Application.get_env(:kiln_cms, KilnCMS.Search, []),
          :suggest_tags_threshold
        )
      )

      threshold = KilnCMS.Search.suggest_tags_threshold()

      assert is_number(threshold)
      assert threshold > 0 and threshold < 2
    end

    # Erlang orders `number < atom < bitstring`, so `0.9 <= nil` is `true` and
    # a `nil` ceiling would pass every candidate — the pre-#851 behaviour, with
    # nothing to say it had happened. `nil` is a plausible thing to write:
    # `semantic_max_distance: nil` sits three lines above it in config.exs and
    # does mean "no ceiling".
    test "a non-numeric ceiling raises instead of quietly admitting everything", %{post: post} do
      for bad <- [nil, "0.25", :none] do
        put_threshold(bad)

        assert_raise ArgumentError, ~r/numeric :threshold/, fn ->
          Related.suggest_tags(post)
        end

        assert_raise ArgumentError, ~r/numeric :threshold/, fn ->
          Related.suggest_tags(post, threshold: bad)
        end
      end
    end
  end

  test "content_gaps surfaces zero-result queries, most-searched first" do
    org = KilnCMS.Accounts.default_org_id()

    KilnCMS.Search.record_query("missing topic", 0, org_id: org)
    KilnCMS.Search.record_query("missing topic", 0, org_id: org)
    KilnCMS.Search.record_query("found topic", 12, org_id: org)

    gaps = Related.content_gaps(org)

    assert Enum.any?(gaps, &(&1.query == "missing topic"))
    refute Enum.any?(gaps, &(&1.query == "found topic"))
  end

  test "content_gaps with an actor is authorized as that actor" do
    org = KilnCMS.Accounts.default_org_id()
    KilnCMS.Search.record_query("missing topic", 0, org_id: org)

    editor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "rel-editor-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    viewer =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "rel-viewer-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    assert Enum.any?(Related.content_gaps(org, actor: editor), &(&1.query == "missing topic"))

    # Search analytics is editor-or-above; passing an actor means the policy
    # decides, rather than the caller's own guess at who may see this. A read
    # policy filters rather than refuses, so a viewer simply sees nothing.
    assert Related.content_gaps(org, actor: viewer) == []
  end

  test "near_duplicates with an actor hides content that actor may not read" do
    admin = admin()

    restricted =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "rel-restricted-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :editor,
        # Granular RBAC (#332): this editor sees drafts in "page" only.
        readable_types: ["page"]
      })

    # Identical *documents*: block embeddings are hierarchical, so a differing
    # title alone puts two copies of the same prose past the near-dup threshold.
    anchor = indexed_post(admin, "identical restricted passage", title: "Same")

    hidden =
      indexed_post(admin, "identical restricted passage", title: "Same", publish?: false)

    # Unauthorized (the automation path) still sees it…
    assert Enum.any?(Related.near_duplicates(anchor), &(&1.id == hidden.id))

    # …but resolved as the restricted editor, the unpublished post drops out
    # rather than leaking its title into an editor-facing panel.
    refute Enum.any?(
             Related.near_duplicates(anchor, actor: restricted),
             &(&1.id == hidden.id)
           )
  end

  test "the public related endpoint serves published neighbours" do
    actor = admin()
    anchor = indexed_post(actor, "shared endpoint passage", title: "Anchor")
    twin = indexed_post(actor, "shared endpoint passage", title: "Twin")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.dispatch(
        KilnCMSWeb.Endpoint,
        :get,
        "/api/content/post/#{anchor.slug}/related",
        %{}
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Enum.any?(body["related"], &(&1["slug"] == twin.slug))
  end

  test "everything degrades to empty when semantic search is off" do
    actor = admin()
    post = indexed_post(actor, "some content")

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Search, []), semantic: false)
    )

    assert Related.related_documents(post) == []
    assert Related.near_duplicates(post) == []
    assert Related.suggest_tags(post) == []
  end

  # ── embedding budget (#1076) ────────────────────────────────────────────
  #
  # A model inference (the computed-centroid fallback, and each un-cached tag
  # embedding) now draws on `KilnCMS.LLM.Budget`'s `"search_embedding"`
  # bucket, the same #943 shape `KilnCMS.Seo.draft/2` uses. Every test here
  # provisions its OWN org (`Accounts.create_organization!/2`, real rows —
  # `KilnCMS.Search.Related`'s org bucket key is `record.org_id`, not a
  # caller-chosen string the way `KilnCMS.Seo.draft/2`'s tests get away with)
  # so a tightened limit in one test can never be starved by budget another
  # test already spent against the shared default org.
  describe "embedding budget (#1076)" do
    setup do
      org =
        Accounts.create_organization!(
          %{name: "Budget org", slug: "budget-#{System.unique_integer([:positive])}"},
          authorize?: false
        )

      %{org: org, actor: admin()}
    end

    defp put_embedding_budget(overrides) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Search,
        Application.get_env(:kiln_cms, KilnCMS.Search, []) |> Keyword.merge(overrides)
      )
    end

    # Same shape as `unindexed_draft/3` above but tenant-scoped, so the
    # document (and the budget charge it triggers) lands in the test's own org.
    defp draft_in(org, actor, text, opts) do
      CMS.create_post!(
        %{
          title: Keyword.get(opts, :title, "Doc"),
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]
        },
        actor: actor,
        tenant: org
      )
    end

    test "computing an unpublished document's centroid spends the org's embedding budget",
         %{org: org, actor: actor} do
      put_embedding_budget(
        embedding_per_user_limit: {100, :timer.minutes(1)},
        embedding_per_org_limit: {1, :timer.hours(1)},
        embedding_unattended_share: 1.0
      )

      first = draft_in(org, actor, "first unpublished passage", title: "One")
      second = draft_in(org, actor, "second unpublished passage", title: "Two")

      # The org's single unit is spent computing the first draft's centroid —
      # neither document has a stored vector, so both would otherwise compute.
      assert is_list(Related.near_duplicates(first, user_id: "caller"))
      assert {:error, {:rate_limited, _}} = Related.near_duplicates(second, user_id: "caller")
    end

    test "a PUBLISHED anchor never spends the embedding budget, even at a zero ceiling",
         %{org: org, actor: actor} do
      # Mirrors the "not computed on demand" test above, but proves the
      # NEGATIVE for the budget specifically: a limit of 0 would refuse any
      # call that actually reached `charge_embedding_budget/1`.
      put_embedding_budget(embedding_per_org_limit: {0, :timer.hours(1)})

      published =
        draft_in(org, actor, "unique passage about kiln firing", title: "Same")
        |> CMS.publish_post!(%{}, actor: actor)

      assert Related.near_duplicates(published, user_id: "caller") == []
      assert Related.related_documents(published, user_id: "caller") == []
    end

    test "suggest_tags spends one unit per un-cached tag, and a cached one is free",
         %{org: org, actor: actor} do
      uniq = System.unique_integer([:positive])
      # Distinct, never-before-embedded names so this test's cache state can't
      # ride on a name another test already embedded.
      tag_a =
        CMS.create_tag!(%{name: "budget tag alpha #{uniq}", slug: "bta-#{uniq}"},
          actor: actor,
          tenant: org
        )

      tag_b =
        CMS.create_tag!(%{name: "budget tag beta #{uniq}", slug: "btb-#{uniq}"},
          actor: actor,
          tenant: org
        )

      refute VectorCache.cached?(tag_a.name)
      refute VectorCache.cached?(tag_b.name)

      # Room for the centroid (1) plus exactly one tag (1); the second tag is
      # refused, and refusing it is what makes `suggest_tags/2` return the
      # error instead of a truncated ranking (see its doc).
      put_embedding_budget(
        embedding_per_user_limit: {100, :timer.minutes(1)},
        embedding_per_org_limit: {2, :timer.hours(1)},
        embedding_unattended_share: 1.0
      )

      post = draft_in(org, actor, "brewing herbal tea slowly", title: "Teas")

      assert {:error, {:rate_limited, _}} =
               Related.suggest_tags(post, threshold: 2.0, user_id: "caller")

      # Exactly one of the two tags got far enough to be cached; the other
      # never reached the model — and the org's budget is now fully spent
      # (centroid + one tag = 2/2), so anything from here on must be free.
      {cached_tag, uncached_tag} =
        if VectorCache.cached?(tag_a.name), do: {tag_a, tag_b}, else: {tag_b, tag_a}

      assert VectorCache.cached?(cached_tag.name)
      refute VectorCache.cached?(uncached_tag.name)

      # A second document, PUBLISHED and indexed so its own centroid comes from
      # `stored_vectors/1` (no fresh charge), with the still-uncached tag
      # already applied (so it's excluded from candidates, and nothing here
      # needs the model). If the cache hit cost anything, this would also come
      # back `{:error, {:rate_limited, _}}` — the org has zero room left.
      other_post =
        CMS.create_post!(
          %{
            title: "More teas",
            slug: slug(),
            blocks: [%{type: :rich_text, content: "<p>brewing herbal tea slowly</p>", order: 0}],
            tag_ids: [uncached_tag.id]
          },
          actor: actor,
          tenant: org
        )
        |> CMS.publish_post!(%{}, actor: actor)

      {:ok, _} = BlockIndexer.reindex(other_post)

      other_post =
        CMS.get_post!(other_post.id, authorize?: false, load: [:tags], tenant: org)

      suggestions = Related.suggest_tags(other_post, threshold: 2.0, user_id: "caller")
      assert Enum.map(suggestions, & &1.tag.id) == [cached_tag.id]
    end

    test "an unattended caller stops at its share while the editor's panel keeps working",
         %{org: org, actor: actor} do
      put_embedding_budget(
        embedding_per_user_limit: {100, :timer.minutes(1)},
        embedding_per_org_limit: {4, :timer.hours(1)},
        embedding_unattended_share: 0.5
      )

      unattended_opts = [user_id: "rule-caller", unattended?: true]
      editor_opts = [user_id: "editor-caller"]

      d1 = draft_in(org, actor, "aaa", title: "A")
      d2 = draft_in(org, actor, "bbb", title: "B")
      d3 = draft_in(org, actor, "ccc", title: "C")

      assert is_list(Related.near_duplicates(d1, unattended_opts))
      assert is_list(Related.near_duplicates(d2, unattended_opts))
      # Half of 4 is 2 — the automation reaction stops there.
      assert {:error, {:rate_limited, _}} = Related.near_duplicates(d3, unattended_opts)

      # The reserved half is still there for the editor's own panel.
      assert is_list(Related.near_duplicates(d3, editor_opts))
    end

    test "unattended_share: 0.0 refuses unattended calls and says it's a setting, not an overload",
         %{org: org, actor: actor} do
      put_embedding_budget(
        embedding_per_org_limit: {10, :timer.hours(1)},
        embedding_unattended_share: 0.0
      )

      draft = draft_in(org, actor, "some passage", title: "Off")

      assert {:error, :unattended_disabled} =
               Related.near_duplicates(draft, user_id: "rule", unattended?: true)
    end
  end

  describe "the shipped embedding budget defaults (#1076)" do
    test "are sized for calls, not for the SEO draft budget's scale" do
      # Deliberately outside the describe above, which overrides these keys: a
      # test that asserts the value its own setup wrote would stay green while
      # someone narrowed the shipped defaults in config/config.exs.
      assert {user_count, _window} = KilnCMS.Search.embedding_per_user_limit()
      assert {org_count, _window} = KilnCMS.Search.embedding_per_org_limit()
      assert is_integer(user_count) and user_count > 0
      assert is_integer(org_count) and org_count > 0
      assert KilnCMS.Search.embedding_unattended_share() == 0.5
    end
  end
end
