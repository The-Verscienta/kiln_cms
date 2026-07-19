defmodule KilnCMS.Search.RelatedTest do
  @moduledoc "Embedding-driven content intelligence (#339 phase 2)."
  # async: false — toggles the global KilnCMS.Search app env (stub embedder).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search.BlockIndexer
  alias KilnCMS.Search.Related

  # Deterministic stub: same text → same 384-d vector (so identical block text
  # means distance 0), no model loaded.
  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, semantic: true, embedder: StubEmbedder)
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

  test "suggest_tags returns scored suggestions and skips applied tags" do
    actor = admin()
    uniq = System.unique_integer([:positive])

    tea = CMS.create_tag!(%{name: "herbal tea", slug: "tea-#{uniq}"}, actor: actor)
    cars = CMS.create_tag!(%{name: "carburetors", slug: "cars-#{uniq}"}, actor: actor)

    post = indexed_post(actor, "brewing herbal tea slowly")

    suggestions = Related.suggest_tags(post)
    suggested_ids = Enum.map(suggestions, & &1.tag.id)
    # Both candidate tags are scored (the stub embedder can't attest semantic
    # ordering — ranking quality is a model property, not a code property).
    assert tea.id in suggested_ids
    assert cars.id in suggested_ids
    assert Enum.all?(suggestions, &is_float(&1.distance))

    # Once applied, a tag is no longer suggested.
    post = CMS.update_post!(post, %{tag_ids: [tea.id]}, actor: actor)
    post = KilnCMS.CMS.get_post!(post.id, authorize?: false, load: [:tags])
    refute Enum.any?(Related.suggest_tags(post), &(&1.tag.id == tea.id))
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
