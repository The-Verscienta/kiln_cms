defmodule KilnCMS.Seo.LinksTest do
  @moduledoc """
  Internal-link suggestions (#377). Both legs matter: the semantic one is the
  good answer, but semantic search is off by default, so the keyword fallback
  is what most installs actually get.
  """
  # async: false — toggles the global KilnCMS.Search app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search.BlockIndexer
  alias KilnCMS.Seo.Links

  defp set_search(overrides) do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
  end

  defp semantic_on, do: set_search(semantic: true, embedder: KilnCMS.StubEmbedder)
  defp semantic_off, do: set_search(semantic: false)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "links-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp post(actor, text, opts \\ []) do
    record =
      CMS.create_post!(
        Map.merge(
          %{
            title: Keyword.get(opts, :title, "Doc"),
            slug: "links-#{System.unique_integer([:positive])}",
            blocks: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]
          },
          Keyword.get(opts, :attrs, %{})
        ),
        actor: actor
      )

    record =
      if Keyword.get(opts, :publish?, true),
        do: CMS.publish_post!(record, %{}, actor: actor),
        else: record

    if Keyword.get(opts, :index?, true), do: {:ok, _} = BlockIndexer.reindex(record)
    record
  end

  describe "the semantic leg" do
    setup do
      semantic_on()
      :ok
    end

    # The block indexer folds ancestor context (the title) into each block's
    # embedded text, and the stub embedder only matches exact strings — so a
    # "twin" has to share the anchor's title as well as its body.
    @twin_title "Same"

    test "suggests the closest published page and never the record itself" do
      actor = admin()
      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)
      twin = post(actor, "brewing herbal tea slowly", title: @twin_title)
      _far = post(actor, "carburetor maintenance schedules", title: "Far")

      suggestions = Links.suggest(anchor)

      assert [%{id: first} | _] = suggestions
      assert first == twin.id
      refute Enum.any?(suggestions, &(&1.id == anchor.id))
      assert Enum.all?(suggestions, &(&1.source == :semantic))
    end

    test "never suggests an unpublished page" do
      # Also covers the fallback: with the draft filtered out the semantic leg
      # is empty, so the keyword leg runs — and it must apply the same
      # published-only rule, or the author gets pointed at a URL that 404s.
      actor = admin()
      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)
      draft = post(actor, "brewing herbal tea slowly", title: @twin_title, publish?: false)

      refute Enum.any?(Links.suggest(anchor), &(&1.id == draft.id))
    end

    test "every suggestion carries a usable public path" do
      actor = admin()
      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)
      _twin = post(actor, "brewing herbal tea slowly", title: @twin_title)

      suggestions = Links.suggest(anchor)
      assert suggestions != []

      for s <- suggestions do
        assert is_binary(s.path)
        assert String.starts_with?(s.path, "/")
      end
    end

    test "a path_alias wins over the flat type path" do
      # The neighbour map used to carry no path at all and callers rebuilt
      # "/type/slug" themselves, which silently ignored multi-segment aliases.
      actor = admin()
      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)

      twin =
        post(actor, "brewing herbal tea slowly",
          title: @twin_title,
          attrs: %{path_alias: "/guides/deep/twin"}
        )

      suggestion = Enum.find(Links.suggest(anchor), &(&1.id == twin.id))

      assert suggestion.path == "/guides/deep/twin"
    end

    test "excludes paths the body already links to" do
      actor = admin()
      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)
      twin = post(actor, "brewing herbal tea slowly", title: @twin_title)

      linked = Enum.find(Links.suggest(anchor), &(&1.id == twin.id))
      assert linked

      refute Enum.any?(
               Links.suggest(anchor, exclude_paths: [linked.path]),
               &(&1.id == twin.id)
             )
    end

    test "respects :limit" do
      actor = admin()
      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)
      for _ <- 1..4, do: post(actor, "brewing herbal tea slowly", title: @twin_title)

      assert length(Links.suggest(anchor, limit: 2)) <= 2
    end
  end

  describe "the keyword fallback" do
    setup do
      # The default install. `Related.related_documents/2` returns [] here,
      # which for a link suggester would mean the feature silently doesn't
      # exist — so the keyword leg has to carry it.
      semantic_off()
      :ok
    end

    test "still finds a match when semantic search is disabled" do
      actor = admin()

      anchor =
        post(actor, "notes on kiln firing",
          title: "Anchor",
          index?: false,
          attrs: %{seo_keywords: "kiln firing"}
        )

      target =
        post(actor, "a thorough guide to kiln firing", title: "Kiln firing guide", index?: false)

      suggestions = Links.suggest(anchor)

      assert Enum.any?(suggestions, &(&1.id == target.id))
      assert Enum.all?(suggestions, &(&1.source == :keyword))
      refute Enum.any?(suggestions, &(&1.id == anchor.id))
    end

    test "falls back to the title when no focus keyphrase is set" do
      actor = admin()
      anchor = post(actor, "unrelated body text", title: "Kiln firing", index?: false)
      target = post(actor, "a thorough guide", title: "Kiln firing guide", index?: false)

      assert Enum.any?(Links.suggest(anchor), &(&1.id == target.id))
    end

    test "keyword suggestions carry a path but no distance" do
      actor = admin()

      anchor =
        post(actor, "notes on kiln firing",
          title: "Anchor",
          index?: false,
          attrs: %{seo_keywords: "kiln firing"}
        )

      _target = post(actor, "a guide to kiln firing", title: "Guide", index?: false)

      for s <- Links.suggest(anchor) do
        assert String.starts_with?(s.path, "/")
        assert s.distance == nil
      end
    end

    test "returns [] rather than raising when there is nothing to search for" do
      # Built in memory, not persisted: `title` is required, so a record with
      # nothing searchable can't be created — but a blank-ish one can still
      # reach the suggester (e.g. mid-edit), and it must not blow up.
      anchor = %KilnCMS.CMS.Post{
        id: Ash.UUID.generate(),
        org_id: KilnCMS.Accounts.default_org_id(),
        title: "   ",
        seo_keywords: nil,
        locale: "en"
      }

      assert Links.suggest(anchor) == []
    end
  end
end
