defmodule KilnCMS.CMS.ContentTypesTest do
  @moduledoc """
  The content-type registry: auto-discovery, public-path metadata, and generic
  dispatch to the per-type `CMS.*` code interfaces.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp slug, do: "ct-#{System.unique_integer([:positive])}"

  describe "discovery" do
    test "finds the content types (and not taxonomy/join resources)" do
      types = ContentTypes.types()
      assert :page in types
      assert :post in types
      refute :tag in types
      refute :category in types
    end

    test "describes each type with label, plural and excerpt flag" do
      post = ContentTypes.get(:post)
      assert post.label == "Post"
      assert post.plural == "posts"
      assert post.excerpt? == true

      page = ContentTypes.get(:page)
      assert page.excerpt? == false
    end

    test "get/1 accepts a string and returns nil for unknown types" do
      assert ContentTypes.get("page").type == :page
      assert ContentTypes.get("widget") == nil
      refute ContentTypes.type?("widget")
    end
  end

  describe "public paths" do
    test "pages serve at the root, posts under /blog" do
      assert ContentTypes.public_prefix(ContentTypes.get(:page)) == ""
      assert ContentTypes.public_prefix(ContentTypes.get(:post)) == "/blog"
    end

    test "get_by_path resolves the URL segment to a content type" do
      assert ContentTypes.get_by_path("blog").type == :post
      # Pages have no segment (served at root), so they aren't matched here.
      assert ContentTypes.get_by_path("pages") == nil
      assert ContentTypes.get_by_path("widgets") == nil
    end
  end

  describe "dispatch" do
    test "create!/get_record!/list! go through the code interfaces" do
      page = ContentTypes.create!(:page, %{title: "T", slug: slug()}, authorize?: false)
      assert ContentTypes.get_record!(:page, page.id, authorize?: false).id == page.id
      assert Enum.any?(ContentTypes.list!(:page, authorize?: false), &(&1.id == page.id))
    end

    test "get_published_by_slug returns published content only" do
      s = slug()
      post = CMS.create_post!(%{title: "P", slug: s}, authorize?: false)

      # Draft: not delivered.
      assert ContentTypes.get_published_by_slug(:post, s, "en",
               authorize?: false,
               not_found_error?: false
             ) == nil

      CMS.publish_post!(post, %{}, authorize?: false)

      assert ContentTypes.get_published_by_slug(:post, s, "en",
               authorize?: false,
               not_found_error?: false
             ).id == post.id
    end

    test "transition runs a workflow action" do
      page = ContentTypes.create!(:page, %{title: "T", slug: slug()}, authorize?: false)
      {:ok, published} = ContentTypes.transition(:page, "publish", page, authorize?: false)
      assert published.state == :published
    end
  end
end
