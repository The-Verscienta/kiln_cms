defmodule KilnCMS.CMS.ContentModelTest do
  @moduledoc """
  Coverage for the content-model enrichments: the `author` relationship,
  the `published`/`word_count` calculations, and the User authored-count
  aggregates.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-cm-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "cm-#{System.unique_integer([:positive])}"

  describe "SEO fields" do
    test "create accepts and persists seo_image and canonical_url" do
      admin = user(:admin)

      page =
        CMS.create_page!(
          %{
            title: "SEO",
            slug: slug(),
            seo_image: "https://cdn.example/og.png",
            canonical_url: "https://example.com/seo"
          },
          actor: admin
        )

      assert page.seo_image == "https://cdn.example/og.png"
      assert page.canonical_url == "https://example.com/seo"
    end
  end

  describe "author relationship" do
    test "create stamps the acting user as the author" do
      editor = user(:editor)
      page = CMS.create_page!(%{title: "T", slug: slug()}, actor: editor)
      assert page.author_id == editor.id
    end

    test "create without an actor leaves the author nil" do
      page = CMS.create_page!(%{title: "T", slug: slug()}, authorize?: false)
      assert is_nil(page.author_id)
    end
  end

  describe "published calculation" do
    test "is false for a draft and true once published" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "T", slug: slug()}, actor: admin)

      assert %{published: false} = CMS.get_page!(page.id, load: [:published], actor: admin)

      published = CMS.publish_page!(page, %{}, actor: admin)
      assert %{published: true} = CMS.get_page!(published.id, load: [:published], actor: admin)
    end
  end

  describe "word_count calculation" do
    test "counts words across blocks, stripping markup, including children" do
      admin = user(:admin)

      page =
        CMS.create_page!(
          %{
            title: "T",
            slug: slug(),
            blocks: [
              %{type: :heading, content: "Hello world", order: 0},
              %{
                type: :rich_text,
                content: "<p>three more words here</p>",
                order: 1,
                children: [%{type: :rich_text, content: "nested child block"}]
              }
            ]
          },
          actor: admin
        )

      # "Hello world" (2) + "three more words here" (4) + "nested child block" (3)
      assert %{word_count: 9} = CMS.get_page!(page.id, load: [:word_count], actor: admin)
    end

    test "is zero when there are no blocks" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "T", slug: slug()}, actor: admin)
      assert %{word_count: 0} = CMS.get_page!(page.id, load: [:word_count], actor: admin)
    end
  end

  describe "authored-count aggregates" do
    test "count the user's authored pages and posts" do
      editor = user(:editor)

      for _ <- 1..2, do: CMS.create_page!(%{title: "P", slug: slug()}, actor: editor)
      CMS.create_post!(%{title: "Post", slug: slug()}, actor: editor)

      loaded = Ash.load!(editor, [:authored_page_count, :authored_post_count], authorize?: false)
      assert loaded.authored_page_count == 2
      assert loaded.authored_post_count == 1
    end
  end
end
