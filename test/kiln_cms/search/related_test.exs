defmodule KilnCMS.Search.RelatedTest do
  @moduledoc "Embedding-driven content intelligence (#339 phase 2)."
  # async: false — toggles the global KilnCMS.Search app env (stub embedder).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search.BlockIndexer
  alias KilnCMS.Search.Related

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
end
