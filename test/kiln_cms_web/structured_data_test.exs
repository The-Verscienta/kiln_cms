defmodule KilnCMSWeb.StructuredDataTest do
  @moduledoc """
  schema.org JSON-LD is built per content type: posts as BlogPosting, everything
  else as WebPage, with empty fields omitted.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.StructuredData

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
end
