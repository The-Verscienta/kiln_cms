defmodule KilnCMSWeb.StructuredDataTest do
  @moduledoc """
  schema.org JSON-LD is built per content type: posts as BlogPosting, everything
  else as WebPage, with empty fields omitted.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.StructuredData

  # An in-memory org struct (never persisted) — `StructuredData` only reads
  # `slug`/`custom_domain` off the struct, no DB round-trip needed (#557).
  defp tenant_org(attrs \\ %{}) do
    struct(
      Organization,
      Map.merge(%{id: Ash.UUID.generate(), slug: "acme", custom_domain: nil}, attrs)
    )
  end

  defp post(attrs \\ %{}) do
    struct(
      KilnCMS.CMS.Post,
      Map.merge(
        %{title: "Hello", slug: "hello", published_at: ~U[2026-01-02 03:04:05Z], updated_at: nil},
        attrs
      )
    )
  end

  defp page(attrs \\ %{}) do
    struct(KilnCMS.CMS.Page, Map.merge(%{title: "About", slug: "about"}, attrs))
  end

  test "a post is a BlogPosting with a /blog/<slug> url and dates" do
    data = StructuredData.build(post(), ContentTypes.get(:post))

    assert data["@context"] == "https://schema.org"
    assert data["@type"] == "BlogPosting"
    assert data["headline"] == "Hello"
    assert data["url"] == "http://localhost:4000/blog/hello"
    assert data["mainEntityOfPage"] == "http://localhost:4000/blog/hello"
    assert data["datePublished"] == "2026-01-02T03:04:05Z"
    assert data["publisher"] == %{"@type" => "Organization", "name" => "KilnCMS"}
  end

  test "a page is a WebPage with a /<slug> url and a name" do
    data = StructuredData.build(page(), ContentTypes.get(:page))

    assert data["@type"] == "WebPage"
    assert data["name"] == "About"
    assert data["url"] == "http://localhost:4000/about"
  end

  test "an editor-set canonical URL wins over the derived one" do
    data =
      StructuredData.build(
        page(%{canonical_url: "https://example.com/x"}),
        ContentTypes.get(:page)
      )

    assert data["url"] == "https://example.com/x"
  end

  test "empty fields are omitted, populated ones included" do
    bare = StructuredData.build(page(), ContentTypes.get(:page))
    refute Map.has_key?(bare, "description")
    refute Map.has_key?(bare, "image")

    rich =
      StructuredData.build(
        page(%{seo_description: "Desc", seo_image: "https://cdn/x.png"}),
        ContentTypes.get(:page)
      )

    assert rich["description"] == "Desc"
    assert rich["image"] == "https://cdn/x.png"
  end

  test "includes a Person author only when the loaded author has a name" do
    named = StructuredData.build(post(%{author: %{name: "Jane Doe"}}), ContentTypes.get(:post))
    assert named["author"] == %{"@type" => "Person", "name" => "Jane Doe"}

    # Unloaded author (struct default) and a blank name are both omitted.
    refute Map.has_key?(StructuredData.build(post(), ContentTypes.get(:post)), "author")

    refute Map.has_key?(
             StructuredData.build(post(%{author: %{name: nil}}), ContentTypes.get(:post)),
             "author"
           )
  end

  test "document/2 appends a BreadcrumbList; posts carry a Blog crumb" do
    [main, crumbs] = StructuredData.document(post(), ContentTypes.get(:post))
    assert main["@type"] == "BlogPosting"
    assert crumbs["@type"] == "BreadcrumbList"
    assert Enum.map(crumbs["itemListElement"], & &1["name"]) == ["Home", "Blog", "Hello"]
    assert Enum.map(crumbs["itemListElement"], & &1["position"]) == [1, 2, 3]

    [_main, page_crumbs] = StructuredData.document(page(), ContentTypes.get(:page))
    assert Enum.map(page_crumbs["itemListElement"], & &1["name"]) == ["Home", "About"]
  end

  test "blog/1 emits a CollectionPage with a positioned ItemList" do
    data =
      StructuredData.blog([post(%{title: "P1", slug: "p1"}), post(%{title: "P2", slug: "p2"})])

    assert data["@type"] == "CollectionPage"
    assert data["url"] == "http://localhost:4000/blog"

    items = data["mainEntity"]["itemListElement"]
    assert Enum.map(items, & &1["name"]) == ["P1", "P2"]
    assert Enum.map(items, & &1["position"]) == [1, 2]
    assert hd(items)["url"] == "http://localhost:4000/blog/p1"
  end

  describe "teaser/2 (#337 Phase 2, #769, #1136)" do
    test "a page teaser resolves @type from its own declared schema_org_type" do
      teaser = KilnCMSWeb.Teaser.from_record(page(%{audience: :member}), "http://x/about")
      [node] = StructuredData.teaser(teaser)

      assert node["@type"] == "WebPage"
      assert node["name"] == "About"
      assert node["isAccessibleForFree"] == false
    end

    test "resolves @type from the gated record, matching the full render's @type" do
      record = post(%{audience: :member})
      teaser = KilnCMSWeb.Teaser.from_record(record, "http://x/blog/hello")

      [node] = StructuredData.teaser(teaser)
      full = StructuredData.build(record, ContentTypes.get(:post))

      assert node["@type"] == "BlogPosting"
      assert node["@type"] == full["@type"]
      assert node["headline"] == "Hello"
      assert node["isAccessibleForFree"] == false
    end
  end

  describe "tenant-hosted org URLs (#557)" do
    test "build/3 and document/3 derive the url/breadcrumbs from the given org's host" do
      org = tenant_org()

      data = StructuredData.build(page(), ContentTypes.get(:page), org)
      assert data["url"] == "http://acme.localhost:4000/about"
      assert data["mainEntityOfPage"] == "http://acme.localhost:4000/about"

      [_main, crumbs] = StructuredData.document(page(), ContentTypes.get(:page), org)

      assert Enum.map(crumbs["itemListElement"], & &1["item"]) == [
               "http://acme.localhost:4000",
               "http://acme.localhost:4000/about"
             ]
    end

    test "a custom domain org emits that domain instead of its slug" do
      org = tenant_org(%{custom_domain: "www.acme-vanity.com"})
      data = StructuredData.build(post(), ContentTypes.get(:post), org)
      # Same scheme/port as the global config (:4000 in test).
      assert data["url"] == "http://www.acme-vanity.com:4000/blog/hello"
    end

    test "blog/2 threads the org through the collection URL and item URLs" do
      org = tenant_org()
      data = StructuredData.blog([post(%{title: "P1", slug: "p1"})], org)

      assert data["url"] == "http://acme.localhost:4000/blog"

      assert hd(data["mainEntity"]["itemListElement"])["url"] ==
               "http://acme.localhost:4000/blog/p1"
    end

    test "an editor-set canonical URL still wins over the tenant-derived one" do
      org = tenant_org()

      data =
        StructuredData.build(
          page(%{canonical_url: "https://example.com/x"}),
          ContentTypes.get(:page),
          org
        )

      assert data["url"] == "https://example.com/x"
    end
  end
end
