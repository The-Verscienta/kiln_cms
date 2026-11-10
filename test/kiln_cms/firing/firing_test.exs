defmodule KilnCMS.Firing.FiringTest do
  @moduledoc "Phase D — firing into immutable per-surface artifacts (decision D9)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.{CMS, Firing}
  alias KilnCMS.Firing.{Cache, Engine}

  # A content resource declares its canonical type atom via `__kiln_content_type__/0`
  # (the Content macro). These stubs stand in for real resources so `document_type/1`
  # can be checked without seeding — the multi-word case is the regression guard.
  defmodule MultiWordDoc do
    defstruct [:id]
    def __kiln_content_type__, do: :recipe_ingredient
  end

  defmodule SingleWordDoc do
    defstruct [:id]
    def __kiln_content_type__, do: :recipe
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fire-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "fire-#{System.unique_integer([:positive])}"

  defp published_page(actor) do
    page =
      CMS.create_page!(
        %{
          title: "Fired",
          slug: slug(),
          blocks:
            KilnCMS.TypedFixtures.typed_blocks([
              %{type: :heading, content: "Welcome", data: %{"level" => 1}, order: 0},
              %{type: :rich_text, content: "<p>Body</p>", order: 1}
            ])
        },
        actor: actor
      )

    published = CMS.publish_page!(page, actor: actor)
    # Firing is async (#201): run the enqueued FireWorker so artifacts exist.
    KilnCMS.DataCase.drain_oban()
    published
  end

  describe "firing on publish" do
    test "fires every surface at the current format_version" do
      actor = admin()
      page = published_page(actor)

      {:ok, artifacts} = Firing.artifacts_for(:page, page.id, authorize?: false)
      surfaces = artifacts |> Enum.map(& &1.surface) |> Enum.sort()

      assert surfaces == [:json, :json_ld, :llm, :web]
      assert Enum.all?(artifacts, &(&1.format_version == Engine.format_version()))
    end

    test "the web artifact is pre-rendered HTML from the typed serializers" do
      org = KilnCMS.Accounts.default_org_id()
      page = published_page(admin())
      {:ok, %{"html" => html}} = Engine.read(org, :page, page.id, :web)

      assert html =~ "<h1>Welcome</h1>"
      assert html =~ "<p>Body</p>"
    end

    # #2164: a fired code block takes focus and a name, in the document's
    # language rather than the worker's.
    test "the web artifact's code blocks are focusable and named in the document's locale" do
      org = KilnCMS.Accounts.default_org_id()
      actor = admin()

      code = %{
        "_type" => "block",
        "style" => "code",
        "language" => "elixir",
        "children" => [%{"_type" => "span", "text" => "IO.puts(1)", "marks" => []}],
        "markDefs" => []
      }

      fr =
        CMS.create_page!(
          %{
            title: "Code",
            slug: slug(),
            locale: "fr",
            blocks: [%{"_type" => "rich_text", "body" => [code]}]
          },
          actor: actor
        )

      CMS.publish_page!(fr, actor: actor)
      KilnCMS.DataCase.drain_oban()

      {:ok, %{"html" => html}} = Engine.read(org, :page, fr.id, :web)

      assert html =~
               ~s(<pre class="highlight" tabindex="0" role="group" aria-label="Exemple de code">)

      {:ok, %{"blocks" => [block]}} = Engine.read(org, :page, fr.id, :json)
      refute inspect(block) =~ "tabindex"
    end

    # #2465: the strings a block writes into the fired artifact are in the
    # document's language, and the sign-up still posts to the bare path — a
    # fired artifact is hosted elsewhere, so the action is not pinned.
    test "the web artifact's embed and sign-up strings are in the document's locale" do
      org = KilnCMS.Accounts.default_org_id()
      actor = admin()

      fr =
        CMS.create_page!(
          %{
            title: "Médias",
            slug: slug(),
            locale: "fr",
            blocks: [
              %{"_type" => "embed", "url" => "https://www.youtube.com/watch?v=abc123"},
              %{"_type" => "newsletter_signup", "collect_name" => true}
            ]
          },
          actor: actor
        )

      CMS.publish_page!(fr, actor: actor)
      KilnCMS.DataCase.drain_oban()

      {:ok, %{"html" => html}} = Engine.read(org, :page, fr.id, :web)

      assert html =~ ~s(title="Média intégré")
      refute html =~ "Embedded media"
      assert html =~ "Laissez ce champ vide"
      assert html =~ ~s(action="/newsletter/subscribe")
    end

    # #2464: a fired table's scroll wrapper takes focus and a name, in the
    # document's language rather than the worker's.
    test "the web artifact's tables are focusable and named in the document's locale" do
      org = KilnCMS.Accounts.default_org_id()
      actor = admin()

      table = %{
        "_type" => "table",
        "rows" => [
          %{"cells" => [%{"children" => [%{"_type" => "span", "text" => "a", "marks" => []}]}]}
        ]
      }

      fr =
        CMS.create_page!(
          %{
            title: "Tableau",
            slug: slug(),
            locale: "fr",
            blocks: [%{"_type" => "rich_text", "body" => [table]}]
          },
          actor: actor
        )

      CMS.publish_page!(fr, actor: actor)
      KilnCMS.DataCase.drain_oban()

      {:ok, %{"html" => html}} = Engine.read(org, :page, fr.id, :web)

      assert html =~
               ~s(<div class="kiln-table-wrap" tabindex="0" role="group" aria-label="Tableau défilant"><table>)

      {:ok, %{"blocks" => [block]}} = Engine.read(org, :page, fr.id, :json)
      refute inspect(block) =~ "tabindex"
    end

    test "the json artifact carries structured intent" do
      org = KilnCMS.Accounts.default_org_id()
      page = published_page(admin())
      {:ok, json} = Engine.read(org, :page, page.id, :json)

      assert json["type"] == "page"
      assert json["title"] == "Fired"
      assert [%{"_type" => "heading"} | _] = json["blocks"]
    end

    test "the json_ld artifact is a schema.org graph derived from the blocks (Phase J)" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()

      page =
        CMS.create_page!(
          %{
            title: "Graphed",
            slug: slug(),
            blocks:
              KilnCMS.TypedFixtures.typed_blocks([
                %{type: :heading, content: "T", order: 0},
                %{type: :image, data: %{"url" => "/p.png", "alt" => "pic"}, order: 1}
              ])
          },
          actor: actor
        )

      page = CMS.publish_page!(page, actor: actor)
      KilnCMS.DataCase.drain_oban()
      {:ok, ld} = Engine.read(org, :page, page.id, :json_ld)

      assert ld["@context"] == "https://schema.org"
      types = Enum.map(ld["@graph"], & &1["@type"])
      # Pages declare WebPage as their main-node @type (#357, GEO).
      assert "WebPage" in types
      assert "ImageObject" in types

      # The main node carries the citation-relevant document metadata (#357).
      main = Enum.find(ld["@graph"], &(&1["@type"] == "WebPage"))
      assert main["headline"] == "Graphed"
      assert main["inLanguage"] == "en"
      assert is_binary(main["datePublished"])
      # WebPage is not an Article subtype, so the body fires as `text`.
      assert is_binary(main["text"])
      refute Map.has_key?(main, "articleBody")
    end

    test "posts fire a BlogPosting main node with articleBody (#357)" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()

      post =
        CMS.create_post!(
          %{
            title: "GEO",
            slug: slug(),
            blocks:
              KilnCMS.TypedFixtures.typed_blocks([%{type: :heading, content: "H", order: 0}])
          },
          actor: actor
        )

      post = CMS.publish_post!(post, actor: actor)
      KilnCMS.DataCase.drain_oban()
      {:ok, ld} = Engine.read(org, :post, post.id, :json_ld)

      assert [%{"@type" => "BlogPosting"} = main | _] = ld["@graph"]
      assert is_binary(main["articleBody"])
    end

    test "a dynamic type's declared schema.org type fires on its entries (#357)" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()

      definition =
        CMS.create_type_definition!(
          %{
            name: "help_article#{System.unique_integer([:positive])}",
            label: "Help article",
            schema_org_type: "FAQPage"
          },
          actor: actor
        )

      entry =
        CMS.ContentTypes.create!(definition.name, %{title: "Returns policy", slug: slug()},
          actor: actor
        )

      {:ok, entry} = CMS.ContentTypes.transition(definition.name, "publish", entry, actor: actor)
      KilnCMS.DataCase.drain_oban()
      {:ok, ld} = Engine.read(org, :entry, entry.id, :json_ld)

      assert [%{"@type" => "FAQPage"} | _] = ld["@graph"]
    end

    test "archiving a dynamic type does not change what its published entries fire (#938)" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()

      definition =
        CMS.create_type_definition!(
          %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: actor
        )

      entry =
        CMS.ContentTypes.create!(definition.name, %{title: "Ginger", slug: slug()}, actor: actor)

      {:ok, entry} = CMS.ContentTypes.transition(definition.name, "publish", entry, actor: actor)
      KilnCMS.DataCase.drain_oban()

      {:ok, before} = Engine.read(org, :entry, entry.id, :json)
      assert before["type"] == definition.name

      # The archived type keeps its entries editable (moduledoc). A re-fire —
      # e.g. from an edit, or here forced directly — must still resolve the
      # SAME name, not fall back to the generic "entry" storage key just
      # because `TypeDefinition`'s default `:read` filters archived rows.
      CMS.destroy_type_definition!(definition, actor: actor)
      Engine.fire(entry)
      KilnCMS.DataCase.drain_oban()

      {:ok, after_archive} = Engine.read(org, :entry, entry.id, :json)
      assert after_archive["type"] == definition.name
    end

    test "faq, how_to and claim blocks expand the fired @graph (#357)" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()

      page =
        CMS.create_page!(
          %{
            title: "Answers",
            slug: slug(),
            blocks:
              KilnCMS.TypedFixtures.typed_blocks([
                %{
                  type: :faq,
                  content: "FAQ",
                  data: %{"items" => [%{"question" => "Q?", "answer" => "A."}]},
                  order: 0
                },
                %{
                  type: :how_to,
                  content: "Do it",
                  data: %{"steps" => [%{"name" => "One", "text" => "First."}]},
                  order: 1
                },
                %{
                  type: :claim,
                  content: "Water is wet.",
                  data: %{"source_title" => "Src", "source_url" => "https://s.example"},
                  order: 2
                }
              ])
          },
          actor: actor
        )

      page = CMS.publish_page!(page, actor: actor)
      KilnCMS.DataCase.drain_oban()

      {:ok, ld} = Engine.read(org, :page, page.id, :json_ld)
      types = Enum.map(ld["@graph"], & &1["@type"])
      assert "FAQPage" in types
      assert "HowTo" in types
      assert "Claim" in types

      # The citation also rides the :llm Markdown surface.
      {:ok, %{"markdown" => md}} = Engine.read(org, :page, page.id, :llm)
      assert md =~ "### Q?"
      assert md =~ "1. **One** — First."
      assert md =~ "Source: [Src](https://s.example)"

      # …and the fired :web HTML.
      {:ok, %{"html" => html}} = Engine.read(org, :page, page.id, :web)
      assert html =~ "kiln-faq"
      assert html =~ "kiln-claim"
    end

    test "a gallery fires ImageGallery, an accordion fires nothing (#482)" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()

      page =
        CMS.create_page!(
          %{
            title: "Gallery",
            slug: slug(),
            blocks:
              KilnCMS.TypedFixtures.typed_blocks([
                %{
                  type: :gallery,
                  content: "Shots",
                  data: %{
                    "layout" => "grid",
                    "images" => [%{"url" => "/a.jpg", "alt" => "A kiln", "caption" => "At work"}]
                  },
                  order: 0
                },
                %{
                  type: :accordion,
                  content: "Specifications",
                  data: %{"panels" => [%{"title" => "Size", "content" => "Large"}]},
                  order: 1
                }
              ])
          },
          actor: actor
        )

      page = CMS.publish_page!(page, actor: actor)
      KilnCMS.DataCase.drain_oban()

      {:ok, ld} = Engine.read(org, :page, page.id, :json_ld)
      types = Enum.map(ld["@graph"], & &1["@type"])

      assert "ImageGallery" in types

      # The whole point of the accordion existing beside `faq`: it renders the
      # same collapsing panels and contributes no claim about the page. If this
      # ever fails, the block has become a duplicate of `faq` under a new name.
      refute "FAQPage" in types

      # Both still render, and both still project into search + the LLM surface.
      {:ok, %{"html" => html}} = Engine.read(org, :page, page.id, :web)
      assert html =~ "kiln-gallery"
      assert html =~ "kiln-accordion"

      {:ok, %{"markdown" => md}} = Engine.read(org, :page, page.id, :llm)
      assert md =~ "![A kiln](/a.jpg)"
      assert md =~ "### Size"
    end
  end

  # #2258: the `:json` artifact carries the document's link-preview fields, so
  # a headless consumer can emit the same Open Graph / X card tags Kiln's own
  # pages do.
  describe "social (#2258)" do
    defp publish_page(actor, attrs, opts \\ []) do
      page =
        CMS.create_page!(
          Map.merge(%{title: "Social", slug: slug()}, attrs),
          Keyword.put(opts, :actor, actor)
        )

      published = CMS.publish_page!(page, Keyword.put(opts, :actor, actor))
      KilnCMS.DataCase.drain_oban()
      published
    end

    defp fired_social(page) do
      {:ok, json} = Engine.read(page.org_id, :page, page.id, :json)
      json["social"]
    end

    test "carries the SEO title, description and an absolute image as typed" do
      page =
        publish_page(admin(), %{
          seo_title: "Hand-picked title",
          seo_description: "Hand-written description",
          seo_image: "https://cdn.example.com/card.png"
        })

      assert fired_social(page) == %{
               "title" => "Hand-picked title",
               "description" => "Hand-written description",
               "image" => "https://cdn.example.com/card.png"
             }
    end

    test "falls back to the title, and omits description and image when there is none" do
      page = publish_page(admin(), %{title: "Only a title"})

      assert fired_social(page) == %{"title" => "Only a title"}
    end

    test "a relative SEO image is made absolute on the document's own site" do
      page = publish_page(admin(), %{seo_image: "/uploads/card.png"})

      assert fired_social(page)["image"] ==
               KilnCMSWeb.Tenant.base_url(page.org_id) <> "/uploads/card.png"
    end

    test "a relative SEO image lands on a tenant's own host, not the default one" do
      org = KilnCMS.OrgFixtures.org("social")
      page = publish_page(admin(), %{seo_image: "/uploads/card.png"}, tenant: org)

      image = fired_social(page)["image"]
      assert image == KilnCMSWeb.Tenant.base_url(org) <> "/uploads/card.png"
      assert URI.parse(image).host =~ org.slug
    end

    test "a type's SEO patterns fill the title and description an entry left blank" do
      actor = admin()

      type =
        CMS.create_type_definition!(
          %{
            name: "guide#{System.unique_integer([:positive])}",
            label: "Guide",
            has_excerpt: true,
            seo_title_pattern: "Guides: [title]",
            seo_description_pattern: "[excerpt] (guide)"
          },
          actor: actor
        )

      entry =
        KilnCMS.CMS.ContentTypes.create!(type.name, %{title: "Firing", excerpt: "How to"},
          actor: actor
        )

      {:ok, %{json: json}} = Engine.fire(entry, mode: :preview, surfaces: [:json])

      assert json["social"] == %{"title" => "Guides: Firing", "description" => "How to (guide)"}
    end

    # Site-level values belong to the page, not to a signed per-document body:
    # the card type, `twitter:site` and the brand's fallback image stay out.
    test "carries no site-level branding" do
      actor = admin()
      org = KilnCMS.OrgFixtures.org("social-brand")
      on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)

      CMS.save_site_branding!(
        %{twitter_site: "@kilnsocial", social_image_url: "/uploads/brand-card.png"},
        actor: actor,
        tenant: org
      )

      page = publish_page(actor, %{}, tenant: org)
      {:ok, json} = Engine.read(org.id, :page, page.id, :json)

      assert json["social"] == %{"title" => "Social"}
      refute Jason.encode!(json) =~ "kilnsocial"
      refute Jason.encode!(json) =~ "brand-card.png"
    end
  end

  describe "reads never touch the live tree" do
    test "editing the live document after publish does not change the fired artifact" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()
      page = published_page(actor)

      # Mutate the live draft AFTER publishing; do not re-publish.
      CMS.update_page!(page, %{title: "Changed Live"}, actor: actor)

      {:ok, json} = Engine.read(org, :page, page.id, :json)
      # Still the fired snapshot, not the live edit.
      assert json["title"] == "Fired"
    end
  end

  describe "unpublish" do
    test "removes artifacts and evicts the cache" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()
      page = published_page(actor)
      assert {:ok, _} = Engine.read(org, :page, page.id, :web)

      CMS.unpublish_page!(page, actor: actor)

      assert {:ok, []} = Firing.artifacts_for(:page, page.id, authorize?: false)
      assert :miss = Cache.get(org, :page, page.id, :web)
      assert :error = Engine.read(org, :page, page.id, :web)
    end
  end

  describe "archive (#879)" do
    test "archiving a published record clears its version and purges artifacts" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()
      page = published_page(actor)

      # A published record has a recorded published version and live artifacts.
      assert {:ok, _} = Engine.read(org, :page, page.id, :web)
      refute is_nil(CMS.get_page!(page.id, actor: actor).published_version_id)

      archived = CMS.archive_page!(page, actor: actor)
      assert archived.state == :archived

      # Same teardown as unpublish — otherwise the artifacts (and the published
      # version pointer) would orphan.
      reloaded = CMS.get_page!(page.id, actor: actor)
      assert is_nil(reloaded.published_version_id)
      assert {:ok, []} = Firing.artifacts_for(:page, page.id, authorize?: false)
      assert :error = Engine.read(org, :page, page.id, :web)
    end

    test "archiving a draft is clean — nothing to clear" do
      actor = admin()

      draft =
        CMS.create_page!(
          %{
            title: "Draft",
            slug: slug(),
            blocks:
              KilnCMS.TypedFixtures.typed_blocks([%{type: :heading, content: "Hi", order: 0}])
          },
          actor: actor
        )

      archived = CMS.archive_page!(draft, actor: actor)
      assert archived.state == :archived
      assert is_nil(archived.published_version_id)
    end
  end

  describe "preview mode" do
    test "compiles to memory without persisting artifacts" do
      actor = admin()

      page =
        CMS.create_page!(
          %{
            title: "Draft",
            slug: slug(),
            blocks:
              KilnCMS.TypedFixtures.typed_blocks([%{type: :heading, content: "Hi", order: 0}])
          },
          actor: actor
        )

      {:ok, artifacts} = Engine.fire(page, mode: :preview)

      assert artifacts.web["html"] =~ "<h2>Hi</h2>"
      assert {:ok, []} = Firing.artifacts_for(:page, page.id, authorize?: false)
    end

    test "surfaces: renders only the named surfaces, and only for a preview (#1887)" do
      page =
        CMS.create_page!(
          %{
            title: "Draft",
            slug: slug(),
            blocks:
              KilnCMS.TypedFixtures.typed_blocks([%{type: :heading, content: "Hi", order: 0}])
          },
          actor: admin()
        )

      assert {:ok, artifacts} = Engine.fire(page, mode: :preview, surfaces: [:json])
      assert Map.keys(artifacts) == [:json]

      assert_raise ArgumentError, fn -> Engine.fire(page, surfaces: [:json]) end
      assert {:ok, []} = Firing.artifacts_for(:page, page.id, authorize?: false)
    end
  end

  describe "document_type/1" do
    test "trusts a multi-word type's declared atom instead of the module name" do
      # Regression: downcasing the module suffix ("RecipeIngredient" -> "recipeingredient")
      # loses the underscores, so String.to_existing_atom/1 used to raise here.
      assert Engine.document_type(%MultiWordDoc{}) == :recipe_ingredient
    end

    test "still resolves a single-word type" do
      assert Engine.document_type(%SingleWordDoc{}) == :recipe
    end
  end
end
