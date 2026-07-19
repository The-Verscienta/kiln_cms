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
    def __kiln_content_type__, do: :tcm_ingredient
  end

  defmodule SingleWordDoc do
    defstruct [:id]
    def __kiln_content_type__, do: :herb
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
          blocks: [
            %{type: :heading, content: "Welcome", data: %{"level" => 1}, order: 0},
            %{type: :rich_text, content: "<p>Body</p>", order: 1}
          ]
        },
        actor: actor
      )

    published = CMS.publish_page!(page, actor: actor)
    # Firing is async (#201): run the enqueued FireWorker so artifacts exist.
    KilnCMS.DataCase.drain_oban()
    published
  end

  describe "firing on publish" do
    test "fires every surface with format_version 1" do
      actor = admin()
      page = published_page(actor)

      {:ok, artifacts} = Firing.artifacts_for(:page, page.id, authorize?: false)
      surfaces = artifacts |> Enum.map(& &1.surface) |> Enum.sort()

      assert surfaces == [:json, :json_ld, :llm, :web]
      assert Enum.all?(artifacts, &(&1.format_version == 1))
    end

    test "the web artifact is pre-rendered HTML from the typed serializers" do
      org = KilnCMS.Accounts.default_org_id()
      page = published_page(admin())
      {:ok, %{"html" => html}} = Engine.read(org, :page, page.id, :web)

      assert html =~ "<h1>Welcome</h1>"
      assert html =~ "<p>Body</p>"
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
            blocks: [
              %{type: :heading, content: "T", order: 0},
              %{type: :image, data: %{"url" => "/p.png", "alt" => "pic"}, order: 1}
            ]
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
          %{title: "GEO", slug: slug(), blocks: [%{type: :heading, content: "H", order: 0}]},
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
            name: "remedy#{System.unique_integer([:positive])}",
            label: "Remedy",
            schema_org_type: "MedicalWebPage"
          },
          actor: actor
        )

      entry =
        CMS.ContentTypes.create!(definition.name, %{title: "Ginger", slug: slug()}, actor: actor)

      {:ok, entry} = CMS.ContentTypes.transition(definition.name, "publish", entry, actor: actor)
      KilnCMS.DataCase.drain_oban()
      {:ok, ld} = Engine.read(org, :entry, entry.id, :json_ld)

      assert [%{"@type" => "MedicalWebPage"} | _] = ld["@graph"]
    end

    test "faq, how_to and claim blocks expand the fired @graph (#357)" do
      actor = admin()
      org = KilnCMS.Accounts.default_org_id()

      page =
        CMS.create_page!(
          %{
            title: "Answers",
            slug: slug(),
            blocks: [
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
            ]
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

  describe "preview mode" do
    test "compiles to memory without persisting artifacts" do
      actor = admin()

      page =
        CMS.create_page!(
          %{title: "Draft", slug: slug(), blocks: [%{type: :heading, content: "Hi", order: 0}]},
          actor: actor
        )

      {:ok, artifacts} = Engine.fire(page, mode: :preview)

      assert artifacts.web["html"] =~ "<h2>Hi</h2>"
      assert {:ok, []} = Firing.artifacts_for(:page, page.id, authorize?: false)
    end
  end

  describe "document_type/1" do
    test "trusts a multi-word type's declared atom instead of the module name" do
      # Regression: downcasing the module suffix ("TcmIngredient" -> "tcmingredient")
      # loses the underscores, so String.to_existing_atom/1 used to raise here.
      assert Engine.document_type(%MultiWordDoc{}) == :tcm_ingredient
    end

    test "still resolves a single-word type" do
      assert Engine.document_type(%SingleWordDoc{}) == :herb
    end
  end
end
