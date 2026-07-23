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

    test "accepts same-origin relative paths" do
      admin = user(:admin)

      page =
        CMS.create_page!(
          %{title: "Rel", slug: slug(), canonical_url: "/blog/post", seo_image: "/img/og.png"},
          actor: admin
        )

      assert page.canonical_url == "/blog/post"
      assert page.seo_image == "/img/og.png"
    end

    test "rejects off-scheme and off-origin URLs" do
      admin = user(:admin)

      for bad <- ["javascript:alert(1)", "http://example.com/x", "//evil.com/x", "/a/../../etc"] do
        assert {:error, _} =
                 CMS.create_page(%{title: "Bad", slug: slug(), canonical_url: bad}, actor: admin)
      end
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

  describe "slug derivation" do
    test "create without a slug derives it from the title, stop words stripped" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "A Guide to the Kiln Firing"}, actor: admin)
      assert page.slug == "guide-kiln-firing"
    end

    test "an explicit slug always wins" do
      admin = user(:admin)
      explicit = slug()
      page = CMS.create_page!(%{title: "A Guide to the Kiln", slug: explicit}, actor: admin)
      assert page.slug == explicit
    end

    test "clearing the slug on update regenerates it from the title" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "T", slug: slug()}, actor: admin)

      updated =
        CMS.update_page!(page, %{title: "New Name for the Page", slug: ""}, actor: admin)

      assert updated.slug == "new-name-page"
    end

    test "an untouched slug survives a title-only update" do
      admin = user(:admin)
      original = slug()
      page = CMS.create_page!(%{title: "T", slug: original}, actor: admin)
      updated = CMS.update_page!(page, %{title: "Renamed"}, actor: admin)
      assert updated.slug == original
    end

    test "a title that derives to nothing still requires a slug" do
      admin = user(:admin)
      assert {:error, _} = CMS.create_page(%{title: "!!!"}, actor: admin)
    end

    test "derived slugs dedupe pathauto-style instead of colliding" do
      admin = user(:admin)

      first = CMS.create_page!(%{title: "A Guide to the Kiln Dedupe"}, actor: admin)
      second = CMS.create_page!(%{title: "The Guide to a Kiln Dedupe!"}, actor: admin)
      third = CMS.create_page!(%{title: "Guide to the Kiln Dedupe"}, actor: admin)

      assert first.slug == "guide-kiln-dedupe"
      assert second.slug == "guide-kiln-dedupe-2"
      assert third.slug == "guide-kiln-dedupe-3"
    end

    test "a derived root slug steps around section URLs (a page titled \"Blog\")" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Blog"}, actor: admin)
      assert page.slug == "blog-2"
    end
  end

  describe "root URL collisions" do
    test "an explicit page slug a section route would shadow is rejected" do
      admin = user(:admin)

      assert {:error, error} = CMS.create_page(%{title: "T", slug: "blog"}, actor: admin)
      assert Exception.message(error) =~ "conflicts with the /blog section"

      # Router-owned segments are equally off-limits at the root.
      assert {:error, _} = CMS.create_page(%{title: "T", slug: "search"}, actor: admin)
    end

    test "a post may use a section word as its slug (it lives under /blog/)" do
      admin = user(:admin)
      post = CMS.create_post!(%{title: "T", slug: "blog"}, actor: admin)
      assert post.slug == "blog"
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
    test "counts words across blocks, stripping markup" do
      admin = user(:admin)

      page =
        CMS.create_page!(
          %{
            title: "T",
            slug: slug(),
            blocks: [
              %{type: :heading, content: "Hello world", order: 0},
              %{type: :rich_text, content: "<p>three more words here</p>", order: 1}
            ]
          },
          actor: admin
        )

      # "Hello world" (2) + "three more words here" (4). (The typed v2 block model
      # has no nested `children`; rich prose nests as Portable Text instead.)
      assert %{word_count: 6} = CMS.get_page!(page.id, load: [:word_count], actor: admin)
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
