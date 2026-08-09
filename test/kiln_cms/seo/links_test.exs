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

  # `:tenant` defaults to the default org. Passing another one is how the
  # cross-org cases build the page that must never surface.
  defp post(actor, text, opts \\ []) do
    tenant = Keyword.get(opts, :tenant)
    write_opts = if tenant, do: [actor: actor, tenant: tenant], else: [actor: actor]

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
        write_opts
      )

    record =
      if Keyword.get(opts, :publish?, true),
        do: CMS.publish_post!(record, %{}, write_opts),
        else: record

    if Keyword.get(opts, :index?, true), do: {:ok, _} = BlockIndexer.reindex(record)
    record
  end

  defp other_org do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: "Other",
      slug: "links-org-#{System.unique_integer([:positive])}",
      status: :active
    })
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

    test "never suggests an audience-gated page" do
      # Delivery serves published AND public (Slugs.find_published_by_alias/3),
      # so a member-only page is a link a reader cannot follow.
      actor = admin()
      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)

      gated =
        post(actor, "brewing herbal tea slowly",
          title: @twin_title,
          attrs: %{audience: :member}
        )

      refute Enum.any?(Links.suggest(anchor), &(&1.id == gated.id))
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

    # #924. The keyword fallback has its own cross-org case, but it sits under a
    # `semantic_off()` setup — so `Links.suggest/2` short-circuits at
    # `Search.semantic?()` and only `Search.global/2`'s scoping is exercised.
    # The docstring naming the SEMANTIC leg as the reason `:tenant` is
    # unnecessary was the one leg no test reached.
    #
    # ## What this does and does not pin
    #
    # `KilnCMS.Search.Related` scopes the semantic path TWICE — `tenant:` on
    # `nearest_block_embeddings!`, and again on the per-neighbour read in
    # `resolve/3` — and either alone is sufficient. Verified by mutation:
    # deleting one and running this file is still green; deleting both turns
    # these two cases red.
    #
    # So this is a guard on the org boundary as a user-visible property, not on
    # either layer individually. That is the property the docstring claims and
    # the one an operator cares about; a single-layer regression stays
    # invisible from out here, which is what defence in depth means and is not
    # something an end-to-end test can fix.
    test "never suggests a page from another organization (#869, #924)" do
      actor = admin()
      other = other_org()

      # A byte-identical twin in ANOTHER org. Under the stub embedder identical
      # title + body means cosine distance 0, so with the boundary gone this
      # ranks FIRST — the strongest version of the leak, not a marginal one.
      foreign =
        post(actor, "brewing herbal tea slowly", title: @twin_title, tenant: other)

      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)

      suggestions = Links.suggest(anchor)

      refute Enum.any?(suggestions, &(&1.id == foreign.id)),
             "a semantic suggestion must not cross the org boundary"

      # The leg really did run — otherwise this passes for the same reason the
      # keyword-fallback case did, and pins nothing.
      assert Enum.all?(suggestions, &(&1.source == :semantic))
    end

    test "the org boundary holds even when the only neighbour is foreign" do
      # The case above still has a same-org twin to return. This one has none,
      # so the semantic leg comes back empty and `candidates/2` falls through to
      # the keyword leg — which must not surface the foreign page either.
      actor = admin()
      other = other_org()

      foreign =
        post(actor, "brewing herbal tea slowly", title: @twin_title, tenant: other)

      anchor = post(actor, "brewing herbal tea slowly", title: @twin_title)

      refute Enum.any?(Links.suggest(anchor), &(&1.id == foreign.id))
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

    # #1066. This stays end-to-end — the fallback is only worth anything if the
    # words it picks reach `Search.global/2` — but it no longer competes for
    # rank against the rest of the corpus.
    #
    # The old version searched for "Kiln firing" and asserted that a target
    # whose ONLY match was its title came back. `keyword/2` fetches `limit * 2`
    # hits and `suggest/2` then takes `limit`, so that target had to out-rank
    # every other post in the tenant on `ts_rank` — including the sibling case
    # above, whose body says "a thorough guide to kiln firing". Which of them
    # placed depended on what else the run had inserted, so the test passed
    # under some seeds and failed under others with nothing naming a cause.
    #
    # A nonce in the title gives the case a corpus it owns: no other row can
    # contain the term, so rank is not a variable and a failure means the
    # fallback itself broke.
    test "falls back to the title when no focus keyphrase is set" do
      actor = admin()
      nonce = "kilnfire#{System.unique_integer([:positive])}"

      anchor = post(actor, "unrelated body text", title: nonce, index?: false)
      target = post(actor, "a thorough guide", title: "#{nonce} guide", index?: false)

      suggestions = Links.suggest(anchor)

      assert Enum.any?(suggestions, &(&1.id == target.id))
      assert Enum.all?(suggestions, &(&1.source == :keyword))
    end

    test "the focus keyphrase wins over the title when both are set" do
      # The other half of the same decision, and it needs both terms present in
      # the corpus to mean anything: if only the keyphrase target existed, a
      # fallback-to-title regression would still return it by accident.
      actor = admin()
      key = "rakuglaze#{System.unique_integer([:positive])}"
      title = "kilnfire#{System.unique_integer([:positive])}"

      anchor =
        post(actor, "unrelated body text",
          title: title,
          index?: false,
          attrs: %{seo_keywords: key}
        )

      keyphrase_target = post(actor, "notes on #{key}", title: "#{key} notes", index?: false)
      title_target = post(actor, "a thorough guide", title: "#{title} guide", index?: false)

      suggestions = Links.suggest(anchor)

      assert Enum.any?(suggestions, &(&1.id == keyphrase_target.id))
      refute Enum.any?(suggestions, &(&1.id == title_target.id))
    end

    test "never suggests a page from another organization (#869)" do
      actor = admin()

      # A published page in ANOTHER org that matches the keyphrase. Scoping comes
      # from the anchor's own `org_id`, so this must never surface — if a future
      # change dropped the tenant thread, it would.
      other_org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other",
          slug: "links-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      foreign =
        CMS.create_post!(
          %{
            title: "Foreign kiln firing",
            slug: "links-foreign-#{System.unique_integer([:positive])}",
            blocks: [
              %{type: :rich_text, content: "<p>a thorough guide to kiln firing</p>", order: 0}
            ]
          },
          actor: actor,
          tenant: other_org
        )

      {:ok, foreign} = CMS.publish_post(foreign, %{}, actor: actor, tenant: other_org)

      anchor =
        post(actor, "notes on kiln firing",
          title: "Anchor",
          index?: false,
          attrs: %{seo_keywords: "kiln firing"}
        )

      refute Enum.any?(Links.suggest(anchor), &(&1.id == foreign.id)),
             "a suggestion must not cross the org boundary"
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
